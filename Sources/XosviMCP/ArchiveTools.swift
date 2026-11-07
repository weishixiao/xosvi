//
//  ArchiveTools.swift
//  Xosvi — 对齐 TrollFools preprocessAssets 的 zip/deb 解压能力
//  纯系统库实现：libz（raw deflate / gzip）+ Compression.framework（lzma）+ liblzma dlsym（xz）
//  + 手写 ZIP/ar/tar 解析
//
//  内存收敛（解包重写，改动前务必读完这段）：
//  旧实现把整个包拷成 `[UInt8](data)`、每个条目再拷一份压缩片、所有解压结果同时攒在
//  `entries` 里，`inflateRaw` 还是个解两遍的空转实现（第一遍结果直接丢掉）。
//  一个 300MB 的 ipa/deb 很容易同时持有 4~6 份整包副本，实测把 Xosvi 顶到 3.0GiB，
//  被 jetsam 以 per-process-limit 杀掉（JetsamEvent 2026-11-07 09:24:37）。
//  现在一律「读一个条目 → 流式解压 → 立刻写盘 → 释放」，常驻内存只剩 64KB 级窗口；
//  另外加了 os_proc_available_memory 水位守卫，余额不够时提前给人话报错，而不是等系统开枪。
//

import Foundation
import Darwin
import zlib
import Compression

enum ArchiveError: Error, CustomStringConvertible {
    case format(String)
    var description: String {
        switch self {
        case .format(let msg): return "ArchiveError: " + msg
        }
    }
}

// MARK: - 内存水位守卫

/// 解包前先看还有多少可用内存：javas 报告里 Xosvi 是被 per-process-limit 打死的，
/// 与其让系统静默 SIGKILL，不如在余额不足时抛一条能看懂的错。
enum MemoryBudget {
    /// 本进程还能申请到多少字节（离 dirty memory 上限的余量）。
    /// 非 App 进程或系统查不到时返回 0，调用方按「未知」处理，不阻断。
    static var available: UInt {
        #if os(iOS) || os(tvOS) || os(watchOS)
        let n = os_proc_available_memory()   // <os/proc.h>，iOS 13+
        return n > 0 ? UInt(n) : 0
        #else
        return 0
        #endif
    }

    static func require(_ need: UInt, context: String) throws {
        let left = available
        guard left > 0 else { return }   // 查不到就不拦，避免误伤
        if left < need {
            throw ArchiveError.format("内存不足：\(context) 预计需要 \(need / 1_048_576)MB，当前可用 \(left / 1_048_576)MB。请先关掉后台 App 再试，或改用更小的包。")
        }
    }
}

// MARK: - 小工具

enum FileIO {
    static func size(_ url: URL) -> Int {
        let n = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return n?.intValue ?? 0
    }

    /// 从 offset 精确读 count 字节（不够就返回 nil）——只用于头部，不用于整个文件
    static func readExactly(_ fh: FileHandle, at offset: UInt64, count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        try fh.seek(toOffset: offset)
        var buf = Data()
        buf.reserveCapacity(count)
        while buf.count < count {
            guard let c = try fh.read(upToCount: count - buf.count), !c.isEmpty else { return nil }
            buf.append(c)
        }
        return buf
    }

    /// 把 fh 的某一段原样拷到目标文件（64KB 一块，不整段进内存）
    static func copy(from fh: FileHandle, at offset: UInt64, count: Int, to dest: URL) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        try fh.seek(toOffset: offset)
        var left = count
        while left > 0 {
            guard let c = try fh.read(upToCount: min(left, 1 << 16)), !c.isEmpty else { break }
            left -= c.count
            try out.write(contentsOf: c)
        }
    }
}

private extension Data {
    // 注意：闭包必须显式标注 UnsafeRawBufferPointer——Data 还有一个
    // 已废弃的 withUnsafeBytes<Result, ContentType>((UnsafePointer<ContentType>) -> Result) 重载，
    // 不标注时 $0[off] 的两个候选下标会撞成 "ambiguous use of 'subscript(_:)'"，
    // 四连移位则会触发 "unable to type-check this expression in reasonable time"。
    func le16(_ off: Int) -> Int {
        guard off + 2 <= count else { return 0 }
        return withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Int in
            let lo = Int(b[off])
            let hi = Int(b[off + 1])
            return lo | (hi << 8)
        }
    }
    func le32(_ off: Int) -> UInt32 {
        guard off + 4 <= count else { return 0 }
        return withUnsafeBytes { (b: UnsafeRawBufferPointer) -> UInt32 in
            let b0 = UInt32(b[off])
            let b1 = UInt32(b[off + 1]) << 8
            let b2 = UInt32(b[off + 2]) << 16
            let b3 = UInt32(b[off + 3]) << 24
            return b0 | b1 | b2 | b3
        }
    }
}

// MARK: - zlib 流式解压（raw deflate / gzip）

enum ZStream {
    /// 从 src 读压缩字节，解出来的块立刻写进 out；常驻只要两个 64KB 缓冲。
    /// windowBits: 15+32 = 自动识别 gzip/zlib；-15 = raw deflate。
    static func expand(from src: FileHandle, byteCount: Int, windowBits: Int32,
                       maxOutput: Int, into out: FileHandle) throws {
        var stream = z_stream()
        let initRet = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initRet == Z_OK else { throw ArchiveError.format("inflateInit2 失败 (\(initRet))") }
        defer { inflateEnd(&stream) }

        var outBuf = [UInt8](repeating: 0, count: 1 << 16)
        var remaining = byteCount
        var total = 0
        var ended = false

        while remaining > 0 && !ended {
            guard let chunk = try src.read(upToCount: min(remaining, 1 << 16)), !chunk.isEmpty else { break }
            remaining -= chunk.count
            ended = try chunk.withUnsafeBytes { raw -> Bool in
                stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(raw.count)
                return try pump(&stream, &outBuf, out, &total, maxOutput)
            }
        }
        if !ended {
            stream.next_in = nil
            stream.avail_in = 0
            // 输入读完但还没见到 stream end：用 Z_FINISH 把尾块逼出来
            _ = try pump(&stream, &outBuf, out, &total, maxOutput, flush: Z_FINISH)
        }
    }

    private static func pump(_ stream: inout z_stream, _ outBuf: inout [UInt8],
                             _ out: FileHandle, _ total: inout Int, _ maxOutput: Int,
                             flush: Int32 = Z_NO_FLUSH) throws -> Bool {
        while true {
            let r: Int32 = outBuf.withUnsafeMutableBufferPointer { b -> Int32 in
                stream.next_out = b.baseAddress
                stream.avail_out = uInt(b.count)
                return inflate(&stream, flush)
            }
            let produced = outBuf.count - Int(stream.avail_out)
            if produced > 0 {
                total += produced
                guard total <= maxOutput else {
                    throw ArchiveError.format("解压结果超过 \(maxOutput / 1_048_576)MB 上限（包内单个文件过大或 zip bomb）")
                }
                try out.write(contentsOf: Data(bytes: outBuf, count: produced))
            }
            if r == Z_STREAM_END { return true }
            if r == Z_OK {
                if stream.avail_in == 0 && produced == 0 { return false }
                continue
            }
            if r == Z_BUF_ERROR {
                if produced == 0 { return false }
                continue
            }
            throw ArchiveError.format("inflate 失败 (\(r))")
        }
    }
}

// MARK: - Compression.framework 流式解压（raw lzma）

enum CompressionStream {
    static func expand(from src: FileHandle, byteCount: Int,
                       algorithm: compression_algorithm, into out: FileHandle) throws {
        // dummy 缓冲区：dst_ptr/src_ptr 在 init 时不能为 nil，但 dst_size/src_size 都是 0，
        // 实际不会被读写。必须用 allocate 出的指针——`&dummy` 只在调用期有效，传进结构体
        // 会报 "cannot use inout expression here"，赋值 src_ptr 时还会直接编译失败。
        let zero = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        zero.initialize(to: 0)
        defer { zero.deinitialize(count: 1); zero.deallocate() }
        var stream = compression_stream(dst_ptr: zero, dst_size: 0, src_ptr: zero, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
            throw ArchiveError.format("Compression 初始化失败")
        }
        defer { compression_stream_destroy(&stream) }

        var outBuf = [UInt8](repeating: 0, count: 262_144)
        var remaining = byteCount
        var ended = false

        while remaining > 0 && !ended {
            guard let chunk = try src.read(upToCount: min(remaining, 1 << 16)), !chunk.isEmpty else { break }
            remaining -= chunk.count
            ended = try chunk.withUnsafeBytes { raw -> Bool in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress!
                stream.src_size = raw.count
                // 后面还有输入时绝不能带 FINALIZE：Compression 会当成「输入到此为止」提前收尾
                return try pump(&stream, &outBuf, out, finalize: false)
            }
        }
        if !ended {
            stream.src_ptr = UnsafePointer(zero)
            stream.src_size = 0
            _ = try pump(&stream, &outBuf, out, finalize: true)
        }
    }

    private static func pump(_ stream: inout compression_stream, _ outBuf: inout [UInt8],
                             _ out: FileHandle, finalize: Bool) throws -> Bool {
        let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
        while true {
            outBuf.withUnsafeMutableBufferPointer { b in
                stream.dst_ptr = b.baseAddress!
                stream.dst_size = b.count
            }
            let status = compression_stream_process(&stream, flags)
            let produced = outBuf.count - stream.dst_size
            if produced > 0 { try out.write(contentsOf: Data(bytes: outBuf, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END:
                return true
            case COMPRESSION_STATUS_ERROR:
                throw ArchiveError.format("Compression 解压失败")
            default:
                if stream.src_size == 0 && produced == 0 { return false }
            }
        }
    }
}

// MARK: - liblzma 流式解压（xz 容器）

/// 名字别叫 XZStream：PackageTools.swift 里已有一个 private enum XZStream（xz-embedded 的
/// 一次性 decode），同模块顶层重名会让两者都失效（invalid redeclaration + 各处 no member 'decode'）。
enum XZFileStream {
    typealias DecoderFn = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> Int32
    typealias CodeFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias EndFn = @convention(c) (UnsafeMutableRawPointer) -> Void

    /// lzma_stream 是 C ABI 固定布局（xz 5.x 64 位）：
    ///   0:next_in 8:avail_in 16:total_in 24:next_out 32:avail_out 40:total_out 48:allocator 56:internal
    /// 用 UInt64 索引固定偏移读写（不用 Swift struct——布局不保证与 C 一致）。
    static func expand(from src: FileHandle, byteCount: Int, into out: FileHandle) throws {
        guard let handle = dlopen("/usr/lib/liblzma.dylib", RTLD_LAZY) else {
            throw ArchiveError.format("liblzma 不可用，无法解 xz 包")
        }
        defer { dlclose(handle) }
        guard let sDec = dlsym(handle, "lzma_stream_decoder"),
              let sCode = dlsym(handle, "lzma_code"),
              let sEnd = dlsym(handle, "lzma_end") else {
            throw ArchiveError.format("liblzma 符号缺失，无法解 xz 包")
        }
        let decoder = unsafeBitCast(sDec, to: DecoderFn.self)
        let code = unsafeBitCast(sCode, to: CodeFn.self)
        let end = unsafeBitCast(sEnd, to: EndFn.self)

        let raw = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 16)
        memset(raw, 0, 256)
        defer { end(raw); raw.deallocate() }
        guard decoder(raw, UInt64.max, 0x001 /* LZMA_CONCATENATED */) == 0 else {
            throw ArchiveError.format("lzma_stream_decoder 初始化失败")
        }

        var outBuf = [UInt8](repeating: 0, count: 262_144)
        var remaining = byteCount
        var ended = false

        while remaining > 0 && !ended {
            guard let chunk = try src.read(upToCount: min(remaining, 1 << 16)), !chunk.isEmpty else { break }
            remaining -= chunk.count
            ended = try chunk.withUnsafeBytes { buf -> Bool in
                let words = raw.assumingMemoryBound(to: UInt64.self)
                words[0] = UInt64(UInt(bitPattern: buf.bindMemory(to: UInt8.self).baseAddress))
                words[1] = UInt64(buf.count)
                return try pump(raw, code, &outBuf, out, action: 0 /* LZMA_RUN */)
            }
        }
        if !ended {
            let words = raw.assumingMemoryBound(to: UInt64.self)
            words[0] = 0
            words[1] = 0
            _ = try pump(raw, code, &outBuf, out, action: 3 /* LZMA_FINISH */)
        }
    }

    private static func pump(_ raw: UnsafeMutableRawPointer, _ code: CodeFn,
                             _ outBuf: inout [UInt8], _ out: FileHandle, action: Int32) throws -> Bool {
        let words = raw.assumingMemoryBound(to: UInt64.self)
        while true {
            outBuf.withUnsafeMutableBufferPointer { b in
                words[3] = UInt64(UInt(bitPattern: b.baseAddress))
                words[4] = UInt64(b.count)
            }
            let r = code(raw, action)
            let produced = outBuf.count - Int(words[4])
            if produced > 0 { try out.write(contentsOf: Data(bytes: outBuf, count: produced)) }
            if r == 1 { return true }                                   // LZMA_STREAM_END
            if r != 0 { throw ArchiveError.format("xz 解码失败 (\(r))") }  // 非 LZMA_OK
            if words[1] == 0 && produced == 0 { return false }
        }
    }
}

// MARK: - ZIP

/// ZIP 读取器（local file header 顺序遍历，支持 store/deflate）
/// 逐条目解压直接落盘，不再返回 [(name, data)]——那个 API 是 3.0GiB 的元凶。
enum ZIPReader {
    private static let sigLocal: UInt32 = 0x04034b50

    /// 解整个 zip 到目录（保持包内路径），返回解出的条目名。
    @discardableResult
    static func extractAll(from url: URL, to dir: String,
                           maxEntryBytes: Int = 256 * 1_048_576) throws -> [String] {
        try extract(from: url, to: dir, maxEntryBytes: maxEntryBytes) { _ in true }
    }

    /// 只解插件资产（.dylib / .framework / .bundle），返回落盘的资产顶层路径。
    @discardableResult
    static func extractAssets(from url: URL, to dir: String,
                              maxEntryBytes: Int = 256 * 1_048_576) throws -> [String] {
        let names = try extract(from: url, to: dir, maxEntryBytes: maxEntryBytes) { name in
            pluginAssetTop(name) != nil
        }
        var seen = Set<String>()
        var paths: [String] = []
        for n in names {
            guard let top = Self.pluginAssetTop(n), seen.insert(top).inserted else { continue }
            paths.append((dir as NSString).appendingPathComponent(top))
        }
        return paths
    }

    /// 插件资产顶层名：
    /// - 路径里有 `Foo.framework/` / `Foo.bundle/` → 资产是那个目录（取最浅一层）
    /// - 文件名本身以 .dylib 结尾 → 资产就是这个文件（保留其相对路径）
    static func pluginAssetTop(_ name: String) -> String? {
        let comps = name.split(separator: "/").map(String.init)
        guard !comps.isEmpty else { return nil }
        for (i, c) in comps.enumerated() {
            let lower = c.lowercased()
            if lower.hasSuffix(".framework") || lower.hasSuffix(".bundle") {
                return comps[0...i].joined(separator: "/")
            }
        }
        let lower = name.lowercased()
        if lower.hasSuffix(".dylib") {
            let base = comps.last ?? ""
            if !base.isEmpty && !base.hasPrefix(".") { return name }
        }
        return nil
    }

    /// 核心：顺着头读，一个条目解完立刻写盘。
    @discardableResult
    static func extract(from url: URL, to dir: String,
                        maxEntryBytes: Int = 256 * 1_048_576,
                        select: (String) -> Bool) throws -> [String] {
        try MemoryBudget.require(48 * 1_048_576, context: "解压 \(url.lastPathComponent)")
        let total = FileIO.size(url)
        guard total > 0 else { throw ArchiveError.format("空文件：\(url.path)") }
        let src = try FileHandle(forReadingFrom: url)
        defer { try? src.close() }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var offset = 0
        var written: [String] = []
        while offset + 30 <= total {
            guard let hdr = try FileIO.readExactly(src, at: UInt64(offset), count: 30) else { break }
            guard hdr.le32(0) == sigLocal else { break }   // 中央目录 / EOCD：结束
            let method = hdr.le16(8)
            let compSize = Int(hdr.le32(18))
            let nameLen = hdr.le16(26)
            let extraLen = hdr.le16(28)
            let dataStart = offset + 30 + nameLen + extraLen
            guard compSize >= 0, dataStart + compSize <= total,
                  let nameData = try FileIO.readExactly(src, at: UInt64(offset + 30), count: nameLen) else { break }
            let name = String(decoding: nameData, as: UTF8.self)
            offset = dataStart + compSize
            guard !name.isEmpty, !name.hasSuffix("/") else { continue }
            guard !name.split(separator: "/").contains("..") else { continue }   // 路径穿越
            guard select(name) else { continue }

            let destPath = (dir as NSString).appendingPathComponent(name)
            try FileManager.default.createDirectory(atPath: (destPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: destPath, contents: nil)
            let out = try FileHandle(forWritingTo: URL(fileURLWithPath: destPath))
            do {
                try src.seek(toOffset: UInt64(dataStart))
                switch method {
                case 0:
                    var left = compSize
                    while left > 0 {
                        guard let c = try src.read(upToCount: min(left, 1 << 16)), !c.isEmpty else { break }
                        left -= c.count
                        try out.write(contentsOf: c)
                    }
                case 8:
                    try ZStream.expand(from: src, byteCount: compSize, windowBits: -15,
                                       maxOutput: maxEntryBytes, into: out)
                default:
                    try? out.close()
                    try? FileManager.default.removeItem(atPath: destPath)
                    throw ArchiveError.format("zip 压缩方式 \(method) 不支持（只支持 store/deflate）：\(name)")
                }
                try? out.close()
            } catch {
                try? out.close()
                try? FileManager.default.removeItem(atPath: destPath)
                throw error
            }
            written.append(name)
        }
        return written
    }
}

// MARK: - ar（deb 外壳）

enum ArReader {
    struct Member { let name: String; let offset: Int; let size: Int }

    /// 只记偏移和长度，不把 member 内容读进内存
    static func members(_ fh: FileHandle, total: Int) throws -> [Member] {
        guard total >= 8, let magic = try FileIO.readExactly(fh, at: 0, count: 8),
              String(decoding: magic, as: UTF8.self) == "!<arch>\n" else { return [] }
        var out: [Member] = []
        var offset = 8
        while offset + 60 <= total {
            guard let hdr = try FileIO.readExactly(fh, at: UInt64(offset), count: 60) else { break }
            let name = String(decoding: hdr[0..<16], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let sizeStr = String(decoding: hdr[48..<58], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let size = Int(sizeStr) ?? 0
            let dataStart = offset + 60
            guard dataStart + size <= total else { break }
            out.append(Member(name: name, offset: dataStart, size: size))
            offset = dataStart + size + (size % 2 == 1 ? 1 : 0)
        }
        return out
    }
}

// MARK: - tar

/// 只走表头，成员内容留在文件里（用到哪段拷哪段）
enum TarReader {
    struct Entry { let name: String; let isDir: Bool; let size: Int; let dataOffset: Int }
    private static let blockSize = 512

    static func walk(_ fh: FileHandle, total: Int, _ body: (Entry) throws -> Void) throws {
        var offset = 0
        while offset + blockSize <= total {
            guard let hdr = try FileIO.readExactly(fh, at: UInt64(offset), count: blockSize) else { break }
            if hdr.allSatisfy({ $0 == 0 }) { break }
            let rawName = String(decoding: hdr[0..<100], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            let sizeStr = String(decoding: hdr[124..<136], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            let size = Int(sizeStr, radix: 8) ?? 0
            let typeflag = hdr[156]
            // ustar 长名前缀
            var name = rawName
            let prefix = String(decoding: hdr[345..<500], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            if !prefix.isEmpty && hdr[257] != 0 { name = prefix + "/" + rawName }
            let isDir = typeflag == 53 || name.hasSuffix("/")   // '5'
            let dataStart = offset + blockSize
            guard dataStart + size <= total else { break }
            let step = dataStart + size + (size % blockSize == 0 ? 0 : blockSize - (size % blockSize))
            if !name.isEmpty {
                try body(Entry(name: name, isDir: isDir, size: size, dataOffset: dataStart))
            }
            offset = step
        }
    }
}

// MARK: - deb 解包

/// deb 解包（对齐 extractDebianPackage：data.tar.gz/bz2/lzma/xz；
/// bzip2/zst/lz4 明确报错并给出重打包指引）
enum DebReader {
    static func extractDylibAndBundles(at url: URL, to targetDir: URL) throws {
        try MemoryBudget.require(64 * 1_048_576, context: "解包 \(url.lastPathComponent)")
        let total = FileIO.size(url)
        guard total > 0 else { throw ArchiveError.format("空文件：\(url.path)") }
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        let members = try ArReader.members(fh, total: total)
        guard let dataMember = members.first(where: { $0.name.hasPrefix("data.tar") }) else {
            throw ArchiveError.format("deb 里没有 data.tar.*")
        }
        let ext = (dataMember.name as NSString).pathExtension.lowercased()

        // data.tar 落到临时文件，内存里只过 64KB 窗口
        let tmpDir = NSTemporaryDirectory() + "XosviDeb-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let tarURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("data.tar")
        FileManager.default.createFile(atPath: tarURL.path, contents: nil)
        let tarOut = try FileHandle(forWritingTo: tarURL)
        try fh.seek(toOffset: UInt64(dataMember.offset))
        do {
            switch ext {
            case "gz":
                try ZStream.expand(from: fh, byteCount: dataMember.size, windowBits: 15 + 32,
                                   maxOutput: 2 * 1_024 * 1_048_576, into: tarOut)
            case "xz":
                try XZFileStream.expand(from: fh, byteCount: dataMember.size, into: tarOut)
            case "lzma":
                try CompressionStream.expand(from: fh, byteCount: dataMember.size,
                                             algorithm: COMPRESSION_LZMA, into: tarOut)
            case "bz2":
                try? tarOut.close()
                throw ArchiveError.format("data.tar.bz2 不支持（SDK 无 COMPRESSION_BZIP2），请用 gzip 打包的 deb")
            case "zst", "lz4":
                try? tarOut.close()
                throw ArchiveError.format("deb 用的是 \(dataMember.name)，iOS 侧没有 \(ext) 解压器。请用 dpkg-deb -Zgzip 重打包后再注入。")
            default:
                try? tarOut.close()
                throw ArchiveError.format("未知的 data.tar 格式：\(dataMember.name)")
            }
        } catch {
            try? tarOut.close()
            throw error
        }
        try? tarOut.close()

        let tarTotal = FileIO.size(tarURL)
        guard tarTotal > 0 else { throw ArchiveError.format("deb 解出的 data.tar 为空") }
        let tar = try FileHandle(forReadingFrom: tarURL)
        defer { try? tar.close() }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try TarReader.walk(tar, total: tarTotal) { e in
            guard !e.isDir else { return }
            if let idx = bundleComponentIndex(e.name) {
                // <...>/Foo.bundle/<rest> → targetDir/Foo.bundle/<rest>
                let comps = e.name.split(separator: "/").map(String.init)
                let rest = comps[(idx + 1)...].joined(separator: "/")
                guard !rest.isEmpty, rest != "", !comps[(idx + 1)...].contains("..") else { return }
                let dest = targetDir.appendingPathComponent(comps[idx]).appendingPathComponent(rest)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileIO.copy(from: tar, at: UInt64(e.dataOffset), count: e.size, to: dest)
            } else if e.name.lowercased().hasSuffix(".dylib") {
                let base = (e.name as NSString).lastPathComponent
                guard !base.isEmpty, !base.hasPrefix(".") else { return }
                try FileIO.copy(from: tar, at: UInt64(e.dataOffset), count: e.size,
                                to: targetDir.appendingPathComponent(base))
            }
        }
    }

    private static func bundleComponentIndex(_ name: String) -> Int? {
        let comps = name.split(separator: "/")
        for (i, c) in comps.enumerated() where c.lowercased().hasSuffix(".bundle") { return i }
        return nil
    }
}
