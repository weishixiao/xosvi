// PyEvalTool.swift — 进程内 CPython 执行（不 spawn 任何子进程）
//
// 背景：进程内解释器，不依赖子进程。注意 App 内置的 bin/python3 是 69 KB 启动壳，
// 独立 exec 时加载不到 @rpath 上的 Python.framework，-V 就 SIGBUS——不要用它。
// 真正可用的 CPython 3.14 就在本文件这条 dlopen 路径里。
// Python.framework + stdlib 本来就在包里，改成 dlopen 进当前进程后
// 直接跑解释器，一次 spawn 都不需要。

import Foundation
import CPyEmbed

final class PyEvalTool: MCPTool {
    let definition = ToolDefinition(
        name: "py",
        summary: "Run Python in-process (no subprocess). Commands: eval (code) / script (path) / status. Use for: parsing/patching bytes, struct unpack, regex over binaries, quick calculations — without spawning a subprocess (faster, no bin/python3 dependency). Don't use for: long-running servers (interpreter shares the app process). Example: py command:eval code:\"print(open('/tmp/a.bin','rb').read(8).hex())\"",
        parameters: [
            "command": "eval / script / status",
            "code": "Python source (for eval)",
            "path": "absolute .py path (for script)",
            "timeout": "wall-clock 秒数（默认 120）：到点放弃等待并返回；解释器停不下来，脚本仍在跑",
            "limit": "max output chars (default 200000)"
        ],
        verified: true, category: "terminal", prerequisites: [
            "首次调用会初始化解释器（约 1 秒）；之后常驻进程",
            "解释器与 App 同进程：死循环杀不掉——超时只是放弃等待，此后调用报 PY_BUSY，直到它结束或重启 App"
        ])

    private static let lock = NSLock()
    private static var initialized = false
    private static var initError = ""

    // 解释器只有一个、且停不下来：上一次调用（可能已被超时放弃）还没返回时，
    // 绝不能再进去——pyx_run_file 会做进程级 fd 重定向、用同一块代码缓冲，
    // 交叉执行会把两次调用一起挂死。所以这里做单实例闸门。
    private static let runLock = NSLock()
    private static var running = false

    private var frameworkPath: String { Bundle.main.bundlePath + "/Frameworks/Python.framework/Python" }
    private var homePath: String { Bundle.main.bundlePath + "/python" }
    private var pathList: String {
        let base = homePath + "/lib/python3.14"
        return [base, base + "/lib-dynload", base + "/site-packages"].joined(separator: ":")
    }

    private func ensureInit() -> String {
        PyEvalTool.lock.lock()
        defer { PyEvalTool.lock.unlock() }
        if PyEvalTool.initialized { return "" }
        if !PyEvalTool.initError.isEmpty { return PyEvalTool.initError }

        guard FileManager.default.fileExists(atPath: frameworkPath) else {
            PyEvalTool.initError = "Python.framework 不在包里：\(frameworkPath)"
            return PyEvalTool.initError
        }
        // 关键：stdlib 路径不对时 Py_Initialize 会走 Py_FatalError →
        // 直接 exit()/abort 掉整个 App（不是抛异常）。所以先自己校验 encodings，
        // 缺了就完全不初始化。
        let encodings = homePath + "/lib/python3.14/encodings/__init__.py"
        guard FileManager.default.fileExists(atPath: encodings) else {
            PyEvalTool.initError = "stdlib 缺失（找不到 \(encodings)）——初始化会 fatal，已放弃"
            return PyEvalTool.initError
        }
        var err = [CChar](repeating: 0, count: 1024)
        let rc = frameworkPath.withCString { fp in
            homePath.withCString { hm in
                pathList.withCString { pp in
                    pyx_init(fp, hm, pp, &err, err.count)
                }
            }
        }
        if rc != 0 {
            PyEvalTool.initError = String(cString: err)
            return PyEvalTool.initError
        }
        PyEvalTool.initialized = true
        return ""
    }

    /// 拿执行权：已有调用在跑就立刻报错，不排队（排队会变成第二个 180s 卡死）
    private func beginRun() throws {
        PyEvalTool.runLock.lock()
        defer { PyEvalTool.runLock.unlock() }
        if PyEvalTool.running {
            throw MCPError.classified("py: 解释器仍被上一次调用占用", code: "PY_BUSY", reason: "tool",
                                      nextStep: "上一次 python 还没返回（多半已超时被放弃）。等它结束，或重启 App 再试；别原样重试")
        }
        PyEvalTool.running = true
    }

    private func endRun() {
        PyEvalTool.runLock.lock()
        PyEvalTool.running = false
        PyEvalTool.runLock.unlock()
    }

    /// 带墙钟上限的执行：到点放弃等待（脚本停不下来，线程继续跑）
    private func runBounded(code: String, limit: Int, timeout: TimeInterval) throws -> String {
        final class Box: @unchecked Sendable {
            var value: Result<String, Error>?
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { box.value = Result<String, Error>.success(try self.run(code: code, limit: limit)) }
            catch { box.value = Result<String, Error>.failure(error) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + max(1, timeout)) == .timedOut {
            throw MCPError.classified("py: 超过 \(Int(timeout))s 未返回，已放弃等待", code: "TIMEOUT", reason: "tool",
                                      nextStep: "脚本可能仍在跑并占着解释器（下一次调用会报 PY_BUSY）。缩小范围或换成更便宜的写法，别原样重试")
        }
        guard let result = box.value else {
            throw MCPError.failed("py: 无结果（内部错误）")
        }
        switch result {
        case .success(let out): return out
        case .failure(let e): throw e
        }
    }

    private func run(code: String, limit: Int) throws -> String {
        let e = ensureInit()
        if !e.isEmpty {
            throw MCPError.classified("py: 解释器初始化失败 — \(e)", code: "PY_INIT_FAILED",
                                      reason: "environment",
                                      nextStep: "确认 App 包内存在 Frameworks/Python.framework 与 python/lib/python3.14；或改用 diagnose spawn 检查环境")
        }
        let tmp = NSTemporaryDirectory()
        let id = UUID().uuidString
        let codePath = tmp + "/pycode_\(id).py"
        let outPath = tmp + "/pyout_\(id).txt"
        let envPath = tmp + "/pyenv_\(id).json"
        defer {
            try? FileManager.default.removeItem(atPath: codePath)
            try? FileManager.default.removeItem(atPath: outPath)
            try? FileManager.default.removeItem(atPath: envPath)
        }
        try code.write(toFile: codePath, atomically: true, encoding: .utf8)
        // v6.6.19：用户环境变量注入 os.environ
        try? EnvVars.pythonEnvJSON().write(toFile: envPath, atomically: true, encoding: .utf8)

        try beginRun()
        defer { endRun() }

        var err = [CChar](repeating: 0, count: 1024)
        let rc = codePath.withCString { cp in
            outPath.withCString { op in
                envPath.withCString { ep in
                    pyx_run_file(cp, op, ep, &err, err.count)
                }
            }
        }
        let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
        if rc != 0 && out.isEmpty {
            throw MCPError.classified("py: 执行失败 — \(String(cString: err))", code: "PY_RUN_FAILED",
                                      reason: "tool", nextStep: "检查代码语法；解释器级错误无 traceback 时多为 stdlib 路径问题")
        }
        return out.count > limit ? String(out.prefix(limit)) + "\n…(截断)" : out
    }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = (params["command"] as? String)?.lowercased(), !command.isEmpty else {
            throw MCPError.invalidParams("py: missing command (eval / script / status)")
        }
        let limit = max(1000, (params["limit"] as? Int) ?? 200_000)
        let timeoutRaw = (params["timeout"] as? NSNumber)?.doubleValue ?? 120
        let timeout = min(max(timeoutRaw, 1), 600)

        switch command {
        case "status":
            let e = ensureInit()
            if !e.isEmpty {
                return ["ready": false, "error": e, "framework": frameworkPath, "home": homePath,
                        "python_path": pathList]
            }
            let ver = (try? run(code: "import sys; print(sys.version); print(sys.executable or '(embedded)')", limit: 4000)) ?? ""
            return ["ready": true, "framework": frameworkPath, "home": homePath,
                    "python_path": pathList, "version": ver.trimmingCharacters(in: .whitespacesAndNewlines),
                    "note": "解释器运行在 App 进程内，不经过任何子进程"]

        case "eval":
            guard let code = params["code"] as? String, !code.isEmpty else {
                throw MCPError.invalidParams("py eval: missing code")
            }
            let out = try runBounded(code: code, limit: limit, timeout: timeout)
            return ["command": "eval", "ok": true, "stdout": out, "runtime": "in-process CPython"]

        case "script":
            guard let path = params["path"] as? String, !path.isEmpty else {
                throw MCPError.invalidParams("py script: missing path")
            }
            guard let code = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw MCPError.classified("py: 读不到脚本 \(path)", code: "NOT_FOUND",
                                          reason: "path", nextStep: "确认路径与编码（UTF-8）")
            }
            let out = try runBounded(code: code, limit: limit, timeout: timeout)
            return ["command": "script", "ok": true, "path": path, "stdout": out, "runtime": "in-process CPython"]

        default:
            throw MCPError.invalidParams("py: unknown command '\(command)' (eval / script / status)")
        }
    }
}
