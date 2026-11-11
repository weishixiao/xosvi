// StaticAnalysisSupport.swift — 纯静态解析的公共底座（v7.18.0）
//
// 背景（对齐 REA 的 static inspection 层次，见 MachoTools.swift 头注释）：
//   macho hardening / macho buildinfo / macho diff / inspect.ips 这四个取证动作
//   都不需要 MachOKit 的结构体，只需要「原始字节 + 加载命令 + 段表」。
//   REA 明确把这些列为 built-in inspection（无外部工具），这里照做：
//   自己扫 load commands，出错时能精确指出「文件本身的问题」还是「不支持」。
//
// 设计约束：
//   · 只读文件，不改内存、不 attach 进程；
//   · 所有列表输出都分页/截断，返回带 evidence；
//   · fat 包取指定 slice（默认第一个），并如实报告选了哪个。

import Foundation
import Compression

/// 轻量 Mach-O 读表器：只解析头 + 加载命令 + 节表，不解释内容。
struct RawMachO {
    struct Section {
        let segname: String
        let sectname: String
        let addr: UInt64
        let size: UInt64
        let offset: UInt32
    }

    struct Command {
        let cmd: UInt32
        let name: String
        let data: [UInt8]      // 整条 load command（含 cmd/cmdsize）
    }

    /// slice 在文件里的起止（fat 包时用于定位符号偏移）
    let sliceOffset: Int
    let sliceSize: Int
    let isFat: Bool
    let cpuType: UInt32
    let cpuSubType: UInt32
    let fileType: UInt32
    let flags: UInt32
    let ncmds: UInt32
    let commands: [Command]
    let sections: [Section]
    let is64: Bool
    let isBigEndian: Bool
    let uuid: String?
    let cryptid: UInt32?
    /// 加载命令里的平台（LC_BUILD_VERSION），如 "iOS 15.0"
    let buildPlatform: String?
    /// LC_SOURCE_VERSION 原始值（24 位编码，A.B.C.D.E）
    let sourceVersion: UInt64?
    /// 原始文件数据（含 fat 头），供后续读符号表/节内容
    let data: [UInt8]

    // MARK: - 读取

    /// 读任意 Mach-O（thin 或 fat）。slice 索引越界时退回第一个 slice。
    static func load(path: String, sliceIndex: Int = 0) throws -> RawMachO {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw MCPError.invalidParams("文件不存在: \(path)")
        }
        var target = url
        if isDir.boolValue {
            // .app 目录 → Info.plist 的 CFBundleExecutable
            let plist = url.appendingPathComponent("Info.plist")
            var exeName: String?
            if let d = try? Data(contentsOf: plist),
               let dict = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] {
                exeName = dict["CFBundleExecutable"] as? String
            }
            let name = exeName ?? url.deletingPathExtension().lastPathComponent
            target = url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw MCPError.invalidParams("目录里找不到可执行文件: \(path)（检查 Info.plist 的 CFBundleExecutable）")
            }
        }
        guard let raw = try? Data(contentsOf: target) else {
            throw MCPError.invalidParams("读文件失败: \(target.path)")
        }
        let bytes = [UInt8](raw)
        return try parse(bytes: bytes, sliceIndex: sliceIndex, path: target.path)
    }

    static func parse(bytes: [UInt8], sliceIndex: Int, path: String) throws -> RawMachO {
        guard bytes.count >= 4 else {
            throw MCPError.invalidParams("文件太小，不是 Mach-O: \(path)")
        }
        let beMagic = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        let leMagic = (UInt32(bytes[3]) << 24) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[1]) << 8) | UInt32(bytes[0])

        var sliceOff = 0
        var sliceSize = bytes.count
        var fatChosen = -1
        var archCount = 0

        if beMagic == 0xcafebabe || beMagic == 0xcafebabf {
            // fat：0xcafebabe = 32 位 fat header，0xcafebabf = 64 位
            let is64Fat = (beMagic == 0xcafebabf)
            archCount = Int(be32(bytes, 4))
            let entrySize = is64Fat ? 32 : 20
            var arches: [(cpu: UInt32, sub: UInt32, off: Int, size: Int)] = []
            var p = 8
            for _ in 0..<max(0, archCount) {
                guard p + entrySize <= bytes.count else { break }
                let cpu = be32(bytes, p)
                let sub = be32(bytes, p + 4)
                let off = is64Fat ? Int(be64(bytes, p + 8)) : Int(be32(bytes, p + 8))
                let size = is64Fat ? Int(be64(bytes, p + 16)) : Int(be32(bytes, p + 12))
                // 越界的 slice 直接跳过（截断/损坏的 fat 包很常见）
                if off >= 0, size > 0, off + size <= bytes.count {
                    arches.append((cpu, sub, off, size))
                }
                p += entrySize
            }
            guard !arches.isEmpty else {
                throw MCPError.invalidParams("fat 包里没有可读的架构 slice: \(path)（文件可能被截断）")
            }
            let idx = min(max(0, sliceIndex), arches.count - 1)
            fatChosen = idx
            sliceOff = arches[idx].off
            sliceSize = arches[idx].size
        } else if beMagic != 0xfeedface && beMagic != 0xfeedfacf {
            throw MCPError.invalidParams(
                "不是 Mach-O 文件: \(path)（magic=0x\(String(beMagic, radix: 16))）。"
                + "常见原因：这是脚本/文本/压缩包，或文件被截断")
        }

        guard sliceOff + 32 <= bytes.count else {
            throw MCPError.invalidParams("Mach-O 头不完整: \(path)")
        }
        // 头本身的字节序：magic 字段在小端机上存储为 cffaedfe，按大端读得到 0xfeedfacf；
        // 大端文件（PowerPC 时代 / 某些固件）存储为 feedfacf，按大端读仍是 0xfeedfacf。
        // 区分方法：看原始 4 字节是 CF FA ED FE（小端）还是 FE ED FA CF（大端）。
        let b0 = bytes[sliceOff], b1 = bytes[sliceOff + 1], b2 = bytes[sliceOff + 2], b3 = bytes[sliceOff + 3]
        let magicLE = (b0 == 0xcf && b1 == 0xfa && b2 == 0xed && b3 == 0xfe)     // 此文件为小端
        let magicLE32 = (b0 == 0xce && b1 == 0xfa && b2 == 0xed && b3 == 0xfe)   // 32 位小端
        let magicBE = (b0 == 0xfe && b1 == 0xed && b2 == 0xfa && (b3 == 0xce || b3 == 0xcf))
        guard magicLE || magicLE32 || magicBE else {
            throw MCPError.invalidParams("slice 不是 Mach-O 头（\(String(format: "%02x %02x %02x %02x", b0, b1, b2, b3))）: \(path)")
        }
        let isLittle = magicLE || magicLE32
        let is64Header = magicLE || (magicBE && b3 == 0xcf)

        func u32(_ off: Int) -> UInt32 { isLittle ? le32(bytes, off) : be32(bytes, off) }
        func u64(_ off: Int) -> UInt64 { isLittle ? le64(bytes, off) : be64(bytes, off) }

        let cpuType = u32(sliceOff + 4)
        let cpuSub = u32(sliceOff + 8)
        let fileType = u32(sliceOff + 12)
        let ncmds = u32(sliceOff + 16)
        let sizeOfCmds = Int(u32(sliceOff + 20))
        let flags = u32(sliceOff + 24)
        let headerSize = is64Header ? 32 : 28

        guard ncmds < 100_000, sizeOfCmds <= sliceSize else {
            throw MCPError.invalidParams("加载命令表异常（ncmds=\(ncmds) sizeofcmds=\(sizeOfCmds)）: \(path)")
        }

        var commands: [Command] = []
        var sections: [Section] = []
        var uuid: String?
        var crypt: UInt32?
        var platform: String?
        var sourceVer: UInt64?

        var p = sliceOff + headerSize
        let end = min(p + sizeOfCmds, bytes.count)
        while p + 8 <= end {
            let cmd = u32(p)
            let size = Int(u32(p + 4))
            guard size >= 8, p + size <= end else { break }
            let body = Array(bytes[p..<(p + size)])
            commands.append(Command(cmd: cmd, name: Self.commandName(cmd), data: body))

            switch cmd {
            case 0x1b:   // LC_UUID
                if body.count >= 24 {
                    var s = ""
                    for i in 0..<16 { s += String(format: "%02x", body[8 + i]) }
                    uuid = s
                }
            case 0x21, 0x2c:  // LC_ENCRYPTION_INFO / _64
                crypt = body.count >= 16 ? Self.le32Or(body, 8, isLittle) : nil
            case 0x19, 0x1:   // LC_SEGMENT_64 / LC_SEGMENT
                let is64 = (cmd == 0x19)
                let segHeader = is64 ? 72 : 56
                guard body.count >= segHeader else { break }
                let segname = Self.cstr(body, 8, 16)
                let nsects = is64 ? Int(Self.u32in(body, 64, isLittle)) : Int(Self.u32in(body, 48, isLittle))
                // 段命令的固定布局：cmd(4) cmdsize(4) segname(16) vmaddr(8) vmsize(8) fileoff(8)
                // filesize(8) maxprot(4) initprot(4) nsects(4) flags(4) = 72（64 位）/ 56（32 位）
                // 节从 segHeader 之后开始。
                var q = segHeader
                for _ in 0..<nsects {
                    let sectSize = is64 ? 80 : 68
                    guard q + sectSize <= body.count else { break }
                    let sectname = Self.cstr(body, q, 16)
                    let addr = is64 ? Self.u64in(body, q + 32, isLittle) : UInt64(Self.u32in(body, q + 32, isLittle))
                    let size = is64 ? Self.u64in(body, q + 40, isLittle) : UInt64(Self.u32in(body, q + 36, isLittle))
                    let off = Self.u32in(body, q + (is64 ? 48 : 40), isLittle)
                    sections.append(Section(segname: segname, sectname: sectname,
                                            addr: addr, size: size, offset: off))
                    q += sectSize
                }
            case 0x32:  // LC_BUILD_VERSION
                guard body.count >= 16 else { break }
                let plat = Self.u32in(body, 8, isLittle)
                let minosRaw = Self.u32in(body, 12, isLittle)
                let names: [UInt32: String] = [1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS",
                                               6: "macCatalyst", 7: "iOSSimulator", 11: "visionOS"]
                let ver = "\(minosRaw >> 16).\((minosRaw >> 8) & 0xff).\(minosRaw & 0xff)"
                platform = "\(names[plat] ?? "platform(\(plat))") \(ver)"
            case 0x2a:  // LC_SOURCE_VERSION
                if body.count >= 16 { sourceVer = is64 ? Self.u64in(body, 8, isLittle) : UInt64(Self.u32in(body, 8, isLittle)) }
            default:
                break
            }
            p += size
        }

        return RawMachO(
            sliceOffset: sliceOff, sliceSize: sliceSize, isFat: beMagic == 0xcafebabe || beMagic == 0xcafebabf,
            cpuType: cpuType, cpuSubType: cpuSub, fileType: fileType, flags: flags,
            ncmds: ncmds, commands: commands, sections: sections,
            is64: is64Header, isBigEndian: !isLittle, uuid: uuid, cryptid: crypt,
            buildPlatform: platform, sourceVersion: sourceVer,
            data: bytes
        )
    }

    // MARK: - 便捷读取

    /// 取某个节的内容（按文件偏移，非虚拟地址）
    func sectionBytes(seg: String, sect: String) -> [UInt8]? {
        guard let s = sections.first(where: { $0.segname == seg && $0.sectname == sect }) else { return nil }
        let start = sliceBase + Int(s.offset)
        let len = Int(s.size)
        guard start >= 0, len > 0, start + len <= data.count else { return nil }
        return Array(data[start..<(start + len)])
    }

    /// 某条加载命令的第一份数据
    func firstCommand(_ cmd: UInt32) -> [UInt8]? {
        commands.first(where: { $0.cmd == cmd })?.data
    }

    /// 字符串表里的符号（LC_SYMTAB），返回 (地址, 名字, 类型)。导入与导出符号都在，
    /// 名字前缀（如 _objc_msgSend / 库名）原样返回，交给调用方判断。
    /// 大二进制上限 200 万条，超出即停（防止解析拖死内存）。
    func symbols(isLittle: Bool = true) -> [(addr: UInt64, name: String, type: UInt8)] {
        guard let symtab = firstCommand(0x2), symtab.count >= 24 else { return [] }
        func u32(_ b: [UInt8], _ o: Int) -> UInt32 { Self.u32in(b, o, isLittle) }
        let symoff = Int(u32(symtab, 8))
        let nsyms = Int(u32(symtab, 12))
        let stroff = Int(u32(symtab, 16))
        let strsize = Int(u32(symtab, 20))
        guard symoff > 0, nsyms > 0, nsyms < 2_000_000,
              stroff > 0, strsize > 0, stroff + strsize <= data.count else { return [] }

        let entrySize = is64 ? 16 : 12   // nlist_64 / nlist
        let limit = min(nsyms, 2_000_000)
        var out: [(UInt64, String, UInt8)] = []
        out.reserveCapacity(min(limit, 100_000))   // 上限只防病态文件，别一次 reserve 2M 条
        for i in 0..<limit {
            let base = sliceBase + symoff + i * entrySize
            guard base + entrySize <= data.count else { break }
            let strx = Int(u32(data, base))
            let type = data[base + 4]
            let value = is64
                ? Self.u64in(data, base + 8, isLittle)
                : UInt64(Self.u32in(data, base + 8, isLittle))
            guard strx > 0, strx < strsize else { continue }
            let name = Self.cstr(data, sliceBase + stroff + strx, 512)
            guard !name.isEmpty else { continue }
            out.append((value, name, type))
        }
        return out
    }

    /// 节内容在文件里的绝对起点（thin：0；fat：slice 起点）
    var sliceBase: Int { sliceOffset }

    // MARK: - 字节工具

    static func u32in(_ b: [UInt8], _ o: Int, _ le: Bool) -> UInt32 { le ? le32(b, o) : be32(b, o) }
    static func u64in(_ b: [UInt8], _ o: Int, _ le: Bool) -> UInt64 { le ? le64(b, o) : be64(b, o) }
    static func le32Or(_ b: [UInt8], _ o: Int, _ le: Bool) -> UInt32 { le ? le32(b, o) : be32(b, o) }

    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
    static func le64(_ b: [UInt8], _ o: Int) -> UInt64 {
        guard o + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(b[o + i]) }
        return v
    }
    static func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        guard o + 4 <= b.count else { return 0 }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }
    static func be64(_ b: [UInt8], _ o: Int) -> UInt64 {
        guard o + 8 <= b.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[o + i]) }
        return v
    }
    static func cstr(_ b: [UInt8], _ o: Int, _ max: Int) -> String {
        guard o >= 0, o < b.count else { return "" }
        var end = o
        let limit = min(b.count, o + max)
        while end < limit && b[end] != 0 { end += 1 }
        return String(bytes: b[o..<end], encoding: .utf8) ?? ""
    }

    static func commandName(_ cmd: UInt32) -> String {
        switch cmd {
        case 0x1: return "LC_SEGMENT";            case 0x2: return "LC_SYMTAB"
        case 0x3: return "LC_SYMSEG";             case 0x4: return "LC_THREAD"
        case 0x5: return "LC_UNIXTHREAD";         case 0xb: return "LC_DYSYMTAB"
        case 0xc: return "LC_LOAD_DYLIB";         case 0xd: return "LC_ID_DYLIB"
        case 0xe: return "LC_LOAD_DYLINKER";      case 0xf: return "LC_ID_DYLINKER"
        case 0x19: return "LC_SEGMENT_64";        case 0x1a: return "LC_ROUTINES_64"
        case 0x1b: return "LC_UUID";              case 0x1c: return "LC_RPATH"
        case 0x1d: return "LC_CODE_SIGNATURE";    case 0x1e: return "LC_SEGMENT_SPLIT_INFO"
        case 0x1f: return "LC_REEXPORT_DYLIB";    case 0x20: return "LC_LAZY_LOAD_DYLIB"
        case 0x21: return "LC_ENCRYPTION_INFO";   case 0x22: return "LC_DYLD_INFO"
        case 0x23: return "LC_DYLD_INFO_ONLY";    case 0x25: return "LC_LOAD_WEAK_DYLIB"
        case 0x26: return "LC_SEGMENT_SPLIT_SEGS"; case 0x27: return "LC_ROUTINES"
        case 0x29: return "LC_DATA_IN_CODE";      case 0x2a: return "LC_SOURCE_VERSION"
        case 0x2b: return "LC_DYLIB_CODE_SIGN_DRS"; case 0x2c: return "LC_ENCRYPTION_INFO_64"
        case 0x2d: return "LC_LINKER_OPTION";     case 0x2f: return "LC_VERSION_MIN_MACOSX"
        case 0x30: return "LC_VERSION_MIN_IPHONEOS"; case 0x31: return "LC_FUNCTION_STARTS"
        case 0x32: return "LC_BUILD_VERSION";     case 0x33: return "LC_DYLD_EXPORTS_TRIE"
        case 0x34: return "LC_DYLD_CHAINED_FIXUPS"; case 0x35: return "LC_FILESET_ENTRY"
        case 0x80000022: return "LC_MAIN";        case 0x80000023: return "LC_DYLD_ENVIRONMENT"
        case 0x8000001c: return "LC_RPATH";       case 0x80000028: return "LC_LOAD_UPWARD_DYLIB"
        default: return String(format: "LC_0x%x", cmd)
        }
    }
}

/// zlib 解压桥（Rust cargo-auditable 的 __dep_v0 节可能是 zlib 流）。
/// Compression 框架的 COMPRESSION_ZLIB 只吃 raw DEFLATE，所以要自己跳过 zlib 头。
/// 不知道解压后大小，就按 64KB → 4x 递增试到 64MB，命中即返回。
enum ZlibBridge {
    static func inflate(_ input: Data) -> Data? {
        guard input.count > 8 else { return nil }
        // 先按标准 zlib 流处理：跳 2 字节头 + 4 字节 adler32 尾
        let body = input[(input.startIndex + 2)..<(input.endIndex - 4)]
        if let out = decode(Data(body)) { return out }
        // 再按裸 deflate 试
        return decode(input)
    }

    private static func decode(_ src: Data) -> Data? {
        guard !src.isEmpty else { return nil }
        var cap = 64 * 1024
        while cap <= 64 * 1024 * 1024 {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            let n = src.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, cap, base, src.count, nil, COMPRESSION_ZLIB)
            }
            if n > 0 {
                let out = Data(bytes: dst, count: n)
                dst.deallocate()
                return out
            }
            dst.deallocate()
            cap *= 4
        }
        return nil
    }
}

/// REA 风格的结果包装：ok / evidence / limitations 三件套。
enum StaticReport {
    /// 统一给结论加证据行；结论已带 evidence 时不覆盖。
    static func finish(_ out: inout [String: Any], _ evidence: String, limitations: [String] = []) {
        out["evidence"] = evidence
        if !limitations.isEmpty { out["limitations"] = limitations }
    }
}
