// PackageTool：解包查看别人的包（deb / ipa）— v3.3.4
// 子命令：inspect（列结构）/ unpack（解包到工作区）
// deb = ar 归档（control.tar.* + data.tar.*）；ipa = zip。
// 压缩支持：gzip（zlib）、xz/lzma（Compression）；zstd 暂不支持（提示电脑端处理）。

import Foundation
import Compression
import zlib
import ZIPFoundation
import CLZMA

final class PackageTool: MCPTool {
    let definition = ToolDefinition(
        name: "package",
        summary: "Inspect & unpack .deb/.ipa packages. Commands: inspect / unpack / selftest (verify built-in decoders). Inspect (list members: deb→ar entries+control text+data.tar list; ipa→zip entries+main Info.plist path) / unpack (extract to workspace dir, read via artifact). Params: command, path, dest. Formats: deb=ar+tar(gz/lzma/xz decoded in-process, bz2/zstd via bundled python3); ipa=zip(stored/deflate); a .app/.appex directory=bundle anatomy (Info.plist fields, archs, cryptid, frameworks/plugins, sizes). Use for: see inside deb/ipa, list structure, read control/info, extract files. Required: command+path.",
        parameters: [
            "command": "inspect / unpack",
            "path": "absolute path to .deb or .ipa, or an unpacked .app/.appex directory (bundle anatomy)",
            "dest": "required for unpack — output directory (will be created)"
        ],
        verified: false, category: "package", prerequisites: [
            "path must be a real file (use shell.exec / shell to locate it first)",
            "unpack writes to dest; ensure enough free space for extracted size",
            "after unpack, read inner files with artifact read"
        ], annotations: .writeLocal, cache: ToolCachePolicy.none)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("package: missing command (inspect / unpack / selftest)")
        }
        // v6.6.12：自检不依赖任何文件，放在 path 校验之前
        if command == "selftest" { return selfTest() }
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("package: missing path")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.classified("package: file not found: \(path)",
                                      code: "NOT_FOUND", reason: "path",
                                      nextStep: "use shell.exec / shell ls to locate the file first")
        }

        switch command {
        case "inspect": return try inspect(path)
        case "unpack":
            guard let dest = params["dest"] as? String, !dest.isEmpty else {
                throw MCPError.invalidParams("package unpack: missing dest (output directory)")
            }
            return try unpack(path, dest: dest)
        default:
            throw MCPError.invalidParams("package: unknown command '\(command)' (inspect / unpack)")
        }
    }

    // MARK: - Inspect

    private func inspect(_ path: String) throws -> [String: Any] {
        // v7.18.0：目录 = 解包后的 .app / .appex，走 Apple bundle 解剖
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return try BundleAnatomy.inspect(path)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("package: cannot read file: \(path)")
        }
        if data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) {
            return try inspectDeb(data, path: path)
        }
        // zip magic: PK\x03\x04 (local) or PK\x05\x06 (empty)
        if data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06]) {
            return try inspectIpa(path)
        }
        throw MCPError.classified("package: unsupported format (not deb/ipa) — magic mismatch",
                                  code: "BAD_FORMAT", reason: "format",
                                  nextStep: "only .deb (ar archive) and .ipa (zip) supported")
    }

    private func inspectDeb(_ data: Data, path: String) throws -> [String: Any] {
        var offset = 8 // skip "!<arch>\n"
        var members: [[String: Any]] = []
        var dataTarName: String?
        var controlText: String?
        var dataFileList: [String] = []
        var dataCompressionNote: String?

        // v6.6.7：所有 ar 偏移先做差值检查，再创建 Data 区间。
        // 恶意/截断归档里的负数或超大 size 会让 offset 变负，Swift Data
        // 下标会直接 brk #1（SIGTRAP），而不是抛出可捕获错误。
        while offset >= 0, offset <= data.count, data.count - offset >= 60 {
            let headerEnd = offset + 60 // 已由上面的差值检查保证不溢出
            // 用 safeSlice 归一化 Data 的索引；Data 的切片可能保留原始
            // lowerBound，随后访问 hdr[0..<16] 会触发 SIGTRAP。
            let hdr = safeSlice(data, offset..<headerEnd)
            let name = String(data: hdr[0..<16], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sizeStr = String(data: hdr[48..<58], encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let size = Int(sizeStr), size >= 0 else {
                ShellDiag.log("package inspectDeb: member '\(name)' size='\(sizeStr)' 无效 (offset=\(offset))")
                break
            }
            let contentStart = headerEnd
            guard size <= data.count - contentStart else {
                ShellDiag.log("package inspectDeb: member '\(name)' size=\(size) 超出归档 (offset=\(offset), total=\(data.count))")
                break
            }
            let contentEnd = contentStart + size
            let padding = size & 1
            guard contentEnd <= data.count - padding else {
                ShellDiag.log("package inspectDeb: member '\(name)' 缺少 ar 对齐字节 (offset=\(offset))")
                break
            }
            // 归一化 ar member 的 Data 索引；Data slice 会保留原始 lowerBound，
            // 后续 decompressTar/raw[0...] 需要从 0 开始的索引。
            let content = safeSlice(data, contentStart..<contentEnd)

            // skip symbol table members
            if name != "/" && name != "//" && !name.hasSuffix("/") {
                members.append([
                    "name": name,
                    "size": size,
                    "type": name.hasPrefix("data.tar") ? "data archive" : (name.hasPrefix("control.tar") ? "control archive" : "member")
                ])
                ShellDiag.log("package inspectDeb member: \(name) size=\(size)")
                if name.hasPrefix("data.tar") {
                    dataTarName = name
                    // v6.6.8: xz/lzma/bz2/zstd 已由内置原生 python3 解码，不再跳过；
                    // 只有真正解不出来时才标注提示，避免 data_file_count=0 误导。
                    dataFileList = tarFileList(content) ?? []
                    if dataFileList.isEmpty {
                        dataCompressionNote = "data.tar 无法解析文件列表（压缩格式不支持或数据损坏）；可在电脑端用 7-Zip/bsdtar 解包"
                        ShellDiag.log("package inspectDeb: data.tar=\(name) 解析失败 —— 提示用户电脑端处理")
                    } else {
                        ShellDiag.log("package inspectDeb data.tar=\(name) files=\(dataFileList.count)")
                    }
                }
                if name.hasPrefix("control.tar") {
                    controlText = controlFromTar(content)
                    ShellDiag.log("package inspectDeb control.tar=\(name) textLen=\((controlText ?? "").count)")
                }
            }
            offset = contentEnd + padding // ar aligns to even
        }

        return [
            "format": "deb (ar archive)",
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "decoders": "in-process: gzip(zlib)/lzma-alone/xz; python3: bz2/zstd",
            "path": path,
            "file_size": data.count,
            "members": members,
            "control": controlText ?? "(no control)",
            "data_archive": dataTarName ?? "(none)",
            "data_file_count": dataFileList.count,
            "data_compression_note": dataCompressionNote ?? "(none)",
            "data_files_sample": Array(dataFileList.prefix(80)),
            "hint": "use package command:unpack path:<file> dest:<dir> to extract, then artifact inner files"
        ]
    }

    private func inspectIpa(_ path: String) throws -> [String: Any] {
        guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read) else {
            throw MCPError.failed("package: cannot open ipa as zip: \(path)")
        }
        let names = archive.map { $0.path }
        var payloadInfoPath: String?
        if let p = names.first(where: { $0.hasSuffix("/Info.plist") && $0.hasPrefix("Payload/") }) {
            payloadInfoPath = p
        }
        var appNames = Set<String>()
        for n in names where n.hasPrefix("Payload/") {
            let parts = n.split(separator: "/", omittingEmptySubsequences: true)
            if parts.count >= 2 { appNames.insert(String(parts[1])) }
        }
        return [
            "format": "ipa (zip)",
            "path": path,
            "file_size": (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0,
            "entry_count": names.count,
            "entries_sample": Array(names.prefix(120)),
            "app_names": Array(appNames),
            "main_info_plist": payloadInfoPath ?? "(none)",
            "hint": "use package command:unpack path:<file> dest:<dir> to extract, then artifact Payload/<App>.app/Info.plist"
        ]
    }

    // MARK: - Unpack

    private func unpack(_ path: String, dest: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("package: cannot read file: \(path)")
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let destURL = URL(fileURLWithPath: dest).standardizedFileURL

        var extracted = 0
        var list: [String] = []
        var format = "unknown"
        var memberErrors: [String] = []

        if data.prefix(8).elementsEqual(Array("!<arch>\n".utf8)) {
            format = "deb"
            // unpack data.tar.* fully; control.tar content too (control file readable)
            // v6.6.7：ar header 的 size 来自外部文件，不能直接参与
            // contentStart + size / Data range 运算；异常值会触发 Swift
            // 的 brk #1（SIGTRAP），而不是可捕获的 Error。
            var offset = 8
            while offset >= 0, offset <= data.count, data.count - offset >= 60 {
                let headerEnd = offset + 60 // 差值检查已保证不会溢出
                // 用 safeSlice 归一化 Data 的索引；Data 的切片可能保留原始
                // lowerBound，随后访问 hdr[0..<16] 会触发 SIGTRAP。
                let hdr = safeSlice(data, offset..<headerEnd)
                let name = String(data: hdr[0..<16], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let sizeStr = String(data: hdr[48..<58], encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let size = Int(sizeStr), size >= 0 else {
                    ShellDiag.log("package unpack: member '\(name)' size='\(sizeStr)' 无效 (offset=\(offset))")
                    break
                }
                let contentStart = headerEnd
                // 先用减法判断，避免 contentStart + size 溢出。
                guard size <= data.count - contentStart else {
                    ShellDiag.log("package unpack: member '\(name)' size=\(size) 超出归档 (offset=\(offset), total=\(data.count))")
                    break
                }
                let contentEnd = contentStart + size
                let padding = size & 1
                guard padding <= data.count - contentEnd else {
                    ShellDiag.log("package unpack: member '\(name)' 缺少 ar 对齐字节 (offset=\(offset))")
                    break
                }
                // 归一化 ar member 的 Data 索引；后续 decompressTar 会读取 raw[0...].
                let content = safeSlice(data, contentStart..<contentEnd)
                if name != "/" && name != "//" && !name.hasSuffix("/") {
                    // v6.6.12：成员之间互相隔离——control.tar.gz 解不开不应该连带
                    // data.tar 一起失败（真机上正是 control 坏了，却报成 data.tar）。
                    do {
                        if name.hasPrefix("data.tar") {
                            let n = try extractTar(content, into: destURL, label: name)
                            extracted += n
                            list.append(contentsOf: tarFileList(content) ?? [])
                        } else if name.hasPrefix("control.tar") {
                            let n = try extractTar(content, into: destURL.appendingPathComponent("_control"), label: name)
                            extracted += n
                        }
                    } catch {
                        let msg: String
                        if let e = error as? MCPError {
                            switch e {
                            case .classified(let m, _, _, _): msg = m
                            case .classifiedData(let m, _, _, _, _): msg = m
                            case .failed(let m): msg = m
                            case .invalidParams(let m): msg = m
                            case .unknownTool(let m): msg = m
                            }
                        } else {
                            msg = "\(error)"
                        }
                        memberErrors.append("\(name): \(msg)")
                    }
                }
                offset = contentEnd + padding
            }
        } else if data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
            || data.prefix(4).elementsEqual([0x50, 0x4B, 0x05, 0x06]) {
            format = "ipa"
            guard let archive = try? Archive(url: URL(fileURLWithPath: path), accessMode: .read) else {
                throw MCPError.failed("package: cannot open ipa as zip: \(path)")
            }
            var count = 0
            for entry in archive {
                do {
                    _ = try archive.extract(entry, to: destURL.appendingPathComponent(entry.path))
                    count += 1
                } catch { /* skip unreadable entry */ }
            }
            extracted = count
            list = archive.map { $0.path }
        } else {
            throw MCPError.classified("package: unsupported format (not deb/ipa)",
                                      code: "BAD_FORMAT", reason: "format",
                                      nextStep: "only .deb (ar) and .ipa (zip) supported")
        }

        return [
            "command": "unpack",
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "format": format,
            "dest": destURL.path,
            "extracted_count": extracted,
            "top_files_sample": Array(list.prefix(100)),
            "member_errors": memberErrors,
            "next": memberErrors.isEmpty
                ? "read inner files with artifact read"
                : "部分成员解析失败（见 member_errors）；其余内容已解出，可直接用 artifact 读取"
        ]
    }

    // MARK: - tar

    /// List file paths inside a possibly-compressed tar (data.tar.gz/.xz/.lzma/plain).
    private func tarFileList(_ raw: Data) -> [String]? {
        // v6.6.12：先走进程内解码——旧实现把压缩成员一律交给 python3，
        // 早期版本误判 python3 起不来，于是 data_file_count 恒为 0；现已内置解码。
        // （inspect 看起来像"包坏了"，实际只是列表来源不可用）。
        if let tar = decompressTar(raw) {
            let names = parseTar(tar).map { $0.name }
            if !names.isEmpty { return names }
        }
        if let kind = compressionKind(raw) { return NativeTar.list(raw, kind: kind) }
        return nil
    }

    private func controlFromTar(_ raw: Data) -> String? {
        guard let tar = decompressTar(raw) else { return nil }
        for (name, data) in parseTar(tar) where name == "./control" || name == "control" {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
        }
        return nil
    }

    /// 压缩类型判定（按魔数）。返回 nil 表示不是已知压缩，调用方按裸 tar 处理。
    /// 注意：魔数一律用 [UInt8] 字面量——字符串转 UTF-8 会把 0xB5 编成两字节（C2 B5），
    /// 旧代码用 "\u{B5}" 比较 zstd 魔数因此永远不匹配。
    private func compressionKind(_ raw: Data) -> String? {
        if raw.count >= 6 && raw[0..<6].elementsEqual([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return "xz" }
        if raw.count >= 3 && raw[0] == 0x42 && raw[1] == 0x5A && raw[2] == 0x68 { return "bz2" }   // "BZh"
        if raw.count >= 4 && raw[0..<4].elementsEqual([0x28, 0xB5, 0x2F, 0xFD]) { return "zstd" }
        // .lzma-alone：13 字节头
        //   byte0    = lc/lp/pb 属性，合法范围 0..224（默认 0x5D）
        //   byte1..4 = 字典大小 LE32
        //   byte5..12= 原始大小，未知时全 0xFF
        // 旧实现硬要求 byte1/byte2 == 0（即字典 < 64KB 段），换个字典大小就漏判，
        // 于是 data.tar.lzma 直接落到「未知格式」→ cannot decompress。改为校验属性范围
        // + 大小字段形状，既能识别任意字典大小，也不会把普通文件误判。
        if raw.count >= 14 {
            let props = raw[raw.startIndex]
            var declared: UInt64 = 0
            for i in 5..<13 { declared |= UInt64(raw[raw.startIndex + i]) << (8 * UInt64(i - 5)) }
            let unknownSize = (declared == 0xFFFF_FFFF_FFFF_FFFF)
            // 合理性：未知大小，或声明值落在 1B..4GB
            if props < 225, unknownSize || (declared > 0 && declared < 0x1_0000_0000) {
                return "lzma"
            }
        }
        return nil
    }

    private func decompressTar(_ raw: Data) -> Data? {
        // detect by magic
        if raw.count >= 2 && raw[0] == 0x1F && raw[1] == 0x8B { return gunzip(raw) }       // gzip
        // 裸 tar 先判（ustar 魔数/校验和是很强的特征）：否则压缩判定可能把它误认成 lzma。
        if raw.count >= 512, looksLikeTar(raw) { return raw }
        // .lzma-alone 优先走进程内 C 解码器（CLZMA）：不依赖 python3/bsdtar 子进程，
        // 早期版本误判子进程被拒；现统一走进程内解码，避免依赖外部二进制。
        if compressionKind(raw) == "lzma", let d = LzmaAlone.decode(raw) { return d }
        // .xz 同样内置解码（LZMA2 + CRC32/CRC64 + BCJ），不依赖子进程。
        if compressionKind(raw) == "xz", let d = XZStream.decode(raw) { return d }
        // v6.6.8：xz / lzma-alone / bz2 / zstd 一律交给内置原生 python3 的 _lzma/_bz2/_zstd。
        // 根因：Apple Compression 的 COMPRESSION_LZMA 官方只支持「XZ 容器里的 LZMA2」，
        // 解不了 deb 最常见的 .lzma-alone（13 字节头）——compression_decode_buffer 恒返回 0，
        // 旧实现于是每次都报 "cannot decompress data.tar"（真机实测，数据为 0x5D 68MB 字典）。
        if let kind = compressionKind(raw), let d = NativeTar.decompress(raw, kind: kind) { return d }
        // 最后一招：头部形态不被识别时也试一次 lzma——各打包工具的字典大小、
        // 声明大小写法不一，光靠魔数会漏判（真机就遇到过）。解完再用 tar 结构校验，
        // 不会把随机数据当成成功。
        if raw.count > 14, let d = LzmaAlone.decode(raw), looksLikeTar(d) { return d }
        return nil
    }

    /// 判断一段数据是否像 tar（ustar 魔数或头部校验和自洽）。
    /// 用于压缩解码后的结果验证，避免把「解出一堆垃圾」当成功。
    private func looksLikeTar(_ d: Data) -> Bool {
        guard d.count >= 512 else { return false }
        let base = d.startIndex
        if d.count >= 265 {
            let magic = d[(base + 257)..<(base + 262)]
            if magic.elementsEqual([0x75, 0x73, 0x74, 0x61, 0x72]) { return true }   // "ustar"
        }
        // 校验和字段：148..156，八进制 ASCII
        var stored: Int64 = 0
        var digits = 0
        for i in 148..<156 {
            let c = d[base + i]
            if c == 0 || c == 0x20 { if digits > 0 { break } else { continue } }
            guard c >= 0x30, c <= 0x37 else { return false }
            stored = stored * 8 + Int64(c - 0x30)
            digits += 1
        }
        guard digits > 0 else { return false }
        var unsigned: Int64 = 0
        var signed: Int64 = 0
        for i in 0..<512 {
            let c = (i >= 148 && i < 156) ? UInt8(0x20) : d[base + i]
            unsigned += Int64(c)
            signed += (c & 0x80) != 0 ? Int64(c) - 256 : Int64(c)
        }
        return stored == unsigned || stored == signed
    }

    /// gzip 解压。
    ///
    /// v6.6.12 修复：旧实现先跳过 10 字节 gzip 头，却用 `inflateInit2(31)`
    /// （31 = 16+15，表示「输入自带 gzip 头」），于是 inflate 拿到的第一个字节
    /// 不是 0x1f，必然 Z_DATA_ERROR —— 这段代码从来没解开过任何 gzip，
    /// deb 的 control.tar.gz 一直失败（还被误报成 data.tar）。
    /// 现在把完整数据交给 zlib，由它解析 header/FEXTRA/FNAME/FCOMMENT 与 CRC。
    private func gunzip(_ data: Data) -> Data? {
        guard data.count > 18 else { return nil }
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let base = src.baseAddress else { return nil }
            let srcPtr = base.bindMemory(to: UInt8.self, capacity: data.count)
            var out = Data()
            let chunk = 64 * 1024
            var dst = [UInt8](repeating: 0, count: chunk)
            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: srcPtr)
            stream.avail_in = UInt32(data.count)
            let ok = inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard ok == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            while true {
                stream.next_out = dst.withUnsafeMutableBytes { $0.bindMemory(to: UInt8.self).baseAddress }
                stream.avail_out = UInt32(chunk)
                let r = inflate(&stream, Z_NO_FLUSH)
                let produced = chunk - Int(stream.avail_out)
                if r == Z_STREAM_END {
                    out.append(dst, count: produced)
                    break
                } else if r == Z_OK {
                    out.append(dst, count: produced)
                    // 输入耗尽且这一轮没产出 → 数据被截断，避免死循环
                    if stream.avail_in == 0 && produced == 0 { return nil }
                } else {
                    return nil
                }
            }
            return out
        }
    }

    /// v6.6.8：xz / lzma-alone / bz2 / zstd 的兼容解码已移到 NativeTar（内置原生 python3）。
    /// Apple 的 COMPRESSION_LZMA 只支持 XZ 容器中的 LZMA2，无法解 .lzma-alone，
    /// 旧 decodeLZMA 对 deb 的 data.tar.lzma 恒失败，已删除。

    private func parseTar(_ data: Data) -> [(name: String, data: Data)] {
        var out: [(String, Data)] = []
        var offset = 0
        var longName: String?
        // v6.6.7：tar header 中的 size 也是外部输入；用差值检查
        // 防止 offset + size / 对齐量溢出后构造非法 Data 区间。
        while offset >= 0, offset <= data.count, data.count - offset >= 512 {
            let blockEnd = offset + 512
            let block = safeSlice(data, offset..<blockEnd)
            guard block.count >= 512 else { break }
            if block.allSatisfy({ $0 == 0 }) { break }
            let name = String(data: safeSlice(block, 0..<100), encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
            if name.isEmpty {
                offset = blockEnd
                continue
            }
            let sizeStr = String(data: safeSlice(block, 124..<136), encoding: .ascii)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? ""
            guard let size = Int(sizeStr, radix: 8), size >= 0 else { break }
            let typeByte = safeByte(block, 156) ?? 0
            let type = typeByte == 0 ? "0" : String(UnicodeScalar(typeByte))
            let contentStart = blockEnd
            guard size <= data.count - contentStart else { break }
            let contentEnd = contentStart + size
            let padding = (512 - (size % 512)) % 512
            guard padding <= data.count - contentEnd else { break }
            let content = safeSlice(data, contentStart..<contentEnd)

            if type == "L" { // GNU longname
                longName = String(data: content, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            } else {
                let finalName = longName ?? name
                longName = nil
                if type == "0" || type == "\u{0}" || type == "" {
                    out.append((finalName, content))
                }
            }
            let aligned = contentEnd + padding
            guard aligned > offset else { break } // 防死循环
            offset = aligned
        }
        return out
    }

    /// 越界安全切片：永远不 trap（返回实际可读部分，越界处截断为空）。
    /// 同时把 Data slice 重新归一化为 0-based Data，避免后续使用
    /// `slice[0..<N]` 时因保留原始 lowerBound 而触发 SIGTRAP。
    private func safeSlice(_ data: Data, _ range: Range<Int>) -> Data {
        let lo = Swift.max(0, Swift.min(range.lowerBound, data.count))
        let hi = Swift.max(lo, Swift.min(range.upperBound, data.count))
        let lower = data.index(data.startIndex, offsetBy: lo)
        let upper = data.index(data.startIndex, offsetBy: hi)
        return Data(data[lower..<upper])
    }

    /// 越界安全单字节读取。
    private func safeByte(_ data: Data, _ i: Int) -> UInt8? {
        guard i >= 0 && i < data.count else { return nil }
        return data[i]
    }

    /// Extract a (possibly compressed) tar into dest, path-traversal safe. Returns file count.
    // v7.14.17：改为 internal——jb 工具解 deb 时复用同一条已验证的解码/落盘路径，
    // 避免另写一份压缩判定（gz/lzma/xz/bz2 各有坑）。
    func extractTar(_ raw: Data, into destURL: URL, label: String = "data.tar") throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destURL, withIntermediateDirectories: true)

        // v6.6.8：xz/lzma/bz2/zstd 直接由原生 python3 流式解到目标目录。
        // 好处：不必把整个解压后的 tar 读进内存（deb 常见 10MB→100MB+），
        // tarfile 的 filter='data' 同时承担了路径穿越防护。
        if let kind = compressionKind(raw) {
            // .lzma-alone：进程内解码，完全不依赖子进程
            if kind == "lzma", let tar = LzmaAlone.decode(raw) {
                return try writeTar(tar, into: destURL)
            }
            if kind == "xz", let tar = XZStream.decode(raw) {
                return try writeTar(tar, into: destURL)
            }
            // v7.8.0：xz / bz2 / zstd 由进程内 CPython 流式解到目录（不 spawn）
            if let n = NativeTar.extract(raw, kind: kind, into: destURL) { return n }
            throw MCPError.classified("package: cannot decompress \(label) (\(kind)) — 内置解码器不可用或压缩数据损坏",
                                      code: "UNSUPPORTED_COMPRESSION", reason: "format",
                                      nextStep: "内置解码走走进程内 CPython（bz2/lzma/zstd），不依赖 App 内置解释器二进制。"
                                          + "若报错，跑 `py command:status` 看 stdlib 是否完整（需 compression.zstd / bz2 / lzma）；"
                                          + "或在电脑端用 7-Zip / bsdtar 解包")
        }

        guard let tar = decompressTar(raw) else {
            // v6.6.10：把 App 版本一起带出来——旧文案只有一句 cannot decompress，
            // 无法区分「装的是旧版没有内置解码器」还是「解码器真失败」，
            // 会导致同一条错误被反复重试、排障靠猜。
            let ver = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
            let head = raw.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            throw MCPError.classified("package: cannot decompress \(label) — 内置解码失败 (ver=\(ver), \(raw.count)B, hdr=\(head))",
                                      code: "DECOMPRESS_FAILED", reason: "format",
                                      nextStep: "把 ver/大小/头部字节一起反馈；临时可在电脑端用 7-Zip 解包")
        }
        return try writeTar(tar, into: destURL)
    }

    // MARK: - 自检

    /// 解码器自检：用内置的固定样本跑一遍 gzip / lzma-alone / xz 与 tar 结构判定。
    ///
    /// 为什么需要：gzip 那条路径曾经因为「跳过 10 字节头还让 zlib 找 gzip 头」
    /// 而恒失败了好几个版本，每次都要靠用户上传会话日志才能发现。
    /// 这个命令让用户在设备上一条调用就能确认解码器是否真的可用。
    private func selfTest() -> [String: Any] {
        let expect = (0..<20).reduce(into: Data()) { acc, _ in
            acc.append(contentsOf: Array("Xosvi selftest payload 0123456789\n".utf8))
        }
        func check(_ name: String, _ got: Data?) -> [String: Any] {
            let ok = got == expect
            return ["case": name, "ok": ok,
                    "got_bytes": got?.count ?? -1, "want_bytes": expect.count]
        }
        var rows: [[String: Any]] = []
        rows.append(check("gzip", hexData("1f8b08000000000002030b29cacfc9f148ac50284ecd492b492d2e512848acccc94f4c513030343236313533b7b0e40a195534aa68e82a0200105aae4be4020000").flatMap { gunzip($0) }))
        rows.append(check("lzma-alone", hexData("5d00008000ffffffffffffffff002a1c89e6f15075d86c7f71c6700ad9509f27ad82d4afa7fa67e914971ea85ffee782834a06b4937a1aef80b1ba838fffffe72f0000").flatMap { LzmaAlone.decode($0) }))
        rows.append(check("xz", hexData("fd377a585a000004e6d6b4460200210116000000742fe5a3e002e300305d002a1c89e6f15075d86c7f71c6700ad9509f27ad82d4afa7fa67e914971ea85ffee782834a06b4937a1aef80b1841380000051fc81eb69373cbb00014ce405000000e78f4551b1c467fb020000000004595a").flatMap { XZStream.decode($0) }))

        // tar 结构判定：带 ustar 魔数应通过，全零块应拒绝
        var tarBlock = [UInt8](repeating: 0, count: 1024)
        for (i, c) in Array("ustar".utf8).enumerated() { tarBlock[257 + i] = c }
        rows.append(["case": "tar-detection", "ok": looksLikeTar(Data(tarBlock)) && !looksLikeTar(Data(repeating: 0, count: 512)),
                     "got_bytes": 1024, "want_bytes": 1024])

        let passed = rows.filter { ($0["ok"] as? Bool) == true }.count
        return [
            "command": "selftest",
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "passed": passed, "total": rows.count,
            "all_ok": passed == rows.count,
            "cases": rows,
            "hint": passed == rows.count
                ? "内置解码器全部正常：deb 的 gzip/lzma/xz 都能在进程内解开，不需要 python3/引擎"
                : "有解码器失败——把本结果整段反馈（含 app_version），不要重复重试解包"
        ]
    }

    private func hexData(_ hex: String) -> Data? {
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out.isEmpty ? nil : out
    }

    /// 把解压后的 tar 写进目标目录（路径穿越防护），返回写入的常规文件数。
    /// v7.15.1：归一化 tar 成员路径——只剥前导 "./" 与 "/"，拒绝含 ".." 的段。
    /// 不用 trimmingCharacters：它会把文件名首尾的 '.'/'/' 一并吃掉。
    static func normalizeMemberPath(_ name: String) -> String {
        var s = name
        while s.hasPrefix("./") { s.removeFirst(2) }
        while s.hasPrefix("/") { s.removeFirst(1) }
        guard !s.isEmpty else { return "" }
        if s.split(separator: "/").contains("..") { return "" }
        return s
    }

    private func writeTar(_ tar: Data, into destURL: URL) throws -> Int {
        let fm = FileManager.default
        var count = 0
        for (name, content) in parseTar(tar) {
            // v7.15.1：trimmingCharacters 从两端剥掉**任意** '.' 与 '/'：
            // .DS_Store → DS_Store、./usr/lib/.keep → usr/lib/.keep（点文件被改名）。
            // tar 成员只可能以 "./" 或 "/" 开头，只剥前缀即可。
            let clean = Self.normalizeMemberPath(name)
            guard !clean.isEmpty else { continue }
            let target = destURL.appendingPathComponent(clean).standardizedFileURL
            guard target.path.hasPrefix(destURL.path + "/") else { continue } // zip-slip guard
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target)
            count += 1
        }
        return count
    }
}

/// v6.6.9：进程内 .lzma-alone 解码（CLZMA / LZMA SDK，公有领域）。
///
/// 这是 deb 解包最关键的一层：实测环境里 python3 子进程会被 AMFI 拒绝
/// （posix_spawn: Bad executable），只要解压依赖子进程，`package unpack`
/// 就必然失败。C 解码器编进主二进制，任何环境下都能解 .lzma。
private enum LzmaAlone {
    static func decode(_ raw: Data, maxBytes: Int = 1 << 30) -> Data? {
        guard raw.count > 13 else { return nil }
        var outLen = 0
        var err: Int32 = 0
        let ptr = raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> UnsafeMutableRawPointer? in
            guard let base = buf.baseAddress else { return nil }
            return lzma_alone_decode(base, buf.count, &outLen, &err, maxBytes)
        }
        guard let p = ptr else {
            ShellDiag.log("package: lzma-alone 解码失败 err=\(err) in=\(raw.count)B")
            return nil
        }
        defer { lzma_shim_free(p) }
        guard outLen > 0 else { return nil }
        return Data(bytes: p, count: outLen)
    }
}

/// v6.6.9：进程内 .xz 解码（xz-embedded，0BSD）。
/// deb 的 data.tar.xz 用 LZMA2 + xz 容器 + CRC 校验，Apple Compression 解不了、
/// 为避免依赖子进程（启动开销 / 环境差异），同样内置到主进程。
private enum XZStream {
    static func decode(_ raw: Data, maxBytes: Int = 1 << 30) -> Data? {
        guard raw.count > 12 else { return nil }
        var outLen = 0
        var err: Int32 = 0
        let ptr = raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> UnsafeMutableRawPointer? in
            guard let base = buf.baseAddress else { return nil }
            return xz_stream_decode(base, buf.count, &outLen, &err, maxBytes)
        }
        guard let p = ptr else {
            ShellDiag.log("package: xz 解码失败 err=\(err) in=\(raw.count)B")
            return nil
        }
        defer { lzma_shim_free(p) }
        guard outLen > 0 else { return nil }
        return Data(bytes: p, count: outLen)
    }
}

/// v6.6.8：deb 的 data.tar 常用 .lzma-alone / .xz / .bz2 / .zstd。
/// Apple Compression 只覆盖 gzip 与「XZ 里的 LZMA2」，其余一律解不了；
/// App 内置原生 CPython 的 _lzma / _bz2 / _zstd 是静态链接的完整实现，
/// 因此压缩成员统一交给它——落临时文件后由 python3 解压（或流式解到目录）。
private enum NativeTar {
    /// v7.8.0：python3() 工厂已删除——统一走进程内解码，不依赖 bin/python3。

    /// python 侧脚本：mode=cat 解压到文件；mode=extract 直接流式解 tar 到目录。
    private static let script = """
    import sys, os, bz2, lzma, shutil, tarfile
    mode, kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

    def opener(path):
        if kind == 'xz':
            return lzma.open(path, 'rb', format=lzma.FORMAT_XZ)
        if kind == 'lzma':
            return lzma.open(path, 'rb', format=lzma.FORMAT_ALONE)
        if kind == 'bz2':
            return bz2.open(path, 'rb')
        from compression import zstd
        return zstd.open(path, 'rb')

    if mode == 'cat':
        with opener(src) as f, open(dst, 'wb') as o:
            shutil.copyfileobj(f, o, 1 << 20)
        print('OK', os.path.getsize(dst))
    elif mode == 'list':
        with opener(src) as f, open(dst, 'w') as o, tarfile.open(fileobj=f, mode='r|') as t:
            for m in t:
                if m.isfile():
                    o.write(m.name + '\\n')
        print('OK')
    else:
        n = 0
        os.makedirs(dst, exist_ok=True)
        root = os.path.realpath(dst)
        with opener(src) as f, tarfile.open(fileobj=f, mode='r|') as t:
            for m in t:
                if not m.isfile():
                    continue
                # v7.14.19：原来直接用 t.extract(m, dst) —— 单成员解包时
                # tarfile 不会还原 m.name 里的目录层级，于是 var/jb/Applications/x.app/jb-p1lot
                # 被平铺到 dst 根下（真机实测：解出的顶层全是 jb-p1lot / AppIcon.png ...，
                # 丢失 var/jb 前缀，导致按 /var/jb/... 找不到可执行文件）。
                # 这里显式拼出目标路径，并做 zip-slip 防护。
                rel = m.name.lstrip('./').lstrip('/')
                if not rel or '..' in rel.split('/'):
                    continue
                target = os.path.realpath(os.path.join(root, rel))
                if not (target == root or target.startswith(root + os.sep)):
                    continue
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with t.extractfile(m) as sf, open(target, 'wb') as out:
                    if sf is not None:
                        shutil.copyfileobj(sf, out, 1 << 20)
                try:
                    os.chmod(target, m.mode & 0o777)
                except OSError:
                    pass
                n += 1
        print('OK', n)
    """

    /// v7.8.0：不再 spawn bin/python3（统一进程内解释器，启动更快、依赖更少）。
    /// 语义与 spawn 版一致：nil = 解释器不可用/超时；0 = 成功；1 = 脚本内部失败。
    private static func run(_ raw: Data, kind: String, mode: String, dstPath: String) -> Int32? {
        let srcPath = NSTemporaryDirectory() + "/pkg_\(UUID().uuidString).in"
        defer { try? FileManager.default.removeItem(atPath: srcPath) }
        guard (try? raw.write(to: URL(fileURLWithPath: srcPath))) != nil else { return nil }
        let quoted = [mode, kind, srcPath, dstPath].map {
            "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\")
                   .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: ", ")
        let wrapped = "import sys as _s; _s.argv = [\"-c\", \(quoted)]\n" + script
        var out = ""
        do {
            let r = try PyEvalTool().invoke(["command": "eval", "code": wrapped, "limit": 200_000])
            out = (r["stdout"] as? String) ?? ""
        } catch {
            return nil
        }
        // 进程内执行拿不到退出码，改用脚本自己打的成功标记判定：
        // 三个 mode 成功时都会 print('OK' ...)，没有该行即脚本中途失败（格式不支持/解压异常）。
        let succeeded = out.split(separator: "\n").contains { $0.hasPrefix("OK") }
        return succeeded ? 0 : 1
    }

    /// 解压到内存（control.tar 与文件清单用，体积小）。
    static func decompress(_ raw: Data, kind: String) -> Data? {
        let outPath = NSTemporaryDirectory() + "/pkg_\(UUID().uuidString).out"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        guard (run(raw, kind: kind, mode: "cat", dstPath: outPath) ?? -1) == 0 else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: outPath),
              let size = attrs[.size] as? Int, size > 0, size <= 512 * 1024 * 1024 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: outPath))
    }

    /// 列出压缩 tar 里的常规文件路径（流式，不把解压结果读进内存）。
    static func list(_ raw: Data, kind: String) -> [String]? {
        let outPath = NSTemporaryDirectory() + "/pkg_\(UUID().uuidString).lst"
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        guard (run(raw, kind: kind, mode: "list", dstPath: outPath) ?? -1) == 0 else { return nil }
        guard let text = try? String(contentsOfFile: outPath, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").map(String.init)
    }

    /// 流式解压 tar 到目录，返回写入的常规文件数；失败返回 nil。
    static func extract(_ raw: Data, kind: String, into dest: URL) -> Int? {
        guard !dest.path.isEmpty else { return nil }
        guard (run(raw, kind: kind, mode: "extract", dstPath: dest.path) ?? -1) == 0 else { return nil }
        // 只统计常规文件（目录不计），用于回填 extracted_count
        var files = 0
        if let en = FileManager.default.enumerator(atPath: dest.path) {
            for case let rel as String in en {
                var isDir: ObjCBool = false
                let full = dest.appendingPathComponent(rel).path
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                    files += 1
                }
            }
        }
        return files
    }
}
