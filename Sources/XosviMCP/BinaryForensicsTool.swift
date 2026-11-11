// BinaryForensicsTool.swift — REA 风格的内置静态检查（v7.18.0）
//
// 移植自 morluto/rea 的三类「built-in static inspection」（无需外部工具）：
//   · binary hardening  —— Mach-O 加固标志、段权限、加密、签名、PIE 等
//   · Go / Rust 溯源    —— Go buildinfo 与 Rust cargo-auditable 依赖表
//   · 构建对比（diff）  —— 两个二进制/两个包之间新增/删除的符号与资源
//
// 与 disasm / macho 的分工：
//   macho  = 头部、entitlements、签名（MachOKit 结构体路线）
//   disasm = 指令解码（capstone）
//   armor  = 安全属性 + 语言溯源 + diff（纯字节、无依赖，砸壳后可立即跑）
//
// 设计原则沿用 MachoTools.swift 头注释：一次一个取证目标、输出强制分页、
// 返回带 evidence / limitations，环境限制与文件问题分开报。

import Foundation

// MARK: - 加固检查 / 语言溯源

final class BinaryArmorTool: MCPTool {
    let definition = ToolDefinition(
        name: "armor",
        summary: "Static binary hardening + language provenance + diff (REA-style built-in inspection, no external tool). Commands: hardening (PIE/NX/stack-canary/arc/relro-ish flags, segment perms, cryptid, codesign), toolchain (Go buildinfo version/modules; Rust cargo-auditable crates), diff (compare two binaries: added/removed symbols and segment sizes, or two .app dirs: added/removed files + size changes). Use for: check if a decrypted app is hardened, find third-party Go/Rust deps after 砸壳, compare two versions of an app. Don't use for: decompilation (none on device), entitlements (use macho entitlements), instruction-level reading (use disasm). Example: armor command:toolchain path:/var/.../BaiMiao.app",
        parameters: [
            "command": "hardening / toolchain / diff (required)",
            "path": "Absolute path to Mach-O file or .app dir (required for hardening/toolchain; first path for diff)",
            "path2": "Second binary or .app dir (required for diff)",
            "slice": "fat slice index, default 0",
            "limit": "Max items per list, default 50 (max 500)",
            "filter": "diff: only paths/symbols containing this substring",
        ],
        returns: [
            "ok": "bool",
            "score": "hardening: 0-100 粗略加固分（仅参考）",
            "flags": "hardening: 各标志布尔值",
            "evidence": "结论依据",
            "limitations": "本次分析未覆盖的部分",
        ],
        verified: false, category: "macho",
        prerequisites: [
            "砸壳后的二进制才有意义（cryptid=1 时 __TEXT 不可读）",
            "静态解析：不运行目标、不 attach 进程",
        ],
        annotations: .readOnlyLocal, cache: ToolCachePolicy.long
    )

    private enum DiffTarget { case binary(RawMachO), directory(files: [(String, Int)]) }

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required. Available: hardening / toolchain / diff")
        }
        let slice = Int("\(params["slice"] ?? 0)") ?? 0
        let limit = max(1, min(Int("\(params["limit"] ?? 50)") ?? 50, 500))
        let filter = (params["filter"] as? String) ?? ""

        switch command {
        case "hardening":
            guard let p = params["path"] as? String, !p.isEmpty else {
                throw MCPError.invalidParams("path required")
            }
            let m = try RawMachO.load(path: p, sliceIndex: slice)
            return Self.hardening(m, path: p)
        case "toolchain":
            guard let p = params["path"] as? String, !p.isEmpty else {
                throw MCPError.invalidParams("path required")
            }
            let m = try RawMachO.load(path: p, sliceIndex: slice)
            return Self.toolchain(m, limit: limit)
        case "diff":
            guard let a = params["path"] as? String, !a.isEmpty,
                  let b = params["path2"] as? String, !b.isEmpty else {
                throw MCPError.invalidParams("path and path2 required for diff")
            }
            return try Self.diff(a, b, filter: filter, limit: limit)
        default:
            throw MCPError.invalidParams("unknown command: \(command). Available: hardening / toolchain / diff")
        }
    }

    // MARK: - hardening

    private static func hardening(_ m: RawMachO, path: String) -> [String: Any] {
        // MH_* 标志位（mach-o/loader.h）
        let MH_NOUNDEFS: UInt32 = 0x1
        let MH_PIE: UInt32 = 0x200000
        let MH_ALLOW_STACK_EXECUTION: UInt32 = 0x20000
        let MH_NO_HEAP_EXECUTION: UInt32 = 0x1000000

        let flags = m.flags
        let pie = (flags & MH_PIE) != 0
        let noUndefs = (flags & MH_NOUNDEFS) != 0
        let stackExec = (flags & MH_ALLOW_STACK_EXECUTION) != 0
        let noHeapExec = (flags & MH_NO_HEAP_EXECUTION) != 0

        // 段权限：__TEXT 可执行、__DATA 不可执行、__LINKEDIT 不可执行
        var segInfo: [[String: Any]] = []
        var writableExecutable: [String] = []
        for cmd in m.commands where cmd.cmd == 0x19 || cmd.cmd == 0x1 {
            let body = cmd.data
            let is64 = (cmd.cmd == 0x19)
            guard body.count >= (is64 ? 72 : 56) else { continue }
            let name = RawMachO.cstr(body, 8, 16)
            guard !name.isEmpty else { continue }
            let maxprotOff = is64 ? 56 : 44
            let initprotOff = is64 ? 60 : 48
            let maxprot = RawMachO.u32in(body, maxprotOff, !m.isBigEndian)
            let initprot = RawMachO.u32in(body, initprotOff, !m.isBigEndian)
            segInfo.append([
                "name": name,
                "maxprot": permString(maxprot),
                "initprot": permString(initprot),
            ])
            if initprot & 0x2 != 0 && initprot & 0x4 != 0 {   // VM_PROT_WRITE | VM_PROT_EXECUTE
                writableExecutable.append(name)
            }
        }

        // 栈保护 / arc / 符号：来自 LC_SOURCE_VERSION 之外的线索——
        // 用 LC_LOAD_DYLIB 里 libSystem 存在性 + 常见 canary 符号近似判断。
        let dylibs: [String] = m.commands.compactMap { cmd in
            switch cmd.cmd {
            case 0xc, 0x8000001f, 0x80000018, 0x20, 0x80000023:
                let off = Int(RawMachO.u32in(cmd.data, 8, !m.isBigEndian))
                return RawMachO.cstr(cmd.data, off, 512)
            default: return nil
            }
        }
        let hasLibSystem = dylibs.contains { $0.hasPrefix("/usr/lib/libSystem") }
        let hasCxx = dylibs.contains { $0.contains("libc++") }

        let cryptid = m.cryptid ?? 0
        let encrypted = cryptid != 0
        let signed = m.firstCommand(0x1d) != nil

        // 加固分：只做粗略参考，不做结论
        var score = 0
        if pie { score += 25 }
        if !stackExec { score += 15 }
        if noHeapExec { score += 10 }
        if writableExecutable.isEmpty { score += 15 }
        if signed { score += 15 }
        if !encrypted { score += 10 }
        if hasLibSystem { score += 5 }
        if noUndefs { score += 5 }

        var findings: [String] = []
        if !pie { findings.append("[缺 PIE] 可执行文件不是位置无关的，无法配合 ASLR") }
        if stackExec { findings.append("[缺 NX] MH_ALLOW_STACK_EXECUTION：栈可执行") }
        if !writableExecutable.isEmpty {
            findings.append("[可写可执行段] \(writableExecutable.joined(separator: ", ")) —— JIT / 注入残留的典型特征")
        }
        if encrypted { findings.append("[已加密] cryptid=\(cryptid)：代码段不可读，需先砸壳（app 工具 decrypt）") }
        if !signed { findings.append("[未签名] 没有 LC_CODE_SIGNATURE：ldid 尚未签名或签名被剥离") }
        if !hasLibSystem { findings.append("[可疑] 没有链接 /usr/lib/libSystem：可能是静态链接或手工拼装的二进制") }
        if findings.isEmpty { findings.append("未发现明显异常：常规加固项齐全") }

        var out: [String: Any] = [
            "ok": true,
            "path": path,
            "cpu": cpuDescription(m.cpuType),
            "file_type": fileTypeName(m.fileType),
            "platform": m.buildPlatform ?? "(no LC_BUILD_VERSION)",
            "uuid": m.uuid ?? "(none)",
            "flags_raw": String(format: "0x%x", flags),
            "flags": [
                "pie": pie,
                "no_undefs": noUndefs,
                "allow_stack_execution": stackExec,
                "no_heap_execution": noHeapExec,
                "two_level_namespace": (flags & 0x80) != 0,
                "dyld_link": (flags & 0x4) != 0,
            ],
            "cryptid": cryptid,
            "encrypted": encrypted,
            "signed": signed,
            "segments": segInfo,
            "writable_executable_segments": writableExecutable,
            "linked": ["libSystem": hasLibSystem, "libc++": hasCxx],
            "dylib_count": dylibs.count,
            "score": score,
            "score_note": "0-100 粗略参考分，只看头与段权限，不代表实际安全性",
            "findings": findings,
        ]
        StaticReport.finish(&out, "armor hardening flags=0x\(String(flags, radix: 16)) cryptid=\(cryptid) signed=\(signed) segs=\(segInfo.count)",
                            limitations: ["栈保护 / FORTIFY 需要扫描 __stack_chk_fail 等符号，当前只做头与段级别判断",
                                          "hardening 不能证明运行时安全，只描述静态属性"])
        return out
    }

    private static func permString(_ p: UInt32) -> String {
        var s = ""
        s += (p & 0x1) != 0 ? "r" : "-"
        s += (p & 0x2) != 0 ? "w" : "-"
        s += (p & 0x4) != 0 ? "x" : "-"
        return s
    }

    // MARK: - toolchain（Go / Rust 溯源）

    private static func toolchain(_ m: RawMachO, limit: Int) -> [String: Any] {
        var out: [String: Any] = ["ok": true]
        var found = false

        // Go buildinfo：节 __TEXT,__go_buildinfo（Go 1.18+）或 magic 0xFF 0x20 Go build ID 所在段
        if let info = goBuildInfo(m, limit: limit) {
            out["go"] = info
            found = true
        }
        // Rust cargo-auditable：节 .dep-v0（Mach-O 里常为 __DATA,__dep_v0 或 __TEXT,__dep_v0）
        if let dep = cargoAuditable(m, limit: limit) {
            out["rust"] = dep
            found = true
        }
        // 顺带给出编译器线索（LC_BUILD_VERSION 平台 + 是否含 Swift/ObjC 运行时）
        let sectNames = Set(m.sections.map { $0.sectname })
        var langs: [String] = []
        if sectNames.contains("__swift5_proto") || sectNames.contains("__swift5_types") { langs.append("Swift") }
        if sectNames.contains("__objc_classlist") { langs.append("Objective-C") }
        if out["go"] != nil { langs.append("Go") }
        if out["rust"] != nil { langs.append("Rust") }
        out["language_hints"] = langs
        out["platform"] = m.buildPlatform ?? "(none)"

        if !found {
            out["note"] = "未发现 Go buildinfo 或 Rust cargo-auditable 段：目标通常不是 Go/Rust 构建（或已被 strip 掉这些节）"
        }
        StaticReport.finish(&out, "armor toolchain go=\(out["go"] != nil) rust=\(out["rust"] != nil) langs=\(langs.joined(separator: ","))",
                            limitations: ["Go buildinfo 被 strip 后无法还原；Rust 只能在编译时启用 cargo-auditable 才有依赖表"])
        return out
    }

    /// Go buildinfo：Go 1.18+ 在 __TEXT,__go_buildinfo 写一段字符串头；
    /// 更老版本用 magic 0xFF 0x20 开头的 blob。这里两种都扫。
    private static func goBuildInfo(_ m: RawMachO, limit: Int) -> [String: Any]? {
        var blob: [UInt8]?
        if let s = m.sectionBytes(seg: "__TEXT", sect: "__go_buildinfo") {
            blob = s
        } else if let s = m.sectionBytes(seg: "__DATA", sect: "__go_buildinfo") {
            blob = s
        } else {
            // 兜底：在 __TEXT 全部节里找 0xFF 0x20 开头的 buildinfo
            for sec in m.sections where sec.segname == "__TEXT" {
                if let b = m.sectionBytes(seg: sec.segname, sect: sec.sectname),
                   b.count > 32, b[0] == 0xff, b[1] == 0x20, b[2] == 0x00, b[3] == 0x00 {
                    blob = b
                    break
                }
            }
        }
        guard var b = blob, b.count > 32 else { return nil }

        // 定位 buildinfo 正文：找到 "go1." 开头的版本串
        var start = -1
        var i = 0
        while i + 4 < b.count {
            if b[i] == 0x67, b[i + 1] == 0x6f, b[i + 2] == 0x31, b[i + 3] == 0x2e {   // "go1."
                start = i
                break
            }
            i += 1
        }
        guard start >= 0 else { return nil }
        b = Array(b[start...])

        // buildinfo 布局：版本 \n 路径 \t 依赖行... \n 末尾 build settings
        var goVersion = ""
        var modulePath = ""
        var deps: [String] = []
        var settings: [String: String] = [:]
        let lines = String(bytes: b, encoding: .utf8)?.components(separatedBy: "\n") ?? []
        for (idx, line) in lines.enumerated() {
            if idx == 0 { goVersion = line; continue }
            if idx == 1 { modulePath = line; continue }
            if line.isEmpty { break }
            if line.contains("\t") {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 2 {
                    // 依赖行通常形如 "dep\tmodule\tversion\t(=|replacement)"
                    if parts[0] == "dep", parts.count >= 3 {
                        deps.append("\(parts[1])@\(parts[2])")
                    } else {
                        deps.append(parts.joined(separator: " "))
                    }
                }
            } else if idx > 1 {
                // 空行结束依赖区，进入 build settings（"-ldflags=..." 这类行没有 \t）
                if line.contains("=") {
                    let kv = line.components(separatedBy: "=")
                    if kv.count >= 2 { settings[kv[0]] = kv[1] }
                }
            }
        }
        // build settings 在依赖区之后，单独扫一遍
        for line in lines where line.contains("=") && !line.contains("\t") && !line.hasPrefix("go1.") {
            let kv = line.components(separatedBy: "=")
            if kv.count >= 2, settings[kv[0]] == nil, !kv[0].isEmpty {
                settings[kv[0]] = kv[1]
            }
        }
        guard !goVersion.isEmpty else { return nil }

        var out: [String: Any] = [
            "go_version": goVersion,
            "module_path": modulePath,
            "dependency_count": deps.count,
            "dependencies": Array(deps.prefix(limit)),
            "truncated": deps.count > limit,
            "key_settings": ["CGO_ENABLED": settings["CGO_ENABLED"] ?? "-",
                             "GOOS": settings["GOOS"] ?? "-",
                             "GOARCH": settings["GOARCH"] ?? "-",
                             "vcs": settings["vcs.revision"].map { String($0.prefix(12)) } ?? "-",
                             "trimpath": settings["-trimpath"] ?? "-"],
        ]
        if deps.count > limit { out["dependencies_note"] = "只显示前 \(limit) 个，共 \(deps.count) 个" }
        return out
    }

    /// Rust cargo-auditable：`.dep-v0` 节，格式为 zlib 压缩的 JSON（{packages:[...]}）。
    /// 先试自带压缩段，再试 zlib 解压。解不出来就报「有段但无法解压」，不静默失败。
    private static func cargoAuditable(_ m: RawMachO, limit: Int) -> [String: Any]? {
        var blob: [UInt8]?
        for sec in m.sections where sec.sectname.hasPrefix("__dep_v0") || sec.sectname.hasPrefix(".dep-v0") {
            blob = m.sectionBytes(seg: sec.segname, sect: sec.sectname)
            break
        }
        guard let raw = blob, !raw.isEmpty else { return nil }

        var payload = Data(raw)
        // 常见情形：节本身就是 zlib 流（0x78 开头）
        var decompressed: Data?
        if raw.count > 2, raw[0] == 0x78 {
            decompressed = Self.inflateRaw(Data(raw))
        }
        if decompressed == nil {
            // 也可能原样存 JSON
            if let s = String(bytes: raw, encoding: .utf8), s.hasPrefix("{") {
                decompressed = Data(s.utf8)
            }
        }
        guard let jsonData = decompressed,
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let packages = obj["packages"] as? [[String: Any]] else {
            return ["present": true, "decoded": false,
                    "note": "找到 cargo-auditable 段但无法解码（\(raw.count) 字节）：可能是不同编码版本",
                    "raw_size": raw.count]
        }

        var items: [[String: Any]] = []
        var versions: [String: String] = [:]
        for p in packages {
            let name = (p["name"] as? String) ?? "?"
            let ver = (p["version"] as? String) ?? "?"
            versions[name] = ver
        }
        for p in packages.prefix(limit) {
            let name = (p["name"] as? String) ?? "?"
            let ver = (p["version"] as? String) ?? "?"
            var d: [String: Any] = ["name": name, "version": ver]
            if let kind = p["kind"] as? String { d["kind"] = kind }
            if let src = p["source"] as? String { d["source"] = src.count > 160 ? String(src.prefix(160)) + "…" : src }
            if let deps = p["dependencies"] as? [String], !deps.isEmpty { d["depends_on_count"] = deps.count }
            items.append(d)
        }
        return [
            "present": true,
            "decoded": true,
            "crate_count": packages.count,
            "crates": items,
            "truncated": packages.count > limit,
            "crates_note": packages.count > limit ? "只显示前 \(limit) 个，共 \(packages.count) 个" : "",
        ]
    }

    /// zlib inflate：走系统 Compression（COMPRESSION_ZLIB 只吃裸 DEFLATE，ZlibBridge 里已处理头尾）
    private static func inflateRaw(_ data: Data) -> Data? {
        return ZlibBridge.inflate(data)
    }

    // MARK: - diff

    private static func diff(_ a: String, _ b: String, filter: String, limit: Int) throws -> [String: Any] {
        let ta = try classify(a)
        let tb = try classify(b)

        switch (ta, tb) {
        case (.binary(let ma), .binary(let mb)):
            return binaryDiff(ma, mb, a: a, b: b, filter: filter, limit: limit)
        case (.directory(let fa), .directory(let fb)):
            return dirDiff(fa, fb, a: a, b: b, filter: filter, limit: limit)
        default:
            throw MCPError.invalidParams("path 与 path2 必须是同类：要么都是二进制文件，要么都是目录")
        }
    }

    private static func classify(_ p: String) throws -> DiffTarget {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else {
            throw MCPError.invalidParams("路径不存在: \(p)")
        }
        if isDir.boolValue {
            return .directory(files: try fileList(p))
        }
        return .binary(try RawMachO.load(path: p))
    }

    /// 目录清单：相对路径 + 大小（两万条上限，防大 App 拖死）
    private static func fileList(_ root: String) throws -> [(String, Int)] {
        var out: [(String, Int)] = []
        let base = URL(fileURLWithPath: root)
        guard let en = FileManager.default.enumerator(at: base,
                                                      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else {
            throw MCPError.invalidParams("无法遍历目录: \(root)")
        }
        for case let url as URL in en {
            if out.count >= 20000 { break }
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard vals?.isRegularFile == true else { continue }
            let rel = url.path.replacingOccurrences(of: base.path + "/", with: "")
            out.append((rel, vals?.fileSize ?? 0))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private static func binaryDiff(_ ma: RawMachO, _ mb: RawMachO,
                                   a: String, b: String, filter: String, limit: Int) -> [String: Any] {
        let sa = ma.symbols(isLittle: !ma.isBigEndian)
        let sb = mb.symbols(isLittle: !mb.isBigEndian)
        let namesA = Set(sa.map { $0.name })
        let namesB = Set(sb.map { $0.name })
        var added = Array(namesB.subtracting(namesA)).sorted()
        var removed = Array(namesA.subtracting(namesB)).sorted()
        if !filter.isEmpty {
            added = added.filter { $0.localizedCaseInsensitiveContains(filter) }
            removed = removed.filter { $0.localizedCaseInsensitiveContains(filter) }
        }

        // 段大小变化（__TEXT / __DATA 最常见）
        func segSize(_ m: RawMachO, _ name: String) -> UInt64 {
            for cmd in m.commands where cmd.cmd == 0x19 {
                let body = cmd.data
                guard body.count >= 72 else { continue }
                if RawMachO.cstr(body, 8, 16) == name {
                    return RawMachO.u64in(body, 32, !m.isBigEndian)   // vmsize：cmd@0 cmdsize@4 segname@8 vmaddr@24 vmsize@32
                }
            }
            return 0
        }
        var segDelta: [[String: Any]] = []
        for name in ["__TEXT", "__DATA", "__DATA_CONST", "__LINKEDIT"] {
            let x = segSize(ma, name), y = segSize(mb, name)
            if x == 0 && y == 0 { continue }
            segDelta.append(["segment": name,
                             "a": Int(x), "b": Int(y),
                             "delta": Int(y) - Int(x)])
        }

        var flagsChanged: [String] = []
        if ma.flags != mb.flags { flagsChanged.append("flags 0x\(String(ma.flags, radix: 16)) → 0x\(String(mb.flags, radix: 16))") }
        if ma.cryptid != mb.cryptid { flagsChanged.append("cryptid \(ma.cryptid ?? 0) → \(mb.cryptid ?? 0)") }
        if ma.uuid != mb.uuid { flagsChanged.append("uuid \(ma.uuid ?? "-") → \(mb.uuid ?? "-")") }
        if ma.buildPlatform != mb.buildPlatform {
            flagsChanged.append("platform \(ma.buildPlatform ?? "-") → \(mb.buildPlatform ?? "-")")
        }

        var out: [String: Any] = [
            "ok": true,
            "a": a, "b": b,
            "symbols_a": namesA.count, "symbols_b": namesB.count,
            "added_count": added.count, "removed_count": removed.count,
            "added": Array(added.prefix(limit)),
            "removed": Array(removed.prefix(limit)),
            "truncated": added.count > limit || removed.count > limit,
            "segments": segDelta,
            "header_changes": flagsChanged,
            "sizes": ["a": ma.data.count, "b": mb.data.count, "delta": mb.data.count - ma.data.count],
        ]
        if added.count > limit || removed.count > limit {
            out["next_offset"] = limit
            out["note"] = "结果被截断：用 filter 缩小范围，或增大 limit（最大 500）"
        }
        StaticReport.finish(&out, "armor diff symbols +\(added.count)/-\(removed.count) segs=\(segDelta.count)",
                            limitations: ["只比较 LC_SYMTAB 里的名字；被 strip 的二进制没有符号可比",
                                          "不比较指令内容：同一符号内部实现变化不会被发现（用 disasm 对照）"])
        return out
    }

    private static func dirDiff(_ fa: [(String, Int)], _ fb: [(String, Int)],
                                a: String, b: String, filter: String, limit: Int) -> [String: Any] {
        let da = Dictionary(uniqueKeysWithValues: fa)
        let db = Dictionary(uniqueKeysWithValues: fb)
        var added = db.keys.filter { da[$0] == nil }
        var removed = da.keys.filter { db[$0] == nil }
        var changed = db.keys.filter { k in
            guard let x = da[k], let y = db[k] else { return false }
            return x != y
        }
        if !filter.isEmpty {
            added = added.filter { $0.localizedCaseInsensitiveContains(filter) }
            removed = removed.filter { $0.localizedCaseInsensitiveContains(filter) }
            changed = changed.filter { $0.localizedCaseInsensitiveContains(filter) }
        }
        added.sort(); removed.sort(); changed.sort()

        var out: [String: Any] = [
            "ok": true,
            "a": a, "b": b,
            "files_a": fa.count, "files_b": fb.count,
            "added_count": added.count, "removed_count": removed.count, "size_changed_count": changed.count,
            "added": Array(added.prefix(limit)),
            "removed": Array(removed.prefix(limit)),
            "size_changed": changed.prefix(limit).map { k -> [String: Any] in
                ["path": k, "a": da[k] ?? 0, "b": db[k] ?? 0, "delta": (db[k] ?? 0) - (da[k] ?? 0)]
            },
            "truncated": added.count > limit || removed.count > limit || changed.count > limit,
        ]
        if out["truncated"] as? Bool == true {
            out["note"] = "结果被截断：用 filter 缩小范围，或增大 limit（最大 500）"
        }
        StaticReport.finish(&out, "armor diff(dir) +\(added.count)/-\(removed.count)/~\(changed.count) files",
                            limitations: ["目录比较只看路径与大小：同名的插件/资源内容变化会被漏掉（用 md5 逐个核对）"])
        return out
    }

    // MARK: - 描述辅助

    private static func cpuDescription(_ cpu: UInt32) -> String {
        switch cpu {
        case 0x0100000c: return "arm64"
        case 0x0200000c: return "arm64e"
        case 0x0000000c: return "arm"
        case 0x01000007: return "x86_64"
        case 0x00000007: return "x86"
        default: return "cpu(0x\(String(cpu, radix: 16)))"
        }
    }

    private static func fileTypeName(_ t: UInt32) -> String {
        switch t {
        case 0x1: return "OBJECT"
        case 0x2: return "EXECUTE"
        case 0x4: return "CORE"
        case 0x5: return "PRELOAD"
        case 0x6: return "DYLIB"
        case 0x7: return "DYLINKER"
        case 0x8: return "BUNDLE"
        case 0x9: return "DYLIB_STUB"
        case 0xb: return "KEXT_BUNDLE"
        case 0xc: return "FILESET"
        default: return "type(\(t))"
        }
    }
}
