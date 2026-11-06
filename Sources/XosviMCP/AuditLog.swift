import Foundation
import Combine

/// 审计日志：记录所有 MCP 工具调用与系统事件
/// v2.9.126：内存 500 条 + 文件日志按天滚动
/// v8.6：按文档删除行式文件日志写入器（audit-YYYYMMDD.log）——只保留结构化
///       tool_log.jsonl（AuditEntry，含失败原因/耗时/参数摘要），不再双写。
///       内存 entries 仍保留给「调用记录」Tab 与导出用。
final class AuditLog: ObservableObject {
    static let shared = AuditLog()

    struct Entry: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var timestamp: Date = Date()
        var category: String
        var detail: String
        var level: Level = .info
        // v2.9.36：老 MCP 审计字段（执行状态/耗时/数据量/权限类型）
        var status: EntryStatus? = nil
        var elapsedMs: Int? = nil
        var dataBytes: Int? = nil
        var permission: String? = nil
        // v2.9.128：CLI 错误四分类（env/target/param/tool）——让用户和 AI 都能看到"为什么失败"
        var errorCode: String? = nil
        var errorReason: String? = nil
        var nextStep: String? = nil

        enum Level: String, Codable {
            case info, warning, error
        }

        enum EntryStatus: String, Codable {
            case success, failure
        }
    }

    @Published var entries: [Entry] = []
    private let maxEntries = 500

    private let logQueue = DispatchQueue(label: "xosvi.auditlog.file")

    init() {}

    func log(_ category: String, detail: String, level: Entry.Level = .info) {
        DispatchQueue.main.async {
            self.entries.insert(Entry(category: category, detail: detail, level: level), at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast()
            }
        }
    }

    // v2.9.36：工具调用统一审计（在 ToolRegistry.dispatch 入口记录）
    // v2.9.128：新增 code/reason/nextStep——失败时记录 CLI 四分类，供健康度聚合与 AI 自查
    func logTool(_ category: String, status: Entry.EntryStatus, elapsedMs: Int, dataBytes: Int,
                 permission: String, detail: String = "",
                 code: String? = nil, reason: String? = nil, nextStep: String? = nil) {
        DispatchQueue.main.async {
            self.entries.insert(Entry(category: category, detail: detail,
                                      status: status, elapsedMs: elapsedMs,
                                      dataBytes: dataBytes, permission: permission,
                                      errorCode: code, errorReason: reason, nextStep: nextStep), at: 0)
            if self.entries.count > self.maxEntries {
                self.entries.removeLast()
            }
        }
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - v2.9.128 工具健康度聚合（从内存 entries 现算）

    struct ToolHealth: Identifiable {
        var id: String { tool }
        let tool: String
        let success: Int
        let failure: Int
        let avgMs: Int
        let topCode: String
        let lastFailureDetail: String
        var failureRate: Double { failure == 0 ? 0 : Double(failure) / Double(failure + success) }
    }

    struct CodeDist: Identifiable {
        var id: String { code }
        let code: String
        let count: Int
    }

    /// 按工具聚合健康度：失败数排序 → 一眼看出"哪些工具有问题"
    func healthSummary(limit: Int = 30) -> [ToolHealth] {
        var map: [String: (s: Int, f: Int, ms: [Int], code: [String: Int], lastFail: String)] = [:]
        for e in entries where e.status != nil && !e.category.isEmpty {
            let k = e.category
            var v = map[k] ?? (s: 0, f: 0, ms: [Int](), code: [String: Int](), lastFail: "")
            if e.status == .success { v.s += 1 }
            else {
                v.f += 1
                let c = e.errorCode ?? "unknown"
                v.code[c, default: 0] += 1
                v.lastFail = e.errorReason ?? e.detail
            }
            if let ms = e.elapsedMs { v.ms.append(ms) }
            map[k] = v
        }
        var ranked: [(tool: String, s: Int, f: Int, ms: [Int], code: [String: Int], lastFail: String)] = []
        for (tool, v) in map {
            if v.f > 0 || v.s > 0 {
                ranked.append((tool, v.s, v.f, v.ms, v.code, v.lastFail))
            }
        }
        ranked.sort { $0.f != $1.f ? $0.f > $1.f : $0.tool < $1.tool }
        var out: [ToolHealth] = []
        for item in ranked.prefix(limit) {
            let avg = item.ms.isEmpty ? 0 : item.ms.reduce(0, +) / item.ms.count
            let topCode = item.code.max { $0.value < $1.value }?.key ?? "ok"
            out.append(ToolHealth(tool: item.tool, success: item.s, failure: item.f,
                                  avgMs: avg, topCode: topCode,
                                  lastFailureDetail: String(item.lastFail.prefix(160))))
        }
        return out
    }

    /// 错误码分布（env/target/param/tool + unknown）
    func codeDistribution() -> [CodeDist] {
        var map: [String: Int] = [:]
        for e in entries where e.status == .failure {
            let c = (e.errorCode ?? "unknown").isEmpty ? "unknown" : e.errorCode!
            map[c, default: 0] += 1
        }
        return map.map { CodeDist(code: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// 最近失败明细（供审计页/AI 自查）
    func recentFailures(limit: Int = 20) -> [Entry] {
        entries.filter { $0.status == .failure }.prefix(limit).map { $0 }
    }

    // MARK: - v8.2 结构化工具调用记录（JSONL 持久化，含失败原因）
    //
    // 旧 logTool 只写人读的行式文件；这里补机器可读的 JSONL（Documents/audit/tool_log.jsonl），
    // 审计页按记录展示失败原因/耗时/参数摘要。滚动保留最近 500 条。

    struct AuditEntry: Codable, Identifiable, Hashable {
        var id = UUID()
        var ts: Date = Date()
        var tool: String
        /// 参数摘要（键=值 截断），不存全量（可能含 path/key）
        var paramsDigest: String
        var ok: Bool
        /// 失败原因，成功时空串
        var error: String
        var durationMs: Int
    }

    private static let jsonlLimit = 500
    private var jsonlURL: URL {
        let dir = URL(fileURLWithPath: XDirs.audit, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tool_log.jsonl")
    }

    /// 工具调度处统一调用：失败原因（throw 与返回 error 字典两种形态都进这里）
    func logResult(tool: String, params: [String: Any], ok: Bool,
                   error: String? = nil, durationMs: Int) {
        let digest = params.keys.sorted()
            .map { "\($0)=\(String(describing: params[$0] ?? "").prefix(40))" }
            .joined(separator: "&")
        let e = AuditEntry(tool: tool,
                           paramsDigest: String(digest.prefix(200)),
                           ok: ok,
                           error: String((error ?? "").prefix(600)),
                           durationMs: durationMs)
        appendEntry(e)
        // 崩溃现场Breadcrumb：崩前最后一次调了什么工具（配合 CrashReporter 排障）
        CrashReporter.setBreadcrumb("\(tool) \(ok ? "ok" : "fail") \(durationMs)ms")
    }

    private func appendEntry(_ e: AuditEntry) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            let url = self.jsonlURL
            guard let data = try? JSONEncoder().encode(e) else { return }
            var line = data
            line.append(0x0A) // \n
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
            // 滚动：超过上限截掉最旧的
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                if lines.count > Self.jsonlLimit {
                    let kept = lines.suffix(Self.jsonlLimit).joined(separator: "\n") + "\n"
                    try? kept.data(using: .utf8)?.write(to: url)
                }
            }
        }
    }

    /// 审计页读取（最新的在前）
    func loadEntries(limit: Int = 500) -> [AuditEntry] {
        guard let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [AuditEntry] = []
        for line in content.components(separatedBy: "\n").reversed() where !line.isEmpty {
            guard out.count < limit, let data = line.data(using: .utf8),
                  let e = try? decoder.decode(AuditEntry.self, from: data) else { continue }
            out.append(e)
        }
        return out
    }
}
