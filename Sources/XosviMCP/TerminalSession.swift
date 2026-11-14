import Foundation
import Combine
import ISHBridge

// MARK: - v9.13 本地终端（Apple 风格终端页的数据层）
//
// 设计参考 OpenMinis 的终端页：整页终端 + 顶部会话标签 + 底部键盘工具条。
// OpenMinis 用 guest PTY 做真交互 shell；本项目的 iSH 桥接（Sources/ISHBridge）
// 没有 PTY 支持，因此这里改成分轮次执行：
//   · 每次回车 → `cd <cwd> && ( <命令> ) 2>&1; echo <哨兵>$?`
//   · stdout/stderr 经 KelivoISHExecutor 的 chunk 回调实时上屏
//   · 拦到哨兵行就取退出码、显示新提示符，并回写 cwd
// 因此 vim/top 这类需要裸终端（raw mode）的交互程序不可用；shell 内建 cd 会被
// 转成 cwd 跟踪（否则显示结果和真实目录会不一致）。
//
// 线程模型：KelivoISHExecutor 的 chunk/done 回调在后台线程，这里一律
// DispatchQueue.main.async 再改 @Published，避免 SwiftUI 后台发布警告。

/// 终端后端（v10.6：由三个合成两个）
///
/// - `alpine`：iSH 沙盒里的 Linux（有 apk / python3 / git），看不到 iOS 真实文件系统；
/// - `ios`：本机原生 shell，直接读写真实文件系统。**身份**由会话的 `elevated` 决定：
///   false = mobile（App 自己 fork），true = uid 0（经 root 守护 xosvid 执行）。
///
/// v10.5 曾把 root 单列成第三个后端，但它和「本机」是同一套 shell、同一套路径，
/// 只有 uid 不同——两个分段等于让用户在选择「同一个东西的两遍」，还多出一堆
/// `backend == .root` 分支。现在合并成「本机」+ 一个 su 开关。
enum TermBackend: String, CaseIterable, Identifiable {
    case alpine
    case ios
    var id: String { rawValue }
    var title: String {
        switch self {
        case .alpine: return L10n.t("term_backend_alpine")
        case .ios: return L10n.t("term_backend_ios")
        }
    }
    /// 分段条上的短标签（宽顶栏放不下整句译名）
    var shortTitle: String {
        switch self {
        case .alpine: return "Alpine"
        case .ios: return "本机"
        }
    }
    /// 该后端的家目录：切换后端时 cwd 必须跟着走，否则提示符会停在另一个根里
    var home: String {
        switch self {
        case .alpine: return "/root"
        case .ios: return "/var/mobile"
        }
    }
    /// 只有 ios 走本机原生执行链（cd 要按原生路径解析，不能用 guest 的 pwd）
    var isNative: Bool { self != .alpine }
}

// v10.4：值类型。
// 原来 TermLine 是 class，`append` 里 `last.text += text` 改的是对象本身，数组没有任何写入，
// @Published 的 objectWillChange 不会发 —— 流式输出只能等 running 变化或用户敲键盘时才顺带刷新，
// 看上去就像「命令没有输出 / 终端卡住」。换成 struct 后下标写会触发发布。
struct TermLine: Identifiable, Equatable {
    enum Kind {
        case output      // 普通输出（含 stderr）
        case command     // 用户输入的命令行回显
        case notice      // 本地提示（连接状态 / 报错）
        case prompt      // 会话启动横幅
    }
    let id = UUID()
    var text: String
    var kind: Kind

    init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }

    static func == (lhs: TermLine, rhs: TermLine) -> Bool { lhs.id == rhs.id }
}

final class TermSession: Identifiable, ObservableObject {
    let id = UUID()
    @Published var title: String
    @Published var lines: [TermLine] = []
    @Published var cwd: String = "/root"
    /// 当前是否有命令在跑（决定停止按钮是否可用、输入是否排队）
    @Published var running = false
    @Published var lastExit: Int32 = 0
    /// v10.5：当前会话跑在哪个后端（v9.13：ios = 直接 fork iOS 原生 shell，alpine = iSH 沙盒）
    @Published var backend: TermBackend = .alpine
    /// v10.6：本机后端的执行身份。false = mobile（App 直接 fork），true = uid 0（经 root 守护）。
    /// 合并前这是独立的第三个后端 `.root`，但它只是「本机」换了 uid，路径与执行链完全相同。
    @Published var elevated: Bool = false

    /// 本机后端 + root 身份：runInGuest / prompt / banner 到处要用，收成一个判断
    var isRoot: Bool { backend == .ios && elevated }

    private(set) var runId: String?
    /// iOS 原生后端当前子进程（停止时 kill）
    private var iosPid: pid_t = 0
    /// v10.4：这一轮是用户主动停的 —— 收尾时按「已停止」处理，
    /// 不再补一行「退出码 -15」这类噪声。
    private var stoppedByUser = false
    /// 命令行历史（上下箭头翻）
    private(set) var history: [String] = []

    /// 输出上限：终端页长时间跑 cat 大文件时不至于把内存和 SwiftUI 拖死
    private let maxLines = 3000

    init(title: String = "终端") {
        self.title = title
    }

    // MARK: 输出

    func append(_ text: String, kind: TermLine.Kind) {
        guard !text.isEmpty else { return }
        // 下标写（而不是改对象）才会让 @Published 发通知
        if kind == .output, let idx = lines.indices.last, lines[idx].kind == .output {
            lines[idx].text += text
        } else {
            lines.append(TermLine(text: text, kind: kind))
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    /// 流式 chunk 可能切开多字节 UTF-8 / 把一行拆成几块：直接拼接即可，
    /// 终端本来就按字面显示，不做行重排。
    func appendChunk(_ text: String) {
        append(text, kind: .output)
    }

    // MARK: 命令

    /// 把用户输入的命令交给 guest 执行。
    /// - Parameters:
    ///   - raw: 用户敲的原文（用于历史与回显）
    ///   - record: 是否写进历史（重放的命令不再写）
    func submit(_ raw: String, record: Bool = true) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if running {
            append(L10n.t("term_busy") + "\n", kind: .notice)
            return
        }
        if record, history.last != trimmed {
            history.append(trimmed)
            if history.count > 200 { history.removeFirst(history.count - 200) }
        }
        append("\(promptText) \(trimmed)\n", kind: .command)

        // shell 内建 cd：不在 guest 里执行，直接改 cwd（否则真实目录与显示不一致）
        if let dir = Self.parseCD(trimmed, home: homeDir) {
            applyCD(dir, original: trimmed)
            return
        }
        if trimmed == "clear" || trimmed == "cls" {
            lines.removeAll()
            return
        }
        runInGuest(trimmed)
    }

    private func runInGuest(_ command: String) {
        if backend == .ios {
            // v10.6：同一套原生 shell，按身份选执行链（mobile 直接 fork / uid 0 交守护）
            if elevated { runInRoot(command) } else { runIniOS(command) }
            return
        }
        // v10.4：boot 不能留在主线程 —— KelivoISHKernel 的契约是「在后台线程 boot」
        // （它会成为 guest PID 1）。旧实现在按钮回调里同步 boot：首次敲命令就卡界面，
        // 缺 rootfs 时还要现场装一遍，几秒钟白屏，严重时被系统 watchdog 杀掉。
        if ISH.isBooted {
            startGuestRun(command)
            return
        }
        running = true
        lastExit = 0
        append(L10n.t("term_boot_hint") + "\n", kind: .notice)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rc = ISH.boot()
            let err = ISH.lastError
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard rc == 0 else {
                    self.running = false
                    self.append((err ?? "沙盒启动失败 rc=\(rc)") + "\n", kind: .notice)
                    return
                }
                // boot 期间用户按了停止：这条命令不再执行
                guard self.running, self.runId == nil else { return }
                self.startGuestRun(command)
            }
        }
    }

    /// guest 里真正的一次执行（boot 完成之后）
    private func startGuestRun(_ command: String) {
        let runId = UUID().uuidString
        self.runId = runId
        running = true
        lastExit = 0
        stoppedByUser = false

        // 哨兵：唯一、不会被用户输出自然命中的串
        let marker = "__XOSVI_RC_\(runId.replacingOccurrences(of: "-", with: ""))__"
        let quotedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        // cd 失败也要继续执行命令：用 `|| true` 吞掉，命令自身的结果才是退出码
        let script = "cd '\(quotedCwd)' 2>/dev/null || true; ( \(command) ) 2>&1; __xosvi_rc=$?; echo \"\(marker)$__xosvi_rc\""

        var pending = ""   // 跨 chunk 的半行缓冲，用来找哨兵

        _ = KelivoISHExecutor.startCommand(
            script,
            runId: runId,
            binds: [],
            cwd: cwd,
            env: nil,
            // 有上限：死循环（如 `yes`）不会把 App 挂死 1 小时，到点按超时收尾
            timeoutMs: 3600 * 1000,
            keepStdinOpen: false,
            started: {},
            chunk: { [weak self] _, _, data in
                var text = String(data: data, encoding: .utf8) ?? ""
                if text.isEmpty { return }
                // 去掉哨兵在实时输出里可能泄漏的部分（块边界切开的半截）
                if let r = text.range(of: "__XOSVI_RC_") { text = String(text[..<r.lowerBound]) }
                let payload = text
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    pending += payload
                    // 哨兵可能分块到达：留最后 (marker 长度 + 6) 个字符不输出
                    let keep = marker.count + 6
                    if pending.count > keep {
                        let cut = pending.index(pending.endIndex, offsetBy: -keep)
                        let head = String(pending[..<cut])
                        pending = String(pending[cut...])
                        self.appendChunk(head)
                    }
                }
            },
            done: { [weak self] dict in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // 收尾：把缓冲里剩下的、哨兵之前的正文吐出来
                    var tail = pending
                    var code: Int32 = (dict["exitCode"] as? NSNumber)?.int32Value ?? -1
                    if let r = tail.range(of: marker) {
                        let after = tail[r.upperBound...]
                        let digits = after.prefix { $0 == "-" || ($0 >= "0" && $0 <= "9") }
                        if let v = Int32(digits) { code = v }
                        tail = String(tail[..<r.lowerBound])
                    }
                    if !tail.isEmpty { self.appendChunk(tail) }
                    pending = ""
                    self.finishRun(code: code, runId: runId, dict: dict)
                }
            })
    }

    // MARK: iOS 原生后端
    //
    // posix_spawn `<可用 shell> -c`，输出经共享 fd + DispatchSource 实时上屏。
    // 与 Alpine 后端的差别：命令读写的是真实文件系统，且没有 apk/python（本机没装）。
    //
    // v10.4：原来写死 `/bin/sh`（注释还写着「本机 /bin/sh 真实存在」）—— iOS 根本不带 sh，
    // 于是本机后端每条命令都只回一行「无法启动 shell：errno 2」，cd 也一并失效。
    // 现在改为运行期解析：真机 /bin/sh → rootless /var/jb/usr/bin/sh → roothide <jbroot>/usr/bin/sh。
    private func runIniOS(_ command: String) {
        guard let shell = JBEnvironment.nativeShellPath else {
            running = false
            append(L10n.t("term_native_no_shell") + "\n", kind: .notice)
            return
        }
        running = true
        lastExit = 0
        stoppedByUser = false
        let quotedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let wrapped = "cd '\(quotedCwd)' 2>/dev/null || true; ( \(command) ) 2>&1"

        var args = [strdup(shell), strdup("-c"), strdup(wrapped)]
        args.append(nil)
        var env = [strdup("PATH=" + ShellExecTool.effectivePATH),
                   strdup("HOME=/var/mobile"),
                   strdup("TERM=dumb"),
                   strdup("LANG=" + (Locale.preferredLanguages.first ?? "en_US") + ".UTF-8")]
        env.append(nil)

        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            running = false
            append(L10n.t("term_spawn_failed", "pipe") + "\n", kind: .notice)
            args.forEach { free($0) }
            env.forEach { free($0) }
            return
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, shell, &actions, nil, args, env)
        posix_spawn_file_actions_destroy(&actions)
        close(fds[1])
        args.forEach { free($0) }
        env.forEach { free($0) }

        guard rc == 0 else {
            close(fds[0])
            running = false
            append(L10n.t("term_spawn_failed", "errno \(rc)") + "\n", kind: .notice)
            return
        }
        iosPid = pid

        let readFD = fds[0]
        let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: .global(qos: .userInitiated))
        var buf = [UInt8](repeating: 0, count: 16384)
        source.setEventHandler { [weak self] in
            let n = read(readFD, &buf, buf.count)
            if n > 0 {
                let data = Data(bytes: buf, count: n)
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // 非 UTF-8 字节按替换字符处理，绝不丢输出
                    var s = String(data: data, encoding: .utf8) ?? ""
                    if s.isEmpty { s = String(decoding: data, as: UTF8.self) }
                    self.appendChunk(s)
                }
            } else if n == 0 {
                source.cancel()
            } else if errno != EINTR && errno != EAGAIN {
                // v10.4：读失败时不再空转（原来只处理 n==0，n<0 会让可读事件反复触发占满 CPU）
                source.cancel()
            }
        }
        source.setCancelHandler {
            close(readFD)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code: Int32 = (status & 0x7F) == 0 ? ((status >> 8) & 0xFF) : -((status & 0x7F))
            DispatchQueue.main.async { [weak self] in
                self?.iosPid = 0
                self?.finishRun(code: code, runId: "", dict: [:])
            }
        }
        source.resume()
    }

    // MARK: root 后端（v10.5）
    //
    // 本机后端以 mobile 身份跑，拿不到 uid=0。真正的 root 身份走设备上已有的 root 守护：
    // 用 `<bootstrap>/usr/bin/xosvi-cli` 把命令交给 xosvid（MachService wiki.qaq.xosvi.service，
    // 以 root 启动的 LaunchDaemon），它再以 root 执行 `xosvi-build --exec <cwd> <命令>`。
    //
    // 两点必须记住：
    //   ① 必须走子进程（cli），不要在 App 里直接用 libxpc 连守护 —— 本机那条路有
    //      EXC_GUARD / LIBXPC 的崩溃史（见 XosviXPC.swift 的长注释）。
    //   ② cli 的 `helper <name> <project-dir> [args...]` 会把第三个参数**原样透传**，
    //      所以 `--exec` 要放在 project-dir 的位置上（实测：放后面会被当成脚本名）。
    //
    // 代价：cli 一次性返回，没有流式输出；命令跑完才整段上屏。
    static let rootCLIPath: String? = JBEnvironment.firstExistingPath("/usr/bin/xosvi-cli")

    private func runInRoot(_ command: String) {
        guard Self.rootCLIPath != nil else {
            running = false
            append(L10n.t("term_root_unavailable") + "\n", kind: .notice)
            return
        }
        running = true
        lastExit = 0
        stoppedByUser = false

        let quotedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        // cwd 两种视图都试一次；都不存在就留在守护的默认目录里，命令照跑。
        // 末尾塞哨兵：xosvi-build 会再打一行 [exit N]，用它取真实退出码。
        let script = "cd '\(quotedCwd)' 2>/dev/null || true; ( \(command) ) 2>&1; "
            + "__xosvi_rc=$?; echo \"__XOSVI_ROOT_RC__$__xosvi_rc\"; exit $__xosvi_rc"

        rootRun(script, timeout: 3600) { [weak self] code, text, timedOut in
            guard let self = self else { return }
            if !text.isEmpty { self.appendChunk(text) }
            self.finishRun(code: code, runId: "",
                           dict: timedOut ? ["timedOut": NSNumber(value: true)] : [:])
        }
    }

    /// 把一段脚本交给 root 守护执行，回调一律在主线程。
    /// - Note: 一次性返回，没有流式输出（cli 收齐守护的 stdout 才打印）。
    private func rootRun(_ script: String, timeout: TimeInterval,
                         completion: @escaping (Int32, String, Bool) -> Void) {
        guard let cli = Self.rootCLIPath else {
            completion(127, L10n.t("term_root_unavailable") + "\n", false)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let res = BuildRunner.shared.run(
                executable: cli,
                args: ["helper", "xosvi-build", "--exec", XDirs.work, script],
                timeout: timeout)
            let raw = res.stdout.isEmpty ? res.stderr : res.stdout
            let parsed = Self.parseRootOutput(raw)
            let code = parsed.code ?? res.exitCode
            DispatchQueue.main.async { completion(code, parsed.text, res.timedOut) }
        }
    }

    /// root 守护跑在 bootstrap 视图里：`pwd` 给 `/rootfs/private/var/mobile/…`，
    /// App 侧看到的是同一个目录的 `/var/mobile/…`。只把这一对前缀折成 App 写法，
    /// 其余（bootstrap 自己的 /usr 等）原样保留 —— 折了反而 cd 不回去。
    static func normalizeRootPath(_ p: String) -> String {
        var s = p
        if s == "/rootfs" { return "/" }
        if s.hasPrefix("/rootfs/") { s = String(s.dropFirst("/rootfs".count)) }
        if s == "/private/var" { return "/var" }
        if s.hasPrefix("/private/var/") { s = String(s.dropFirst("/private".count)) }
        return s
    }

    /// 从 `xosvi-cli` 的文本输出里剥出命令本身的输出与退出码。
    ///
    /// cli 的格式（xosvi-cli.c / xosvi-build.c）：
    ///   status: OK … exit_code: N
    ///   --- stdout ---
    ///   bootstrap=… shell=… uid=0 cwd=…      ← xosvi-build 的诊断头，丢掉
    ///   <命令输出>
    ///   __XOSVI_ROOT_RC__<rc>
    ///   [exit <rc>]
    static func parseRootOutput(_ raw: String) -> (text: String, code: Int32?) {
        guard let marker = raw.range(of: "--- stdout ---") else {
            // 通道层失败（连不上守护）：cli 的报错本来就在这段文本里，原样给用户
            let msg = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return (msg.isEmpty ? "" : msg + "\n", nil)
        }
        var body = String(raw[marker.upperBound...])
        // 去掉 xosvi-build 的 4 行诊断头（只在最前面，且只认这几种前缀）
        var lines = body.components(separatedBy: "\n")
        var i = 0
        while i < lines.count && i < 8 {
            let l = lines[i]
            if l.isEmpty { i += 1; continue }
            if l.hasPrefix("bootstrap=") || l.hasPrefix("shell=")
                || l.hasPrefix("uid=") || l.hasPrefix("cwd=") {
                lines.remove(at: i)
                continue
            }
            break
        }
        body = lines.joined(separator: "\n")

        var code: Int32?
        if let rc = body.range(of: "__XOSVI_ROOT_RC__") {
            let digits = body[rc.upperBound...].prefix { $0 == "-" || ($0 >= "0" && $0 <= "9") }
            if let v = Int32(digits) { code = v }
            body = String(body[..<rc.lowerBound])
        }
        if let ex = body.range(of: "[exit ", options: .backwards) {
            if code == nil {
                let digits = body[ex.upperBound...].prefix { $0 == "-" || ($0 >= "0" && $0 <= "9") }
                if let v = Int32(digits) { code = v }
            }
            body = String(body[..<ex.lowerBound])
        }
        while body.hasSuffix("\n\n") { body.removeLast() }
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
        return (body, code)
    }

    private func finishRun(code: Int32, runId: String, dict: [String: Any]) {
        running = false
        self.runId = nil
        lastExit = code
        // v10.4：用户主动停止也算 cancelled —— 否则本机后端 kill 之后会再补一行「退出码 -15」
        let cancelled = stoppedByUser || ((dict["cancelled"] as? NSNumber)?.boolValue ?? false)
        stoppedByUser = false
        let timedOut = (dict["timedOut"] as? NSNumber)?.boolValue ?? false
        if cancelled {
            append(L10n.t("term_stopped") + "\n", kind: .notice)
        } else if timedOut {
            append(L10n.t("term_timeout") + "\n", kind: .notice)
        }
        // 末尾没换行时补一个，保证下一次输入从新行开始
        if let idx = lines.indices.last, lines[idx].kind == .output, !lines[idx].text.hasSuffix("\n") {
            lines[idx].text += "\n"
        }
        if code != 0 && !cancelled {
            append(L10n.t("term_exit_code", Int(code)) + "\n", kind: .notice)
        }
        // 命令可能自己 cd 过：同步一次真实 pwd（异步，不动 running 状态）
        syncCwd()
    }

    /// 命令里可能含 cd（如 `cd /tmp && ls`）：跑完取一次真实 pwd
    private func syncCwd() {
        if backend == .ios {
            // v9.14：原先不论后端都去问 guest 要 pwd，本机后端跑完拿回来的是
            // Alpine 的路径，提示符就跳回沙盒了。本机后端自己算。
            // v10.6：root 身份交给守护侧解析（权限与视图都跟 App 侧不同）。
            let script = "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null && pwd"
            if elevated {
                resolveCwdRoot(script, original: "")
            } else {
                resolveCwdNative(script, original: "")
            }
            return
        }
        _ = KelivoISHExecutor.startCommand(
            "pwd",
            runId: UUID().uuidString,
            binds: [],
            cwd: cwd,
            env: nil,
            timeoutMs: 5000,
            keepStdinOpen: false,
            started: {},
            chunk: { _, _, data in
                guard let s = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if p.hasPrefix("/") { self.cwd = p }
                }
            },
            done: { _ in })
    }

    func stop() {
        if isRoot {
            // 守护侧的命令在另一个进程里跑，cli 只能等它结束 —— 这里杀不到，也不谎报「已停止」。
            if running { append(L10n.t("term_root_no_stop") + "\n", kind: .notice) }
            return
        }
        if iosPid > 0 {
            // v10.4：「已停止」交给收尾的 finishRun 统一写一行（原来这里再加一次 = 两行）
            stoppedByUser = true
            kill(iosPid, SIGTERM)
            kill(iosPid, SIGKILL)
            iosPid = 0
            running = false
            return
        }
        if let runId = runId {
            _ = KelivoISHExecutor.cancelRunId(runId)
        }
        // v10.4：boot 阶段（runId 还没建立）也要能停下；旧实现在这里直接 return，
        // 「正在启动沙盒」时按停止毫无反应。
        running = false
    }

    /// v9.14：切换后端。
    ///
    /// 旧实现只是把 `backend` 改掉：cwd 还停在上一个后端的路径上（/root 在本机视图里
    /// 不存在、/var/mobile 在 guest 里也不存在），于是「cd 失败 → 命令照跑」，
    /// 看上去就像切换没生效；正在跑的进程也不会被收掉。
    /// 这里一次做完三件事：停掉当前进程、cwd 归位到新后端的家目录、写一行提示。
    func switchBackend(to target: TermBackend) {
        guard backend != target else { return }
        if running {
            stop()
        }
        backend = target
        // v10.6：离开「本机」就退回 mobile 身份——Alpine 里没有 uid 这回事，
        // 回到本机时也不该悄悄还是 root（用户看得见的开关才算数）。
        if target != .ios { elevated = false }
        cwd = target.home
        append(L10n.t("term_backend_switched", target.title) + "\n", kind: .notice)
    }

    /// v10.6：切换「本机」后端的执行身份（mobile ⇄ uid 0）。
    /// - Parameter on: true = 经 root 守护以 uid 0 执行；false = App 自己 fork（mobile）。
    /// - Returns: 切换后的真实状态（守护不可用时会保持 false）。
    @discardableResult
    func setElevated(_ on: Bool) -> Bool {
        if backend != .ios {
            switchBackend(to: .ios)
        }
        guard on != elevated else { return elevated }
        if on, Self.rootCLIPath == nil {
            append(L10n.t("term_root_unavailable") + "\n", kind: .notice)
            return elevated
        }
        // 有命令在跑就别换身份：守护侧的命令杀不掉，输出会混在两条执行链之间
        if running {
            append(L10n.t(isRoot ? "term_root_no_stop" : "term_busy") + "\n", kind: .notice)
            return elevated
        }
        elevated = on
        append(L10n.t(on ? "term_root_on" : "term_root_off") + "\n", kind: .notice)
        return elevated
    }

    // MARK: cd

    private static func parseCD(_ cmd: String, home: String) -> String? {
        // 只处理最简单形态：cd / cd .. / cd 路径 / cd "路径" / cd '路径'
        guard cmd.hasPrefix("cd ") || cmd == "cd" else { return nil }
        if cmd.contains("&&") || cmd.contains(";") || cmd.contains("|") { return nil }
        var arg = String(cmd.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if arg.isEmpty || arg == "~" { arg = home }
        if (arg.hasPrefix("\"") && arg.hasSuffix("\"")) || (arg.hasPrefix("'") && arg.hasSuffix("'")) {
            arg = String(arg.dropFirst().dropLast())
        }
        return arg
    }

    private var homeDir: String { backend.home }

    private func applyCD(_ target: String, original: String) {
        var resolved = target
        if resolved == "-" { resolved = homeDir }
        if resolved == "~" { resolved = homeDir }
        if resolved.hasPrefix("~/") { resolved = homeDir + resolved.dropFirst(1) }
        if resolved.hasPrefix("/") {
            setCwd(resolved)
        } else if backend == .ios {
            // 本机原生后端不走 iSH：相对路径交给原生后端自己解析（下面复用 runIniOS 的包装逻辑）
            let base = cwd.replacingOccurrences(of: "'", with: "'\\''")
            let arg = resolved.replacingOccurrences(of: "'", with: "'\\''")
            resolveCwdNative("cd '\(base)' 2>/dev/null; cd '\(arg)' 2>/dev/null && pwd", original: original)
        } else if isRoot {
            // root 后端同样本机解析，但要在守护里跑（/var/root 这类目录 mobile 进不去）
            let base = cwd.replacingOccurrences(of: "'", with: "'\\''")
            let arg = resolved.replacingOccurrences(of: "'", with: "'\\''")
            resolveCwdRoot("cd '\(base)' 2>/dev/null; cd '\(arg)' 2>/dev/null && pwd", original: original)
        } else {
            // 相对路径：交给 guest 解析（符号链接 / .. 都按真实结果）
            let base = cwd.replacingOccurrences(of: "'", with: "'\\''")
            let arg = resolved.replacingOccurrences(of: "'", with: "'\\''")
            _ = KelivoISHExecutor.startCommand(
                "cd '\(base)' && cd '\(arg)' && pwd",
                runId: UUID().uuidString,
                binds: [],
                cwd: cwd,
                env: nil,
                timeoutMs: 5000,
                keepStdinOpen: false,
                started: {},
                chunk: { _, _, data in
                    guard let s = String(data: data, encoding: .utf8) else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        let p = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if p.hasPrefix("/") { self.cwd = p }
                        else { self.append(L10n.t("term_cd_failed", original) + "\n", kind: .notice) }
                    }
                },
                done: { dict in
                    let code = (dict["exitCode"] as? NSNumber)?.int32Value ?? -1
                    if code != 0 {
                        DispatchQueue.main.async { [weak self] in
                            self?.append(L10n.t("term_cd_failed", original) + "\n", kind: .notice)
                        }
                    }
                })
        }
    }

    /// 本机原生后端里解析 cd：跑一段 `pwd`，成功就把结果当新 cwd
    private func resolveCwdNative(_ script: String, original: String) {
        // v10.4：原来走 run(executable: "/bin/sh") —— iOS 没这个文件，FileManager 直接判 not found，
        // 于是本机后端每一次 cd（含启动时的 prompt 探测）都报「无法进入」
        guard let shell = JBEnvironment.nativeShellPath else {
            append(L10n.t("term_native_no_shell") + "\n", kind: .notice)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let res = BuildRunner.shared.run(executable: shell, args: ["-c", script], timeout: 10)
            let out = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if res.exitCode == 0, out.hasPrefix("/") {
                    self.cwd = out
                } else {
                    if self.backend == .ios, !self.elevated, original == "cd /root" {
                        // v9.13.1：手敲 cd /root 在本机后端必败（iOS 无 /root），
                        // 直接给出真实原因与正确路径，而不是一句「无法进入」。
                        self.append(L10n.t("term_root_home_hint") + "\n", kind: .notice)
                    } else {
                        self.append(L10n.t("term_cd_failed", original) + "\n", kind: .notice)
                    }
                }
            }
        }
    }

    /// root 后端里解析 cd：脚本交给守护以 root 跑，成功就把 pwd 归一化后当新 cwd
    private func resolveCwdRoot(_ script: String, original: String) {
        rootRun(script, timeout: 20) { [weak self] code, text, _ in
            guard let self = self else { return }
            let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if code == 0, out.hasPrefix("/") {
                self.cwd = Self.normalizeRootPath(out)
            } else if !original.isEmpty {
                self.append(L10n.t("term_no_such_dir", original) + "\n", kind: .notice)
            }
        }
    }

    /// 校验目录存在（Alpine 后端）：在 guest 里 cd 一次，成功才改 cwd
    private func setCwd(_ p: String) {
        if isRoot {
            resolveCwdRoot("cd '\(p.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null && pwd",
                           original: "cd \(p)")
            return
        }
        if backend == .ios {
            resolveCwdNative("cd '\(p.replacingOccurrences(of: "'", with: "'\\''"))' && pwd", original: "cd \(p)")
            return
        }
        let q = p.replacingOccurrences(of: "'", with: "'\\''")
        _ = KelivoISHExecutor.startCommand(
            "cd '\(q)' && pwd",
            runId: UUID().uuidString,
            binds: [],
            cwd: cwd,
            env: nil,
            timeoutMs: 5000,
            keepStdinOpen: false,
            started: {},
            chunk: { _, _, _ in },
            done: { [weak self] dict in
                let code = (dict["exitCode"] as? NSNumber)?.int32Value ?? -1
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if code == 0 { self.cwd = p }
                    else { self.append(L10n.t("term_no_such_dir", p) + "\n", kind: .notice) }
                }
            })
    }

    // MARK: 提示符

    var promptText: String {
        // root 身份的 pwd 来自 bootstrap 视图，按 App 写法归一化后再与 home 比
        let home = backend.isNative ? TermSession.normalizeRootPath(backend.home) : backend.home
        let cur = isRoot ? TermSession.normalizeRootPath(cwd) : cwd
        let shown: String
        if cur == home { shown = "~" }
        else if cur.hasPrefix(home + "/") { shown = "~" + cur.dropFirst(home.count) }
        else { shown = cur }
        let device = TermSession.deviceName
        // v10.5：uid=0 的提示符按惯例用 #，一眼能看出当前身份
        return "\(device):\(shown)\(isRoot ? "#" : "$")"
    }

    /// 提示符里的设备名一律用 guest 的 hostname，这里是编译期常量，避免每帧查内核
    static let deviceName = "xosvi"

    // MARK: 启动横幅

    func greet() {
        // v10.5：横幅按后端区分——root / 本机会话之前也印「Alpine … iSH 沙盒」，
        // 切到 uid=0 之后仍然写着沙盒，看起来就像没切过去。
        // 非 Alpine 后端没有 guest 运行时，写 iOS 版本更有意义。
        let info = ProcessInfo.processInfo.operatingSystemVersion
        let bannerVer = "iOS \(info.majorVersion).\(info.minorVersion)"
        let key: String
        let ver: String
        switch backend {
        case .alpine:
            key = "term_banner"
            ver = ISH.runtimeVersion
        case .ios:
            // v10.6：本机后端两种身份共用一条横幅位，root 时换成「uid=0」那版
            key = elevated ? "term_banner_root" : "term_banner_native"
            ver = bannerVer
        }
        append(L10n.t(key, TermSession.deviceName, ver) + "\n", kind: .prompt)
        append(L10n.t("term_banner_hint") + "\n\n", kind: .prompt)
    }
}

// MARK: - 会话管理

final class TermManager: ObservableObject {
    static let shared = TermManager()

    @Published var sessions: [TermSession] = []
    @Published var selectedId: UUID?

    /// v10.4：终端页只 `@ObservedObject` 了 manager，会话自己的 `@Published` 没人订阅 ——
    /// 命令回显、流式输出、running/停止键都不会触发重绘（只有敲键盘改 `input` 时顺带重画，
    /// 所以「不敲字就看不到输出」）。把每个会话的 objectWillChange 转到 manager 上：
    /// 用 receive(on: main) 让这次通知排在真正的写入之后，界面读到的就是新值。
    private var forwarders: [UUID: AnyCancellable] = [:]

    private init() {
        let s = TermSession(title: "1")
        s.greet()
        sessions = [s]
        selectedId = s.id
        observe(s)
    }

    var selected: TermSession? {
        sessions.first { $0.id == selectedId } ?? sessions.first
    }

    /// 打开终端页时调用：会话存在就不重置，避免每次进来清掉上一次的输出
    func activate() {
        if sessions.isEmpty { newSession() }
        if selectedId == nil { selectedId = sessions.first?.id }
    }

    func newSession() {
        let s = TermSession(title: "\(sessions.count + 1)")
        s.greet()
        sessions.append(s)
        selectedId = s.id
        observe(s)
    }

    func close(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].stop()
        sessions.remove(at: idx)
        forwarders[id] = nil
        if sessions.isEmpty { newSession(); return }
        if selectedId == id { selectedId = sessions[min(idx, sessions.count - 1)].id }
    }

    private func observe(_ s: TermSession) {
        guard forwarders[s.id] == nil else { return }
        forwarders[s.id] = s.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
