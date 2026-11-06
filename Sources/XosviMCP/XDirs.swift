import Foundation

// v9.12：数据目录独立化（二改与上游 TrollAgent 并存时不再共用同一份数据）
//
// 全部可写数据集中到 /var/mobile/Documents/wiki.qaq.xosvi 下，与「安装目录」「共享缓存」彻底分开：
//   <root>/Workspace      —— 工作区（artifact / shell / 抓包日志 / 证书 / 项目）
//   <root>/Rootd          —— root 通道落盘目录（Support/rootd/rootd.sh 用同一路径）
//   <root>/logs           —— App 级日志（hud.log / kfd_helper.log）
//   <root>/work           —— xosvid 守护的 helper 工作区（Support/xosvi/*.c 里写死的就是它）
//   <root>/Knowledge      —— 知识库 FTS 索引（kb.sqlite）
//   <root>/KnowledgeBase  —— 技能 / 开发者指令 / agent 定义
//   <root>/audit          —— 工具审计日志（tool_log.jsonl）
//   <root>/CrashLogs      —— 崩溃报告
//   <root>/persist        —— 持久化注入资产（App 重装后可从持久区恢复注入）
// App Group 也从上游的 group.com.ai.iosxcode 换成自己的 group.wiki.qaq.xosvi。
//
// 注意三条硬约束：
//   ① App 带 com.apple.private.security.no-container（Support/Xosvi.entitlements），
//      FileManager 的 .documentDirectory / .libraryDirectory 解析出来是 /var/mobile/Documents
//      与 /var/mobile/Library —— 全机共享位置，不是本 App 私有目录。凡是「本 App 自己的数据」
//      都必须走本文件里的常量，别再用 documentDirectory。
//   ② 共享位置（/var/mobile/Documents 下的同名目录）可能正被同机的上游 TrollAgent 使用，
//      迁移一律【复制】，绝不 move。
//   ③ Swift 侧改这里，C / shell 侧（Support/、tools/、vpnxcode/、tweaks/）是字面量，
//      改目录时两边要一起改，别只改一边。
enum XDirs {
    /// 共享位置：带 no-container 时 FileManager 的 .documentDirectory 就是它，不要往这里写本 App 的数据
    static let sharedDocuments = "/var/mobile/Documents"

    /// 数据根（真实文件系统路径，App 带 no-sandbox 才写得到）
    static let dataRoot = sharedDocuments + "/wiki.qaq.xosvi"
    static let workspace = dataRoot + "/Workspace"
    static let rootd = dataRoot + "/Rootd"
    static let logs = dataRoot + "/logs"
    static let work = dataRoot + "/work"
    static let tmp = dataRoot + "/tmp"
    static let knowledge = dataRoot + "/Knowledge"
    static let knowledgeBase = dataRoot + "/KnowledgeBase"
    static let audit = dataRoot + "/audit"
    static let crashLogs = dataRoot + "/CrashLogs"
    static let persist = dataRoot + "/persist"
    /// token 用量记录（单文件，不是目录）
    static let usage = dataRoot + "/xosvi_usage.jsonl"

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
        // workspace/logs 也要提前建：appex 的 appex.log / hev.log 是 fopen 直写，
        // 目录不存在就静默丢弃（旧路径能写是因为上游早把那个目录建好了）。
        for d in [dataRoot, workspace, workspace + "/logs", rootd, logs, work, tmp,
                  knowledge, knowledgeBase, audit, crashLogs, persist] {
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

        // 与上游共用的老位置：只复制，绝不搬走。
        let sharedMoves: [(String, String)] = [
            (sharedDocuments + "/Workspace", workspace),
            (sharedDocuments + "/Rootd", rootd),
            (sharedDocuments + "/Knowledge", knowledge),
            (sharedDocuments + "/KnowledgeBase", knowledgeBase),
            (sharedDocuments + "/audit", audit),
            (sharedDocuments + "/CrashLogs", crashLogs),
        ]
        for (src, dst) in sharedMoves {
            copyContents(from: src, into: dst)
        }

        // 只有「本 App 自己沙盒容器里的旧工作区」才搬走。
        // 关键：no-container 时 .documentDirectory 就是 /var/mobile/Documents，与上面那条是同一目录，
        // 那种情况必须跳过——否则会把与上游共用的工作区整个挪进新目录，等于替上游删了数据。
        let containerDocs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        if containerDocs.contains("/Containers/Data/Application/") {
            mergeContents(from: containerDocs + "/Workspace", into: workspace, removeSource: true)
        }

        // 旧散落文件收进新位置（同样只复制，上游可能还在写它自己的）。
        // appex.log 以 App Group 容器里的那份为准（vpnxcode/Sources/VpnTunnel/Provider.swift 写），
        // 这里只是把升级前留在共享 Documents 下的旧日志归档，没有生产者再写这个位置。
        copyLog(sharedDocuments + "/hud.log", to: logs + "/hud.log")
        copyLog(sharedDocuments + "/kfd_helper.log", to: logs + "/kfd_helper.log")
        copyLog(sharedDocuments + "/appex.log", to: logs + "/appex.log")
        copyLog(sharedDocuments + "/xosvi_usage.jsonl", to: usage)

        try? "1".write(toFile: dirsMarker, atomically: true, encoding: .utf8)
    }

    /// 旧 App Group 容器里的抓包库/日志/证书复制到新容器（新容器已有内容就不动，免得覆盖 appex 刚生成的数据）
    static func migrateLegacyAppGroup() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: groupMarker) else { return }
        // 新组容器都拿不到（entitlement 没生效）时不要落标记，下次启动再试
        guard let newRoot = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?.path else { return }

        try? fm.createDirectory(atPath: newRoot, withIntermediateDirectories: true)
        // 容器根总带着 container manager 的元数据 plist，判断「有没有真数据」必须把它排除掉，
        // 否则这个目录永远非空，迁移就成了死代码。
        let existing = ((try? fm.contentsOfDirectory(atPath: newRoot)) ?? []).filter {
            !$0.hasPrefix(".com.apple.mobile_container_manager") && $0 != ".DS_Store"
        }
        if existing.isEmpty, let oldRoot = legacyGroupContainer() {
            copyContents(from: oldRoot, into: newRoot)
        }
        // 复制完成之后才落标记：拿不到旧容器或中途失败的话，下次启动还能再试一次
        try? "1".write(toFile: groupMarker, atomically: true, encoding: .utf8)
    }

    /// 顶层条目逐个搬：目标已有同名就跳过；removeSource 时源目录搬空后才删掉
    private static func mergeContents(from src: String, into dst: String, removeSource: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src, isDirectory: &isDir), isDir.boolValue else { return }
        // 防止把自己搬进自己（dataRoot 之外的共享路径才允许搬，见 migrateLegacyDirs 的守卫）
        guard !dst.hasPrefix(src + "/"), src != dst else { return }
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

    /// 单个文件复制：源不存在或目标已存在就跳过
    private static func copyLog(_ src: String, to dst: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src), !fm.fileExists(atPath: dst) else { return }
        try? fm.copyItem(atPath: src, toPath: dst)
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
