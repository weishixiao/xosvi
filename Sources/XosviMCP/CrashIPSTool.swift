// CrashIPSTool.swift — .ips / .crash 崩溃报告结构化解析（v7.18.0）
//
// 对齐 REA 的 `inspect.ips`：把一份 Apple 崩溃报告拆成
//   头部元信息 / 异常与终止原因 / 崩溃线程调用栈 / 二进制镜像表 / ASI
// 两类格式都吃：
//   · iOS 15+ 的 JSON .ips（首行 JSON 头 + 正文 JSON）
//   · iOS 14 及更早的 .ips / .crash（首行 JSON 头 + 文本段）
//
// 与 diagnose.crash 的分工：
//   diagnose.crash 把 CrashReporter 目录里的报告拼成一段文本喂给模型，
//   这里只做「一份报告的结构化还原」：字段拿不到就如实留空，不猜。

import Foundation

final class CrashIPSTool: MCPTool {
    let definition = ToolDefinition(
        name: "crash.ips",
        summary: "Structured parser for Apple crash reports (.ips / .crash). Commands: list (scan CrashReporter dirs, newest first, header fields only) / parse (exception, termination reason, faulting-thread backtrace with base+offset per frame, used image table, ASI). Reads the file only — no respring, no process attach. Use for: tell why an app crashed after injection/patch, find the faulting image+offset before asking for a dSYM, triage a respring from a report the user exported. Don't use for: symbolication (needs the app's dSYM), live process state (use diagnose / memory), building repro steps (use crash.repro_template). Example: crash.ips command:parse path:/var/mobile/Library/Logs/CrashReporter/Foo-2024-01-01.ips",
        parameters: [
            "command": "list / parse (required)",
            "path": "parse: absolute path to one .ips/.crash; list: directory to scan (default: system CrashReporter dirs)",
            "filter": "Only reports whose relative path contains this substring",
            "limit": "Max reports (list) or frames (parse). Default 40, max 500",
            "threads": "parse: true = include every thread's frames, not just the faulting one. Default false",
        ],
        returns: [
            "ok": "bool",
            "format": "ips-json / ips-legacy / crash-text",
            "header": "报告头（app_name / bug_type / os_version / timestamp / incident_id）",
            "exception": "异常类型、codes、subtype（JSON 格式）",
            "termination": "终止原因（namespace / code / indicator / reasons）",
            "faulting_thread": "崩溃线程序号",
            "faulting_frames": "崩溃线程调用栈：image / offset / address / symbol",
            "images": "用到的二进制镜像：name / base / uuid / arch / path",
            "evidence": "结论依据",
            "limitations": "本次解析未覆盖的部分",
        ],
        verified: false, category: "diagnose",
        prerequisites: [
            "先从 CrashReporter 目录或用户导出的文件里拿到 .ips；list 命令可以列出现有报告",
            "JSON 格式的 symbol 列只有 App 自带符号表时才有值；系统库要配 dSYM 才能还原函数名",
            "解析失败先看 header 是否被截断：从「报告」App 复制出来的文件常常只剩正文",
        ],
        annotations: .readOnlyLocal, cache: ToolCachePolicy.short
    )

    /// 系统崩溃报告默认搜索目录（App 有 no-container 权限，看到的是真实路径）
    private static let defaultDirs = [
        "/var/mobile/Library/Logs/CrashReporter",
        "/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs",
    ]

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let command = (params["command"] as? String) ?? "parse"
        let filter = (params["filter"] as? String) ?? ""
        let limit = max(1, min(Int("\(params["limit"] ?? 40)") ?? 40, 500))
        switch command {
        case "list":
            return try listReports(path: params["path"] as? String, filter: filter, limit: limit)
        case "parse":
            guard let p = params["path"] as? String, !p.isEmpty else {
                throw MCPError.invalidParams("path required（.ips / .crash 的绝对路径）")
            }
            let allThreads = CrashIPSTool.boolValue(params["threads"])
            return try parseReport(path: CrashIPSTool.resolve(p), allThreads: allThreads, limit: limit)
        default:
            throw MCPError.invalidParams("unknown command: \(command). Available: list / parse")
        }
    }

    // MARK: - list

    private func listReports(path: String?, filter: String, limit: Int) throws -> [String: Any] {
        var dirs = CrashIPSTool.defaultDirs
        if let p = path, !p.isEmpty { dirs = [p] }
        let fm = FileManager.default
        var rows: [([String: Any], Int)] = []
        var missing: [String] = []
        for dir in dirs {
            let root = CrashIPSTool.resolve(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                missing.append(dir)
                continue
            }
            guard let en = fm.enumerator(atPath: root) else { continue }
            for case let rel as String in en {
                let lower = rel.lowercased()
                guard lower.hasSuffix(".ips") || lower.hasSuffix(".crash") else { continue }
                // 目录太深的（DiagnosticLogs 下再套子目录）不看，避免扫全盘
                if rel.split(separator: "/").count > 3 { continue }
                if !filter.isEmpty && !lower.contains(filter.lowercased()) { continue }
                let full = root + "/" + rel
                // 先只拿 mtime 排序，header 只给最终翻出来的那几条读（目录里常有上千份报告）
                let row = CrashIPSTool.fileRow(full, rel: rel, withHeader: false)
                rows.append((row, (row["mtime_epoch"] as? Int) ?? 0))
            }
        }
        rows.sort { $0.1 > $1.1 }
        let page = rows.prefix(limit).map { entry -> [String: Any] in
            let full = (entry.0["path"] as? String) ?? ""
            let rel = (entry.0["name"] as? String) ?? ""
            return CrashIPSTool.fileRow(full, rel: rel, withHeader: true)
        }
        return [
            "ok": true,
            "searched": dirs,
            "missing_dirs": missing,
            "total": rows.count,
            "returned": page.count,
            "reports": Array(page),
            "evidence": ["扫描目录：\(dirs.joined(separator: ", "))", "只认 .ips / .crash 后缀，按修改时间倒序"],
            "limitations": [
                "缺失目录常见原因：该进程从没崩过，或报告已被「设置 ▸ 隐私 ▸ 分析与改进」清理",
                "header 里的 os_version / app_name 取自报告首行，首行被截断时为空",
            ],
        ]
    }

    private static func fileRow(_ full: String, rel: String, withHeader: Bool) -> [String: Any] {
        var row: [String: Any] = ["name": rel, "path": full]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: full) {
            if let size = attrs[.size] as? Int { row["size"] = size }
            if let date = attrs[.modificationDate] as? Date {
                row["mtime_epoch"] = Int(date.timeIntervalSince1970)
                row["mtime"] = ISO8601DateFormatter().string(from: date)
            }
        }
        guard withHeader else { return row }
        let header = CrashIPSTool.headerOf(full)
        if !header.isEmpty {
            for key in ["app_name", "name", "bug_type", "os_version", "timestamp", "incident_id"] {
                if let v = header[key] { row[key] = v }
            }
        }
        return row
    }

    // MARK: - parse

    private func parseReport(path: String, allThreads: Bool, limit: Int) throws -> [String: Any] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw MCPError.invalidParams("文件不存在或不是文件: \(path)")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("无法读取文件: \(path)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError.classified("报告不是 UTF-8 文本，无法解析: \(path)",
                                      code: "BAD_FORMAT", reason: "format",
                                      nextStep: "确认这是 .ips / .crash 文本报告，而不是压缩包或二进制")
        }
        let split = CrashIPSTool.splitHeader(text)
        let header = split.header
        var out: [String: Any] = [
            "ok": true,
            "path": path,
            "file_size": data.count,
            "header": header,
        ]
        let body = split.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{"), let obj = CrashIPSTool.jsonDict(body) {
            out["format"] = "ips-json"
            out.merge(CrashIPSTool.parseJSONBody(obj, allThreads: allThreads, limit: limit)) { _, new in new }
        } else if !body.isEmpty {
            out["format"] = "ips-legacy"
            out.merge(CrashIPSTool.parseLegacyText(body, limit: limit)) { _, new in new }
            out["raw_head"] = String(split.body.prefix(1200))
        } else {
            out["format"] = "ips-legacy"
            out.merge(CrashIPSTool.parseLegacyText(text, limit: limit)) { _, new in new }
        }
        out["evidence"] = [
            "文件：\(path)（\(data.count) 字节）",
            "格式判定：\(out["format"] as? String ?? "?")",
            "镜像表条数：\((out["images_total"] as? Int) ?? 0)",
        ]
        out["limitations"] = [
            "只解析文件内容，不推断根因、不生成复现步骤（复现模板用 crash.repro_template）",
            "frame 只有 base+offset 与报告里自带的 symbol 列；系统库函数名要配 dSYM 才能还原",
            "报告若被截断（只剩正文或只剩头部），缺失字段留空，不猜",
        ]
        return out
    }

    private static func parseJSONBody(_ body: [String: Any], allThreads: Bool, limit: Int) -> [String: Any] {
        var out: [String: Any] = [:]

        // 进程与系统
        var proc: [String: Any] = [:]
        for key in ["procName", "procPath", "procRole", "procLaunch", "pid", "ppid",
                    "parentProc", "parentPid", "coalitionName", "coalitionID",
                    "modelCode", "cpuType", "captureTime", "incident", "uptime",
                    "codeSigningID", "codeSigningTeamID", "codeSigningFlags",
                    "translated", "sip", "crashReporterKey", "bootSessionUUID"] {
            if let v = body[key] { proc[key] = v }
        }
        if let bundle = body["bundleInfo"] as? [String: Any] {
            proc["bundle"] = bundle
        }
        if let os = body["osVersion"] as? [String: Any] {
            proc["osVersion"] = os
        }
        out["process"] = proc

        // 异常
        if let exc = body["exception"] as? [String: Any] {
            var e: [String: Any] = [:]
            for key in ["type", "subtype", "codes", "rawCodes", "signal", "description"] {
                if let v = exc[key] { e[key] = v }
            }
            out["exception"] = e
        }
        // 终止原因：SIGNAL / namespace + reasons
        if let term = body["termination"] as? [String: Any] {
            var t: [String: Any] = [:]
            for key in ["namespace", "code", "indicator", "flags", "byProc", "byPid"] {
                if let v = term[key] { t[key] = v }
            }
            if let reasons = term["reasons"] as? [String] { t["reasons"] = reasons }
            out["termination"] = t
        }
        if let vm = body["vmRegionInfo"] as? String { out["vm_region_info"] = vm }
        if let asi = body["asi"] { out["asi"] = asi }
        if let pc = body["instructionByteStream"] as? [String: Any] { out["instruction_stream"] = pc }

        // 线程
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        let faulting = CrashIPSTool.intValue(body["faultingThread"])
        out["threads_total"] = threads.count
        out["faulting_thread"] = faulting ?? -1

        if let fi = faulting, fi >= 0, fi < threads.count {
            let thr = threads[fi]
            var row: [String: Any] = ["index": fi, "crashed": true]
            if let q = thr["queue"] as? String { row["queue"] = q }
            if let n = thr["name"] as? String, !n.isEmpty { row["name"] = n }
            if let tid = thr["id"] { row["thread_id"] = tid }
            let frames = (thr["frames"] as? [[String: Any]]) ?? []
            row["frame_count"] = frames.count
            var rows: [[String: Any]] = []
            for (i, f) in frames.prefix(limit).enumerated() {
                rows.append(CrashIPSTool.frameRow(f, images: images, index: i))
            }
            row["frames"] = rows
            out["faulting_frames"] = rows
            out["faulting_thread_info"] = row
        }

        // 全线程（可选）
        if allThreads {
            var list: [[String: Any]] = []
            for (i, thr) in threads.enumerated() {
                if let fi = faulting, i == fi { continue }
                var row: [String: Any] = ["index": i]
                if let q = thr["queue"] as? String { row["queue"] = q }
                if let n = thr["name"] as? String, !n.isEmpty { row["name"] = n }
                let frames = (thr["frames"] as? [[String: Any]]) ?? []
                row["frame_count"] = frames.count
                var rows: [[String: Any]] = []
                for (j, f) in frames.prefix(min(limit, 12)).enumerated() {
                    rows.append(CrashIPSTool.frameRow(f, images: images, index: j))
                }
                row["frames"] = rows
                list.append(row)
            }
            out["other_threads"] = list
        }

        // 最近一次 NSException 回溯
        if let leb = body["lastExceptionBacktrace"] as? [[String: Any]] {
            var rows: [[String: Any]] = []
            for (i, f) in leb.prefix(limit).enumerated() {
                rows.append(CrashIPSTool.frameRow(f, images: images, index: i))
            }
            out["last_exception_backtrace"] = rows
        }

        // 镜像表
        out["images_total"] = images.count
        var imageRows: [[String: Any]] = []
        for (i, img) in images.prefix(limit).enumerated() {
            var row: [String: Any] = ["index": i]
            if let n = img["name"] as? String { row["name"] = n }
            else if let p = img["path"] as? String { row["name"] = (p as NSString).lastPathComponent }
            if let u = img["uuid"] as? String { row["uuid"] = u }
            if let a = img["arch"] as? String { row["arch"] = a }
            if let b = CrashIPSTool.uint64Value(img["base"]) {
                row["base"] = String(format: "0x%llx", b)
            }
            if let s = CrashIPSTool.uint64Value(img["size"]) {
                row["size"] = String(format: "0x%llx", s)
            }
            if let p = img["path"] as? String { row["path"] = p }
            imageRows.append(row)
        }
        out["images"] = imageRows
        if images.count > limit { out["images_note"] = "只列前 \(limit) 个镜像，共 \(images.count) 个；调 limit 拿更多" }
        return out
    }

    private static func frameRow(_ f: [String: Any], images: [[String: Any]], index: Int) -> [String: Any] {
        var row: [String: Any] = ["frame": index]
        let imgIdx = CrashIPSTool.intValue(f["imageIndex"]) ?? -1
        if imgIdx >= 0 && imgIdx < images.count {
            let img = images[imgIdx]
            if let n = img["name"] as? String { row["image"] = n }
            else if let p = img["path"] as? String { row["image"] = (p as NSString).lastPathComponent }
            if let off = CrashIPSTool.uint64Value(f["imageOffset"]) {
                row["offset"] = String(format: "0x%llx", off)
                if let base = CrashIPSTool.uint64Value(img["base"]) {
                    row["address"] = String(format: "0x%llx", base &+ off)
                }
            }
        } else if let off = CrashIPSTool.uint64Value(f["imageOffset"]) {
            // JIT / 无镜像帧：给了偏移但不在镜像表里
            row["offset"] = String(format: "0x%llx", off)
        }
        if let s = f["symbol"] as? String, !s.isEmpty { row["symbol"] = s }
        if let loc = CrashIPSTool.intValue(f["symbolLocation"]) { row["symbol_location"] = loc }
        if let sf = f["sourceFile"] as? String { row["source_file"] = sf }
        if let sl = CrashIPSTool.intValue(f["sourceLine"]) { row["source_line"] = sl }
        return row
    }

    // MARK: - legacy 文本格式

    private static let legacyKeys = [
        "Incident Identifier", "CrashReporter Key", "Hardware Model", "Process", "Path",
        "Identifier", "Version", "Code Type", "Role", "Parent Process", "Responsible",
        "Date/Time", "Launch Time", "OS Version", "Report Version", "Exception Type",
        "Exception Subtype", "Exception Codes", "Exception Note", "Termination Reason",
        "Termination Description", "Triggered by Thread", "Application Specific Information",
        "Crashed Thread", "Bug Type", "Kernel Triage",
    ]

    private static func parseLegacyText(_ text: String, limit: Int) -> [String: Any] {
        var out: [String: Any] = [:]
        var fields: [String: String] = [:]
        var frames: [[String: Any]] = []
        var images: [String] = []
        var asiLines: [String] = []
        var inASI = false
        var inFrames = false
        var inImages = false
        let lines = text.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine.replacingOccurrences(of: "\t", with: " ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                inFrames = false
                inASI = false
                continue
            }
            if trimmed.hasPrefix("Binary Images:") {
                inImages = true
                inFrames = false
                inASI = false
                continue
            }
            if inImages {
                if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
                    if images.count < limit { images.append(trimmed) }
                }
                continue
            }
            if trimmed.hasPrefix("Thread ") && trimmed.contains("Crashed:") {
                fields["Triggered by Thread"] = trimmed
                inFrames = true
                inASI = false
                continue
            }
            if inFrames && trimmed.hasPrefix("Thread ") {
                inFrames = false
            }
            if inFrames {
                if let row = CrashIPSTool.legacyFrameRow(trimmed, index: frames.count) {
                    if frames.count < limit { frames.append(row) }
                    continue
                }
                inFrames = false
            }
            if inASI {
                if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    if asiLines.count < limit { asiLines.append(trimmed) }
                    continue
                }
                inASI = false
            }
            if let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if legacyKeys.contains(key) {
                    fields[key] = value
                    if key == "Application Specific Information" { inASI = true }
                }
            }
        }
        out["fields"] = fields
        if !frames.isEmpty { out["faulting_frames"] = frames }
        if !asiLines.isEmpty { out["asi_lines"] = asiLines }
        if !images.isEmpty { out["binary_images"] = images }
        out["images_total"] = images.count
        if let t = fields["Triggered by Thread"] { out["faulting_thread"] = t }
        if let e = fields["Exception Type"] { out["exception"] = ["type": e] }
        if let c = fields["Exception Codes"] { out["exception_codes"] = c }
        return out
    }

    private static func legacyFrameRow(_ line: String, index: Int) -> [String: Any]? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3, Int(parts[0]) != nil else { return nil }
        // 行格式：序号 镜像名 帧地址 镜像基址 + 偏移 [符号]，例：
        //   0   MyApp   0x104a1c000 0x104a00000 + 114688  -[Foo bar] + 12
        var row: [String: Any] = ["frame": Int(parts[0]) ?? index]
        row["image"] = parts[1]
        row["address"] = parts[2]
        if parts.count > 3 { row["image_base"] = parts[3] }
        if parts.count > 5, parts[4] == "+" {
            row["offset"] = parts[5]
            if parts.count > 6 { row["symbol"] = parts[6...].joined(separator: " ") }
        } else if parts.count > 4 {
            row["symbol"] = parts[4...].joined(separator: " ")
        }
        return row
    }

    // MARK: - 小工具

    private static func splitHeader(_ text: String) -> (header: [String: Any], body: String) {
        guard let nl = text.firstIndex(of: "\n") else { return ([:], text) }
        let first = String(text[text.startIndex..<nl]).trimmingCharacters(in: .whitespaces)
        let rest = String(text[text.index(after: nl)...])
        if first.hasPrefix("{"), let dict = jsonDict(first) {
            return (dict, rest)
        }
        return ([:], text)
    }

    private static func headerOf(_ path: String) -> [String: Any] {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return [:] }
        var chunk = Data()
        let readData = try? fh.read(upToCount: 4096)
        if let d = readData ?? nil { chunk = d }
        try? fh.close()
        if chunk.isEmpty { return [:] }
        let nl = chunk.firstIndex(of: 0x0A) ?? chunk.endIndex
        let lineData = chunk[chunk.startIndex..<nl]
        guard let line = String(data: lineData, encoding: .utf8) else { return [:] }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{") else { return [:] }
        return jsonDict(trimmed) ?? [:]
    }

    private static func jsonDict(_ s: String) -> [String: Any]? {
        guard let d = s.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
        return obj as? [String: Any]
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func uint64Value(_ v: Any?) -> UInt64? {
        if let n = v as? NSNumber { return n.uint64Value }
        if let s = v as? String { return UInt64(s) }
        return nil
    }

    private static func boolValue(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    }

    /// 真实路径 / /rootfs 前缀两段尝试（shell 视图下 /var/mobile 是 jbroot）
    static func resolve(_ path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return path }
        let prefixed = "/rootfs" + path
        if fm.fileExists(atPath: prefixed) { return prefixed }
        return path
    }
}
