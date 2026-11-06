import Foundation
import UIKit
import ObjectiveC

/// 枚举设备已安装 App（通过 LSApplicationWorkspace 私有 API，TrollStore 环境下可用）
/// v2.9.128：AppEntry 扩展 version / execName / 类型分类（对齐 Fuck 工具箱应用管理）
final class AppCatalog {
    struct AppEntry: Identifiable, Hashable {
        let bundleId: String
        let name: String
        let path: String
        let containerPath: String?
        let version: String
        let execName: String
        /// LSApplicationProxy.applicationType："User"（App Store 装）/ "System"
        let appType: String
        /// 签名 TeamID（TrollStore 侧载为 TROLLTROLL）
        let teamID: String?
        /// 存原始proxy，直接拿系统缓存图标
        let proxy: NSObject?
        var id: String { bundleId }

        /// 用户 App（App Store / 企业签名）：LS 类型 = User
        var isUser: Bool { appType == "User" }
        /// 系统 App：路径不在第三方容器（正常已被过滤，不出现）
        var isSystem: Bool { !path.contains("/var/containers/Bundle/Application") }
        /// 巨魔 TrollStore 侧载：LS 类型 = System（系统 App 已被路径过滤，
        /// 剩余 System 即 TrollStore 装）；teamID=TROLLTROLL 兜底
        var isTroll: Bool { appType == "System" || (teamID?.uppercased().contains("TROLL") ?? false) }

        /// 直接拿系统缓存的图标，秒出，不用自己找文件
        func iconImage() -> UIImage? {
            guard let p = proxy else { return nil }
            let sel = NSSelectorFromString("iconImage")
            guard p.responds(to: sel) else { return nil }
            typealias IconFn = @convention(c) (AnyObject, Selector) -> UIImage?
            guard let m = class_getMethodImplementation(type(of: p), sel) else { return nil }
            let fn = unsafeBitCast(m, to: IconFn.self)
            return fn(p, sel)
        }

        // 只比较bundleId，proxy不参与Hashable，避免编译错误
        static func == (lhs: AppEntry, rhs: AppEntry) -> Bool {
            return lhs.bundleId == rhs.bundleId
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(bundleId)
        }
    }

    /// v2.9.135：全量枚举缓存（TTL 5 秒）——旧版每次 list() 都重新枚举 266 个 App，
    /// AI 连续调用 injection.list / app.diagnose 等会反复全量扫描，慢且耗资源。
    /// 运行中集合（runningExecNames）不缓存，每次实时查（变化频繁且查询轻量）。
    private static var cachedList: [AppEntry]?
    private static var cachedAt: Date?
    // v2.9.148：枚举锁——后台 DeviceProbe 与主线程 UI 会同时 list()，
    // LSApplicationWorkspace 私有 API 并发枚举 266 个 App 会 SIGSEGV 闪退
    private static let listLock = NSLock()

    static func list() -> [AppEntry] {
        listLock.lock()
        defer { listLock.unlock() }
        if let cached = cachedList, let at = cachedAt,
           Date().timeIntervalSince(at) < 300 {
            return cached
        }
        let fresh = enumerate()
        cachedList = fresh
        cachedAt = Date()
        // 枚举完立刻后台预加载所有图标，和TrollStore一样，不管哪个页面打开都秒显示
        preloadIcons(for: fresh)
        return fresh
    }

    /// v2.9.144：可启动判定——过滤系统服务、扩展、无界面 daemon、隐藏 App。
    /// 特征：.appex 扩展 / ViewService·UIService·Extension·XPCService / isHidden=true
    static func isLaunchable(bundleId: String, path: String, proxy: NSObject?) -> Bool {
        if path.contains(".appex") { return false }
        // v2.9.159：系统自带 App（root 分区 /System /Applications）不展示——
        // 只保留第三方容器 App（App Store / TrollStore / 企业签名）。
        // 注意 bundleURL 在部分 iOS 版本返回 /private/var/containers/...（/var 是符号链接），
        // 前缀必须兼容 /private/var 与 /var 两种形态，否则全部 App 被过滤（列表空+环境检测误报）。
        let containerPrefixes = [
            "/var/containers/Bundle/Application/",
            "/private/var/containers/Bundle/Application/"
        ]
        if !containerPrefixes.contains(where: { path.hasPrefix($0) }) { return false }
        let lower = bundleId.lowercased()
        let serviceHints = ["viewservice", "uiservice", "xpcservice", "extension",
                            "intents", "widget", "share", "watchapp", "messagesextension",
                            "remotewebsheet", "webapp"]
        for h in serviceHints where lower.contains(h) { return false }
        // 系统 UI 服务/接收器（无主界面，不可交互）
        let daemonHints = ["airdropui", "airplayreceiver", "tvremoteuiservice",
                           "amsengagementviewservice", "accountauthentication",
                           "aauiviewservice", "mediaservice", "companionlink"]
        for h in daemonHints where lower.contains(h) { return false }
        // v2.9.161：不查 isHidden——LSApplicationProxy.isHidden 返回 BOOL（标量），
        // 经 AnyObject? 函数签名桥接会读到垃圾高位指针导致闪退（TrollFools 也不查 isHidden）。
        // serviceHints/daemonHints + 容器路径过滤已覆盖绝大多数不可交互条目。
        return true
    }

    /// v2.9.160：安全 KVC——先 responds 检查再用 method 调用。
    /// 裸 value(forKey:) 对不存在的 key 会抛 NSUnknownKeyException 导致整页闪退
    /// （158 的 applicationType/teamID 读取就是此问题）。LSApplicationProxy 属性均为对象类型。
    private static func safeValue(_ obj: NSObject, _ key: String) -> Any? {
        let sel = NSSelectorFromString(key)
        guard obj.responds(to: sel),
              let m = class_getMethodImplementation(type(of: obj), sel) else { return nil }
        typealias GetFn = @convention(c) (AnyObject, Selector) -> AnyObject?
        let fn = unsafeBitCast(m, to: GetFn.self)
        return fn(obj, sel)
    }

    /// 强制刷新（安装/卸载 App 后由调用方触发，避免旧缓存误导）
    static func invalidateCache() {
        listLock.lock()
        cachedList = nil
        cachedAt = nil
        // 同时清图标缓存
        AppIconLoader.shared.clear()
        listLock.unlock()
    }

    private static func enumerate() -> [AppEntry] {
        guard let wsClass = NSClassFromString("LSApplicationWorkspace") else { return [] }
        guard let m = class_getClassMethod(wsClass, NSSelectorFromString("defaultWorkspace")) else { return [] }
        let fn = unsafeBitCast(method_getImplementation(m), to: (@convention(c) (AnyClass, Selector) -> AnyObject?).self)
        guard let ws = fn(wsClass, NSSelectorFromString("defaultWorkspace")) else { return [] }

        guard let m2 = class_getInstanceMethod(object_getClass(ws), NSSelectorFromString("allInstalledApplications")) else { return [] }
        let fn2 = unsafeBitCast(method_getImplementation(m2), to: (@convention(c) (AnyObject, Selector) -> AnyObject?).self)
        guard let apps = fn2(ws, NSSelectorFromString("allInstalledApplications")) as? [NSObject] else { return [] }

        return apps.compactMap { (p: NSObject) -> AppEntry? in
            let bid = safeValue(p, "applicationIdentifier") as? String ?? ""
            guard !bid.isEmpty else { return nil as AppEntry? }
            let path = (safeValue(p, "bundleURL") as? URL)?.path ?? ""
            let plist = path.isEmpty ? nil : NSDictionary(contentsOfFile: path + "/Info.plist")
            // v2.9.144：过滤系统服务/隐藏应用（ViewService/UIService/Extension/无界面 daemon），
            // 避免"全部"列表混入 AAUIViewService、AirDropUI 之类不可交互条目
            guard isLaunchable(bundleId: bid, path: path, proxy: p) else { return nil }
            // v2.9.158：对齐 TrollFools——LSApplicationProxy.applicationType 区分
            // "User"（App Store 装）/ "System"（TrollStore 侧载，系统 App 已被路径过滤）；
            // teamID 兜底（TrollStore 重签名为 TROLLTROLL）
            let appType: String = (safeValue(p, "applicationType") as? String)
                ?? (path.contains("/var/containers/Bundle/Application") ? "User" : "System")
            let teamID: String? = safeValue(p, "teamID") as? String
            return AppEntry(
                bundleId: bid,
                name: safeValue(p, "localizedName") as? String ?? bid,
                path: path,
                containerPath: nil,
                version: plist?["CFBundleShortVersionString"] as? String ?? "",
                execName: plist?["CFBundleExecutable"] as? String ?? "",
                appType: appType,
                teamID: teamID,
                proxy: p
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// v4.3.59：只读缓存数量（不触发 LSApplicationWorkspace 全量枚举）。
    /// 启动探测/设备报告用——避免"启动即枚举 266 个 App"污染进程 LaunchServices 状态，
    /// 导致后续分享面板（ShareSheet/OpenIn 也走 LS 枚举）空窗口/闪退。
    /// v4.3.60：按需查询单个 App 的数据容器路径（懒查，一次只查一个）。
    /// 替代枚举期全量读取 dataContainerURL——避免污染进程 LaunchServices/容器状态。
    static func lookupContainer(bundleId: String) -> String? {
        guard let cls = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationProxyForIdentifier:")
        guard let m = class_getClassMethod(cls, sel) else { return nil }
        typealias GetFn = @convention(c) (AnyClass, Selector, NSString) -> AnyObject?
        let fn = unsafeBitCast(method_getImplementation(m), to: GetFn.self)
        guard let proxy = fn(cls, sel, bundleId as NSString) as? NSObject else { return nil }
        if let url = safeValue(proxy, "dataContainerURL") as? URL {
            return url.path
        }
        return nil
    }

    /// v4.3.64：懒查某个 App 的 Bundle 安装路径（不触发全量枚举）。
    /// 用于 UpdateManager 找 trollstorehelper 等场景——对齐 TrollFools 干净枚举：
    /// 单查 LSApplicationProxy，绝不遍历 allApplications。
    static func lookupBundlePath(bundleId: String) -> String? {
        guard let cls = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationProxyForIdentifier:")
        guard let m = class_getClassMethod(cls, sel) else { return nil }
        typealias GetFn = @convention(c) (AnyClass, Selector, NSString) -> AnyObject?
        let fn = unsafeBitCast(method_getImplementation(m), to: GetFn.self)
        guard let proxy = fn(cls, sel, bundleId as NSString) as? NSObject else { return nil }
        if let url = safeValue(proxy, "bundleURL") as? URL {
            return url.path
        }
        return nil
    }

    static func cachedCount() -> Int {
        listLock.lock()
        defer { listLock.unlock() }
        return cachedList?.count ?? -1
    }

    static func find(_ bundleId: String) -> AppEntry? {
        list().first(where: { $0.bundleId == bundleId })
    }

    // v6.0.30: app图标全局内存缓存，key是bundleId，预加载后直接读，滚动不卡顿
    static let iconCache = NSCache<NSString, UIImage>()

    /// v6.0.30: 图标磁盘缓存目录——内存缓存被系统回收后，回划仍能毫秒级读盘，不会重新占位加载
    static let diskIconDir = NSHomeDirectory() + "/Documents/IconCache"

    private static func iconCachePath(bundleId: String) -> String {
        return diskIconDir + "/" + bundleId + ".png"
    }

    static func saveIconToDisk(bundleId: String, image: UIImage) {
        guard let data = image.pngData() else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: diskIconDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: iconCachePath(bundleId: bundleId)), options: .atomic)
    }

    static func diskIcon(bundleId: String) -> UIImage? {
        return UIImage(contentsOfFile: iconCachePath(bundleId: bundleId))
    }

    /// v6.0.30终版：TrollStore同款系统图标——`+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]`
    /// 这是 UIImage 的私有**类方法**（不是 LSApplicationWorkspace 的方法！v6.0.30 之前调在
    /// LSApplicationWorkspace 实例上直接返回 nil，导致全部图标变占位/空白）。
    /// 参数对齐 TrollStore/TSAppTableViewController.m：iPhone format=10、iPad format=8，scale 用屏幕倍率。
    static func systemIconImage(bundleId: String) -> UIImage? {
        guard let imgClass = NSClassFromString("UIImage") else { return nil }
        let sel = NSSelectorFromString("_applicationIconImageForBundleIdentifier:format:scale:")
        guard let m = class_getClassMethod(imgClass, sel) else { return nil }
        typealias IconFn = @convention(c) (AnyClass, Selector, NSString, NSInteger, Double) -> UIImage?
        let fn = unsafeBitCast(method_getImplementation(m), to: IconFn.self)
        let format: NSInteger = UIDevice.current.userInterfaceIdiom == .pad ? 8 : 10
        let scale = Double(UIScreen.main.scale)
        return fn(imgClass, sel, bundleId as NSString, format, scale)
    }

    /// 预热/预加载一组图标（全程后台线程）：串行系统方法（秒出）+ 并行文件读取（兜底快）。
    /// 之前文件读取是串行循环——266 个包要 5-25 秒，滚动时没覆盖到的图标只能靠 cell 现读
    /// → "划到那一栏才展示图标"；并行后 1-2 秒全部进缓存 → 回划毫秒级命中（配合磁盘缓存）。
    static func warmIcons(for apps: [AppEntry], until deadline: Date? = nil) {
        func expired() -> Bool {
            if let d = deadline { return Date() > d }
            return false
        }
        // 1) 串行系统方法（私有 API 避免并发，系统图标缓存秒出）
        for app in apps {
            if expired() { break }
            guard iconCache.object(forKey: app.bundleId as NSString) == nil else { continue }
            if let img = systemIconImage(bundleId: app.bundleId) {
                iconCache.setObject(img, forKey: app.bundleId as NSString)
                saveIconToDisk(bundleId: app.bundleId, image: img)
            }
        }
        // 2) 剩余走文件读取的并行跑（纯 IO，线程安全）
        let remain = apps.filter { iconCache.object(forKey: $0.bundleId as NSString) == nil }
        guard !remain.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: remain.count) { i in
            let app = remain[i]
            if let img = AppIconLoader.shared.icon(forPath: app.path) {
                iconCache.setObject(img, forKey: app.bundleId as NSString)
                saveIconToDisk(bundleId: app.bundleId, image: img)
            }
        }
    }

    /// 预加载所有图标（列表显示后后台继续补）——完整链路 + 并行文件读取
    static func preloadIcons(for apps: [AppEntry]) {
        DispatchQueue.global(qos: .utility).async {
            warmIcons(for: apps)
        }
    }

    /// 完整图标加载链（TrollStore 同款主流程，主线程调用）：
    /// 内存缓存 → 磁盘缓存（毫秒级）→ 系统私有方法（秒出）→ proxy.iconImage（主线程兜底）
    /// → 后台读包内图标文件（异步回填 + 落盘，cell 重试自动补上）
    static func icon(for app: AppEntry) -> UIImage? {
        if let cached = iconCache.object(forKey: app.bundleId as NSString) {
            return cached
        }
        // 磁盘缓存（防止内存被系统回收后回划重载）
        if let disk = diskIcon(bundleId: app.bundleId) {
            iconCache.setObject(disk, forKey: app.bundleId as NSString)
            return disk
        }
        // 1) TrollStore同款：+[UIImage _applicationIconImageForBundleIdentifier:format:scale:]
        var img = systemIconImage(bundleId: app.bundleId)
        // 2) proxy.iconImage 兜底（必须主线程，这里就是主线程）
        if img == nil {
            img = app.iconImage()
        }
        if let img = img {
            iconCache.setObject(img, forKey: app.bundleId as NSString)
            saveIconToDisk(bundleId: app.bundleId, image: img)
            return img
        }
        // 3) 后台读包内图标文件，异步回填缓存 + 落盘；cell 的重试（0.4s/1.5s）自动补上
        DispatchQueue.global(qos: .utility).async {
            if let fimg = AppIconLoader.shared.icon(forPath: app.path) {
                iconCache.setObject(fimg, forKey: app.bundleId as NSString)
                saveIconToDisk(bundleId: app.bundleId, image: fimg)
            }
        }
        return nil
    }

    /// 安装/删除app时清缓存
    static func invalidateIconCache() {
        iconCache.removeAllObjects()
    }

    /// v6.0.30: 自动清理3天前的临时文件，不占空间
    static func autoCleanTempFiles() {
        let fm = FileManager.default
        let tempDirs = [
            NSHomeDirectory() + "/tmp",
            XDirs.workspace
        ]
        let cutoff = Date().addingTimeInterval(-3*24*3600) // 3天前
        for dir in tempDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files {
                // 只清理临时文件：_*.py、_*.bin、troll_py_*
                guard f.hasPrefix("_") || f.hasPrefix("troll_py_") else { continue }
                let fullPath = (dir as NSString).appendingPathComponent(f)
                guard let attr = try? fm.attributesOfItem(atPath: fullPath),
                      let mtime = attr[.modificationDate] as? Date,
                      mtime < cutoff else { continue }
                try? fm.removeItem(atPath: fullPath)
            }
        }
    }

    /// v2.9.128：运行中 App 的可执行名集合（ps -ax，匹配 execName；兼容 16 字符截断）
    static func runningExecNames() -> Set<String> {
        var set = Set<String>()
        // v2.9.164：ps -ax 解析——BSD ps 在 iOS 精简版不支持 -o pid,comm（163 实测运行中仍空），
        // 回退 -ax 并取"第 4 列起第一个 token"为命令名（PID TTY TIME CMD[带参数]），
        // 命令名带路径取 lastPathComponent，兼容 (WeChat) 括号形态。
        let (_, out) = InjectionManager.shared.spawnRoot("/bin/ps", args: ["-ax"], timeout: 10)
        for line in out.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4 else { continue }
            var name = String(parts[3])
            if name.hasPrefix("(") { name.removeFirst() }
            if name.hasSuffix(")") { name.removeLast() }
            name = (name as NSString).lastPathComponent
            if !name.isEmpty { set.insert(String(name.prefix(16))) }
        }
        return set
    }
}
