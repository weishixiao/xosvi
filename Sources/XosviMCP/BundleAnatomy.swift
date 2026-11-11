// BundleAnatomy.swift — .app / .appex 目录解剖（v7.18.0）
//
// 对齐 REA 的 `inspect`（Apple bundle anatomy）：给一个解包后的 App 目录，
// 一次说清「这是什么 App、能不能注、装了些什么」：
//   · Info.plist 关键字段（bundle id / 版本 / 最低系统 / SDK / 隐私用途键 / URL scheme）
//   · 主二进制（架构列表、加密状态、签名、链接的 dylib）
//   · Frameworks / PlugIns / Swift 运行时 / 资源规模 / 描述文件 / 代码签名目录
//
// 只读目录，不解包、不改文件；由 package inspect 在 path 是目录时调用。

import Foundation

enum BundleAnatomy {

    static func inspect(_ path: String) throws -> [String: Any] {
        let fm = FileManager.default
        let infoPath = path + "/Info.plist"
        guard let infoData = fm.contents(atPath: infoPath) else {
            throw MCPError.classified("目录里没有 Info.plist，不像 .app / .appex: \(path)",
                                      code: "BAD_FORMAT", reason: "format",
                                      nextStep: "传解包后的 .app 目录（package unpack 解出来的 Payload/Xxx.app）")
        }
        var info: [String: Any] = [:]
        if let plist = try? PropertyListSerialization.propertyList(from: infoData, options: [], format: nil),
           let dict = plist as? [String: Any] {
            info = dict
        }
        guard !info.isEmpty else {
            throw MCPError.classified("Info.plist 解析失败（可能是二进制 plist 之外的格式或已损坏）: \(infoPath)",
                                      code: "BAD_FORMAT", reason: "format",
                                      nextStep: "用 artifact read 打开 Info.plist 确认内容")
        }

        var out: [String: Any] = [
            "format": "app-bundle",
            "path": path,
        ]

        // MARK: Info.plist 关键字段
        var bundle: [String: Any] = [:]
        func putInfo(_ outKey: String, _ plistKey: String) {
            if let v = info[plistKey] { bundle[outKey] = v }
        }
        putInfo("identifier", "CFBundleIdentifier")
        putInfo("name", "CFBundleName")
        putInfo("display_name", "CFBundleDisplayName")
        putInfo("version", "CFBundleShortVersionString")
        putInfo("build", "CFBundleVersion")
        putInfo("executable", "CFBundleExecutable")
        putInfo("minimum_os", "MinimumOSVersion")
        putInfo("sdk", "DTSDKName")
        putInfo("platform", "DTPlatformName")
        putInfo("device_families", "UIDeviceFamily")
        putInfo("required_device_capabilities", "UIRequiredDeviceCapabilities")
        putInfo("file_type", "CFBundlePackageType")
        bundle["info_plist_bytes"] = infoData.count

        // 隐私用途键：注入/改包后最容易出问题的就是这几个
        var privacy: [String] = []
        for key in info.keys.sorted() where key.hasSuffix("UsageDescription") {
            privacy.append(key)
        }
        bundle["privacy_usage_keys"] = privacy

        // URL scheme
        var schemes: [String] = []
        if let types = info["CFBundleURLTypes"] as? [[String: Any]] {
            for t in types {
                if let list = t["CFBundleURLSchemes"] as? [String] { schemes.append(contentsOf: list) }
            }
        }
        bundle["url_schemes"] = schemes
        if let modes = info["UIBackgroundModes"] as? [String] { bundle["background_modes"] = modes }
        if let pairs = info["UISupportedInterfaceOrientations"] as? [String] {
            bundle["orientations"] = pairs
        }
        out["bundle"] = bundle

        // MARK: 主二进制
        var binary: [String: Any] = [:]
        if let exe = info["CFBundleExecutable"] as? String {
            let binPath = path + "/" + exe
            binary["path"] = binPath
            if fm.fileExists(atPath: binPath) {
                binary["size"] = sizeOf(binPath)
                if let attrs = try? fm.attributesOfItem(atPath: binPath),
                   let perms = attrs[.posixPermissions] as? NSNumber {
                    binary["mode"] = String(format: "%o", perms.intValue)
                }
                for (k, v) in archInfo(binPath) { binary[k] = v }
                if let m = try? RawMachO.load(path: binPath) {
                    var dylibs: [String] = []
                    for cmd in m.commands where isDylibCommand(cmd.cmd) {
                        if cmd.data.count >= 24 {
                            let nameOff = Int(RawMachO.u32in(cmd.data, 8, !m.isBigEndian))
                            if nameOff >= 24 && nameOff < cmd.data.count {
                                let name = RawMachO.cstr(cmd.data, nameOff, 512)
                                if !name.isEmpty { dylibs.append(name) }
                            }
                        }
                    }
                    binary["linked_dylibs_total"] = dylibs.count
                    binary["linked_dylibs_sample"] = Array(dylibs.prefix(30))
                    if let uuid = m.uuid { binary["uuid"] = uuid }
                    if let crypt = m.cryptid { binary["cryptid"] = crypt }
                    if let platform = m.buildPlatform { binary["build_platform"] = platform }
                    binary["has_code_signature"] = m.firstCommand(0x1d) != nil
                }
            } else {
                binary["error"] = "Info.plist 声明的可执行文件不存在"
            }
        } else {
            binary["error"] = "Info.plist 没有 CFBundleExecutable"
        }
        out["binary"] = binary

        // MARK: 顶层条目
        var top: [[String: Any]] = []
        if let names = try? fm.contentsOfDirectory(atPath: path) {
            for name in names.sorted() {
                var row: [String: Any] = ["name": name]
                let full = path + "/" + name
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir) {
                    row["kind"] = isDir.boolValue ? "dir" : "file"
                    if isDir.boolValue {
                        row["items"] = (try? fm.contentsOfDirectory(atPath: full).count) ?? 0
                        row["size"] = dirSize(full, limit: 20000)
                    } else {
                        row["size"] = sizeOf(full)
                    }
                }
                top.append(row)
            }
        }
        out["top_level"] = Array(top.prefix(40))
        out["top_level_total"] = top.count

        // MARK: Frameworks / PlugIns
        var frameworks: [[String: Any]] = []
        if let names = try? fm.contentsOfDirectory(atPath: path + "/Frameworks") {
            for name in names.sorted() {
                var row: [String: Any] = ["name": name]
                row["size"] = dirSize(path + "/Frameworks/" + name, limit: 20000)
                if name.hasSuffix(".framework") {
                    let inner = path + "/Frameworks/" + name + "/" + String(name.dropLast(10))
                    if fm.fileExists(atPath: inner) {
                        for (k, v) in archInfo(inner) { row[k] = v }
                    }
                }
                frameworks.append(row)
            }
        }
        out["frameworks"] = Array(frameworks.prefix(40))
        out["frameworks_total"] = frameworks.count

        var plugins: [[String: Any]] = []
        if let names = try? fm.contentsOfDirectory(atPath: path + "/PlugIns") {
            for name in names.sorted() {
                var row: [String: Any] = ["name": name]
                row["size"] = dirSize(path + "/PlugIns/" + name, limit: 20000)
                plugins.append(row)
            }
        }
        out["plugins"] = Array(plugins.prefix(20))
        out["plugins_total"] = plugins.count

        // MARK: 资源规模
        var resources: [String: Any] = [:]
        let assets = path + "/Assets.car"
        if fm.fileExists(atPath: assets) { resources["assets_car_bytes"] = sizeOf(assets) }
        let prov = path + "/embedded.mobileprovision"
        if fm.fileExists(atPath: prov) {
            resources["embedded_mobileprovision_bytes"] = sizeOf(prov)
            resources["embedded_mobileprovision"] = true
        }
        let sig = path + "/_CodeSignature/CodeResources"
        if fm.fileExists(atPath: sig) {
            resources["code_resources_bytes"] = sizeOf(sig)
            resources["signed_bundle"] = true
        }
        resources["pkg_info"] = fm.fileExists(atPath: path + "/PkgInfo")
        resources["frameworks_total"] = frameworks.count
        var swiftLibs: [String] = []
        for f in frameworks where f["name"] as? String != nil {
            if let n = f["name"] as? String, n.hasPrefix("libswift") { swiftLibs.append(n) }
        }
        resources["swift_runtime_dylibs"] = swiftLibs
        resources["bundle_bytes"] = dirSize(path, limit: 200000)
        out["resources"] = resources

        out["evidence"] = [
            "Info.plist：\(infoPath)（\(infoData.count) 字节）",
            "主二进制：\((binary["path"] as? String) ?? "(未声明)")",
            "顶层条目 \(top.count) 个，Frameworks \(frameworks.count) 个，PlugIns \(plugins.count) 个",
        ]
        out["limitations"] = [
            "只读目录，不解包 ipa；ipa 先用 package unpack 解出 Payload/Xxx.app",
            "架构/加密状态取自二进制头与 LC_ENCRYPTION_INFO；cryptid=1 时内容不可静态分析，需先砸壳",
            "entitlements 不在这里：用 macho command:entitlements 读二进制的签名权限",
            "mobileprovision 只报存在与大小，不解析 Team ID（需要 CMS/DER 解析）",
        ]
        return out
    }

    // MARK: - 二进制头

    /// LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB / LC_LOAD_UPWARD_DYLIB
    private static func isDylibCommand(_ cmd: UInt32) -> Bool {
        return cmd == 0xc || cmd == 0x80000018 || cmd == 0x8000001f || cmd == 0x80000023
    }

    /// fat / thin 的架构列表；顺带给出是否 fat、字节序与 slice 数
    static func archInfo(_ path: String) -> [String: Any] {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return [:] }
        var head = Data()
        let readData = try? fh.read(upToCount: 4096)
        if let d = readData ?? nil { head = d }
        try? fh.close()
        guard head.count >= 8 else { return [:] }
        let bytes = Array(head)
        var out: [String: Any] = [:]
        if bytes[0] == 0xca && bytes[1] == 0xfe && bytes[2] == 0xba && bytes[3] == 0xbe {
            // fat32，大端
            let count = Int(RawMachO.be32(bytes, 4))
            out["fat"] = true
            out["slices"] = count
            var arches: [String] = []
            var i = 0
            while i < count && i < 16 {
                let base = 8 + i * 20
                guard base + 20 <= bytes.count else { break }
                let cpu = RawMachO.be32(bytes, base)
                let sub = RawMachO.be32(bytes, base + 4)
                arches.append(cpuName(cpu, sub))
                i += 1
            }
            out["architectures"] = arches
            return out
        }
        if bytes[0] == 0xca && bytes[1] == 0xfe && bytes[2] == 0xba && bytes[3] == 0xbf {
            let count = Int(RawMachO.be32(bytes, 4))
            out["fat"] = true
            out["slices"] = count
            var arches: [String] = []
            var i = 0
            while i < count && i < 16 {
                let base = 8 + i * 32
                guard base + 32 <= bytes.count else { break }
                let cpu = RawMachO.be32(bytes, base)
                let sub = RawMachO.be32(bytes, base + 4)
                arches.append(cpuName(cpu, sub))
                i += 1
            }
            out["architectures"] = arches
            return out
        }
        // thin：0xfeedfacf / 0xfeedface，两种字节序
        var cpu: UInt32 = 0
        var sub: UInt32 = 0
        if bytes[0] == 0xcf && bytes[1] == 0xfa && bytes[2] == 0xed && bytes[3] == 0xfe {
            cpu = RawMachO.le32(bytes, 4)
            sub = RawMachO.le32(bytes, 8)
        } else if bytes[0] == 0xfe && bytes[1] == 0xed && bytes[2] == 0xfa && bytes[3] == 0xcf {
            cpu = RawMachO.be32(bytes, 4)
            sub = RawMachO.be32(bytes, 8)
        } else if bytes[0] == 0xce && bytes[1] == 0xfa && bytes[2] == 0xed && bytes[3] == 0xfe {
            cpu = RawMachO.le32(bytes, 4)
            sub = RawMachO.le32(bytes, 8)
        } else {
            return ["mach_o": false]
        }
        out["fat"] = false
        out["slices"] = 1
        out["architectures"] = [cpuName(cpu, sub)]
        return out
    }

    private static func cpuName(_ cpu: UInt32, _ sub: UInt32) -> String {
        switch cpu {
        case 0x0100000c:
            return sub == 2 ? "arm64e" : "arm64"
        case 0x0200000c:
            return "arm64_32"
        case 12:
            return "armv7"
        case 0x01000007:
            return "x86_64"
        default:
            return String(format: "cpu_0x%x", cpu)
        }
    }

    // MARK: - 大小

    static func sizeOf(_ path: String) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int) ?? 0
    }

    /// 目录递归大小；超过 limit 个文件就停，避免在 Resources 上扫太久
    static func dirSize(_ path: String, limit: Int) -> Int {
        let fm = FileManager.default
        var total = 0
        var count = 0
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        for case let rel as String in en {
            count += 1
            if count > limit { break }
            let full = path + "/" + rel
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                total += sizeOf(full)
            }
        }
        return total
    }
}
