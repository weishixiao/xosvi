import Foundation
import Darwin

/// v0.2.0（rootd 桥 → XPC 桥）：给 AI 一条**真正可用的 root 通道**。
///
/// v0.2.0 起执行不再靠目录轮询，而是直接连 root 守护 `xosvid` 的 MachService
/// `wiki.qaq.xosvi.service`（deb `com.xosvi.daemon` 的 LaunchDaemon `wiki.qaq.xosvid`）：
///   App ──XPC──▶ xosvid(uid 0) ──▶ <bootstrap>/usr/libexec/xosvi/xosvi-build --exec <cwd> <命令>
/// 理由：roothide 下 App 与 root 进程是两套文件视图，1777 目录的 `.cmd/.out/.status`
/// 会被视图差异、心跳时延、写探针误判反复坑；XPC 走 launchd 的 Mach bootstrap，不依赖共享目录，
/// 也没有可被别的进程抢占的命令文件。
///
/// 守护侧在连接时校验 `wiki.qaq.xosvi.client` entitlement，所以 App 必须在 Support/Xosvi.entitlements
/// 里声明它，并在 `com.apple.security.exception.mach-lookup.global-name` 加上服务名。
///
/// 旧目录通道（rootd v1.5.0，LaunchDaemon `com.xosvi.rootd`）保留在 `runViaDirectory` 里作为参考实现，
/// 主流程不再调用。
final class RootdTool: MCPTool {
    let definition = ToolDefinition(
        name: "root",
        summary: "Run a command as root through the xosvid daemon (MachService wiki.qaq.xosvi.service, LaunchDaemon wiki.qaq.xosvid, installed by the com.xosvi.daemon deb). Commands: status / exec / probe / enable / disable. Use for: chown/chmod, launchctl, editing /Library, anything shell.exec refuses. Don't use for: normal file reads (use shell.exec) or on a device without the daemon (status says so). Example: root command:exec cmd:\"id -u\"",
        parameters: [
            "command": "status / exec / probe / enable / disable",
            "cmd": "shell script text (for exec) — runs as root in xosvid",
            "timeout": "seconds to wait for the result (default 30, max 300)"
        ],
        returns: [
            "stdout": "命令输出（exec），以 root 身份由守护的子进程产生",
            "exit_code": "退出码（exec）",
            "transport": "exec 走的通道：xpc",
            "xpc": "XPC 通道状态：reachable / client_entitled / daemon pid 与 uid / 失败原因（status、probe）",
            "diagnosis": "失败时的现场诊断"
        ],
        verified: false, category: "shell",
        prerequisites: ["需要已安装 com.xosvi.daemon deb（LaunchDaemon wiki.qaq.xosvid，MachService wiki.qaq.xosvi.service）；App 须带 wiki.qaq.xosvi.client 并声明该服务名的 mach-lookup。status 里 xpc.reachable=false 或缺 entitlement 时通道不可用。"], annotations: .readOnlyLocal, cache: ToolCachePolicy.none)

    /// 候选目录，**App 侧可写的排前面**。
    /// v7.16.8：Library 在真机上对 App 不可见（写入探针会报 ENOENT/EACCES），Documents 侧才是通的。
    static let candidateDirs: [String] = {
        // v7.16.10：App 自己的沙箱 Documents 才是它**一定能写**的地方。
        // 现场：App 能看到 /var/mobile/Documents/Workspace（可能是容器映射），
        // 却看不到 /var/mobile/Library/Rootd；于是把 NSHomeDirectory() 也加进候选，
        // rootd 1.3.3 起会 glob 每个 App 容器的 Documents/Rootd。
        var dirs: [String] = []
        let home = NSHomeDirectory()
        dirs.append(home + "/Documents/Rootd")
        dirs.append("/var/mobile/Documents/Rootd")
        dirs.append("/var/mobile/Library/Rootd")
        dirs.append("/var/mobile/Documents/Workspace")
        dirs.append("/rootfs/var/mobile/Library/Rootd")
        return dirs
    }()

    private var fm: FileManager { FileManager.default }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let sub = ((params["command"] as? String) ?? "status").lowercased()
        switch sub {
        case "status": return statusReport()
        case "probe":  return probe()
        case "enable": return setDisabled(false)
        case "disable": return setDisabled(true)
        case "exec":
            guard let cmd = params["cmd"] as? String, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("cmd required. Usage: root command:exec cmd:\"id -u\"")
            }
            let timeout = min(max(Double((params["timeout"] as? Int) ?? 30), 3), 300)
            return try run(cmd, timeout: timeout)
        default:
            throw MCPError.invalidParams("unknown command \(sub); use status / exec / probe / enable / disable")
        }
    }

    // MARK: - 目录探测

    private struct DirState {
        let path: String
        let exists: Bool
        let writeError: String?      // nil = 真写进去了
        let status: String
        let inode: UInt64
        let aliveAge: Int            // 心跳文件的年龄（秒），-1 = 没有心跳文件

        var writable: Bool { writeError == nil }
        /// 心跳新鲜 = 这个目录与 daemon 是同一个视图（唯一可靠的共享判据）。
        /// 阈值必须 ≥ 心跳间隔（rootd.sh 里 HEARTBEAT_EVERY=5 × SLEEP_SEC=2 = 10s），
        /// 原来写死 5 秒，心跳每 10 秒才写一次，永远判成「不共享」。
        var shared: Bool { aliveAge >= 0 && aliveAge <= 15 }
    }

    /// 真实写入探针：能不能在这个目录里建文件。比 isWritableFile 可信——
    /// 后者在容器重定向/roothide 下会照着容器注册表撒谎。
    private func writeProbe(_ dir: String) -> String? {
        let name = ".probe-\(getpid())-\(Int(Date().timeIntervalSince1970))"
        let path = dir + "/" + name
        errno = 0
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        if fd >= 0 {
            close(fd)
            unlink(path)
            return nil
        }
        let code = errno
        return "errno=\(code) \(String(cString: strerror(code)))"
    }

    private func dirState(_ dir: String) -> DirState {
        if !(fm.fileExists(atPath: dir) || FSStat.exists(dir)), dir.hasPrefix(NSHomeDirectory()) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let exists = fm.fileExists(atPath: dir) || FSStat.exists(dir)
        let werr = exists ? writeProbe(dir) : "目录不存在"
        let status = (try? String(contentsOfFile: dir + "/.status", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 心跳：daemon 每 HEARTBEAT_EVERY 秒往每个目录写 `<epoch> <pid>`
        var age = -1
        if let raw = try? String(contentsOfFile: dir + "/.alive", encoding: .utf8),
           let first = raw.split(separator: " ").first, let ts = Int(first) {
            age = Int(Date().timeIntervalSince1970) - ts
        }
        let ino = FSStat.lstat(dir)?.inode ?? 0
        return DirState(path: dir, exists: exists, writeError: werr, status: status, inode: ino, aliveAge: age)
    }

    /// daemon 存活：pid 文件名在新旧版本里不一致，两种都要认。
    /// v7.16.12：修「daemon 明明在跑，工具却报 daemon_alive:false」——
    /// 设备上的 rootd.sh 写的是 `.rootd.pid`（带点），工具原来只读 `rootd.pid`（无点），
    /// 永远读不到 → pid == nil → status 报未运行、exec 直接拒绝执行。
    private func daemonPID() -> pid_t? {
        let pidFiles = [".rootd.pid", "rootd.pid"]
        for d in Self.candidateDirs {
            for name in pidFiles {
                guard let raw = try? String(contentsOfFile: d + "/" + name, encoding: .utf8) else { continue }
                // 可能带换行或额外字段，只取第一段数字
                let first = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }).first ?? ""
                guard let pid = pid_t(first.trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
                // kill(pid,0)：0 = 进程存在；EPERM 说明存在但无权发信号（App 对 root 进程就是这种）
                if kill(pid, 0) == 0 || errno == EPERM {
                    return pid
                }
            }
        }
        return nil
    }

    /// 优先「能写 + 心跳新鲜」（= 与 daemon 同一个视图）；没有心跳时退回「能写」。
    /// 心跳证据：daemon 每秒往每个目录写 `.alive`。即使 pid 文件不可见（跨视图），
    /// 只要某个目录的心跳是新鲜的，就证明守护进程活着。
    private func freshestHeartbeat() -> Int? {
        var best: Int?
        for d in Self.candidateDirs {
            guard let raw = try? String(contentsOfFile: d + "/.alive", encoding: .utf8),
                  let first = raw.split(separator: " ").first, let ts = Int(first) else { continue }
            let age = Int(Date().timeIntervalSince1970) - ts
            if age < 0 || age > 30 { continue }
            if best == nil || age < best! { best = age }
        }
        return best
    }

    /// v8.2：daemon 跑在哪个 launchd 域。
    /// user/501 域里进程是 mobile 身份——state 也是 running，但执行 root 命令必然失败。
    /// 旧版只看 pid/心跳，会把这种「假活」当成可用。
    /// v0.2.2：当前守护的真实 label（xosvid）排在旧的 rootd label 之前。
    /// 旧版只认 com.xosvi.rootd，于是 xosvid 明明在跑，status 仍报 daemon_domain: none。
    private func daemonDomain() -> String {
        let labels = ["wiki.qaq.xosvid", "com.xosvi.rootd", "com.trollhax.rootd"]
        for label in labels {
            if launchctlPrint("system/\(label)") { return "system" }
        }
        for label in labels {
            if launchctlPrint("user/501/\(label)") { return "user/501" }
        }
        return "none"
    }

    /// xosvid 的 LaunchDaemon plist 在哪（roothide 的 jbroot 每次重装都会变）。
    private func daemonPlistPath() -> String? {
        var candidates: [String] = []
        if let jb = JBEnvironment.jbrootPath, !jb.isEmpty {
            candidates.append(jb + "/Library/LaunchDaemons/wiki.qaq.xosvid.plist")
        }
        candidates.append("/var/jb/Library/LaunchDaemons/wiki.qaq.xosvid.plist")
        candidates.append("/Library/LaunchDaemons/wiki.qaq.xosvid.plist")
        return candidates.first { fm.fileExists(atPath: $0) }
    }

    private func launchctlPrint(_ target: String) -> Bool {
        let res = BuildRunner.shared.run(executable: "/bin/launchctl",
                                         args: ["print", target],
                                         env: ["PATH": "/usr/bin:/bin"],
                                         timeout: 5)
        return res.exitCode == 0 && !res.stdout.isEmpty
    }

    private func usableDirs() -> [DirState] {
        let all = Self.candidateDirs.map(dirState)
        let shared = all.filter { $0.exists && $0.writable && $0.shared }
        if !shared.isEmpty { return shared }
        return all.filter { $0.exists && $0.writable }
    }

    /// 检查 LaunchDaemon plist 里 ProgramArguments 的每一项是否真实存在。
    /// 返回 nil = 没问题（或找不到 plist，交给上层按「未安装」处理）。
    private func brokenLaunchdPaths() -> String? {
        var plistCandidates: [String] = [
            "/var/jb/Library/LaunchDaemons/com.xosvi.rootd.plist",
            "/Library/LaunchDaemons/com.xosvi.rootd.plist",
            "/var/mobile/Library/LaunchDaemons/com.xosvi.rootd.plist"
        ]
        // roothide：plist 在随机 jbroot 里，路径每次重装都会变
        if let jb = JBEnvironment.jbrootPath, !jb.isEmpty {
            plistCandidates.insert(jb + "/Library/LaunchDaemons/com.xosvi.rootd.plist", at: 0)
        }
        // 当前守护（xosvid）优先
        if let p = daemonPlistPath() { plistCandidates.insert(p, at: 0) }

        for path in plistCandidates {
            guard let data = fm.contents(atPath: path) else { continue }
            let parsed = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
            guard let dict = parsed as? [String: Any],
                  let args = dict["ProgramArguments"] as? [String],
                  !args.isEmpty else { continue }
            for a in args where !a.hasPrefix("-") {
                if !fm.fileExists(atPath: a) && !FSStat.exists(a) {
                    return a
                }
            }
            return nil
        }
        return nil
    }

    // MARK: - 子命令

    private func statusReport() -> [String: Any] {
        let states = Self.candidateDirs.map(dirState)
        let pid = daemonPID()
        let hb = freshestHeartbeat()
        let dirs: [[String: Any]] = states.map {
            var m: [String: Any] = ["path": $0.path, "exists": $0.exists,
                                    "writable": $0.writable, "status": $0.status,
                                    "shared": $0.shared, "alive_age": $0.aliveAge,
                                    "inode": $0.inode]
            if let e = $0.writeError { m["write_error"] = e }
            return m
        }
        let domain = daemonDomain()
        let xpc = xpcStatus()
        // v0.2.2：xosvid 是 C 守护，不写 .rootd.pid、也不写 .alive 心跳（那套是旧 rootd.sh 的），
        // 所以旧的两种判据在它身上永远为假。XPC 握手成功 = 守护活着且身份正确，这才是权威判据。
        let xpcReachable = (xpc["reachable"] as? Bool) == true
        let alive = pid != nil || (hb != nil && hb! <= 5) || xpcReachable
        let aliveSource: String
        if pid != nil { aliveSource = "pid" } else if xpcReachable { aliveSource = "xpc" }
        else if alive { aliveSource = "heartbeat" } else { aliveSource = "none" }
        var out: [String: Any] = [
            "installed": states.contains { $0.exists } || daemonPlistPath() != nil,
            "daemon_domain": domain,
            "privileged": domain == "system" || ((xpc["uid"] as? Int) == 0),
            "xpc": xpc,
            "daemon_alive": alive,
            "daemon_pid": pid.map { Int($0) } ?? (xpc["pid"] as? Int ?? 0),
            "alive_source": aliveSource,
            "heartbeat_age": hb ?? -1,
            "dirs": dirs,
            "app_home": NSHomeDirectory(),
            "jb_kind": JBEnvironment.kind.rawValue,
            "jbroot": JBEnvironment.jbrootPath ?? "",
            "rootfs": JBEnvironment.rootfsPrefix.isEmpty ? "无" : JBEnvironment.rootfsPrefix
        ]
        // v0.2.0：诊断「launchd 反复拉起又秒死」——plist 里的脚本路径必须真实存在。
        // 现场就踩过：脚本被复制到 Library/Rootd，plist 仍指向旧位置 → 进程起不来，
        // 而 launchctl print 只显示 program（dash），看不到 arguments，极难发现。
        // 域错误最高优先：pid 活着、心跳也新鲜，但身份是 mobile，root 命令全都会失败。
        // v0.2.0 起执行走 XPC，所以「XPC 可达」才是通道可用的判据，目录心跳只做旁证。
        if (xpc["reachable"] as? Bool) == true {
            out["hint"] = "XPC 通道可用（daemon uid=\(xpc["uid"] ?? "?")）"
            return out
        }
        if domain == "system" {
            out["hint"] = "xosvid 已在 system 域，但 App 侧 XPC 连不上（xpc.error）："
                + "看 xpc.client_entitled，App 必须带 \(XosviXPC.clientEntitlement) 并获准查找该 MachService"
            return out
        }
        if domain == "user/501" {
            out["hint"] = "daemon 跑在 user/501 域（mobile 身份），没有 root 权限。修复："
                + "launchctl bootout user/501/com.xosvi.rootd; "
                + "launchctl bootstrap system <jbroot>/Library/LaunchDaemons/com.xosvi.rootd.plist"
            return out
        }
        if let bad = brokenLaunchdPaths() {
            out["launchd_problem"] = bad
            out["hint"] = "LaunchDaemon 配置指向的路径不存在：\(bad)。修正 plist 的 ProgramArguments，或重装 newterm-autoroot deb"
            return out
        }
        if !states.contains(where: { $0.exists }) {
            out["hint"] = "xosvid 未安装（找不到 LaunchDaemon plist）：装 com.xosvi.daemon"
        } else if !alive {
            out["hint"] = "plist 在但服务没跑：root 下执行 icli svc bootstrap <jbroot>/Library/LaunchDaemons/wiki.qaq.xosvid.plist，再 icli svc start wiki.qaq.xosvid"
        } else if !states.contains(where: { $0.shared }) {
            out["hint"] = "daemon 活着但没有任何目录收到心跳（.alive 不新鲜）：App 与本机文件系统是两个视图。dirs[].inode 与终端 ls -di 对比可确认"
        } else if !states.contains(where: { $0.writable }) {
            out["hint"] = "daemon 活着但所有目录都写不进去：让用户 chmod 1777 对应目录（deb ≥1.5.0 会自动建 /var/mobile/Documents/Rootd）"
        }
        return out
    }

    private func probe() -> [String: Any] {
        let xpc = xpcStatus()
        // run() 声明成 throws（老目录通道会 throw），这里必须 try? 兜住，否则非 throws 的 probe() 编不过
        let res: [String: Any] = (try? run("id -u", timeout: 8)) ?? ["completed": false, "exit_code": -1]
        let uidText = (res["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let working = (xpc["reachable"] as? Bool) == true && (res["exit_code"] as? Int) == 0
        return ["working": working,
                "transport": "xpc",
                "xpc": xpc,
                "uid": uidText,
                "result": res,
                "hint": working ? "root 通道可用（XPC → xosvid uid=\(xpc["uid"] ?? "?"))"
                                : "XPC 不通：看 xpc.error / xpc.client_entitled / daemon_domain"]
    }

    private func setDisabled(_ disabled: Bool) -> [String: Any] {
        let dirs = usableDirs()
        guard !dirs.isEmpty else {
            return ["ok": false, "error": "找不到可写的 Rootd 目录（rootd 未安装？）", "diagnosis": statusReport()]
        }
        var done: [String] = []
        for d in dirs {
            let f = d.path + "/disabled"
            if disabled {
                if (try? "1".write(toFile: f, atomically: true, encoding: .utf8)) != nil { done.append(d.path) }
            } else {
                try? fm.removeItem(atPath: f)
                done.append(d.path)
            }
        }
        return ["ok": !done.isEmpty, "disabled": disabled, "dirs": done]
    }

    // MARK: - 执行
    //
    // v0.2.0：执行改走 XPC（MachService `wiki.qaq.xosvi.service`，守护 tools/xosvid.c）。
    // 旧的 1777 目录 `.cmd/.out/.status` 轮询在 roothide 下不可靠（App 与 root 是两套文件视图），
    // 只在 XPC 明确不可达时才作为兜底保留。目录相关字段仍由 statusReport / dirState 提供。

    private func run(_ script: String, timeout: Double, forceDir: String? = nil) throws -> [String: Any] {
        return runViaXPC(script, timeout: timeout)
    }

    /// 通过 root 守护执行命令。守护以 root 身份起 `<bootstrap>/usr/bin/dash -c <脚本>`。
    private func runViaXPC(_ script: String, timeout: Double) -> [String: Any] {
        // 守护只认三个 helper；给一条命令用的是 xosvi-build 的 --exec 模式（见 tools/xosvi-build.c）
        let res = XosviXPC.helper("xosvi-build",
                                  args: ["--exec", execWorkingDir(), script],
                                  timeout: Int(max(3, min(timeout, 300))))
        guard (res["ok"] as? Bool) == true else {
            let err = res["error"] as? String ?? "unknown"
            return ["completed": false, "error": "xpc_unreachable", "transport": "xpc",
                    "detail": err, "diagnosis": statusReport(),
                    "hint": "root 通道依赖 xosvid（MachService \(XosviXPC.serviceName)）在 system 域加载；"
                        + "它没起来时 App 无法以 root 执行。"]
        }
        let stdout = res["stdout"] as? String ?? ""
        if let e = res["error"] as? String, !e.isEmpty {
            return ["completed": false, "error": e, "transport": "xpc",
                    "resolved": res["resolved"] ?? "", "stdout": stdout,
                    "diagnosis": statusReport()]
        }
        var out: [String: Any] = [
            "completed": true,
            "transport": "xpc",
            "stdout": stdout,
            "exit_code": res["exit_code"] ?? -1,
            "status": "DONE rc=\(res["exit_code"] ?? -1)",
            "resolved": res["resolved"] ?? "",
            "daemon_pid": res["pid"] ?? 0
        ]
        if let timedOut = res["timed_out"] as? Bool, timedOut { out["timed_out"] = true }
        if let ms = res["elapsed_ms"] as? Double { out["elapsed_ms"] = ms }
        return out
    }

    /// 守护进程里 helper 的 cwd：固定用数据目录下的 work（xosvi-build 的项目根白名单就在它下面）。
    private func execWorkingDir() -> String {
        if let jb = JBEnvironment.jbrootPath, !jb.isEmpty {
            let p = jb + "/private/var/mobile/Documents/wiki.qaq.xosvi/work"
            if FSStat.exists(p) { return p }
        }
        let fallback = "/private/var/mobile/Documents/wiki.qaq.xosvi/work"
        return FSStat.exists(fallback) ? fallback : "/"
    }

    /// XPC 侧状态：守护是否可达。与磁盘目录探测分开，避免把视图问题当成守护问题。
    private func xpcStatus() -> [String: Any] {
        let res = XosviXPC.serviceStatus(timeout: 5)
        var out: [String: Any] = [
            "service": XosviXPC.serviceName,
            "reachable": (res["ok"] as? Bool) == true && (res["error"] as? String ?? "").isEmpty,
            "client_entitled": XosviXPC.hasClientEntitlement()
        ]
        if let e = res["error"] as? String { out["error"] = e }
        for k in ["status", "bootstrap", "resolved", "dash", "helper", "peer", "pid", "uid"] {
            if let v = res[k] { out[k] = v }
        }
        return out
    }

    /// 旧通道：1777 目录 `.cmd/.out/.status`。仅在 XPC 不可达且目录心跳新鲜时使用。
    private func runViaDirectory(_ script: String, timeout: Double, forceDir: String? = nil) -> [String: Any] {
        let target: DirState?
        if let fd = forceDir {
            let st = dirState(fd)
            target = (st.exists && st.writable) ? st : nil
        } else {
            target = usableDirs().first
        }
        if let d = target?.path, d.hasPrefix(NSHomeDirectory()) {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        let aliveForRun = daemonPID() != nil || (freshestHeartbeat().map { $0 <= 5 } ?? false)
        guard let dir = target, aliveForRun else {
            return ["completed": false, "error": "no_writable_dir",
                    "diagnosis": statusReport(),
                    "hint": "rootd 未安装 / 未运行 / 候选目录都写不进去；先看 diagnosis.dirs[].write_error"]
        }
        let base = dir.path
        let cmdPath = base + "/.cmd"
        let outPath = base + "/.out"
        let statusPath = base + "/.status"

        // v7.16.12：先把状态清成 PENDING，再投递命令。
        // 顺序不能反：如果先投递，daemon 可能在 sleep 间隔内执行完并写 DONE，
        // 我们随后又把状态改成 PENDING，就永远等不到 DONE（超时误判）。
        // 同时清掉旧输出，避免把上一次的 .out 当成本次结果。
        try? "PENDING".write(toFile: statusPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(atPath: outPath)

        // 原子写入：先写临时文件再 rename（避免 daemon 读到半截脚本）
        let tmp = base + "/.cmd.tmp\(UInt32.random(in: 1000...9999))"
        do {
            try script.write(toFile: tmp, atomically: false, encoding: .utf8)
            if rename(tmp, cmdPath) != 0 {
                try? fm.removeItem(atPath: tmp)
                try script.write(toFile: cmdPath, atomically: true, encoding: .utf8)
            }
        } catch {
            return ["completed": false, "error": "write_failed", "dir": base,
                    "detail": "\(error)",
                    "diagnosis": statusReport()]
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status = ""

        while Date() < deadline {
            status = ((try? String(contentsOfFile: statusPath, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if status.hasPrefix("DONE") { break }
            if status == "DISABLED" {
                return ["completed": false, "error": "disabled", "dir": base,
                        "hint": "rootd 处于 disabled 状态：root command:enable 或删掉 disabled 文件"]
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        if !status.hasPrefix("DONE") {
            let stillPending = fm.fileExists(atPath: cmdPath)
            return ["completed": false, "status": status, "dir": base,
                    "cmd_consumed": !stillPending,
                    "diagnosis": stillPending
                        ? "命令没被取走：daemon 没在看这个目录（deb 版本太旧？1.5.0 起使用 com.xosvi.rootd 标签并轮询 Documents/Rootd）"
                        : "命令被取走了但没等到 DONE：可能在执行中超时（默认 \(Int(timeout))s）",
                    "hint": "root command:probe 看哪个目录通"]
        }

        let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        var code = -1
        if let r = status.range(of: "rc=") {
            code = Int(status[r.upperBound...].trimmingCharacters(in: .whitespaces)) ?? -1
        }
        return ["completed": true, "stdout": out, "exit_code": code,
                "status": status, "dir": base]
    }
}
