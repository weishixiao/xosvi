import Foundation

// MARK: - v10.1：分析型任务自动落盘可读报告
//
// 问题：一轮里跑了七八个工具、翻了几十个文件，最后的结论只活在聊天流里。
// 想回头看、想给别人看、想当文档存，都得自己从气泡里抄。
//
// 机制：本轮**真的查过东西**（工具执行 ≥3 次）并且**给出了有分量的结论**（≥300 字），
// 就在本轮结束时把结论 + 执行轨迹 + 关键输出摘录写成一份 Markdown，
// 落到 <数据根>/Workspace/reports/（工作区 UI 里显示为「分析报告」），
// 并在回复末尾补一行可点开的路径。
//
// 不是提示词要求模型「请输出报告」——模型怎么写就怎么写，这里只负责把已经产出的东西存成文档。

/// 一次工具执行的记录（RunReport 的原料）
struct RunToolEntry {
    let tool: String
    let args: String
    let result: String
    let isError: Bool
    let durationMs: Int
    let narration: String?
}

enum RunReport {

    /// 报告目录（工作区 UI 把 reports 映射成「分析报告」）
    static var directory: String { XDirs.workspace + "/reports" }

    /// 判定：这轮值不值得留文档
    static func shouldWrite(entryCount: Int, answer: String) -> Bool {
        let chars = answer.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard chars >= 120 else { return false }
        // 出错了 / 被预算或轮次上限截断的收尾不当作分析结果存
        if answer.contains("[[RUN_TERMINATED]]") || answer.contains("[[RUN_BUDGET") { return false }
        if entryCount >= 3 && chars >= 300 { return true }
        if entryCount >= 6 && chars >= 180 { return true }
        return false
    }

    /// 写报告，返回绝对路径；失败返回 nil（报告是加分项，不能影响本轮回复）
    static func write(question: String,
                      answer: String,
                      entries: [RunToolEntry],
                      startedAt: Date,
                      finishedAt: Date) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let slug = slugify(question)
        let name = stamp.string(from: finishedAt) + (slug.isEmpty ? "" : "-" + slug) + ".md"
        let path = directory + "/" + name

        let body = render(question: question, answer: answer, entries: entries,
                          startedAt: startedAt, finishedAt: finishedAt)
        do {
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    // MARK: - 渲染

    private static func render(question: String,
                               answer: String,
                               entries: [RunToolEntry],
                               startedAt: Date,
                               finishedAt: Date) -> String {
        let human = DateFormatter()
        human.locale = Locale(identifier: "en_US_POSIX")
        human.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let ok = entries.filter { !$0.isError }.count
        let failed = entries.count - ok
        let seconds = max(0, Int(finishedAt.timeIntervalSince(startedAt).rounded()))

        var out = ""
        out += "# " + headline(question) + "\n\n"
        out += "- 生成时间：\(human.string(from: finishedAt))\n"
        out += "- 耗时：\(seconds)s　工具调用：\(entries.count) 次（成功 \(ok)"
        if failed > 0 { out += "，失败 \(failed)" }
        out += "）\n\n"

        out += "## 结论\n\n"
        out += answer.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"

        if !entries.isEmpty {
            out += "## 执行轨迹\n\n"
            out += "| # | 状态 | 工具 | 参数 / 结果 |\n|---|---|---|---|\n"
            for (i, e) in entries.enumerated() {
                let status = e.isError ? "❌" : "✅"
                let tool = escape(e.tool)
                let brief = escape(firstLine(e.narration?.isEmpty == false ? e.narration! : e.args))
                let ms = e.durationMs > 0 ? "（\(e.durationMs)ms）" : ""
                out += "| \(i + 1) | \(status) | `\(tool)` | \(brief)\(ms) |\n"
            }
            out += "\n"

            out += "## 关键输出\n\n"
            for (i, e) in entries.enumerated() {
                out += "### \(i + 1). `\(e.tool)`\(e.isError ? "（失败）" : "")\n\n"
                if !e.args.isEmpty {
                    out += "参数：`" + escape(firstLine(e.args)) + "`\n\n"
                }
                out += "```\n" + excerpt(e.result, limit: 1500) + "\n```\n\n"
            }
        }

        out += "---\n\n"
        out += "由 Xosvi 在本次 run 结束时自动生成（`RunReport`）。\n"
        return out
    }

    private static func headline(_ question: String) -> String {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if q.isEmpty { return "分析报告" }
        return q.count > 60 ? String(q.prefix(60)) + "…" : q
    }

    private static func firstLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        let line = t.components(separatedBy: "\n").first ?? t
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }

    private static func excerpt(_ s: String, limit: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "(空)" }
        if t.count <= limit { return t }
        return String(t.prefix(limit)) + "\n…[已截断，原文 \(t.count) 字符]"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
    }

    /// 文件名里只用安全字符，避免中文/空格在某些文件系统视图里出问题
    private static func slugify(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        var out = ""
        for ch in s.lowercased() {
            if allowed.contains(ch) {
                out.append(ch)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
            if out.count >= 24 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // MARK: - 会话内提示

    /// 追加到回复末尾的那一行（Markdown，聊天里以纯文本显示，可直接抄路径）
    static func footer(path: String) -> String {
        "📄 报告已保存：`\(path)`"
    }
}
