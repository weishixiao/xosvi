import Foundation

// MARK: - v8.2：轻量崩溃采集（TrollStore/侧载也能用的进程内捕获）
//
// 已有 CrashCatcher（v2.9.145c，signal-safe C 级写盘 Workspace/crash/）覆盖 SIGSEGV/SIGBUS/
// SIGABRT 等 6 个信号。这里补它没有的两块：
//   1. NSSetUncaughtExceptionHandler——ObjC NSException（数组越界等）不走信号，CrashCatcher 抓不到
//   2. 面包屑（breadcrumb）——AuditLog.logResult 每次工具调用后刷新，崩溃日志里自带
//      "崩前最后一次调了什么工具"，排障时能把崩溃定位到具体工具调用
// 日志落 Documents/CrashLogs/crash-<unix>.log，与 CrashCatcher 的 Workspace/crash/ 互不干扰。

final class CrashReporter {
    static let shared = CrashReporter()
    private static var lastBreadcrumb = ""

    /// AuditLog.logResult 每次工具调用后刷新
    static func setBreadcrumb(_ s: String) {
        lastBreadcrumb = String(s.prefix(300))
    }

    private static var installed = false

    func start() {
        guard !CrashReporter.installed else { return }
        CrashReporter.installed = true
        NSSetUncaughtExceptionHandler { ex in
            let msg = "exception:\(ex.name.rawValue)\n"
                + "reason:\(ex.reason ?? "-")\n"
                + "stack:\(ex.callStackSymbols.prefix(20).joined(separator: "\n"))\n"
                + "breadcrumb:\(CrashReporter.lastBreadcrumb)"
            CrashReporter.write(msg)
        }
        // NSException 之外的硬信号仍由 CrashCatcher 主力（signal-safe 写盘）。
        // 这里不重复注册信号 handler——后注册者会覆盖前者，反而削弱现有采集。
    }

    static func write(_ text: String) {
        let dir = URL(fileURLWithPath: XDirs.crashLogs, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).log")
        try? text.data(using: .utf8)?.write(to: path)
    }

    static func logs() -> [URL] {
        var out: [URL] = []
        let dir = URL(fileURLWithPath: XDirs.crashLogs, isDirectory: true)
        if let here = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter({ $0.lastPathComponent.hasPrefix("crash-") }) {
            out += here
        }
        // 顺带把 CrashCatcher 的旧日志（Workspace/crash/）也纳入——一个入口看全部
        let legacyDir = Workspace.root.appendingPathComponent("crash", isDirectory: true)
        if let legacy = (try? FileManager.default.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil))?
            .filter({ !$0.lastPathComponent.hasPrefix(".") }) {
            out += legacy
        }
        return out.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
