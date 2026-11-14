// ReTool.swift — 内置逆向引擎（CReCore）的 MCP 工具封装
//
// 流程：解包后的 dylib / framework 二进制 → Mach-O 段表、链接库、导入符号 →
// ObjC 类/分类/协议（方法签名 + 类型编码）、ivar、属性 → 字符串与代码交叉引用 →
// 函数起点、__objc_msgSend 调用关系 → report.json + report.md。
//
// 解析全部在进程内的 C 引擎里完成（CReCore/src/xosvi_re.c），这里只做：
// 参数校验、目录/多文件调度、输出目录管理、结果摘要。

import Foundation
import CReCore

final class ReTool: MCPTool {
    /// 引擎版本（"1.0.0"），随二进制一起编进来
    static var engineVersion: String {
        guard let p = xosvi_re_version() else { return "?" }
        return String(cString: p)
    }

    /// 单文件分析上限：引擎整文件读入内存，超过这个大小先劝退（可给更大的 App 走 shell 分片）
    private static let maxFileBytes = 200 * 1024 * 1024
    /// 目录模式最多分析多少个 Mach-O
    private static let maxTargets = 24
    /// 目录遍历最多看多少个条目
    private static let maxVisited = 6000

    let definition = ToolDefinition(
        name: "re",
        summary: "Static reverse-engineering of Mach-O binaries in-process (built-in C engine, no subprocess). "
            + "commands: analyze (write report.json + report.md) / strings (string dump, optional query) / selftest. "
            + "analyze recovers: sections & linked dylibs, imports, ObjC classes/categories/protocols with method "
            + "signatures and type encodings, ivars, properties, strings with code cross-references, function "
            + "starts and __objc_msgSend call targets. path may be one Mach-O file or a directory (an unpacked "
            + "deb/app), in which case up to 24 binaries are analyzed into per-file subfolders. "
            + "Use for: turning an unpacked package into a readable report, finding which methods reference a "
            + "string, recovering class layout / superclass (decrypted dylib, framework binary). "
            + "Don't use for: decryption (app decrypt), dumping a running process's ObjC runtime (inject), "
            + "disassembling one address (disasm), .deb/.ipa containers (package unpack first, then re analyze).",
        parameters: [
            "command": "analyze (default) / strings / selftest",
            "path": "absolute path to a Mach-O file, or a directory to scan for Mach-O files",
            "out_dir": "analyze/strings: output directory (created). Default: <data>/Workspace/re/<time>-<name>",
            "query": "strings: only strings containing this substring (case-insensitive)",
            "max_strings": "analyze: cap on collected strings (default 20000)",
            "min_len": "analyze: minimum string length (default 4)",
            "xrefs": "analyze: 1 (default) scan code for string/method cross references, 0 skip for speed",
        ],
        returns: [
            "engine": "引擎版本，如 xosvi-re 1.0.0",
            "out_dir": "本次输出的总目录",
            "targets": "[{file, size, report_json, report_md, counts{classes,categories,protocols,methods,ivars,properties,strings,functions,stubs,imports,binds,rebases}}]",
            "skipped": "目录模式下被跳过的文件与原因（过大 / 非 Mach-O 上限）",
            "report_head": "首个目标 report.md 的开头（概览表 + 类清单），完整内容读 report_md",
        ],
        verified: false, category: "macho",
        prerequisites: [
            "path 必须是真实存在的 Mach-O 或包含 Mach-O 的目录；.deb/.ipa 先用 package unpack 解出二进制",
            "输出写到 out_dir（默认工作区），不会修改输入文件",
        ],
        paramSpecs: [
            .e("command", "analyze 出完整报告 / strings 只导字符串 / selftest 自检",
               values: ["analyze", "strings", "selftest"], required: true, example: "analyze"),
            .s("path", "Mach-O 文件或目录的绝对路径", required: false,
               example: "/var/mobile/Documents/xxx/com.ioskuka.baozang.dylib"),
            .s("out_dir", "输出目录（会自动创建）", required: false,
               example: "/var/mobile/Documents/wiki.qaq.xosvi/Workspace/re/baozang"),
            .s("query", "strings：子串过滤（不区分大小写）", required: false, example: "pay"),
            .i("max_strings", "analyze：字符串上限，默认 20000", required: false),
            .i("min_len", "analyze：字符串最短长度，默认 4", required: false),
            .i("xrefs", "analyze：1 扫交叉引用（默认）/ 0 跳过", required: false),
        ],
        variants: [
            ToolVariant("analyze", requires: ["path"], accepts: ["out_dir", "max_strings", "min_len", "xrefs"],
                        note: "写 report.json + report.md；目录模式每个二进制一个子目录"),
            ToolVariant("strings", requires: ["path"], accepts: ["out_dir", "query"],
                        note: "写 strings.json，不分报告"),
            ToolVariant("selftest", requires: [], accepts: [], note: "引擎自检，不需要文件"),
        ],
        annotations: .writeLocal,
        cache: ToolCachePolicy.none,
        related: [
            RelatedTool(tool: "package", command: "unpack", when: "输入是 .deb/.ipa，先解出二进制"),
            RelatedTool(tool: "macho", when: "只看 Mach-O 头 / 是否加密"),
            RelatedTool(tool: "disasm", when: "对报告里的函数地址做反汇编"),
            RelatedTool(tool: "artifact", command: "read", when: "读取生成的 report.md / report.json"),
        ])

    // MARK: - invoke

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let command = ((params["command"] as? String) ?? "analyze").lowercased()
        switch command {
        case "analyze", "":  return try analyze(params)
        case "strings":      return try stringsOnly(params)
        case "selftest":     return selfTest()
        default:
            throw MCPError.invalidParams("re: 未知 command '\(command)'（analyze / strings / selftest）")
        }
    }

    // MARK: - 参数

    private func targetPath(_ params: [String: Any]) throws -> String {
        guard let raw = params["path"] as? String, !raw.isEmpty else {
            throw MCPError.invalidParams("re: missing path（Mach-O 文件或目录的绝对路径）")
        }
        let path = (raw as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw MCPError.classified("re: 路径不存在: \(path)", code: "NOT_FOUND", reason: "path",
                                      nextStep: "先用 shell.exec ls 或 app status 确认路径；.deb/.ipa 先用 package unpack")
        }
        let lower = path.lowercased()
        if lower.hasSuffix(".deb") || lower.hasSuffix(".ipa") || lower.hasSuffix(".zip") {
            throw MCPError.classified("re: \(path) 是压缩包，不是 Mach-O", code: "BAD_PARAM", reason: "parameter",
                                      nextStep: "先 package command:unpack path:<包> dest:<目录>，再 re command:analyze path:<解出的 dylib 或目录>")
        }
        return path
    }

    private func optionsString(_ params: [String: Any]) -> String? {
        var parts: [String] = []
        if let n = intValue(params["max_strings"]), n > 0 { parts.append("max_strings=\(min(n, 200_000))") }
        if let n = intValue(params["min_len"]), n > 0 { parts.append("min_len=\(min(n, 64))") }
        if let x = params["xrefs"] {
            if let b = x as? Bool { parts.append("xrefs=\(b ? 1 : 0)") }
            else if let n = intValue(x) { parts.append("xrefs=\(n != 0 ? 1 : 0)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ";")
    }

    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    // MARK: - 输出目录

    private func makeOutRoot(_ params: [String: Any], basedOn path: String) throws -> String {
        let fm = FileManager.default
        let root: String
        if let given = params["out_dir"] as? String, !given.isEmpty {
            root = (given as NSString).standardizingPath
        } else {
            let name = (path as NSString).lastPathComponent
            let stamp = Self.stamp()
            root = XDirs.workspace + "/re/" + stamp + "-" + Self.slug(name)
        }
        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            throw MCPError.classified("re: 无法创建输出目录 \(root): \(error.localizedDescription)",
                                      code: "ENV_PERMISSION", reason: "environment",
                                      nextStep: "换一个可写目录（工作区 <数据根>/Workspace 下）再试")
        }
        return root
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date())
    }

    private static func slug(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let out = s.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return out.isEmpty ? "target" : String(out.prefix(60))
    }

    // MARK: - analyze

    private func analyze(_ params: [String: Any]) throws -> [String: Any] {
        let path = try targetPath(params)
        let outRoot = try makeOutRoot(params, basedOn: path)
        let options = optionsString(params)
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)

        var skipped: [[String: Any]] = []
        var targets: [[String: Any]] = []
        var firstReportHead = ""

        if isDir.boolValue {
            let files = scanMachOs(in: path, skipped: &skipped)
            guard !files.isEmpty else {
                throw MCPError.classified("re: 目录里没找到可解析的 Mach-O: \(path)", code: "NOT_FOUND", reason: "target",
                                          nextStep: "确认解包目录里确实有 .dylib/.framework 二进制（package inspect 看成员清单）")
            }
            for (idx, file) in files.enumerated() {
                let sub = outRoot + "/" + String(format: "%02d-", idx) + Self.slug((file as NSString).lastPathComponent)
                try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
                do {
                    targets.append(try analyzeOne(file, outDir: sub, options: options,
                                                  previewInto: &firstReportHead))
                } catch let e as MCPError {
                    skipped.append(["file": file, "reason": e.description])
                }
            }
        } else {
            let size = Self.fileSize(path)
            guard size <= Self.maxFileBytes else {
                throw MCPError.classified("re: 文件 \(size / 1024 / 1024) MB 超过上限 \(Self.maxFileBytes / 1024 / 1024) MB",
                                          code: "BAD_PARAM", reason: "parameter",
                                          nextStep: "超大二进制请先裁剪 __TEXT 之外的段，或让 shell 分片后逐个分析")
            }
            targets.append(try analyzeOne(path, outDir: outRoot, options: options, previewInto: &firstReportHead))
        }

        var out: [String: Any] = [
            "engine": "xosvi-re " + Self.engineVersion,
            "input": path,
            "out_dir": outRoot,
            "targets": targets,
            "hint": "完整内容：artifact read path:<report_md>；结构化数据：artifact read path:<report.json>",
        ]
        if !skipped.isEmpty { out["skipped"] = skipped }
        if !firstReportHead.isEmpty { out["report_head"] = firstReportHead }
        return out
    }

    /// 分析一个文件，返回该目标的摘要；首个目标的 md 头写进 previewInto
    private func analyzeOne(_ file: String, outDir: String, options: String?,
                            previewInto preview: inout String) throws -> [String: Any] {
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc: Int32 = file.withCString { fp in
            outDir.withCString { op in
                if let o = options {
                    return o.withCString { xosvi_re_analyze(fp, op, $0, &errBuf, 512) }
                }
                return xosvi_re_analyze(fp, op, nil, &errBuf, 512)
            }
        }
        if rc != 0 {
            let msg = Self.cString(errBuf)
            throw MCPError.classified("re: 解析失败 \(file): \(msg.isEmpty ? "rc=\(rc)" : msg)",
                                      code: "TOOL_FAILED", reason: "tool",
                                      nextStep: "确认是 64 位 Mach-O（macho 工具看架构）；加密二进制需先砸壳")
        }
        let jsonPath = outDir + "/report.json"
        let mdPath = outDir + "/report.md"
        var item: [String: Any] = [
            "file": file,
            "size": Self.fileSize(file),
            "report_json": jsonPath,
            "report_md": mdPath,
        ]
        if let counts = Self.readCounts(jsonPath) { item["counts"] = counts }
        if preview.isEmpty {
            preview = Self.head(mdPath, bytes: 2600)
        }
        return item
    }

    // MARK: - strings

    private func stringsOnly(_ params: [String: Any]) throws -> [String: Any] {
        let path = try targetPath(params)
        let outRoot = try makeOutRoot(params, basedOn: path)
        let query = (params["query"] as? String) ?? ""
        var errBuf = [CChar](repeating: 0, count: 512)
        let rc: Int32 = path.withCString { fp in
            outRoot.withCString { op in
                if query.isEmpty {
                    return xosvi_re_strings(fp, nil, op, &errBuf, 512)
                }
                return query.withCString { qp in
                    xosvi_re_strings(fp, qp, op, &errBuf, 512)
                }
            }
        }
        if rc != 0 {
            let msg = Self.cString(errBuf)
            throw MCPError.classified("re strings: 失败 \(path): \(msg.isEmpty ? "rc=\(rc)" : msg)",
                                      code: "TOOL_FAILED", reason: "tool",
                                      nextStep: "确认是 64 位 Mach-O；加密二进制需先砸壳")
        }
        let jsonPath = outRoot + "/strings.json"
        var out: [String: Any] = [
            "engine": "xosvi-re " + Self.engineVersion,
            "file": path,
            "query": query,
            "strings_json": jsonPath,
        ]
        if let total = Self.readTopInt(jsonPath, key: "total") { out["total"] = total }
        return out
    }

    // MARK: - selftest

    /// 引擎自检：不需要外部文件，构造一个最小 Mach-O 头验证版本与错误路径
    private func selfTest() -> [String: Any] {
        let fm = FileManager.default
        let dir = XDirs.tmp + "/re-selftest-" + Self.stamp()
        var checks: [[String: Any]] = []
        checks.append(["id": "version", "passed": !Self.engineVersion.isEmpty, "detail": Self.engineVersion])

        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            checks.append(["id": "tmpdir", "passed": false, "detail": error.localizedDescription])
            return Self.verdict(checks)
        }
        checks.append(["id": "tmpdir", "passed": true, "detail": dir])

        // 不是 Mach-O → 引擎必须报错而不是崩溃
        let bogus = dir + "/bogus.bin"
        fm.createFile(atPath: bogus, contents: Data(repeating: 0x41, count: 4096))
        var errBuf = [CChar](repeating: 0, count: 512)
        let badRC: Int32 = bogus.withCString { fp in
            dir.withCString { op in xosvi_re_analyze(fp, op, nil, &errBuf, 512) }
        }
        let badMsg = Self.cString(errBuf)
        checks.append(["id": "reject_non_macho", "passed": badRC != 0 && !badMsg.isEmpty,
                       "detail": "rc=\(badRC) err=\(badMsg)"])

        // 只有 magic、没有装载命令的 Mach-O → 引擎必须能容忍并照样出报告（空壳不崩）
        var headBytes = Data()
        headBytes.append(contentsOf: [0xCF, 0xFA, 0xED, 0xFE])
        headBytes.append(Data(repeating: 0, count: 2044))
        let broken = dir + "/empty.macho"
        fm.createFile(atPath: broken, contents: headBytes)
        var err2 = [CChar](repeating: 0, count: 512)
        let emptyDir = dir + "/out"
        try? fm.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
        let brokenRC: Int32 = broken.withCString { fp in
            emptyDir.withCString { op in xosvi_re_analyze(fp, op, nil, &err2, 512) }
        }
        let brokenMsg = Self.cString(err2)
        let reportPath = emptyDir + "/report.json"
        let hasCounts = (Self.readCounts(reportPath)?.isEmpty == false)
        checks.append(["id": "empty_header_ok", "passed": brokenRC == 0 && hasCounts,
                       "detail": "rc=\(brokenRC) counts=\(hasCounts ? "ok" : "missing") err=\(brokenMsg)"])

        try? fm.removeItem(atPath: dir)
        return Self.verdict(checks)
    }

    private static func verdict(_ checks: [[String: Any]]) -> [String: Any] {
        let failed = checks.filter { ($0["passed"] as? Bool) != true }
        return [
            "engine": "xosvi-re " + engineVersion,
            "verdict": failed.isEmpty ? "RE_OK" : "RE_BROKEN",
            "checks": checks,
            "failed": failed.count,
        ]
    }

    // MARK: - 目录扫描

    /// 递归找 Mach-O（64 位 thin / fat），按大小降序，最多 maxTargets 个
    private func scanMachOs(in dir: String, skipped: inout [[String: Any]]) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        var hits: [(String, Int)] = []
        var visited = 0
        for case let rel as String in en {
            visited += 1
            if visited > Self.maxVisited { break }
            let full = dir + "/" + rel
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // 跳过明显无关的大目录，避免遍历整个 .app
                let base = (rel as NSString).lastPathComponent
                if base == "_CodeSignature" || base == "SC_Info" || base == "__MACOSX" {
                    en.skipDescendants()
                }
                continue
            }
            // 深度限制：只看到第 6 层
            if rel.components(separatedBy: "/").count > 6 { continue }
            guard Self.isMachO(full) else { continue }
            let size = Self.fileSize(full)
            if size > Self.maxFileBytes {
                skipped.append(["file": full, "reason": "超过 \(Self.maxFileBytes / 1024 / 1024) MB 上限（\(size / 1024 / 1024) MB）"])
                continue
            }
            hits.append((full, size))
        }
        hits.sort { $0.1 > $1.1 }
        if hits.count > Self.maxTargets {
            for (f, _) in hits[Self.maxTargets...] {
                skipped.append(["file": f, "reason": "超过单次 \(Self.maxTargets) 个目标上限"])
            }
            hits = Array(hits.prefix(Self.maxTargets))
        }
        return hits.map { $0.0 }
    }

    private static func isMachO(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        let magic = fh.readData(ofLength: 4)
        guard magic.count == 4 else { return false }
        let be = (UInt32(magic[0]) << 24) | (UInt32(magic[1]) << 16) | (UInt32(magic[2]) << 8) | UInt32(magic[3])
        switch be {
        case 0xfeedfacf, 0xfeedface: return true    // 64 / 32 位 thin
        case 0xcafebabe, 0xbebafeca: return true    // fat
        default: return false
        }
    }

    // MARK: - 小工具

    private static func fileSize(_ path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    private static func cString(_ buf: [CChar]) -> String {
        String(cString: buf)
    }

    /// 读 report.json 的 counts：只取文件头的 counts 对象，避免把几十 MB 的报告整个读进来
    private static func readCounts(_ path: String) -> [String: Any]? {
        let head = Self.head(path, bytes: 8192)
        guard let r = head.range(of: "\"counts\":{") else { return nil }
        let rest = head[r.upperBound...]
        guard let close = rest.firstIndex(of: "}") else { return nil }
        let body = "{" + String(rest[rest.startIndex..<close]) + "}"
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func readTopInt(_ path: String, key: String) -> Int? {
        let head = Self.head(path, bytes: 256)
        guard let r = head.range(of: "\"\(key)\":") else { return nil }
        let digits = head[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private static func head(_ path: String, bytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        var d = fh.readData(ofLength: bytes)
        // 截断处可能落在多字节 UTF-8 中间：去掉末尾不完整序列
        while !d.isEmpty, String(data: d, encoding: .utf8) == nil {
            d.removeLast()
        }
        return String(data: d, encoding: .utf8) ?? ""
    }
}
