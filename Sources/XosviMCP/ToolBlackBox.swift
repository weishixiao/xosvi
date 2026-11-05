// ToolBlackBox.swift — 工具调用黑匣子
//
// 解决「不知道调了哪个工具就直接闪退，且没有崩溃日志」：
// 每次 dispatch 真正执行前，把工具名 + 参数摘要写进 Workspace/.runtime/last-tool.json。
// 闪退时文件会停在 phase="start" —— 下次启动 `diagnose lasttool` 就能看到最后调的是谁。
// 正常结束会写成 phase="done"，所以残留 start 就是"这条调用没走完"。

import Foundation

enum ToolBlackBox {
    static var fileURL: URL {
        Workspace.root
            .appendingPathComponent(".runtime", isDirectory: true)
            .appendingPathComponent("last-tool.json")
    }

    /// 参数摘要：单值截断 120 字，整体截断 400 字
    static func preview(_ params: [String: Any]) -> String {
        var parts: [String] = []
        for (k, v) in params.sorted(by: { $0.key < $1.key }) {
            var s = "\(v)"
            if s.count > 120 { s = String(s.prefix(120)) + "…" }
            parts.append("\(k)=\(s)")
        }
        return String(parts.joined(separator: " ").prefix(400))
    }

    static func mark(tool: String, params: [String: Any], phase: String) {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "ts": formatter.string(from: now),
            "epoch": now.timeIntervalSince1970,
            "tool": tool,
            "phase": phase,
            "thread": Thread.isMainThread ? "main" : "bg",
            "params": preview(params),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// 读取最后一次记录（没有则 nil）
    static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: fileURL),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// 是否"上次调用没走完"（= 可能就是在它上面闪退的）
    static func lastCrashedTool() -> [String: Any]? {
        guard let obj = read() else { return nil }
        let phase = (obj["phase"] as? String) ?? ""
        return phase == "start" ? obj : nil
    }

    // MARK: - v9.2：追加式面包屑（定位「卡在哪一步」用）

    static var breadcrumbURL: URL {
        Workspace.root
            .appendingPathComponent(".runtime", isDirectory: true)
            .appendingPathComponent("tool-breadcrumbs.jsonl")
    }

    /// 每次进入/退出工具调用追加一行（工具名、argsHash、起止时间、结果 hash、是否被守卫拦）。
    /// 与 last-tool.json 的区别：后者只留最后一次（闪退看现场），本文件留一串（看路径）。
    /// 配合 watch 桥，卡死时能直接看到最后一条 start 之后再没有 done —— 卡的就是它。
    static func breadcrumb(tool: String, params: [String: Any], phase: String,
                           info: [String: Any] = [:]) {
        let now = Date()
        var row: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: now),
            "epoch": now.timeIntervalSince1970,
            "tool": tool,
            "phase": phase,
            "args_hash": ToolLoopGuard.argsHash(tool: tool, params: params),
            "thread": Thread.isMainThread ? "main" : "bg",
        ]
        for (k, v) in info { row[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        let dir = breadcrumbURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let fh = try? FileHandle(forWritingTo: breadcrumbURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            fh.write(data)
            fh.write(Data("\n".utf8))
        } else {
            try? (data + Data("\n".utf8)).write(to: breadcrumbURL, options: .atomic)
        }
        // 滚动：只留最近 200 行，避免长期运行把工作区写满
        trimBreadcrumbs()
    }

    private static func trimBreadcrumbs() {
        guard let text = try? String(contentsOf: breadcrumbURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 200 else { return }
        let kept = lines.suffix(200).joined(separator: "\n") + "\n"
        try? kept.write(to: breadcrumbURL, atomically: true, encoding: .utf8)
    }

    /// 读出最近的 N 条面包屑（诊断工具 / 手工排查用）
    static func readBreadcrumbs(limit: Int = 40) -> [[String: Any]] {
        guard let text = try? String(contentsOf: breadcrumbURL, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(limit).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }
}
