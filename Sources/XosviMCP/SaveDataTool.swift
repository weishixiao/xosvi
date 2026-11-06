import Foundation
import SQLite3

/// v6.6.16：存档修改（游戏数据修改的「无 spawn」通路）。
///
/// 背景：用户设备 App bundle 属主异常（uid=33）+ 缺 no-sandbox，导致 posix_spawn 全线失败：
///   · Alpine 引擎起不来（for 循环路由失败）
///   · 原生 python3 起不来
///   · MemoryTweak 注入失败
/// 但**改存档根本不需要执行任何子进程** —— 存档就是 SQLite / plist 文件，
/// 用 SQLite3 C API 与 PropertyListSerialization 直接在进程内读写即可。
///
/// 子命令：
///   discover  按 bundle_id 找存档（sqlite / plist / 存档目录）
///   read      sqlite 查询（SELECT）或 plist 读取
///   write     sqlite 写入（UPDATE/INSERT）或 plist 修改
///   dump      sqlite 表结构 + 前 N 行
final class SaveDataTool: MCPTool {
    let definition = ToolDefinition(
        name: "save",
        summary: "Edit game/app save data WITHOUT root, injection or Alpine — reads/writes SQLite and plist files directly in-process. Use for: game currency/HP/level edits when injection is unavailable, app data forensics, config tweaks. Don't use for: files inside an encrypted app bundle (use inject), live memory values (use memory). Example: game gold → save {command:'discover', bundle_id:'com.x.y'} then save {command:'write', path:'...', sql:\"UPDATE ...\"}.",
        parameters: [
            "command": "discover / read / write / dump",
            "bundle_id": "For discover: target app bundle id",
            "path": "Absolute path to .sqlite/.db/.plist file",
            "sql": "For sqlite read/write: SQL statement",
            "key": "For plist: key path (dot separated, e.g. 'Player.Coins')",
            "value": "For plist write: new value (string/number/bool auto-detect)",
            "limit": "For dump: max rows (default 20)"
        ],
        verified: true,
        category: "file",
        prerequisites: [
            "只读操作无需任何权限；写入需要 App 数据容器可写（通常已满足）",
            "不依赖 Alpine 引擎 / posix_spawn / 注入（纯文件写入，环境怎么变都能用）"
        ])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = (params["command"] as? String)?.lowercased(), !command.isEmpty else {
            throw MCPError.invalidParams("command required: discover/read/write/dump")
        }
        switch command {
        case "discover": return try discover(params)
        case "read":     return try read(params)
        case "write":    return try write(params)
        case "dump":     return try dump(params)
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: discover/read/write/dump")
        }
    }

    // MARK: - discover

    private func discover(_ params: [String: Any]) throws -> [String: Any] {
        guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        // 通过 App 列表拿 dataContainer
        guard let app = AppCatalog.list().first(where: { $0.bundleId == bid }) else {
            return ["message": "未找到 App：\(bid)", "hint": "用 app list 确认 bundle_id"]
        }
        let house = NSHomeDirectory() // 本 App 容器
        // 目标 App 数据容器：优先 container 解析
        let candidates = [
            "/var/mobile/Containers/Data/Application",
            "/private/var/mobile/Containers/Data/Application"
        ]
        var found: [[String: Any]] = []
        for root in candidates {
            guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for d in dirs.prefix(400) {
                let meta = root + "/" + d + "/.com.apple.mobile_container_manager.metadata.plist"
                guard let dict = NSDictionary(contentsOfFile: meta),
                      let mid = dict["MCMMetadataIdentifier"] as? String,
                      mid == bid else { continue }
                found.append(contentsOf: scanSaveFiles(root + "/" + d))
            }
        }
        // 也扫 App bundle 自身（有些游戏把初始存档放 bundle）
        found.append(contentsOf: scanSaveFiles(app.path))

        // 去重
        var seen = Set<String>()
        let unique = found.filter { item in
            guard let p = item["path"] as? String else { return false }
            return seen.insert(p).inserted
        }
        return [
            "message": unique.isEmpty
                ? "未在 \(bid) 容器中找到 sqlite/plist 存档（可能加密或使用自定义格式）"
                : "找到 \(unique.count) 个候选存档文件",
            "bundle_id": bid,
            "files": Array(unique.prefix(60)),
            "hint": "用 save {command:'dump', path:'...'} 看表结构；plist 用 read 直接看内容"
        ]
    }

    private func scanSaveFiles(_ root: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return out }
        var count = 0
        for case let rel as String in en {
            count += 1
            if count > 6000 { break }   // 防遍历爆炸
            let lower = rel.lowercased()
            guard lower.hasSuffix(".sqlite") || lower.hasSuffix(".db")
                || lower.hasSuffix(".sqlite3") || lower.hasSuffix(".plist") else { continue }
            let full = root + "/" + rel
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.intValue ?? 0
            if size == 0 { continue }
            // 跳过系统噪音
            if lower.contains("/library/caches/") && lower.hasSuffix(".plist") { continue }
            out.append([
                "path": full,
                "size": size,
                "kind": lower.hasSuffix(".plist") ? "plist" : "sqlite"
            ])
        }
        return out
    }

    // MARK: - read

    private func read(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        if path.lowercased().hasSuffix(".plist") {
            guard let dict = NSDictionary(contentsOfFile: path) else {
                // 可能是二进制 plist 但读取失败
                guard let data = FileManager.default.contents(atPath: path),
                      let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
                    return ["message": "plist 读取失败", "path": path]
                }
                return ["message": "plist 已读取", "path": path, "content": String(describing: obj)]
            }
            return ["message": "plist 已读取", "path": path, "content": dict]
        }
        guard let sql = params["sql"] as? String, !sql.isEmpty else {
            throw MCPError.invalidParams("sql required for sqlite read (or use dump)")
        }
        return query(path: path, sql: sql)
    }

    // MARK: - write

    private func write(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        if path.lowercased().hasSuffix(".plist") {
            guard let key = params["key"] as? String, !key.isEmpty,
                  let raw = params["value"] else {
                throw MCPError.invalidParams("key and value required for plist write")
            }
            return plistWrite(path: path, keyPath: key, rawValue: raw)
        }
        guard let sql = params["sql"] as? String, !sql.isEmpty else {
            throw MCPError.invalidParams("sql required for sqlite write")
        }
        let lower = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix("update") || lower.hasPrefix("insert")
                || lower.hasPrefix("replace") || lower.hasPrefix("delete") else {
            return ["message": "只允许 UPDATE / INSERT / REPLACE / DELETE（防误删表）", "sql": sql]
        }
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return ["message": "打开数据库失败：\(err)", "path": path]
        }
        defer { sqlite3_close(db) }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        let changes = sqlite3_changes(db)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            return ["message": "SQL 失败：\(msg)", "path": path, "sql": sql]
        }
        return [
            "message": "写入成功，影响 \(changes) 行",
            "path": path,
            "sql": sql,
            "rows_affected": Int(changes)
        ]
    }

    // MARK: - dump

    private func dump(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("path required")
        }
        let limit = min(max(params["limit"] as? Int ?? 20, 1), 200)
        let tables = query(path: path, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        guard let rows = tables["rows"] as? [[String: Any]], !rows.isEmpty else {
            return ["message": "没有表或读取失败", "path": path, "detail": tables]
        }
        var summary: [[String: Any]] = []
        for row in rows.prefix(20) {
            guard let t = row["name"] as? String else { continue }
            let schema = query(path: path, sql: "SELECT sql FROM sqlite_master WHERE name='\(t.replacingOccurrences(of: "'", with: "''"))'")
            let sample = query(path: path, sql: "SELECT * FROM \"\(t)\" LIMIT \(limit)")
            summary.append([
                "table": t,
                "schema": (schema["rows"] as? [[String: Any]])?.first?["sql"] ?? "",
                "sample": sample["rows"] ?? [],
                "rows_in_sample": (sample["rows"] as? [[String: Any]])?.count ?? 0
            ])
        }
        return ["message": "共 \(rows.count) 张表（展示前 20）", "path": path, "tables": summary]
    }

    // MARK: - SQLite 查询

    private func query(path: String, sql: String) -> [String: Any] {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let err = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            return ["message": "打开数据库失败：\(err)", "path": path]
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            return ["message": "SQL 错误：\(err)", "path": path, "sql": sql]
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [[String: Any]] = []
        let colCount = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_NULL:
                    row[name] = NSNull()
                default:
                    if let c = sqlite3_column_text(stmt, i) {
                        row[name] = String(cString: c)
                    } else {
                        row[name] = NSNull()
                    }
                }
            }
            rows.append(row)
            if rows.count >= 500 { break }   // 防爆
        }
        return ["path": path, "sql": sql, "rows": rows, "count": rows.count]
    }

    // MARK: - plist 写入（支持点分 keyPath）

    private func plistWrite(path: String, keyPath: String, rawValue: Any) -> [String: Any] {
        // 备份
        let bak = path + ".haxbak"
        if !FileManager.default.fileExists(atPath: bak) {
            try? FileManager.default.copyItem(atPath: path, toPath: bak)
        }
        guard let data = FileManager.default.contents(atPath: path),
              var root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return ["message": "plist 解析失败", "path": path]
        }
        let keys = keyPath.split(separator: ".").map(String.init)

        // 类型推断
        let newValue: Any
        if let s = rawValue as? String {
            if let i = Int(s) { newValue = i }
            else if let d = Double(s) { newValue = d }
            else if s.lowercased() == "true" { newValue = true }
            else if s.lowercased() == "false" { newValue = false }
            else { newValue = s }
        } else {
            newValue = rawValue
        }

        func setIn(_ obj: Any, _ idx: Int) -> Any? {
            if idx == keys.count { return newValue }
            let k = keys[idx]
            if var dict = obj as? [String: Any] {
                if idx == keys.count - 1 {
                    dict[k] = newValue
                } else if let child = dict[k], let updated = setIn(child, idx + 1) {
                    dict[k] = updated
                } else {
                    return nil
                }
                return dict
            }
            return nil
        }

        guard let updated = setIn(root, 0) else {
            return ["message": "keyPath 不存在：\(keyPath)（为避免误改，不自动创建新 key）", "path": path]
        }
        root = updated

        guard let out = try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) else {
            return ["message": "序列化失败", "path": path]
        }
        do {
            try out.write(to: URL(fileURLWithPath: path))
            return [
                "message": "已写入 \(keyPath) = \(newValue)（备份：\(bak)）",
                "path": path,
                "key": keyPath,
                "value": String(describing: newValue)
            ]
        } catch {
            return ["message": "写入失败：\(error.localizedDescription)", "path": path]
        }
    }
}
