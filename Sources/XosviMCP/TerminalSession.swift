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

/// 终端后端：alpine = iSH 沙盒（默认，有 apk/python/git）；ios = 直接 fork 本机 shell（能读写真实文件系统）
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
    var home: String { self == .ios ? "/var/mobile" : "/root" }
}

final class TermLine: Identifiable, Equatable {
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
    /// 当前会话跑在哪个后端（v9.13：ios = 直接 fork iOS 原生 shell，alpine = iSH 沙盒）
    @Published var backend: TermBackend = .alpine

    private(set) var runId: String?
    /// iOS 原生后端当前子进程（停止时 kill）
    private var iosPid: pid_t = 0
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
        if let last = lines.last, last.kind == kind, kind == .output {
            last.text += text
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
            runIniOS(command)
            return
        }
        let bootRC = ISH.boot()
        guard bootRC == 0 else {
            append((ISH.lastError ?? "沙盒启动失败 rc=\(bootRC)") + "\n", kind: .notice)
            return
        }
        let runId = UUID().uuidString
        self.runId = runId
        running = true
        lastExit = 0

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
    // 直接 posix_spawn `/bin/sh -c`（本机 /bin/sh 真实存在），输出经共享 fd + DispatchSource
    // 实时上屏。与 Alpine 后端的差别：命令读写的是真实文件系统，且没有 apk/python（本机没装）。
    private func runIniOS(_ command: String) {
        running = true
        lastExit = 0
        let quotedCwd = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let wrapped = "cd '\(quotedCwd)' 2>/dev/null || true; ( \(command) ) 2>&1"

        var args = [strdup("/bin/sh"), strdup("-c"), strdup(wrapped)]
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
        let rc = posix_spawn(&pid, "/bin/sh", &actions, nil, args, env)
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

    private func finishRun(code: Int32, runId: String, dict: [String: Any]) {
        running = false
        self.runId = nil
        lastExit = code
        let cancelled = (dict["cancelled"] as? NSNumber)?.boolValue ?? false
        let timedOut = (dict["timedOut"] as? NSNumber)?.boolValue ?? false
        if cancelled {
            append(L10n.t("term_stopped") + "\n", kind: .notice)
        } else if timedOut {
            append(L10n.t("term_timeout") + "\n", kind: .notice)
        }
        // 末尾没换行时补一个，保证下一次输入从新行开始
        if let last = lines.last, last.kind == .output, !last.text.hasSuffix("\n") {
            last.text += "\n"
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
            resolveCwdNative("cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' 2>/dev/null && pwd",
                             original: "")
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
        if iosPid > 0 {
            kill(iosPid, SIGTERM)
            kill(iosPid, SIGKILL)
            iosPid = 0
            running = false
            append(L10n.t("term_stopped") + "\n", kind: .notice)
            return
        }
        guard let runId = runId else { return }
        _ = KelivoISHExecutor.cancelRunId(runId)
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
            append(L10n.t("term_stopped") + "\n", kind: .notice)
        }
        backend = target
        cwd = target.home
        append(L10n.t("term_backend_switched", target.title) + "\n", kind: .notice)
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

    private var homeDir: String { backend == .ios ? "/var/mobile" : "/root" }

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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let res = BuildRunner.shared.run(executable: "/bin/sh", args: ["-c", script], timeout: 10)
            let out = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if res.exitCode == 0, out.hasPrefix("/") {
                    self.cwd = out
                } else {
                    if backend == .ios, original == "cd /root" {
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

    /// 校验目录存在（Alpine 后端）：在 guest 里 cd 一次，成功才改 cwd
    private func setCwd(_ p: String) {
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
        let home = backend == .ios ? "/var/mobile" : "/root"
        let shown: String
        if cwd == home { shown = "~" }
        else if cwd.hasPrefix(home + "/") { shown = "~" + cwd.dropFirst(home.count) }
        else { shown = cwd }
        let device = TermSession.deviceName
        return "\(device):\(shown)$"
    }

    /// 提示符里的设备名一律用 guest 的 hostname，这里是编译期常量，避免每帧查内核
    static let deviceName = "xosvi"

    // MARK: 启动横幅

    func greet() {
        let ver = ISH.runtimeVersion
        append(L10n.t("term_banner", TermSession.deviceName, ver) + "\n", kind: .prompt)
        append(L10n.t("term_banner_hint") + "\n\n", kind: .prompt)
    }
}

// MARK: - 会话管理

final class TermManager: ObservableObject {
    static let shared = TermManager()

    @Published var sessions: [TermSession] = []
    @Published var selectedId: UUID?

    private init() {
        let s = TermSession(title: "1")
        s.greet()
        sessions = [s]
        selectedId = s.id
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
    }

    func close(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].stop()
        sessions.remove(at: idx)
        if sessions.isEmpty { newSession(); return }
        if selectedId == id { selectedId = sessions[min(idx, sessions.count - 1)].id }
    }
}
