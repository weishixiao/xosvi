import Foundation

// MARK: - v7.9.0 环境预设 / 镜像（严格对齐 Kelivo 的实现）
//
// 与 Kelivo 的对应关系：
//   EnvironmentDependency        → EnvDependency（6 个预设，包名与探测命令逐字对齐）
//   EnvironmentDependencies      → EnvironmentInstaller（进程内单例，离开页面不中断安装）
//   MirrorEntry / MirrorService  → AlpineMirror / MirrorCatalog
//   MirrorSpeedTest              → MirrorCatalog.speedTest（**在宿主侧**用 Range 请求测，不下发到 guest）
//
// 上一版为什么装不上：
//   1) 探测脚本写成了 printf '%@=' —— Objective-C 的格式符，shell 不认，等于永远探不出来
//   2) 安装直接 apk add --no-cache，没先 apk update；iSH 的 apk 需要先拉索引
//   3) SSH 包名写成 openssh-client，Alpine 里实际是 openssh-client-default
//   4) 测速在 guest 里跑 wget，沙盒没起来时全超时

// MARK: - 环境预设

enum EnvDependency: String, CaseIterable, Identifiable {
    case python, node, git, ssh, network, archive
    var id: String { rawValue }

    var title: String {
        switch self {
        case .python: return "Python"
        case .node: return "Node.js"
        case .git: return "Git"
        case .ssh: return "SSH"
        case .network: return "网络工具"
        case .archive: return "压缩工具"
        }
    }
    var subtitle: String {
        switch self {
        case .python: return "Python、pip 和虚拟环境"
        case .node: return "Node.js 和 npm"
        case .git: return "克隆仓库与版本管理"
        case .ssh: return "SSH、SCP、SFTP 与密钥生成"
        case .network: return "curl · wget"
        case .archive: return "zip · unzip"
        }
    }
    var icon: String {
        switch self {
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node: return "cube"
        case .git: return "point.topleft.down.curvedto.point.bottomright.up"
        case .ssh: return "key"
        case .network: return "globe"
        case .archive: return "archivebox"
        }
    }

    /// 与 Kelivo 完全一致（alpine 分支）
    var packages: String {
        switch self {
        case .python: return "python3 py3-pip py3-virtualenv"
        case .node: return "nodejs npm"
        case .git: return "git"
        case .ssh: return "openssh-client-default"
        case .network: return "curl wget"
        case .archive: return "zip unzip"
        }
    }

    /// 与 Kelivo 完全一致：全部子命令都成功才算装了
    var probe: String {
        switch self {
        case .python: return "python3 --version && python3 -m pip --version && virtualenv --version"
        case .node: return "node --version && npm --version"
        case .git: return "git --version"
        case .ssh: return "ssh -V && command -v scp && command -v sftp && command -v ssh-keygen"
        case .network: return "curl --version && wget --version"
        case .archive: return "zip -v && unzip -v"
        }
    }
}

enum DependencyStatus { case unknown, missing, installed }

enum DependencyFailure { case check, install, cancelled }

// MARK: - 镜像

struct AlpineMirror: Identifiable, Equatable {
    var id: String
    var name: String
    var region: String          // "中国" / "全球"
    var base: String            // https://mirrors.aliyun.com/alpine/

    var displayName: String { region.isEmpty ? name : "\(name) · \(region)" }

    // v7.9.1：iSH guest 的 TLS 握手会挂死（实测：HTTP 正常、HTTPS 一直卡到超时），
    // 所以写进 guest 的源一律降级成 http；宿主侧测速仍用 https。
    // v9.6：写进 /etc/apk/repositories 的**每一行**都必须是 http。
    // 之前只把这些行拼成字符串，sed 只处理行首的 https://，
    // 于是留下 "https://.../main" 与 "http://.../community" 混杂的畸形文件。
    var guestBase: String {
        base.replacingOccurrences(of: "https://", with: "http://")
    }

    func apkIndexURL(alpineVersion: String? = nil) -> URL? {
        URL(string: base + "\(alpineVersion ?? AlpineVersion.branch())/main/\(AlpineVersion.arch())/APKINDEX.tar.gz")
    }
    func pipIndexURL() -> String {
        // v7.9.1：同上，guest 内只能走 http（宿主侧 TLS 正常，这里只影响写进 pip.conf 的值）
        switch id {
        case "pip.aliyun": return "http://mirrors.aliyun.com/pypi/simple"
        case "pip.tuna": return "http://pypi.tuna.tsinghua.edu.cn/simple"
        case "pip.ustc": return "http://mirrors.ustc.edu.cn/pypi/simple"
        default: return "http://pypi.org/simple"
        }
    }
    var npmRegistry: String {
        id == "npm.official" ? "https://registry.npmjs.org" : "https://registry.npmmirror.com"
    }
}

// MARK: - 动态读取 Alpine 分支（v7.14.20）
//
// 原来分支硬编码 "v3.21"，但每个用户的 rootfs 可能来自不同版本：
// 分支对不上时，镜像上该目录不存在 → apk fetch 直接 404 → 安装中止。
// 正确做法：从 rootfs 的 /etc/alpine-release（形如 "3.21.0"）取主次版本拼成 "v3.21"，
// 读不到再保守回退。
enum AlpineVersion {
    /// 缓存：同一个 App 进程内只读一次，避免每次安装都起一个 shell
    private static var cached: String?
    private static var cachedArch: String?

    /// v9.6：iSH 内核跑的是 x86 解释器，包目录是 x86（不是 arm64/aarch64）。
    /// 原来探测与 community 检测都写死 aarch64 → 镜像上 404 → 镜像被误判不可用，
    /// 表现为"测速全部超时 / 安装不动"。这里从 rootfs 真实读取，读不到才回退。
    /// 注意：ISH.run 会阻塞到命令结束，主线程上不能起沙盒（会卡界面），
    /// 所以主线程只返回缓存或回退值，真正的探测在后台线程做。
    static func arch() -> String {
        if let c = cachedArch { return c }
        guard !Thread.isMainThread else { return "x86" }
        let out = ISH.run("apk --print-arch 2>/dev/null || uname -m 2>/dev/null", timeout: 10).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let first = out.split(separator: "\n").first.map(String.init) ?? ""
        let result = (first.isEmpty || first.contains("沙盒")) ? "x86" : first
        cachedArch = result
        return result
    }

    /// v9.6：预热架构缓存（在后台线程调一次，之后主线程也拿得到真实值）
    static func warmArch() {
        guard cachedArch == nil else { return }
        DispatchQueue.global(qos: .utility).async { _ = arch() }
    }

    static func branch() -> String {
        if let c = cached { return c }
        let out = ISH.run("cat /etc/alpine-release 2>/dev/null", timeout: 10).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "v3.20"          // 保守回退（不要回退到具体小版本）
        let parts = out.split(separator: ".")
        if parts.count >= 2, !out.contains("\n") {
            result = "v\(parts[0]).\(parts[1])"
        } else if let major = parts.first, !major.isEmpty, !out.contains("\n") {
            result = "v\(major)"     // 极老版本只有主版本
        }
        cached = result
        return result
    }

    /// 供"重新探测"用（例如重装 rootfs 后版本变了）
    static func reset() { cached = nil }
}

enum MirrorCatalog {
    static let apk: [AlpineMirror] = [
        .init(id: "apk.aliyun", name: "阿里云", region: "中国", base: "https://mirrors.aliyun.com/alpine/"),
        .init(id: "apk.tuna", name: "清华 TUNA", region: "中国", base: "https://mirrors.tuna.tsinghua.edu.cn/alpine/"),
        .init(id: "apk.ustc", name: "中科大", region: "中国", base: "https://mirrors.ustc.edu.cn/alpine/"),
        .init(id: "apk.huawei", name: "华为云", region: "中国", base: "https://repo.huaweicloud.com/alpine/"),
        .init(id: "apk.tencent", name: "腾讯云", region: "中国", base: "https://mirrors.cloud.tencent.com/alpine/"),
        .init(id: "apk.official", name: "官方", region: "全球", base: "https://dl-cdn.alpinelinux.org/alpine/"),
    ]
    static let pip: [AlpineMirror] = [
        .init(id: "pip.aliyun", name: "阿里云", region: "中国", base: ""),
        .init(id: "pip.tuna", name: "清华 TUNA", region: "中国", base: ""),
        .init(id: "pip.ustc", name: "中科大", region: "中国", base: ""),
        .init(id: "pip.official", name: "官方", region: "全球", base: ""),
    ]
    static let npm: [AlpineMirror] = [
        .init(id: "npm.npmmirror", name: "npmmirror", region: "中国", base: ""),
        .init(id: "npm.official", name: "官方", region: "全球", base: ""),
    ]

    static func current(_ kind: String) -> AlpineMirror {
        let key = "mirror.\(kind)"
        let saved = UserDefaults.standard.string(forKey: key)
        let list = kind == "apk" ? apk : (kind == "pip" ? pip : npm)
        return list.first { $0.id == saved } ?? list[0]
    }

    static func setCurrent(_ kind: String, _ m: AlpineMirror) {
        UserDefaults.standard.set(m.id, forKey: "mirror.\(kind)")
    }

    /// 宿主侧测速（Kelivo 的做法）：Range 请求 APKINDEX，比在 guest 里跑 wget 稳
    static func speedTest(_ mirrors: [AlpineMirror], timeout: TimeInterval = 6) -> [(AlpineMirror, Double)] {
        var out: [(AlpineMirror, Double)] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for m in mirrors {
            guard let url = m.apkIndexURL() else { continue }
            group.enter()
            var req = URLRequest(url: url, timeoutInterval: timeout)
            req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let start = CFAbsoluteTimeGetCurrent()
            URLSession.shared.dataTask(with: req) { _, resp, err in
                defer { group.leave() }
                let dt = CFAbsoluteTimeGetCurrent() - start
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard err == nil, code >= 200, code < 400 else { return }
                lock.lock(); out.append((m, dt)); lock.unlock()
            }.resume()
        }
        _ = group.wait(timeout: .now() + timeout + 2)
        return out.sorted { $0.1 < $1.1 }
    }
}

// MARK: - 安装器（进程内单例，离开页面不中断）

final class EnvironmentInstaller: ObservableObject {
    static let shared = EnvironmentInstaller()

    @Published private(set) var statuses: [EnvDependency: DependencyStatus] = [:]
    @Published private(set) var installing: EnvDependency?
    @Published private(set) var lastInstalled: EnvDependency?
    @Published private(set) var failure: DependencyFailure?
    @Published private(set) var log: String = ""
    @Published private(set) var busy = false
    /// v7.14.12：实时进度（阶段 + 已安装包数/百分比）
    @Published private(set) var phase: Phase = .idle
    /// 已完成的包数 / 总数（从 apk 的 (n/m) 里拿）
    @Published private(set) var pkgDone = 0
    @Published private(set) var pkgTotal = 0
    var progressFraction: Double? {
        guard pkgTotal > 0 else { return nil }
        return min(1.0, Double(pkgDone) / Double(pkgTotal))
    }

    private var queue = DispatchQueue(label: "env.installer", qos: .userInitiated)

    func status(_ d: EnvDependency) -> DependencyStatus { statuses[d] ?? .unknown }

    // MARK: 探测

    /// 一次 shell 把 6 个都探完（用醒目的标记，避免和命令自身输出混在一起）
    func refresh(completion: (() -> Void)? = nil) {
        guard !busy else { completion?(); return }
        busy = true
        let script = EnvDependency.allCases.map { d in
            "if ( \(d.probe) ) >/dev/null 2>&1; then echo '__envdep_\(d.rawValue)=1'; "
            + "else echo '__envdep_\(d.rawValue)=0'; fi"
        }.joined(separator: "\n")

        queue.async {
            let r = ISH.run(script, timeout: 60)
            var map: [EnvDependency: DependencyStatus] = [:]
            for line in r.output.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("__envdep_"), let eq = t.firstIndex(of: "=") else { continue }
                let key = String(t[t.index(t.startIndex, offsetBy: 9)..<eq])
                let val = String(t[t.index(after: eq)...])
                if let d = EnvDependency(rawValue: key) {
                    map[d] = (val == "1") ? .installed : .missing
                }
            }
            DispatchQueue.main.async {
                self.statuses = map
                self.busy = false
                if map.isEmpty { self.failure = .check }
                completion?()
            }
        }
    }

    // MARK: 安装

    func install(_ d: EnvDependency) {
        guard installing == nil else { return }
        // v7.14.18：照 Kelivo 的守卫——沙盒没 ready 就别进安装流程
        // （Kelivo: `if (busy || !supportsPackages || env.state.phase != ready) return;`）
        if ISH.boot() != 0 {
            failure = .install
            log = "沙盒未就绪：\(ISH.lastError ?? "boot 失败")。请到 设置 → 环境 先启动/修复沙盒。"
            phase = .failed
            return
        }
        installing = d
        failure = nil
        log = ""
        phase = .idle
        pkgDone = 0
        pkgTotal = 0

        queue.async {
            var logLines: [String] = []
            Self.setPhase(.writingMirror, notify: self)
            // 先把当前选择的 APK 源写进去（Kelivo 也是先应用源再装）
            // v7.9.1：分支从 rootfs 真实版本读（原来硬编码 v3.21 → 404）
            let branch = AlpineVersion.branch()
            // v7.9.1：先按 http 逐个镜像实测，选第一个真能拉到索引的。
            // 之前直接用当前镜像的 https 地址 —— iSH 的 TLS 挂死，表现为
            // "fetch 发出后无响应直到 30 分钟超时"，用户看到的就是装了永远不动。
            let preferred = MirrorCatalog.current("apk")
            let candidates = [preferred] + MirrorCatalog.apk.filter { $0.id != preferred.id }
            var mirror = preferred
            // v9.6：架构从 rootfs 实际读（iSH 是 x86），原来写死 aarch64 → 索引 404
            let arch = AlpineVersion.arch()
            for candidate in candidates.prefix(5) {
                let probeURL = candidate.guestBase + "\(branch)/main/\(arch)/APKINDEX.tar.gz"
                let probe = ISH.run(
                    "wget -q -O /dev/null --timeout=6 --tries=1 '\(probeURL)' && echo __MIRROR_OK || echo __MIRROR_FAIL",
                    timeout: 20, cwd: "/")
                if probe.output.contains("__MIRROR_OK") {
                    mirror = candidate
                    break
                }
            }
            if mirror.id != preferred.id {
                MirrorCatalog.setCurrent("apk", mirror)
                logLines.append("[env] 镜像自动切换：\(preferred.name) → \(mirror.name)（http）")
            }
            let repoMain = mirror.guestBase + "\(branch)/main"
            let repoComm = mirror.guestBase + "\(branch)/community"
            _ = ISH.run("""
            mkdir -p /etc/apk
            old=$(cat /etc/apk/repositories 2>/dev/null)
            printf '%s\n' '\(repoMain)' > /etc/apk/repositories
            printf '%s\n' '\(repoComm)' >> /etc/apk/repositories
            if [ "$old" != "$(cat /etc/apk/repositories)" ]; then
              rm -f /var/cache/apk/APKINDEX.*.tar.gz
              echo "[env] 镜像源已切换（\(branch)），清空旧索引缓存"
            fi
            """, timeout: 25)

            // v7.14.7：先清残锁。iSH 内核里的 apk 进程被强杀/沙盒重启后，
            // /lib/apk/db/lock 可能留下"无人持有但 apk 认为被占"的状态，
            // 表现为一直卡在 "Waiting for repository lock"。
            // 用 flock -n 判定：能拿到 = 确实没人持有 → 删除锁文件重来。
            _ = ISH.run("""
            if command -v flock >/dev/null 2>&1; then
              if flock -n /lib/apk/db/lock true 2>/dev/null; then
                rm -f /lib/apk/db/lock
                echo "[env] 清理残留 apk 锁"
              fi
            fi
            """, timeout: 20)

            // 与 Kelivo 一致：先 update 再 add，--wait 等锁
            // v7.14.9：分步执行并把每一步的耗时/退出码写进日志。
            // 之前一条 script 跑完只见两行 fetch 就"取消"，无法判断是 update 卡住、
            // apk 被信号打断，还是沙盒中途重启——现在日志里能直接看出是哪一步。
            // v7.14.16：完全照 Kelivo 的做法（environment_dependencies.dart:96）
            //   installScript = 'set -e\napk --wait 60 update\napk --wait 60 add $packages\n'
            //   cwd = '/'，timeout = 30 分钟，**一条脚本跑完**，不拆步、不预探、不跳过 update。
            // 之前我加了"索引探测/跳过 update/分阶段"，反而引入了 430s 卡死与换源逻辑混乱。
            // 先回到 Kelivo 的原样实现，把可靠性交给 apk 自己的 --wait 与 30 分钟上限。
            // v7.14.16：先做 15 秒网络自检，把实际情况写进日志。
            // 之前在 App 里表现为"fetch 发出后无响应直到超时"，但同一台机器 shell 里 2~3s 就成功，
            // 需要先拿到 DNS / 直连 / 代理三个层面的证据，而不是继续猜。
            Self.setPhase(.updatingIndex("网络自检"), notify: self)
            // 用单行命令，避免多层转义；每项都单独带标记，便于从日志一眼看出是哪层断了
            let diagCmd = [
                "echo '[diag] resolv:'; cat /etc/resolv.conf 2>&1 | head -3",
                "echo '[diag] dns:'; nslookup mirrors.aliyun.com 2>&1 | grep -i addr | head -3",
                "echo '[diag] route:'; cat /proc/net/route 2>&1 | head -2",
                "echo '[diag] branch:'; cat /etc/alpine-release 2>&1",
                "echo '[diag] wget:'; wget -q -O /dev/null --timeout=8 --tries=1 '\(repoMain)/\(AlpineVersion.arch())/APKINDEX.tar.gz' && echo OK || echo FAIL",
            ].joined(separator: "; ")
            let diag = ISH.run(diagCmd, timeout: 45, cwd: "/")
            logLines.append(diag.output)
            logLines.append("[env] 自检 exit=\(diag.exitCode) timedOut=\(diag.timedOut)")

            Self.setPhase(.updatingIndex(""), notify: self)
            // v7.14.20：community 只存在于部分镜像/部分版本。它的 404 不应中止安装。
            // 原来整条脚本在 `set -e` 下执行，community 一旦拉不到就整条退出，
            // 表现正是"日志里 fetch 出两行后戛然而止"。
            // 现在：main 是硬要求（set -e 只覆盖它），community 拉不到只记一行日志。
            // v7.9.3：**先挂 community 再装**。
            // 原来顺序是「先装 → 再尝试加 community」，而 py3-pip / py3-virtualenv
            // 这类包装在 community，main 里没有 → apk 直接报
            // "py3-pip (no such package): required by: world[py3-pip]" 整单失败。
            // 现在：先探 community 索引，可达就一起写进 repositories，再 update + add。
            let script = """
            set -e
            # v9.6：架构取真实值（iSH=x86），并清掉上次强杀留下的 apk 锁，
            # 否则 apk 会一直停在 "Waiting for repository lock"。
            ARCH=$(apk --print-arch 2>/dev/null || uname -m)
            rm -f /lib/apk/db/lock
            printf '%s\n' '\(repoMain)' > /etc/apk/repositories
            if wget -q -O /dev/null --timeout=10 "\(repoComm)/$ARCH/APKINDEX.tar.gz"; then
              printf '%s\n' '\(repoComm)' >> /etc/apk/repositories
              echo '[env] community 源可用，已加入'
            else
              echo '[env] community 源不可达（py3-pip 等包可能缺失）'
            fi
            if ! wget -q -O /dev/null --timeout=10 "\(repoMain)/$ARCH/APKINDEX.tar.gz"; then
              echo '[env] main 源 https 不通，降级 http 重试'
              sed -i 's|^https://|http://|' /etc/apk/repositories
            fi
            apk --wait 60 update
            apk --wait 60 add \(d.packages)
            """
            let r = ISH.runStreaming(script, timeout: 1800, cwd: "/",
                                     onChunk: { text in self.consume(text) })
            logLines.append(r.output)
            logLines.append("[env] exit=\(r.exitCode) timedOut=\(r.timedOut)")

            // 装完立刻复查这一项（不靠返回值猜）
            Self.setPhase(.verifying, notify: self)
            let verify = ISH.run("if ( \(d.probe) ) >/dev/null 2>&1; then echo 1; else echo 0; fi", timeout: 60)
            let ok = verify.output.contains("1")

            DispatchQueue.main.async {
                self.log = r.output
                self.installing = nil
                if ok {
                    self.statuses[d] = .installed
                    self.lastInstalled = d
                    self.phase = .done
                    self.pkgDone = self.pkgTotal
                } else {
                    self.phase = .failed
                    self.statuses[d] = .missing
                    // v7.14.9：原来靠 `output.contains("cancel")` 猜状态——apk 在某些失败/中断的
                    // 输出里也带 "cancel"，于是任何失败都会被说成"安装已取消"，误导排查。
                    // 现在按**真实结果**判定：超时 / 非零退出 / 探测仍未通过。
                    if r.timedOut {
                        self.failure = .cancelled
                        self.log = r.output + "\n[env] 安装超时（apk 等待锁或网络过慢），已中止"
                    } else if r.exitCode != 0 {
                        self.failure = .install
                    } else {
                        self.failure = .install
                        self.log = r.output + "\n[env] apk 返回成功但探测未通过（包可能已装，命令名不一致）"
                    }
                }
            }
        }
    }

    /// 解析流式输出：拆行→推阶段→累计 (n/m) 进度。
    /// 在后台队列被调用，UI 更新一律抛回主线程。
    private func consume(_ text: String) {
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let p = Self.phase(from: line) {
                DispatchQueue.main.async { self.phase = p }
            }
            // (3/12) 形式：更新 done/total
            if let open = line.firstIndex(of: "("), let slash = line.firstIndex(of: "/") {
                let doneStr = line[line.index(after: open)..<slash]
                let rest = line[slash...].dropFirst()
                if let close = rest.firstIndex(of: ")"),
                   let done = Int(doneStr), let total = Int(rest[..<close]) {
                    DispatchQueue.main.async {
                        self.pkgDone = done
                        self.pkgTotal = total
                    }
                }
            }
        }
    }

    private static func setPhase(_ p: Phase, notify: EnvironmentInstaller) {
        DispatchQueue.main.async { notify.phase = p }
    }

    /// v7.14.12：安装进度（给 UI 的实时状态）
    enum Phase: Equatable {
        case idle
        case writingMirror          // 写入镜像源
        case checkingIndex          // 检查索引
        case updatingIndex(String)  // 拉取索引（显示已下载字节）
        case downloading(String)    // 下载包（显示包名/字节）
        case installing(String)     // 安装/配置
        case verifying              // 校验命令
        case done
        case failed

        var text: String {
            switch self {
            case .idle: return "准备中"
            case .writingMirror: return "写入镜像源"
            case .checkingIndex: return "检查包索引"
            case .updatingIndex(let d): return d.isEmpty ? "拉取包索引…" : "拉取包索引  \(d)"
            case .downloading(let d): return d.isEmpty ? "下载安装包…" : "下载安装包  \(d)"
            case .installing(let d): return d.isEmpty ? "安装中…" : "安装中  \(d)"
            case .verifying: return "校验安装结果"
            case .done: return "完成"
            case .failed: return "失败"
            }
        }

        var isTerminal: Bool { self == .done || self == .failed }
    }

    /// 从 apk 的输出行推断当前阶段（apk 的输出格式稳定：fetch / (n/m) Upgrading|Installing）
    static func phase(from line: String) -> Phase? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if t.hasPrefix("fetch ") {
            return .updatingIndex("")
        }
        if t.contains("Installing ") || t.contains("Upgrading ") || t.contains("Replacing ") {
            // (3/12) Installing python3 (3.12.15-r0)
            if let open = t.firstIndex(of: "("), let slash = t.firstIndex(of: "/") {
                let done = t[t.index(after: open)..<slash]
                let rest = t[slash...].dropFirst()
                if let close = rest.firstIndex(of: ")") {
                    return .installing("[\(done)/\(rest[..<close])]  \(t.split(separator: " ").dropFirst(2).first ?? "")")
                }
            }
            return .installing("")
        }
        if t.hasPrefix("Executing busybox") || t.hasPrefix("OK:") { return .installing("") }
        if t.contains("ERROR") || t.hasPrefix("WARNING") { return nil }
        return nil
    }

/// 安装失败时给人看的解释
    func diagnose(_ d: EnvDependency) -> String {
        let l = log.lowercased()
        if l.contains("no space") { return "沙盒空间不足" }
        if l.contains("network") || l.contains("unable to select") || l.contains("temporary failure")
            || l.contains("could not connect") { return "拉不到软件源，换一个镜像再试" }
        if l.contains("unable to lock") || l.contains("waiting for repository lock") {
            return "apk 锁被占用或残留：点「重新安装」会自动清一次残留锁；仍不行就重启 iSH 沙盒后再试"
        }
        if l.contains("apk: not found") || l.contains("/sbin/apk") && l.contains("no such file") {
            return "沙盒里没有 apk，说明 rootfs 不完整：到 设置 → 环境 页重装 rootfs"
        }
        if l.isEmpty { return "安装失败，没拿到输出（沙盒可能未启动，见 设置 → 环境 → 沙盒状态）" }
        return String(log.suffix(300))
    }
}
