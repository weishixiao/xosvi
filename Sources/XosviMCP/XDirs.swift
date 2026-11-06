import Foundation

// v9.12：数据目录独立化（二改与上游 TrollAgent 并存时不再共用同一份数据）
//
// 全部可写数据集中到 /var/mobile/Documents/wiki.qaq.xosvi 下，与「安装目录」「共享缓存」彻底分开：
//   <root>/Workspace  —— 工作区（artifact / shell / 抓包日志 / 证书 / 项目）
//   <root>/Rootd      —— root 通道落盘目录（Support/rootd/rootd.sh 用同一路径）
//   <root>/logs       —— App 级日志（hud.log / kfd_helper.log / appex.log）
//   <root>/work       —— xosvid 守护的 helper 工作区（Support/xosvi/*.c 里写死的就是它）
// App Group 也从上游的 group.com.ai.iosxcode 换成自己的 group.wiki.qaq.xosvi。
//
// 注意：Swift 侧改这里，C / shell 侧（Support/、tools/、vpnxcode/、tweaks/）是字面量，
// 改目录时两边要一起改，别只改一边。
enum XDirs {
    /// 数据根（真实文件系统路径，App 带 no-sandbox 才写得到）
    static let dataRoot = "/var/mobile/Documents/wiki.qaq.xosvi"
    static let workspace = dataRoot + "/Workspace"
    static let rootd = dataRoot + "/Rootd"
    static let logs = dataRoot + "/logs"
    static let work = dataRoot + "/work"

    /// 主 App 与 VpnTunnel appex 共享的 App Group（两侧 entitlements 必须一致）
    static let appGroupID = "group.wiki.qaq.xosvi"
    /// 上游沿用下来的旧 App Group，仅用于一次性迁移
    static let legacyAppGroupID = "group.com.ai.iosxcode"

    /// 启动时调用：建目录 → 迁移旧数据（都只做一次）
    static func bootstrap() {
        ensure()
        migrateLegacyDirs()
        migrateLegacyAppGroup()
    }

    static func ensure() {
        let fm = FileManager.default
        for d in [dataRoot, workspace, rootd, logs, work] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
    }

    // MARK: - 一次性迁移
    //
    // 迁移的底线是「绝不破坏旧数据」：同机可能还装着上游 TrollAgent，
    // /var/mobile/Documents 下那些目录是两边共用的老位置，搬走就等于把上游搞坏，
    // 所以共享位置一律【复制】，只有本 App 自己沙盒容器里的旧工作区（只可能是我们的）才【搬走】。

    private static let dirsMarker = dataRoot + "/.migrated-v2"
    private static let groupMarker = dataRoot + "/.migrated-appgroup"

    static func migrateLegacyDirs() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dirsMarker) else { return }

        // 旧工作区之一：本 App 沙盒容器的 Documents/Workspace（旧 Workspace.root）——独属我们，搬走。
        let containerDocs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mergeContents(from: containerDocs.appendingPathComponent("Workspace", isDirectory: true).path,
                      into: workspace, removeSource: true)
        // 旧工作区之二：/var/mobile/Documents/Workspace——与上游共用，只复制。
        copyContents(from: "/var/mobile/Documents/Workspace", into: workspace)
        copyContents(from: "/var/mobile/Documents/Rootd", into: rootd)

        // 旧散落日志收进 logs/（同样只复制，上游可能还在写它自己的）
        for name in ["hud.log", "kfd_helper.log", "appex.log"] {
            let src = "/var/mobile/Documents/" + name
            let dst = logs + "/" + name
            if fm.fileExists(atPath: src) && !fm.fileExists(atPath: dst) {
                try? fm.copyItem(atPath: src, toPath: dst)
            }
        }

        try? "1".write(toFile: dirsMarker, atomically: true, encoding: .utf8)
    }

    /// 旧 App Group 容器里的抓包库/日志/证书复制到新容器（新容器已有内容就不动，免得覆盖 appex 刚生成的数据）
    static func migrateLegacyAppGroup() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: groupMarker) else { return }
        // 新组容器都拿不到（entitlement 没生效）时不要落标记，下次启动再试
        guard let newRoot = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?.path else { return }
        try? "1".write(toFile: groupMarker, atomically: true, encoding: .utf8)

        try? fm.createDirectory(atPath: newRoot, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: newRoot)) ?? []
        guard existing.isEmpty else { return }
        guard let oldRoot = legacyGroupContainer() else { return }
        copyContents(from: oldRoot, into: newRoot)
    }

    /// 顶层条目逐个搬：目标已有同名就跳过；removeSource 时源目录搬空后才删掉
    private static func mergeContents(from src: String, into dst: String, removeSource: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else { return }
        try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(atPath: src) else { return }
        for name in items {
            let d = dst + "/" + name
            if fm.fileExists(atPath: d) { continue }
            if removeSource {
                try? fm.moveItem(atPath: src + "/" + name, toPath: d)
            } else {
                try? fm.copyItem(atPath: src + "/" + name, toPath: d)
            }
        }
        guard removeSource else { return }
        if let rest = try? fm.contentsOfDirectory(atPath: src), rest.isEmpty {
            try? fm.removeItem(atPath: src)
        }
    }

    /// 顶层条目逐个复制：目标已有同名就跳过，源目录原封不动
    private static func copyContents(from src: String, into dst: String) {
        mergeContents(from: src, into: dst, removeSource: false)
    }

    /// 按 container-manager 的元数据找出旧 App Group 的容器目录。
    /// App 带 no-sandbox，可以直接读 Shared/AppGroup；只是改完 entitlement 后 containerURL 已经查不到旧组了。
    private static func legacyGroupContainer() -> String? {
        let fm = FileManager.default
        let base = "/var/mobile/Containers/Shared/AppGroup"
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }
        for d in dirs {
            let meta = base + "/" + d + "/.com.apple.mobile_container_manager.metadata.plist"
            guard let data = fm.contents(atPath: meta),
                  let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  (plist["MCMMetadataIdentifier"] as? String) == legacyAppGroupID else { continue }
            return base + "/" + d
        }
        return nil
    }
}
