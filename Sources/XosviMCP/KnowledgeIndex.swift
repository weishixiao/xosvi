import Foundation
import UIKit
import SQLite3

// MARK: - v8.4：知识库 FTS5 全文索引（升级现有文件 BM25 检索）
//
// 现有 KnowledgeStore.bm25Search 是"每次扫描所有知识库文件构建索引"——文件多了会慢。
// 这里补 SQLite FTS5 层（NativeSQLite 已链接 sqlite3，fts5 编译开关需 CI 确认）：
//   · 建表 fts5(id, title, tags, body, tokenize='unicode61')，中文逐字切 + 2-gram 混合查询
//   · bm25(kb, 8.0, 4.0, 1.0) 加权：标题命中 > 标签 > 正文
//   · applies_if 环境过滤加权：当前环境命中越具体越优先
//   · 全量 rebuild（导入/升级后）+ meta 记录构建时间与条目数
//
// 数据源：Documents/Knowledge/*.json（现有种子 md 可后续转 JSON；两种并存时 FTS 只吃 JSON）。
// 条目结构：{id, title, tags:[], applies_if:[], body, updated}

struct KnowledgeEntry: Codable {
    var id: String
    var title: String
    var tags: [String]
    var appliesIf: [String]
    var body: String
    var updated: String
    enum CodingKeys: String, CodingKey {
        case id, title, tags, body, updated
        case appliesIf = "applies_if"
    }
}

struct KnowledgePack: Codable {
    var pack: String?
    var entries: [KnowledgeEntry]
}

struct KnowledgeHit {
    var id: String
    var title: String
    var body: String
    var score: Double
    var appliesIf: [String]
}

final class KnowledgeIndex {
    static let shared = KnowledgeIndex()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "xosvi.kb.index")

    private var dbPath: String {
        // v9.12：索引落到本 App 数据根。共享 Documents 下那份与上游 TrollAgent 共用，
        // 两边的 SQLite WAL 会互相抢锁。
        let dir = URL(fileURLWithPath: XDirs.knowledge, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kb.sqlite").path
    }

    func open() {
        queue.sync {
            guard db == nil else { return }
            guard sqlite3_open(dbPath, &db) == SQLITE_OK else { return }
            exec("PRAGMA journal_mode=WAL;")
            // 中文用 unicode61（逐字切）；查询侧用 2-gram 提升命中率
            exec("""
                CREATE VIRTUAL TABLE IF NOT EXISTS kb USING fts5(
                    id UNINDEXED, title, tags, body, applies_if UNINDEXED, updated UNINDEXED,
                    tokenize='unicode61'
                );
                """)
            exec("CREATE TABLE IF NOT EXISTS kb_meta (k TEXT PRIMARY KEY, v TEXT);")
        }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// 全量重建索引（导入/升级知识包后调用）
    func rebuild(packs: [KnowledgePack]) {
        open()
        queue.sync {
            exec("DELETE FROM kb;")
            exec("BEGIN;")
            var stmt: OpaquePointer?
            let sql = "INSERT INTO kb(id,title,tags,body,applies_if,updated) VALUES(?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("COMMIT;")
                return
            }
            defer { sqlite3_finalize(stmt) }
            var count = 0
            for pack in packs {
                for e in pack.entries {
                    sqlite3_reset(stmt)
                    // 标签与 applies_if 拼进 tags 列参与检索
                    let tagText = (e.tags + e.appliesIf).joined(separator: " ")
                    bind(stmt, 1, e.id); bind(stmt, 2, e.title)
                    bind(stmt, 3, tagText); bind(stmt, 4, e.body)
                    bind(stmt, 5, e.appliesIf.joined(separator: ",")); bind(stmt, 6, e.updated)
                    if sqlite3_step(stmt) == SQLITE_DONE { count += 1 }
                }
            }
            exec("COMMIT;")
            setMeta("built_at", "\(Int(Date().timeIntervalSince1970))")
            setMeta("entry_count", "\(count)")
        }
    }

    /// 检索（BM25 + applies_if 环境加权）
    /// context: 当前设备/会话条件，如 ["rootless","ios17","jailbroken"]
    func search(_ query: String, context: [String] = [], limit: Int = 3) -> [KnowledgeHit] {
        open()
        var out: [KnowledgeHit] = []
        queue.sync {
            guard db != nil else { return }
            let terms = Self.terms(from: query)
            guard !terms.isEmpty else { return }
            let match = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
            let sql = """
                SELECT id, title, body, applies_if, bm25(kb, 8.0, 4.0, 1.0) AS score
                FROM kb WHERE kb MATCH ? ORDER BY score LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (match as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit * 3))   // 多取再按环境加权重排
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let title = String(cString: sqlite3_column_text(stmt, 1))
                let body = String(cString: sqlite3_column_text(stmt, 2))
                let ai = (String(cString: sqlite3_column_text(stmt, 3)))
                    .split(separator: ",").map(String.init)
                var score = -sqlite3_column_double(stmt, 4)   // bm25 越小越好，取负转大
                // applies_if 命中当前环境 → 加权（环境越具体越优先）
                if !ai.isEmpty, ai.allSatisfy({ context.contains($0) }) { score += 5.0 }
                out.append(KnowledgeHit(id: id, title: title, body: body,
                                        score: score, appliesIf: ai))
            }
            out.sort { $0.score > $1.score }
            out = Array(out.prefix(limit))
        }
        return out
    }

    func meta(_ k: String) -> String? {
        guard db != nil else { return nil }
        var result: String?
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT v FROM kb_meta WHERE k = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (k as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = String(cString: sqlite3_column_text(stmt, 0))
            }
        }
        return result
    }

    private func setMeta(_ k: String, _ v: String) {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO kb_meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, k); bind(stmt, 2, v)
        _ = sqlite3_step(stmt)
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ v: String) {
        sqlite3_bind_text(stmt, i, (v as NSString).utf8String, -1, nil)
    }

    /// 查询分词：英文按词、中文按 2-gram（比逐字命中率高）
    static func terms(from q: String) -> [String] {
        let cleaned = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        var out = Set(cleaned)
        let cjk = q.filter { $0.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false }
        let chars = Array(cjk)
        if chars.count >= 2 {
            for i in 0..<(chars.count - 1) { out.insert(String(chars[i...i + 1])) }
        }
        return Array(out).sorted { $0.count > $1.count }   // 长词优先
    }
}

// MARK: - 知识包加载

enum KnowledgeLoader {
    /// 内置包：Bundle Resources/Knowledge/*.json + Documents/Knowledge/custom/*.json
    static func loadAll() -> [KnowledgePack] {
        var packs: [KnowledgePack] = []
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Knowledge") {
            for u in urls {
                if let d = try? Data(contentsOf: u),
                   let p = try? JSONDecoder().decode([KnowledgeEntry].self, from: d) {
                    packs.append(KnowledgePack(pack: u.lastPathComponent, entries: p))
                }
            }
        }
        // v9.12：自定义条目跟索引同目录，落在本 App 数据根（迁移时已从共享 Documents 复制过来）
        let customDir = URL(fileURLWithPath: XDirs.knowledge + "/custom", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(at: customDir, includingPropertiesForKeys: nil) {
            for u in files where u.pathExtension == "json" {
                if let d = try? Data(contentsOf: u),
                   let p = try? JSONDecoder().decode([KnowledgeEntry].self, from: d) {
                    packs.append(KnowledgePack(pack: "custom/\(u.lastPathComponent)", entries: p))
                }
            }
        }
        return packs
    }

    /// 当前设备环境上下文（applies_if 匹配用）
    static var deviceContext: [String] {
        var ctx: [String] = []
        switch ExecutionStrategy.tier() {
        case .rootHide: ctx += ["jailbroken", "roothide"]
        case .jailbroken: ctx += ["jailbroken"]
        case .trollStore: ctx += ["trollstore"]
        default: break
        }
        let ver = UIDevice.current.systemVersion
        if let major = ver.split(separator: ".").first, let n = Int(major) { ctx.append("ios\(n)") }
        return ctx
    }
}
