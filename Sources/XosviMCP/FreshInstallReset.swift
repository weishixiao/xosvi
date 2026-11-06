import Foundation

/// v7.16.11：卸载即清空数据。
///
/// 背景（真机复现）：TrollStore 覆盖安装 / 重装 tipa 时，iOS **保留** 沙盒 Documents 与
/// UserDefaults，于是「卸载 → 重装」后旧会话、旧 Key、旧工作区全都还在。
///
/// 做法：放一个「安装标记」，并把它和一组指纹一起记进 Keychain。
///   · Keychain 在 App 被删除后**仍然保留**（这是系统行为，正好当外部见证人）。
///   · App 启动时：标记存在 → 正常升级，什么都不做。
///   · 标记不存在且见证没了 → 真正的首次安装，写标记就行。
///   · 标记不存在但见证还在 → 判定为「卸载后重装」，清空本 App 数据。
///
/// v9.12 起标记挪进 XDirs.dataRoot。注意本 App 带 no-container，.documentDirectory 解析出来是
/// /var/mobile/Documents（全机共享），标记放那儿既脏共享目录，也会和同机的上游 TrollAgent 撞名；
/// 旧位置仍然参与判定，免得升级用户被误判成「卸载后重装」而丢掉刚迁移过来的数据。
enum FreshInstallReset {

    /// 新位置：本 App 自己的数据根
    private static var markerURL: URL {
        // dataRoot 可能刚被 wipeAllData 清掉，写之前确保存在
        try? FileManager.default.createDirectory(atPath: XDirs.dataRoot, withIntermediateDirectories: true)
        return URL(fileURLWithPath: XDirs.dataRoot).appendingPathComponent(".install-marker")
    }

    /// 旧位置（v9.11 及更早）。只读，用于兼容升级。
    private static var legacyMarkerURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".install-marker")
    }

    /// Keychain 里的见证记录（App 删除后仍保留）
    private static let keychainWitnessKey = "install_witness_v1"

    /// App 启动时调用，尽量靠前（在任何 Store 单例读 UserDefaults 之前）。
    @discardableResult
    static func runIfNeeded() -> Bool {
        let fm = FileManager.default
        let markerExists = fm.fileExists(atPath: markerURL.path)
            || fm.fileExists(atPath: legacyMarkerURL.path)
        let witness = KeychainStore.shared.string(forKey: keychainWitnessKey)

        if markerExists && witness != nil {
            // 正常升级：标记与见证都在
            return false
        }

        if !markerExists && witness == nil {
            // 真正的第一次安装（从来没装过）：不用清，直接写标记
            writeMarker()
            return false
        }

        if !markerExists && witness != nil {
            // 卸载后重装 —— 需要清空
            wipeAllData()
            writeMarker()
            return true
        }

        // marker 在但 witness 没了（Keychain 被清/换了签名证书）：保守处理，
        // 只补写见证，不删用户数据，避免误伤。
        writeMarker()
        return false
    }

    // MARK: - 内部

    private static func writeMarker() {
        let info = """
        created=\(Int(Date().timeIntervalSince1970))
        bundle=\(Bundle.main.bundleIdentifier ?? "?")
        version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        """
        let url = markerURL
        try? info.write(to: url, atomically: true, encoding: .utf8)
        _ = KeychainStore.shared.set(info, forKey: keychainWitnessKey)
        // 标记文件本身不需要备份，也不要被 iCloud 同步
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    /// 清空本 App 的全部数据。调用方已确认是「卸载后重装」。
    ///
    /// v9.12 修：以前按 .documentDirectory / .libraryDirectory / .applicationSupportDirectory
    /// 逐个清空，但本 App 带 no-container，这四个枚举值在这台机器上分别解析成
    ///   /var/mobile/Documents、/var/mobile/Library/Application Support、
    ///   /var/mobile/Library、/var/mobile/Library/Caches
    /// 也就是说一旦触发，清掉的是 mobile 用户的整个 Documents 与整个 Library（含其它 App 与系统的数据），
    /// 且不可恢复。现在只清本 App 自己的东西：数据根、真正的沙盒容器、Keychain。
    private static func wipeAllData() {
        // 1. UserDefaults（会话、模型配置、开关、引导标记……）
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        UserDefaults.standard.synchronize()

        // 2. 本 App 数据根（Workspace / Knowledge / audit / CrashLogs / persist … 全在里面）。
        //    共享位置 /var/mobile/Documents 上与本 App 无关的东西一律不碰。
        wipeContents(of: XDirs.dataRoot)

        // 3. 真正的沙盒容器（没有 no-container 的环境才会走到这里）。
        //    判据用路径里有没有 Containers/Data/Application：no-container 下 .documentDirectory
        //    是 /var/mobile/Documents，绝不能当成自家容器清掉。
        let containerDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        if containerDocs.contains("/Containers/Data/Application/") {
            wipeContents(of: containerDocs)
        }

        // 4. Keychain（API Key / token）
        KeychainStore.shared.clearAll()
    }

    /// 清空一个目录的内容（保留目录本身）。路径必须是绝对路径且不是根。
    private static func wipeContents(of dir: String) {
        let fm = FileManager.default
        guard dir.hasPrefix("/"), dir.count > 1 else { return }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        for item in items {
            try? fm.removeItem(atPath: dir + "/" + item)
        }
    }
}
