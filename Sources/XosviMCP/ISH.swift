import Foundation
import ISHBridge
import ZIPFoundation
import UIKit

// MARK: - v7.6.0 Linux 沙盒（移植自 Kelivo 的 iSH 集成）
//
// 本项目原来的 iSH 是早期构建，在 arm64 上反复段错误，上一轮被整体删掉。
// 这一版把 Kelivo 的沙盒移植过来——它的桥接层带崩溃保护（KelivoISHCrashGuards），
// 在真机上能正常跑 Alpine 3.21.3。
//
// 组成：
//   · Sandbox/build_ish.sh         → 编译 libish.a / libish_emu.a / libfakefs.a
//   · Sandbox/prepare_alpine_rootfs.sh → 生成 alpine-rootfs.zip
//   · Sources/ISHBridge/           → ObjC 桥接（kernel / executor / filesystem / mounts）
//   · 本文件                        → Swift 门面：装 rootfs、boot、执行命令、挂载
//
// 运行时布局：Application Support/ish-rootfs/{data, ...}，版本变化会自动重装。

enum ISH {

    static let rootfsVersionKey = "ishRootfsVersion"
    /// 与 Sandbox/resources/VERSION 对应；改 rootfs 内容时同步 bump
    /// v9.3：r6 —— guest 源改 http（iSH TLS 挂死）、预装 python3/curl/git/sqlite3 等。
    /// 版本号一变，下一次安装的 App 首次启动会自动重装 rootfs。
    static let bundledVersion = "alpine-3.21.3-r6"

    // MARK: 路径

    static var installRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ish-rootfs", isDirectory: true)
    }
    static var dataPath: String { installRoot.appendingPathComponent("data").path }

    static var bundledZip: URL? {
        Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip")
    }

    // MARK: 状态

    static var isBooted: Bool { KelivoISHKernel.shared().isBooted }
    static var rootfsInstalled: Bool { isRootfsValid() }
    /// rootfs 占了多少空间
    static var rootfsSize: Int64 {
        guard rootfsInstalled else { return 0 }
        var total: Int64 = 0
        let fm = FileManager.default
        if let en = fm.enumerator(at: URL(fileURLWithPath: dataPath),
                                  includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en {
                let s = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                total += Int64(s)
            }
        }
        return total
    }
    static var runtimeVersion: String {
        let p = dataPath + "/etc/alpine-release"
        if let s = try? String(contentsOfFile: p, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // 兜底：读安装时写的 VERSION 资源
        if let v = try? String(contentsOf: installRoot.appendingPathComponent(".version"), encoding: .utf8) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return "未知"
    }

    // MARK: 安装 rootfs

    enum InstallError: LocalizedError {
        case noBundle
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noBundle: return "安装包里没有 alpine-rootfs.zip"
            case .failed(let m): return m
            }
        }
    }

    /// 首次启动或版本变化时解压内置 rootfs。
    ///
    /// v7.12.0（对齐 Kelivo RootfsInstaller，修 boot rc=-22）：
    ///   · zip 里的路径带 `alpine-rootfs/` 前缀，必须 strip 掉——否则 meta.db 和 data/
    ///     会被多套一层目录，内核 mount_root 找不到 meta.db → EINVAL(-22)
    ///   · 先解压到 staging，**校验 meta.db + data/bin/sh 都是常规文件**才提交，
    ///     避免半成品目录留在正式位置（下次启动会误判"已安装"）
    @discardableResult
    static func installRootfsIfNeeded(force: Bool = false) throws -> Bool {
        // v9.12：按用户要求，覆盖安装不再重装 rootfs。
        // v9.3 曾把「CFBundleVersion」纳入判定（换了 App 包就重新解压），结果每次覆盖安装
        // 版本号都变 → rootfs 连同 apk 装的 python3/curl/git/sqlite3 一起被清空，
        // 环境预设里的工具要重新下载。现在只看「rootfs 版本 + 目录是否完整」：
        // 只有内置 rootfs 内容真的变了（bump bundledVersion）或用户点「修复」才重装。
        let saved = UserDefaults.standard.string(forKey: rootfsVersionKey)
        if !force, saved == bundledVersion, isRootfsValid() { return false }
        guard let zip = bundledZip else { throw InstallError.noBundle }

        let fm = FileManager.default
        if isBooted {
            // 内核已启动无法换 rootfs（fakefs 不卸载）
            throw InstallError.failed("内核已启动，无法更换 rootfs。请完全退出 App 后重开再试。")
        }

        let parent = installRoot.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("ish-rootfs.staging-\(UUID().uuidString)")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        guard let archive = Archive(url: zip, accessMode: .read) else {
            throw InstallError.failed("打不开 alpine-rootfs.zip")
        }

        let destBase = staging.standardizedFileURL.path
        var written = 0
        var failed = 0
        // Kelivo 的 WorkspaceZipArchive 是先把条目读进内存再解压；
        // ZIPFoundation 的迭代器共享底层句柄，必须在循环外先快照，不能边迭代边 extract。
        let entries = Array(archive)
        for entry in entries {
            var rel = entry.path
            // 关键：剥掉打包前缀
            for prefix in ["alpine-rootfs/", "ish-rootfs/"] where rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count))
            }
            if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            if rel.isEmpty { continue }
            if rel.contains("..") { continue }          // 越界条目直接跳过

            let destURL = staging.appendingPathComponent(rel).standardizedFileURL
            guard destURL.path == destBase || destURL.path.hasPrefix(destBase + "/") else { continue }

            if entry.type == .directory {
                try? fm.createDirectory(at: destURL, withIntermediateDirectories: true)
                continue
            }
            let parentDir = destURL.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try? fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                failed += 1
                continue
            }
            // v10.4：符号链接必须建成链接。原来不管 entry 类型一律 data.write，
            // 于是 /bin/sh、/bin/ls、/usr/bin/python3 全成了「内容是目标路径的小文本文件」
            // （12 字节的 "/bin/busybox"），guest 里 exec 直接失败 —— Alpine 终端敲什么都没反应。
            // ZIPFoundation 的 EntryType 成员是 .symlink（不是 .symbolicLink）
            if entry.type == .symlink {
                var target = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if target.hasPrefix("alpine-rootfs/") || target.hasPrefix("ish-rootfs/") {
                    target = String(target.dropFirst("alpine-rootfs/".count))
                }
                if !target.isEmpty {
                    try? fm.removeItem(at: destURL)
                    // v10.8：链接位置要按 guest 路径算（zip 里 rel 是 data/bin/sh → /bin/sh），
                    // 否则 data/ 这一层会被算进相对目标
                    let dest = relativeLinkTarget(fromLinkAt: guestPath(fromInstallRelative: rel),
                                                  to: target) ?? target
                    if (try? fm.createSymbolicLink(atPath: destURL.path, withDestinationPath: dest)) != nil {
                        written += 1
                    } else {
                        failed += 1
                    }
                    continue
                }
            }
            if (try? data.write(to: destURL)) != nil { written += 1 } else { failed += 1 }
            // 可执行位（fakefs 主要靠 meta.db，但补上更稳）
            if rel.hasPrefix("bin/") || rel.hasPrefix("sbin/") || rel.hasPrefix("usr/bin/")
                || rel.hasPrefix("usr/sbin/") || rel.hasPrefix("usr/local/bin/") {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)
            }
        }

        // 校验：meta.db 是常规文件，busybox 是真的二进制（>100KB）
        // v10.4：data/bin/sh 现在可能是符号链接（正常形态），不能再要求 isRegularFile；
        // 反过来也要拦住「12 字节文本当 shell」的坏包。
        func isRegular(_ path: String) -> Bool {
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        func isLink(_ path: String) -> Bool {
            guard let attr = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
            let type = attr[.type] as? FileAttributeType
            return type == FileAttributeType.typeSymbolicLink
        }
        func size(_ path: String) -> Int64 {
            guard let attr = try? FileManager.default.attributesOfItem(atPath: path),
                  let n = attr[.size] as? NSNumber else { return 0 }
            return n.int64Value
        }
        let metaOK = isRegular(staging.appendingPathComponent("meta.db").path)
        let busyboxPath = staging.appendingPathComponent("data/bin/busybox").path
        let busyboxOK = isRegular(busyboxPath) && size(busyboxPath) > 100_000
        // v10.8：源 zip 的 symlink 目标不带前导 /（`bin/busybox`），解压完先按 guest 路径统一重算，
        // 否则 302 个 applet（sh/ls/apk/wget…）全是悬空链接，校验却只看到「是个链接」就放行。
        let linkRepair = repairDanglingRootfsLinks(at: staging.appendingPathComponent("data").path)
        let shPath = staging.appendingPathComponent("data/bin/sh").path
        let shOK = (isLink(shPath) && fm.fileExists(atPath: shPath))
            || (isRegular(shPath) && size(shPath) > 100_000)
        guard metaOK, busyboxOK, shOK else {
            let listing = (try? fm.contentsOfDirectory(atPath: staging.path).prefix(8).joined(separator: ", ")) ?? "?"
            try? fm.removeItem(at: staging)
            throw InstallError.failed("rootfs 解压不完整：条目 \(entries.count)，写入 \(written)，失败 \(failed)；meta.db=\(metaOK)·busybox=\(busyboxOK)·data/bin/sh=\(shOK)·链接修复 \(linkRepair.converted)；顶层：\(listing)")
        }

        // 提交：换掉旧目录
        try? fm.removeItem(at: installRoot)
        do {
            try fm.moveItem(at: staging, to: installRoot)
        } catch {
            try? fm.removeItem(at: staging)
            throw InstallError.failed("无法写入 rootfs 目录：\(error.localizedDescription)")
        }

        UserDefaults.standard.set(bundledVersion, forKey: rootfsVersionKey)
        // v9.12：构建戳判定已取消，顺手清掉旧版留下的键，免得以后误读
        UserDefaults.standard.removeObject(forKey: "ishRootfsBuildStamp")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "ishInstalledAt")
        return true
    }

    /// rootfs 是否完整可用（不只看目录存在）
    /// v10.8：正常 rootfs 的 data/bin/sh 是**符号链接**（→ busybox），v10.4 用 isRegularFile 判，
    /// 链接形态一律判坏 → 每次启动都重解压 172MB，还把 apk 装的 75 个包全清掉。
    /// 现在按「能解析到真实文件」判（fileExists 会跟随链接，悬空链接返回 false）。
    static func isRootfsValid() -> Bool {
        let fm = FileManager.default
        let meta = installRoot.appendingPathComponent("meta.db").path
        let sh = installRoot.appendingPathComponent("data/bin/sh").path
        let busybox = installRoot.appendingPathComponent("data/bin/busybox").path
        guard fm.fileExists(atPath: meta), fm.fileExists(atPath: sh) else { return false }
        // busybox 必须是真的二进制，挡住「空壳 / 文本文件」的坏解压
        let bbSize = ((try? fm.attributesOfItem(atPath: busybox))?[.size] as? NSNumber)?.int64Value ?? 0
        return bbSize > 100_000
    }

    /// 「修复」= 强制重装 rootfs
    static func repair() throws {
        _ = try installRootfsIfNeeded(force: true)
    }

    // MARK: 破损 rootfs 自愈（v10.4）

    struct LinkRepair {
        var scanned = 0
        var converted = 0
        var failed = 0
    }

    private static let linkTargetChars = Set<Character>(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/+-")

    /// guest 绝对目标 → 相对链接目标。
    /// iSH 的 fakefs 把 guest 路径拼成 host 路径再交给内核，绝对链接（/bin/busybox）会逃出 rootfs
    /// 指到 iOS 自己的根上、必然 ENOENT；相对链接两种解析方式都对。
    private static func relativeLinkTarget(fromLinkAt linkGuestPath: String, to target: String) -> String? {
        guard target.hasPrefix("/") else { return target.isEmpty ? nil : target }
        var dirComps = linkGuestPath.split(separator: "/").map(String.init)
        if !dirComps.isEmpty { dirComps.removeLast() }          // 去掉文件名，只留目录
        let tComps = target.split(separator: "/").map(String.init)
        var i = 0
        while i < dirComps.count, i < tComps.count, dirComps[i] == tComps[i] { i += 1 }
        var parts = Array(repeating: "..", count: dirComps.count - i)
        parts.append(contentsOf: tComps[i...])
        if parts.isEmpty { return nil }
        let rel = parts.joined(separator: "/")
        return rel.isEmpty ? nil : rel
    }

    /// zip 条目相对 installRoot 的路径（"data/bin/sh"）→ guest 路径（"/bin/sh"）
    private static func guestPath(fromInstallRelative rel: String) -> String {
        var r = rel
        if r.hasPrefix("data/") { r = String(r.dropFirst("data/".count)) }
        return "/" + r
    }

    /// 链接目标的落盘形态：先认「同目录相对」，再认「guest 根的绝对路径」，两者都不成立返回 nil。
    /// v10.8：源 zip 里的 symlink 目标是不带前导 / 的 `bin/busybox`，v10.4 原样写盘，
    /// 于是 `data/bin/sh -> bin/busybox` 从 /bin 解析成 /bin/bin/busybox —— 全悬空。
    private static func linkDestination(linkGuestPath: String, target: String, dataRoot: String) -> String? {
        let fm = FileManager.default
        func hostExists(_ guest: String) -> Bool {
            let rel = guest.hasPrefix("/") ? String(guest.dropFirst()) : guest
            return fm.fileExists(atPath: dataRoot + "/" + rel)
        }
        if target.hasPrefix("/") {
            guard hostExists(target) else { return nil }
            return relativeLinkTarget(fromLinkAt: linkGuestPath, to: target)
        }
        let dir = (linkGuestPath as NSString).deletingLastPathComponent
        let sibling = dir == "/" ? "/" + target : dir + "/" + target
        if hostExists(sibling) { return target }              // 真·同目录相对（usr/bin/2to3 -> 2to3-3.12）
        guard hostExists("/" + target) else { return nil }     // 否则按 guest 根解析
        return relativeLinkTarget(fromLinkAt: linkGuestPath, to: "/" + target)
    }

    /// 单个 token 的路径形状（不含空白/换行/#/:），才可能是符号链接的目标
    private static func looksLikeLinkTarget(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 255 else { return false }
        guard s.allSatisfy({ linkTargetChars.contains($0) }) else { return false }
        // 至少要有一个「不是 . 也不是 /」的字符，挡住 "."、"./"、".." 这类噪声
        return s.contains(where: { $0 != "." && $0 != "/" })
    }

    /// 内置 alpine-rootfs.zip 把符号链接打成了普通文件：`data/bin/sh` 是 12 字节文本
    /// "/bin/busybox"，`data/bin/ls`、`data/usr/bin/python3` 同理（这台机器上近 800 个）。
    /// guest 里这些路径于是都是**文本文件**，exec 必然失败 —— Alpine 终端连 sh 都起不来，
    /// 敲任何命令都报错。这里就地改回真正的符号链接：不动 apk 装的包，也不重装 rootfs。
    static func rootfsLinksLookBroken() -> Bool {
        let fm = FileManager.default
        let root = installRoot.path
        for rel in ["data/bin/sh", "data/bin/ls", "data/usr/bin/env", "data/usr/bin/python3"] {
            let path = root + "/" + rel
            guard let attr = try? fm.attributesOfItem(atPath: path) else { continue }
            let type = attr[.type] as? FileAttributeType
            if type == FileAttributeType.typeSymbolicLink { continue }     // 这条是好的
            let size = (attr[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0 && size <= 255 { return true }                     // 文本壳 = 坏的
        }
        return false
    }

    /// 扫描 data/，把「内容只是目标路径的小文本文件」还原成符号链接。
    /// 只认：单 token、无空白、目标真实存在（相对目标按同目录解析）。幂等，修完再跑就没事可做。
    @discardableResult
    static func repairBrokenRootfsLinks() -> LinkRepair {
        var st = LinkRepair()
        let fm = FileManager.default
        let dataRoot = dataPath
        guard !dataRoot.isEmpty,
              let en = fm.enumerator(at: URL(fileURLWithPath: dataRoot),
                                     includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                     options: [],
                                     errorHandler: { _, _ in true }) else { return st }
        let skipTop: Set<String> = ["proc", "sys", "dev", "run", "mounts"]
        for case let url as URL in en {
            let full = url.path
            let relPath = full.hasPrefix(dataRoot + "/") ? String(full.dropFirst(dataRoot.count + 1)) : url.lastPathComponent
            let top = relPath.split(separator: "/").first.map(String.init) ?? ""
            if skipTop.contains(top) {
                en.skipDescendants()
                continue
            }
            st.scanned += 1
            guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  v.isSymbolicLink != true,
                  v.isRegularFile == true,
                  let sz = v.fileSize, sz > 1, sz <= 255,
                  let data = try? Data(contentsOf: url),
                  data.count == Int(sz),
                  let raw = String(data: data, encoding: .utf8) else { continue }
            let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 只认「整个文件就是一个目标路径」（允许尾部换行），多行文本一律不碰
            guard raw == target || raw == target + "\n" || raw == target + "\r\n" else { continue }
            guard looksLikeLinkTarget(target) else { continue }
            // v10.8：目标按「同目录相对」或「guest 根绝对」解析，两种都不成立才跳过
            guard let linkDest = linkDestination(linkGuestPath: "/" + relPath,
                                                 target: target,
                                                 dataRoot: dataRoot) else { continue }
            do {
                try fm.removeItem(at: url)
                try fm.createSymbolicLink(atPath: full, withDestinationPath: linkDest)
                st.converted += 1
            } catch {
                // 建链接失败就把原文写回去：data/bin/sh 缺失会让 isRootfsValid() 判坏 →
                // 下次启动重装 rootfs，把 apk 装的 python3/git/npm 全清掉。宁可修不动。
                try? data.write(to: url)
                st.failed += 1
            }
        }
        return st
    }

    /// v10.8：悬空链接自愈。
    /// v10.4 把源 zip 里的相对目标（`bin/busybox`）原样写盘，`data/bin/sh`、`data/bin/ls`、
    /// `data/usr/bin/*` 等 300 多个链接从各自目录解析都是 `/bin/bin/busybox` 之类 —— 全悬空。
    /// guest 里 sh/apk/wget 于是全部 exec 失败，环境页的启动沙盒、刷新工具状态、修复、
    /// 装预设、切源一起失效。这里按 linkDestination 重算，不动 apk 装的包。
    @discardableResult
    static func repairDanglingRootfsLinks(at dataRootOverride: String? = nil) -> LinkRepair {
        var st = LinkRepair()
        let fm = FileManager.default
        let dataRoot = dataRootOverride ?? dataPath
        guard !dataRoot.isEmpty,
              let en = fm.enumerator(at: URL(fileURLWithPath: dataRoot),
                                     includingPropertiesForKeys: [.isSymbolicLinkKey],
                                     options: [],
                                     errorHandler: { _, _ in true }) else { return st }
        let skipTop: Set<String> = ["proc", "sys", "dev", "run", "mounts"]
        for case let url as URL in en {
            let full = url.path
            let relPath = full.hasPrefix(dataRoot + "/") ? String(full.dropFirst(dataRoot.count + 1)) : url.lastPathComponent
            let top = relPath.split(separator: "/").first.map(String.init) ?? ""
            if skipTop.contains(top) {
                en.skipDescendants()
                continue
            }
            st.scanned += 1
            guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  v.isSymbolicLink == true,
                  fm.fileExists(atPath: full) == false,               // 能解析的是好链接
                  let raw = try? fm.destinationOfSymbolicLink(atPath: full),
                  let dest = linkDestination(linkGuestPath: "/" + relPath,
                                             target: raw,
                                             dataRoot: dataRoot),
                  dest != raw else { continue }
            do {
                try fm.removeItem(at: full)
                try fm.createSymbolicLink(atPath: full, withDestinationPath: dest)
                st.converted += 1
            } catch {
                st.failed += 1
            }
        }
        return st
    }

    // MARK: 启动

    private static var bootLock = NSLock()
    /// 最近一次 boot/安装的错误（UI 直接显示，不再只给一个 rc 数字）
    nonisolated(unsafe) static var lastError: String?

    /// 幂等 boot；返回 0 = 成功
    @discardableResult
    static func boot() -> Int32 {
        bootLock.lock()
        defer { bootLock.unlock() }
        lastError = nil
        if isBooted { return 0 }
        // v10.8：已装的 rootfs 若只剩悬空链接（v10.4 遗留），先就地修好再判有效性，
        // 否则 isRootfsValid 判坏 → 白重装一次 172MB，还会清掉 apk 装的包
        if !isRootfsValid() {
            let pre = repairDanglingRootfsLinks()
            if pre.converted > 0 {
                Log.browser("ISH rootfs 预修复悬空链接：converted=\(pre.converted) failed=\(pre.failed)")
            }
        }
        do {
            try installRootfsIfNeeded()
        } catch {
            lastError = "rootfs 安装失败：\(error.localizedDescription)"
            Log.browser(lastError ?? "")
            return -2
        }
        try? FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true)
        // v10.4：源 rootfs.zip 把符号链接打成了文本文件 —— 不修的话 guest 里 sh/ls/python3
        // 全是 12 字节的 "/bin/busybox" 文本，exec 直接失败，Alpine 终端敲什么都不会有输出。
        if rootfsLinksLookBroken() {
            let rep = repairBrokenRootfsLinks()
            Log.browser("ISH rootfs 链接自愈：converted=\(rep.converted) scanned=\(rep.scanned) failed=\(rep.failed)")
        }
        // v10.8：v10.4 写坏的悬空链接（相对目标少了目录层）在这里修好；
        // 不修的话 guest 里 sh 都起不来，环境页所有动作都会失败。
        let dangling = repairDanglingRootfsLinks()
        if dangling.converted > 0 || dangling.failed > 0 {
            Log.browser("ISH rootfs 悬空链接自愈：converted=\(dangling.converted) failed=\(dangling.failed)")
        }
        let rc = KelivoISHKernel.shared().boot(withRootPath: installRoot.path)
        if rc != 0 {
            lastError = "内核启动返回 rc=\(rc)（rootfs: meta.db=\(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent("meta.db").path)), data=\(FileManager.default.fileExists(atPath: dataPath))）"
        }
        Log.browser("ISH boot rc=\(rc)")
        return rc
    }

    // MARK: 执行命令

    struct RunResult {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
    }

    /// 同步执行（内部用信号量等回调；调用方应在后台线程）
    static func run(_ command: String,
                    timeout: Double = 30,
                    cwd: String? = "/root",
                    env: [String: String]? = nil) -> RunResult {
        if boot() != 0 {
            return RunResult(output: "沙盒启动失败（rootfs 未就绪或内核出错）", exitCode: -2, timedOut: false)
        }
        var out = Data()
        let sem = DispatchSemaphore(value: 0)
        var result: RunResult?

        _ = KelivoISHExecutor.startCommand(
            command,
            runId: UUID().uuidString,
            binds: [],
            cwd: cwd,
            env: env,
            timeoutMs: Int(timeout * 1000),
            keepStdinOpen: false,
            started: {},
            chunk: { _, _, data in
                out.append(data)
            },
            done: { dict in
                let code = (dict["exitCode"] as? NSNumber)?.int32Value ?? -1
                let timedOut = (dict["timedOut"] as? NSNumber)?.boolValue ?? false
                result = RunResult(output: String(data: out, encoding: .utf8) ?? "",
                                   exitCode: code, timedOut: timedOut)
                sem.signal()
            })

        if sem.wait(timeout: .now() + timeout + 10) == .timedOut {
            return RunResult(output: String(data: out, encoding: .utf8) ?? "", exitCode: -1, timedOut: true)
        }
        return result ?? RunResult(output: String(data: out, encoding: .utf8) ?? "", exitCode: -1, timedOut: false)
    }

    /// v7.14.12：流式执行——每产生一块输出就回调（供环境安装的实时进度框用）。
    /// 与 run() 的区别只有一点：把 chunk 里的数据随手转给调用方，其余语义完全一致。
    static func runStreaming(_ command: String,
                             timeout: Double = 30,
                             cwd: String? = "/root",
                             env: [String: String]? = nil,
                             onChunk: @escaping (String) -> Void) -> RunResult {
        if boot() != 0 {
            let msg = "沙盒启动失败（rootfs 未就绪或内核出错）"
            onChunk(msg)
            return RunResult(output: msg, exitCode: -2, timedOut: false)
        }
        var out = Data()
        let lock = NSLock()
        let sem = DispatchSemaphore(value: 0)
        var result: RunResult?

        _ = KelivoISHExecutor.startCommand(
            command,
            runId: UUID().uuidString,
            binds: [],
            cwd: cwd,
            env: env,
            timeoutMs: Int(timeout * 1000),
            keepStdinOpen: false,
            started: {},
            chunk: { _, _, data in
                lock.lock()
                out.append(data)
                lock.unlock()
                if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    onChunk(text)
                }
            },
            done: { dict in
                let code = (dict["exitCode"] as? NSNumber)?.int32Value ?? -1
                let timedOut = (dict["timedOut"] as? NSNumber)?.boolValue ?? false
                lock.lock()
                let text = String(data: out, encoding: .utf8) ?? ""
                lock.unlock()
                result = RunResult(output: text, exitCode: code, timedOut: timedOut)
                sem.signal()
            })

        if sem.wait(timeout: .now() + timeout + 10) == .timedOut {
            lock.lock()
            let text = String(data: out, encoding: .utf8) ?? ""
            lock.unlock()
            return RunResult(output: text, exitCode: -1, timedOut: true)
        }
        return result ?? RunResult(output: "", exitCode: -1, timedOut: false)
    }

    // MARK: 挂载外部文件夹

    /// 把 iOS 上的目录挂到 guest 的 /mounts/<name>
    @discardableResult
    static func mountExternal(hostPath: String, name: String, readOnly: Bool = false) -> Int32 {
        if boot() != 0 { return -2 }
        let guest = "/mounts/\(name)"
        // 先建目录（在真实 fs 上）
        _ = run("mkdir -p '\(guest)'", timeout: 10)
        return KelivoISHKernel.shared().bindMountPath(guest, toHostPath: hostPath, readOnly: readOnly)
    }

    static func unmountExternal(name: String) -> Int32 {
        KelivoISHKernel.shared().bindUnmountPath("/mounts/\(name)")
    }

    // MARK: 镜像源（见 EnvironmentCore.swift 的 MirrorCatalog）

    // MARK: 文件系统浏览

    struct Entry {
        var name: String
        var isDir: Bool
        var size: Int64
    }

    /// 列 guest 里的目录（借 `ls` 输出，避免跨内核直接读 fakefs）
    /// 列出 guest 目录。
    /// v7.14.8：修「沙盒根目录显示空目录」——
    ///   1) 原来用 `ls -la --time-style=+`，BusyBox 的 ls **不认** --time-style，
    ///      整条命令报 unrecognized option，stderr 又被丢进 /dev/null，于是恒为空列表；
    ///   2) 解析按空白 split 后取 parts[7...]，而 BusyBox `-l` 是 "日期 时间 名字" 三段，
    ///      parts[7...] 会把时间拼进文件名（甚至吞掉名字首字母）。
    /// 现在：不传任何 BusyBox 不支持的选项；用「按行正则」解析，
    /// 以「权限段 + 链接数 + 属主 + 属组」之后的**最后一个**字段反复尝试，兼容带空格的文件名。
    static func listGuest(_ path: String) -> [Entry] {
        var p = path
        if p.isEmpty { p = "/" }
        // 带空格的路径用单引号包住（调用方可能传 /var/jb 之类的正常路径）
        let quoted = "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let r = run("ls -la \(quoted) 2>&1", timeout: 15)
        var out: [Entry] = []
        for line in r.output.components(separatedBy: "\n") {
            if line.hasPrefix("total ") || line.hasPrefix("ls:") || line.isEmpty { continue }
            let entry = parseLsLine(line)
            guard let e = entry else { continue }
            if e.name == "." || e.name == ".." { continue }
            out.append(e)
        }
        // 目录在前，然后按名字排序，保证 UI 稳定
        return out.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// 解析一行 `ls -l` 输出。字段布局：
    ///   -rw-r--r--   1 root root   640 Oct  8 19:36 name
    ///   drwxr-xr-x   2 root root  2720 Oct 25 23:30 name with space
    ///   lrwxrwxrwx   1 root root    11 Oct  8 19:36 lib -> usr/lib
    /// 前面 8 段是固定的（权限/链接数/属主/属组/大小/月/日/时间），名字从第 9 段起，
    /// 但 BusyBox 对「很久以前的文件」会把时间换成年份（仍然是单段），所以按 8 段定位即可。
    private static func parseLsLine(_ line: String) -> Entry? {
        guard let perm = line.first, "dl-bcps".contains(perm) else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9 else { return nil }
        // 权限段本身不能含空格；第 0 段就是权限
        guard parts[0].count >= 10, parts[0].first == perm else { return nil }
        let name = parts[8...].joined(separator: " ")
        guard !name.isEmpty else { return nil }
        let size = Int64(parts[4]) ?? 0
        return Entry(name: name, isDir: perm == "d", size: size)
    }

    static func readGuestFile(_ path: String, maxBytes: Int = 200_000) -> String? {
        let r = run("cat '\(path)' 2>/dev/null | head -c \(maxBytes)", timeout: 20)
        return r.output.isEmpty ? nil : r.output
    }
}

// MARK: - v7.16.2：iSH 引擎体检
//
// 把"命令卡住/起不来"拆成可判定的几层：rootfs → 内核 boot → guest 工具 → DNS → TCP。
// 每层都带真实输出与超时，避免再靠猜。

extension ISH {
    static func diagnose() -> [String: Any] {
        let fm = FileManager.default
        var out: [String: Any] = [:]
        var advice: [String] = []

        // ① rootfs
        let meta = installRoot.appendingPathComponent("meta.db").path
        let dataDir = dataPath
        let rootfs: [String: Any] = [
            "path": installRoot.path,
            "meta_db": fm.fileExists(atPath: meta),
            "data_dir": fm.fileExists(atPath: dataDir),
            "bundled_zip": bundledZip != nil,
        ]
        out["rootfs"] = rootfs
        if !fm.fileExists(atPath: meta) || !fm.fileExists(atPath: dataDir) {
            advice.append("rootfs 不完整：设置 → 环境 → 重装 rootfs（会重新解压 alpine-rootfs.zip）")
        }

        // ② boot
        let rc = boot()
        out["boot"] = ["rc": Int(rc), "error": lastError ?? ""]
        if rc != 0 {
            out["ok"] = false
            out["advice"] = advice + ["内核启动失败，后续检查已跳过。优先看 boot.error 里的 rc 与 meta.db/data 标记。"]
            return out
        }
        if let e = lastError { advice.append(e) }

        // ③ guest 环境
        func probe(_ cmd: String, _ timeout: Double) -> [String: Any] {
            let r = run(cmd, timeout: timeout, cwd: "/")
            return ["exit": Int(r.exitCode),
                    "timed_out": r.timedOut,
                    "out": String(r.output.prefix(600))]
        }
        var guest: [String: Any] = [:]
        guest["uname"] = probe("uname -a", 10)
        guest["alpine"] = probe("cat /etc/alpine-release 2>/dev/null", 8)
        guest["sh"] = probe("echo $((1+1))", 8)
        guest["apk"] = probe("command -v apk && apk --version 2>&1 | head -1", 10)
        guest["python3"] = probe("command -v python3 || echo MISSING", 8)
        guest["repositories"] = probe("cat /etc/apk/repositories 2>/dev/null", 8)
        out["guest"] = guest

        if let sh = guest["sh"] as? [String: Any], (sh["timed_out"] as? Bool) == true {
            advice.append("guest 连 `echo` 都超时 → 内核卡死，重装 rootfs 并完全退出 App 后重开")
        }
        if let apk = guest["apk"] as? [String: Any], (apk["exit"] as? Int) != 0 {
            advice.append("guest 里没有 apk → rootfs 不是 Alpine 或解包不完整")
        }

        // ④ DNS
        var network: [String: Any] = [:]
        network["resolv_conf"] = probe("cat /etc/resolv.conf 2>/dev/null", 8)
        network["dns"] = probe("nslookup mirrors.aliyun.com 2>&1 | head -6", 15)
        // ⑤ TCP（用 busybox wget，5 秒超时，能区分"DNS 通但 TCP 不通"）
        network["tcp_http"] = probe("wget -q -O /dev/null --timeout=5 http://mirrors.aliyun.com/alpine/ 2>&1 && echo TCP_OK || echo TCP_FAIL", 20)
        network["tcp_https"] = probe("wget -q -O /dev/null --timeout=5 https://mirrors.aliyun.com/alpine/ 2>&1 && echo TLS_OK || echo TLS_FAIL", 25)
        out["network"] = network

        let dnsOK: Bool = {
            if let d = network["dns"] as? [String: Any], let t = d["out"] as? String {
                return t.contains("Address") || t.contains("Name:")
            }
            return false
        }()
        if !dnsOK {
            advice.append("DNS 解析失败：检查 设置 → 环境 里的 rootfs 是否带 /etc/resolv.conf，或换一个 APK 源")
        }
        if let t = network["tcp_https"] as? [String: Any], let o = t["out"] as? String, o.contains("TLS_FAIL") {
            advice.append("DNS 可通但 HTTPS 建连失败：多见于宿主网络受限（VPN/代理），可试 http 源或换镜像")
        }

        out["ok"] = rc == 0 && (guest["apk"] as? [String: Any])?["exit"] as? Int == 0
        out["advice"] = advice.isEmpty ? ["各层检查正常"] : advice
        return out
    }
}

// MARK: - v7.14.4：Log 命名空间
// ISH 桥接里用的是 Log.browser(...)，但全仓没有定义（CI 报 cannot find 'Log' in scope）。
// 这里补一个最小实现：同时写审计日志（设置 → 日志可见）和系统日志（log_query 可抓）。
enum Log {
    static func browser(_ message: String) {
        AuditLog.shared.log("ish", detail: message)
        NSLog("[ISH] %@", message)
    }
}
