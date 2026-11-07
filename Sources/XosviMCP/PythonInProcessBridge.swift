// PythonInProcessBridge.swift — 把 shell 语法的 `python3 ...` 转成 PyEvalTool 的进程内调用
//
// 结论（2026-11 实测）：环境是健康的——entitlements 里 com.apple.private.security.no-sandbox
// = true，jq / bsdtar / ldid 等纯 C 工具直接 exec 全部成功，posix_spawn 并不返 ENOSYS(85)。
// 唯一坏掉的是我们自己打的 69 KB bin/python3 壳：它加载不了 @rpath 上的 Python.framework，
// 连 -V 都 SIGBUS。所以 shell 里的 python3 不再 exec 它，统一转调进程内 CPython
// （PyEvalTool：dlopen Python.framework + pyx_init/pyx_run_file），两条腿合成一条。
//
// 本文件只做「argv 解析 + 返回结构转换」，绝不 spawn。

import Foundation

enum PythonInProcessBridge {

    /// 进程内解释器的默认墙钟上限：到点只「放弃等待」，脚本本身停不下来
    /// （解释器与 App 同进程，没有安全的强杀手段）。
    static let defaultTimeout: TimeInterval = 120

    /// shell_exec 的返回结构（与 ShellTool 其它分支保持一致）
    static func run(command: String, limit: Int = 200_000,
                    timeout: TimeInterval = defaultTimeout) -> [String: Any] {
        let body = dropInterpreter(command)
        let args = ShellExecTool.shellSplitArgs(body)

        // 1) 无参 / --version / -V / -h / --help → 等价于 py status 的版本探针
        if args.isEmpty || isVersionOrHelpOnly(args) {
            return call(["command": "eval",
                         "code": "import sys; print(sys.version); print(sys.executable or '(embedded-in-process)')",
                         "limit": 4000],
                        echo: command, limit: limit, timeout: timeout)
        }

        // 2) -c <code>
        if let i = args.firstIndex(where: { $0 == "-c" }) {
            guard i + 1 < args.count else {
                return failure(command, "python3: argument expected for the -c option", 2, hint: nil)
            }
            // `-c` 之后的第一个非选项串是 code（-c 只吃一个实参）
            let code = args[i + 1]
            // 剩余的实参按 CPython 语义成为 sys.argv[1:]
            let rest = Array(args.dropFirst(i + 2)).filter { !isPreOption($0) }
            return call(["command": "eval", "code": wrapArgv(code, rest), "limit": limit],
                        echo: command, limit: limit, timeout: timeout)
        }

        // 3) script.py [args...]
        if let first = args.first(where: { !$0.hasPrefix("-") }) {
            let expanded = (first as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                return failure(command,
                               "python3: can't open file '\(first)': No such file or directory",
                               2,
                               hint: "进程内解释器看不到 iSH 的 Alpine 路径；确认路径在 App 容器内。"
                                   + "要 Alpine 版 Python 用 sh -c 'python3 ...'")
            }
            return call(["command": "script", "path": expanded, "limit": limit],
                        echo: command, limit: limit, timeout: timeout)
        }

        // 4) -m module → 目前不映射（importlib.run_module 会动 sys.argv，风险高），
        //    明确报错，不要把用户引到 spawn 上。
        if let i = args.firstIndex(of: "-m"), i + 1 < args.count {
            return failure(command, "python3 -m \(args[i + 1]): 进程内模式不支持 -m",
                           1,
                           hint: "改用 `py command:eval code:\"import runpy; runpy.run_module('\(args[i + 1])', run_name='__main__')\"`"
                               + "，或把模块入口写成脚本后 `python3 <script.py>`")
        }

        return failure(command, "python3: 无法解析参数（仅支持 -c / <script.py> / --version）", 2, hint: nil)
    }

    // MARK: - 内部

    /// 跨线程回传 invoke 的结果（信号量之前写入、之后读取）
    private final class ResultBox: @unchecked Sendable {
        var value: Result<[String: Any], Error>?
    }

    private static func call(_ params: [String: Any], echo: String, limit: Int,
                             timeout: TimeInterval) -> [String: Any] {
        // 解释器在 App 进程内跑，调用线程一去不回就是整轮工具卡死（外层看门狗要 180s 才收）。
        // 所以这里按超时放弃等待：脚本停不下来，但至少把结果按时还给模型。
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { box.value = Result<[String: Any], Error>.success(try PyEvalTool().invoke(params)) }
            catch { box.value = Result<[String: Any], Error>.failure(error) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + max(1, timeout)) == .timedOut {
            return ["command": echo,
                    "exit_code": 124,
                    "timed_out": true,
                    "stdout": "…(超时：\(Int(timeout))s 内没返回，已放弃等待)\n"
                            + "进程内解释器不能强杀，这段代码可能仍在跑。",
                    "ios_native": true,
                    "runtime_actual": "in-process-cpython",
                    "hint": "别原样重试：脚本还占着解释器，下一次 python3 会直接报 PY_BUSY，"
                          + "直到它跑完或重启 App。缩小范围（只看需要的文件/片段）或换成更便宜的写法。"]
        }
        guard let r = box.value else {
            return failure(echo, "py: 无结果（内部错误）", 1, hint: nil)
        }
        switch r {
        case .success(let dict):
            var out = (dict["stdout"] as? String) ?? ""
            if out.count > limit { out = String(out.prefix(limit)) + "\n…(截断)" }
            return ["command": echo,
                    "exit_code": (dict["ok"] as? Bool == true) ? 0 : 1,
                    "stdout": out,
                    "ios_native": true,
                    "runtime_actual": "in-process-cpython",
                    "hint": "Python 运行在 App 进程内（dlopen Python.framework），不经 posix_spawn。"]
        case .failure(let err):
            let text = String(describing: err)
            // pyx_init 失败（Python.framework / stdlib 缺失）、PY_BUSY 等也走这里，不回退 spawn
            if text.contains("PY_BUSY") || text.contains("占用") {
                return failure(echo, text, 1,
                               hint: "解释器只有一个，上一次调用（多半已超时被放弃）还在跑。"
                                   + "等它结束或重启 App；不要原样重试同一段脚本。")
            }
            return failure(echo, text, 1,
                           hint: "进程内解释器初始化失败；先看 Python.framework 与 stdlib 是否随包分发（不要回退到 bin/python3——那个壳本身就起不来）。"
                               + "跑 `py command:status` 看 framework / stdlib 路径。")
        }
    }

    private static func failure(_ echo: String, _ msg: String, _ code: Int, hint: String?) -> [String: Any] {
        var r: [String: Any] = ["command": echo, "exit_code": code, "stdout": msg]
        if let hint { r["hint"] = hint }
        return r
    }

    /// 去掉开头的解释器名（python3 / python / /xx/bin/python3）
    private static func dropInterpreter(_ command: String) -> String {
        let t = command.trimmingCharacters(in: .whitespaces)
        for prefix in ["python3", "python"] where t == prefix || t.hasPrefix(prefix + " ") {
            return String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func isPreOption(_ a: String) -> Bool {
        ["-u", "-B", "-E", "-s", "-S", "-O", "-OO", "-q"].contains(a)
    }

    private static func isVersionOrHelpOnly(_ args: [String]) -> Bool {
        let meaningful = args.filter { !isPreOption($0) }
        guard meaningful.count == 1, let only = meaningful.first else { return false }
        return ["--version", "-V", "-h", "--help"].contains(only)
    }

    /// 把额外实参注入 sys.argv，保持 CPython 的 `sys.argv[0] == "-c"` 语义
    private static func wrapArgv(_ code: String, _ rest: [String]) -> String {
        guard !rest.isEmpty else { return code }
        let lit = rest.map(pyStringLiteral).joined(separator: ", ")
        return "import sys as _s; _s.argv = [\"-c\"] + [\(lit)]\n" + code
    }

    /// 生成 Python 源码里的安全字符串字面量（先转义反斜杠，再转义双引号）
    static func pyStringLiteral(_ s: String) -> String {
        let esc = s.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + esc + "\""
    }
}
