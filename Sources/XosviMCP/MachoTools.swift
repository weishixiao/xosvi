// Mach-O 静态分析工具（macho）
//
// 后端：MachOKit（p-x9/MachOKit，MIT，上游声明 iOS 13+）
// 设计原则（对齐 REA 的取证流程）：
//   1. 一次调用只完成一个取证目标，避免 AI 一口气拉全量
//   2. 所有列表类输出都强制分页/截断（默认 30 条），防 token 爆炸
//   3. 返回结构里带 evidence 字段，便于 AI 在结论里标注证据来源
//   4. 区分「文件本身的问题」与「环境限制」，报错信息要能指导下一步
//
// 注意：本工具只做**静态文件解析**，不 attach 进程、不改内存。
// 进程内存在 memory 工具（VansonMod 引擎）；运行时 hook 后续单独做。

import Foundation
// data(in:) 等节内容读取 API 标注为 @_spi(Support)，必须显式导入
@_spi(Support) import MachOKit

/// Mach-O 分析工具
final class MachoExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "macho",
        summary: "Static Mach-O binary analysis (headers / entitlements / codesign / exported symbols / strings). Reads the file only — no process attach, no memory write. Use for: verify IPA/app binary arch & UUID, extract entitlements before injection, diagnose ldid/codesign errors, list exported symbols to find hook targets, grep strings in a binary. For live process memory use memory tool. For running ldid/codesign use shell.exec.",
        parameters: [
            "command": "Subcommand (required): load / entitlements / codesign / symbols / strings / slices",
            "path": "Absolute path to Mach-O file (app executable, dylib, or .app dir). REQUIRED for all commands.",
            "pid": "Process pid — for command:load only, resolves the executable path from the running process instead of path.",
            "keyword": "Search keyword — REQUIRED for strings. Case-insensitive substring match.",
            "section": "For strings: restrict to a section. Default cstring. Options: cstring / objc_methname / objc_classname / ustring / all",
            "limit": "Max items to return. Default 30 (symbols/strings), keep small to save tokens.",
            "offset": "Paging offset for symbols/strings. Default 0. If results are truncated, call again with offset=limit."
        ],
        prerequisites: [
            "path 必须是绝对路径；.app 目录会自动解析到其中的可执行文件",
            "解析失败常见原因：文件未解密（cryptid=1，App Store 加密二进制只有头可读，需先砸壳）、架构 slice 不匹配",
            "entitlements 为空 ≠ 没有权限：可能是 ad-hoc 签名或权限被剥离，用 codesign 交叉验证"
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required. Available: load / entitlements / codesign / symbols / strings / slices")
        }

        let limit = max(1, min(Int("\(params["limit"] ?? 30)") ?? 30, 500))
        let offset = max(0, Int("\(params["offset"] ?? 0)") ?? 0)

        // pid 模式（仅 load）：从运行中进程反查可执行路径
        var resolvedPath: String?
        if command == "load", let pidRaw = params["pid"], let pid = Int32("\(pidRaw)"), pid > 0 {
            resolvedPath = Self.executablePath(forPid: pid)
            if resolvedPath == nil {
                throw MCPError.invalidParams("无法从 pid \(pid) 解析出可执行路径（进程可能已退出，或该进程是内核任务）")
            }
        }
        if resolvedPath == nil {
            guard let p = params["path"] as? String, !p.isEmpty else {
                throw MCPError.invalidParams("path required（绝对路径）")
            }
            resolvedPath = p
        }

        let file = try Self.openMachO(path: resolvedPath!)

        switch command {
        case "load":         return Self.describeHeader(file)
        case "entitlements": return try Self.entitlements(file)
        case "codesign":     return try Self.codeSignInfo(file)
        case "slices":       return Self.slices(path: resolvedPath!)
        case "symbols":      return try Self.exportedSymbols(file, offset: offset, limit: limit)
        case "strings":
            guard let kw = params["keyword"] as? String, !kw.isEmpty else {
                throw MCPError.invalidParams("keyword required for strings")
            }
            let section = (params["section"] as? String) ?? "cstring"
            return try Self.searchStrings(file, keyword: kw, section: section, offset: offset, limit: limit)
        default:
            throw MCPError.invalidParams("unknown command: \(command). Available: load / entitlements / codesign / symbols / strings / slices")
        }
    }

    // MARK: - 文件加载

    static func openMachO(path: String) throws -> MachOFile {
        let url = URL(fileURLWithPath: path)
        var target = url

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw MCPError.invalidParams("文件不存在: \(path)")
        }
        // .app 目录 → 解析到可执行文件（Info.plist 的 CFBundleExecutable）
        if isDir.boolValue {
            guard let exe = appExecutable(in: target) else {
                throw MCPError.invalidParams("目录里找不到可执行文件: \(path)（检查 Info.plist 的 CFBundleExecutable）")
            }
            target = exe
        }

        do {
            // loadFromFile 会自动区分 thin / fat；fat 包取第一个 slice
            switch try loadFromFile(url: target) {
            case .machO(let m):
                return m
            case .fat(let fat):
                // 官方推荐：fat.machOFiles() 直接给出各 slice 的 MachOFile
                let slices = try fat.machOFiles()
                guard let first = slices.first else {
                    throw MCPError.invalidParams("fat 包里没有架构: \(target.path)")
                }
                return first
            }
        } catch let e as MCPError {
            throw e
        } catch {
            throw MCPError.invalidParams(
                "解析 Mach-O 失败 (\(target.path)): \(error.localizedDescription)。"
                + "常见原因：不是 Mach-O 文件 / 文件被截断 / 是特殊格式（如 dyld shared cache）"
            )
        }
    }

    private static func appExecutable(in appDir: URL) -> URL? {
        let plist = appDir.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let exe = dict["CFBundleExecutable"] as? String {
            let u = appDir.appendingPathComponent(exe)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        // 兜底：找目录下同名的 Mach-O
        let base = appDir.deletingPathExtension().lastPathComponent
        let guess = appDir.appendingPathComponent(base)
        return FileManager.default.fileExists(atPath: guess.path) ? guess : nil
    }

    /// 从 pid 反查可执行路径（proc_pidpath）
    static func executablePath(forPid pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        // sys_proc_pidpath 由 ProcessTools.swift 用 @_silgen_name 声明（libproc）
        let n = sys_proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    // MARK: - load

    /// v10.11：MachOKit 0.56 起 `MachOFile.url` 变成可选（0.56.0 新增「从内存 Data 构造
    /// MachOFile」，源码注释：nil 表示不是从磁盘文件加载的）。所有输出路径统一走这里：
    /// 磁盘文件用 `url.path`，内存构造的回退到 `imagePath`（LC_ID_DYLIB / 空串）。
    static func fsPath(_ file: MachOFile) -> String {
        file.url?.path ?? file.imagePath
    }

    private static func describeHeader(_ file: MachOFile) -> [String: Any] {
        let h = file.header
        // CPUType / FileType 是库里的枚举，直接取描述即可（未知值返回 raw value）
        let cpu = h.cpuType.map { "\($0)" } ?? "unknown(\(h.layout.cputype))"
        let filetype = h.fileType.map { "\($0)" } ?? "unknown(\(h.layout.filetype))"

        var out: [String: Any] = [
            "ok": true,
            "path": Self.fsPath(file),
            "is_64bit": file.is64Bit,
            "is_swapped": file.isSwapped,
            "cpu_type": cpu,
            "cpu_subtype": h.cpuSubType.map { "\($0)" } ?? "unknown",
            "file_type": filetype,
            "ncmds": h.ncmds,
            "sizeofcmds": h.sizeofcmds,
            "flags": h.flags,
            "header_size": file.headerSize,
        ]

        // 单次遍历收集 UUID / 加密状态 / 依赖库
        var uuidString: String?
        var cryptId: Int?
        var dylibs: [String] = []
        for cmd in file.loadCommands {
            switch cmd {
            case let .uuid(c):
                uuidString = c.uuid.uuidString
            case let .encryptionInfo(c):
                cryptId = c.cryptId
            case let .encryptionInfo64(c):
                cryptId = c.cryptId
            case let .loadDylib(c), let .loadWeakDylib(c), let .reexportDylib(c),
                 let .lazyLoadDylib(c), let .loadUpwardDylib(c):
                dylibs.append(c.dylib(in: file).name)
            default:
                break
            }
        }

        if let u = uuidString { out["uuid"] = u }
        if let c = cryptId {
            out["cryptid"] = c
            if c != 0 {
                out["warning"] = "cryptid=\(c)：二进制已加密，代码段不可读。需先砸壳再分析（app 工具 decrypt）"
            }
        }
        out["dylib_count"] = dylibs.count
        out["dylibs"] = Array(dylibs.prefix(20))
        if dylibs.count > 20 {
            out["dylibs_note"] = "只显示前 20 个，共 \(dylibs.count) 个"
        }

        out["evidence"] = "macho load path:\(Self.fsPath(file)) cpu=\(cpu) filetype=\(filetype)"
        return out
    }

    // MARK: - entitlements

    /// v6.9.4：改为 internal——app entitlements 在 ldid 不可用时降级复用此实现
    static func entitlements(_ file: MachOFile) throws -> [String: Any] {
        guard let cs = file.codeSign else {
            return [
                "ok": false,
                "entitlements": [:] as [String: Any],
                "diagnosis": [
                    "[缺失] 该二进制没有 LC_CODE_SIGNATURE 加载命令，即未签名或签名被剥离",
                    "下一步：用 macho codesign 复查；若是自己构建的 App，重新用 ldid 签名"
                ],
            ]
        }
        let ents = cs.embeddedEntitlements ?? [:]

        var out: [String: Any] = [
            "ok": true,
            "path": Self.fsPath(file),
            "entitlements": ents,
            "count": ents.count,
        ]
        if ents.isEmpty {
            out["diagnosis"] = [
                "[空] 有签名但没有 entitlements blob",
                "可能原因：普通 Xcode 签名（未注入权限）或 ad-hoc 签名（ldid -S 未指定 plist）",
                "若目标是注入/task_for_pid，需要 task_for_pid-allow + platform-application"
            ]
        } else {
            // 常见关键权限速查，便于 AI 直接判断
            let keys = ["task_for_pid-allow", "platform-application",
                        "com.apple.private.security.no-sandbox",
                        "get-task-allow", "com.apple.system-task-ports"]
            var quick: [String: Bool] = [:]
            for k in keys { quick[k] = ents[k] as? Bool ?? false }
            out["key_entitlements"] = quick
        }
        out["evidence"] = "macho entitlements path:\(Self.fsPath(file)) count=\(ents.count)"
        return out
    }

    // MARK: - codesign

    private static func codeSignInfo(_ file: MachOFile) throws -> [String: Any] {
        guard let cs = file.codeSign else {
            return [
                "ok": false,
                "diagnosis": ["[缺失] 没有 LC_CODE_SIGNATURE：未签名或签名被剥离"]
            ]
        }
        var out: [String: Any] = ["ok": true, "path": Self.fsPath(file)]

        if let cd = cs.codeDirectory {
            out["hash_type"] = "\(cd.hashType)"
            out["version"] = cd.layout.version
            out["flags"] = cd.layout.flags
            out["code_limit"] = cd.layout.codeLimit
            // identifier 是 CDHash 输入的一部分，ldid/codesign 报错时常用它对照
            out["identifier"] = cd.identifier(in: cs)
            out["is_supports_team_id"] = cd.isSupportsTeamID
            out["is_supports_runtime"] = cd.isSupportsRuntime
        }
        out["has_entitlements"] = !(cs.embeddedEntitlements ?? [:]).isEmpty
        out["has_requirements"] = cs.requirementsBlob != nil
        out["signature_size"] = cs.signatureData?.count ?? 0

        if let flags = cs.codeDirectory?.layout.flags {
            // CS_ADHOC = 0x2：ad-hoc 签名（ldid 默认），App Store 分发不允许
            out["is_adhoc"] = (flags & 0x2) != 0
        }
        out["evidence"] = "macho codesign path:\(Self.fsPath(file))"
        return out
    }

    // MARK: - slices

    private static func slices(path: String) -> [String: Any] {
        do {
            guard case let .fat(fat) = try loadFromFile(url: URL(fileURLWithPath: path)) else {
                return [
                    "ok": true, "path": path, "is_fat": false,
                    "note": "thin Mach-O（单架构），用 command:load 查看 cpu_type"
                ]
            }
            let items = fat.arches.map { arch -> [String: Any] in
                [
                    "cpu_type": arch.cpuType.map { "\($0)" } ?? "unknown",
                    "cpu_subtype": arch.cpuSubType.map { "\($0)" } ?? "unknown",
                    "offset": arch.offset,
                    "size": arch.size,
                    "align": arch.align,
                ]
            }
            return ["ok": true, "path": path, "is_fat": true, "count": items.count, "slices": items]
        } catch {
            // 非 fat（thin）包
            return [
                "ok": true, "path": path, "is_fat": false,
                "note": "thin Mach-O（单架构），直接用 load 看 cpu_type"
            ]
        }
    }

    // MARK: - symbols

    private static func exportedSymbols(_ file: MachOFile, offset: Int, limit: Int) throws -> [String: Any] {
        let all = file.exportedSymbols
        let total = all.count
        let page = Array(all.dropFirst(min(offset, total)).prefix(limit))

        let items = page.map { s -> [String: Any] in
            var d: [String: Any] = [
                "name": s.name,
                "flags": "\(s.flags)",
            ]
            // offset 是相对文件头的偏移（MachOFile 语义）
            if let off = s.offset { d["offset"] = String(format: "0x%llx", off) }
            if let stub = s.stub { d["stub"] = String(format: "0x%llx", stub) }
            if let imp = s.importedName { d["imported_from"] = imp }
            return d
        }

        return [
            "ok": true,
            "path": Self.fsPath(file),
            "total": total,
            "offset": offset,
            "returned": items.count,
            "truncated": offset + items.count < total,
            "next_offset": offset + items.count < total ? offset + items.count : NSNull(),
            "symbols": items,
            "evidence": "macho symbols path:\(Self.fsPath(file)) total=\(total) page=\(offset)-\(offset + items.count)",
        ]
    }

    // MARK: - strings

    /// 在指定 section 里按关键词搜索字符串（默认 __TEXT,__cstring）
    private static func searchStrings(_ file: MachOFile, keyword: String, section: String,
                                      offset: Int, limit: Int) throws -> [String: Any] {
        let targets: [(String, String)] = {
            switch section.lowercased() {
            case "all":
                return [("__TEXT", "__cstring"), ("__TEXT", "__objc_methname"),
                        ("__TEXT", "__objc_classname"), ("__TEXT", "__ustring")]
            case "objc_methname": return [("__TEXT", "__objc_methname")]
            case "objc_classname": return [("__TEXT", "__objc_classname")]
            case "ustring": return [("__TEXT", "__ustring")]
            default: return [("__TEXT", "__cstring")]
            }
        }()

        var hits: [(addr: UInt64, text: String, sect: String)] = []
        var scannedSections: [String] = []
        let maxHits = 5000   // 防止超大字符串表拖死内存

        outer: for (segName, sectName) in targets {
            guard let sectionData = readSection(file, segName, sectName) else { continue }
            scannedSections.append("\(segName),\(sectName)")
            let base = sectionData.addr
            // 按 NUL 切分
            var start = 0
            let bytes = sectionData.bytes
            for i in 0..<bytes.count {
                if bytes[i] == 0 {
                    if i > start {
                        let slice = bytes[start..<i]
                        if let s = String(bytes: slice, encoding: .utf8),
                           s.lowercased().contains(keyword.lowercased()) {
                            hits.append((base + UInt64(start), s, "\(segName),\(sectName)"))
                            if hits.count >= maxHits { break outer }
                        }
                    }
                    start = i + 1
                }
            }
        }

        let total = hits.count
        let page = Array(hits.dropFirst(min(offset, total)).prefix(limit))
        let items = page.map { h -> [String: Any] in
            [
                "address": String(format: "0x%llx", h.addr),
                "text": h.text.count > 300 ? String(h.text.prefix(300)) + "…" : h.text,
                "section": h.sect,
            ]
        }

        return [
            "ok": true,
            "path": Self.fsPath(file),
            "keyword": keyword,
            "sections_scanned": scannedSections,
            "total": total,
            "offset": offset,
            "returned": items.count,
            "truncated": offset + items.count < total,
            "capped": total >= maxHits,
            "next_offset": offset + items.count < total ? offset + items.count : NSNull(),
            "matches": items,
            "note": "address 是虚拟地址（相对 image base），配合 disasm_arm64 / memory write 使用",
            "evidence": "macho strings path:\(Self.fsPath(file)) kw=\(keyword) total=\(total)",
        ]
    }

    private struct SectionBytes {
        let addr: UInt64
        let bytes: [UInt8]
    }

    private static func readSection(_ file: MachOFile, _ seg: String, _ sect: String) -> SectionBytes? {
        // machO.sections64 已是全部节的平铺数组，不必自己遍历 segment
        for sec in file.sections64 where sec.segname == seg && sec.sectname == sect {
            guard let data = sec.data(in: file) else { continue }
            return SectionBytes(addr: UInt64(sec.address), bytes: [UInt8](data))
        }
        return nil
    }

    // MARK: - 辅助


}
