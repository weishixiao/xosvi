import UIKit
import SwiftUI

// v6.9.14：桌面悬浮 HUD（可爱助手 / 桌宠）已按用户要求整块移除，
// 这里只保留 -trollish（iSH 隔离子模式）与正常 App 启动两条路径。

@main
struct XosviApp {
    static func main() {
        let args = CommandLine.arguments
        // v7.3.0：iSH 引擎与它的 -trollish 子进程模式已整体移除，只剩正常启动。
        UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(AppDelegate.self)
        )
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // v2.9.368：全局 UITextView 零内边距——TextEditor 默认有 8pt 上下内边距，
        // 导致输入框高度过大；全局清零后 TextEditor 高度紧贴文字。
        UITextView.appearance().textContainerInset = .zero

        CrashCatcher.install()  // v2.9.145c：最先注册崩溃捕获，闪退自动落盘 crash/ 可查
        CrashReporter.shared.start()   // v8.2：补 NSException 捕获 + 工具面包屑（与 CrashCatcher 互补）
        // v8.4：知识库 FTS5 索引后台构建（不阻塞启动）
        DispatchQueue.global(qos: .utility).async {
            KnowledgeIndex.shared.rebuild(packs: KnowledgeLoader.loadAll())
        }

        // v7.16.11：卸载即清空数据。
        // 必须在任何 Store 单例读 UserDefaults **之前**执行，否则内存里会先加载旧值。
        // 判定：沙盒标记消失但 Keychain 见证还在 = 卸载后重装 → 清空全部数据。
        FreshInstallReset.runIfNeeded()

        // v9.12：数据目录独立化——建 <Documents>/wiki.qaq.xosvi 全套目录并迁移旧数据（只跑一次）。
        //   必须在 Workspace.ensure() / 各 Store 首次落盘之前。
        XDirs.bootstrap()
        Workspace.ensure()
        Workspace.ensureBundledTweaks()  // v2.9.62：把内置 dylib（MemoryTweak 等）复制到工作区，AI 可直接 artifact.find 定位
        ConfigMigration.migrateIfNeeded()  // v2.9.126：配置 schema 迁移（防模块脱节：升级后旧配置结构自动搬运）
        SearchAlwaysOn.apply()   // v7.1.0：联网检索默认全开（清掉旧版"搜索·关"的残留设置）
        ToolRegistry.shared.registerBuiltinTools()
        // v2.9.145：启动探测移到后台——DeviceProbe.run() 含 spawnRoot/文件遍历，
        // 主线程同步跑会卡死启动被看门狗杀（表现为"装完打开就闪退"）
        DispatchQueue.global(qos: .userInitiated).async {
            _ = DeviceProbe.shared.run()
        }
        // v7.7.0：内置工具链自检 + 自签——解决 python3/r2/bsdtar 等 errno 85 起不来
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            ToolchainSigner.autoRepairIfNeeded()
        }
        // v7.9.8：不再启动即开定位（原来这里 start → 前台全程 GPS，耗电主因）。
        // 定位改为按需：只有 location 工具真正要坐标时才 start，拿到即停。
        // v2.9.10：网络与生命周期监控（切后台重连 / 网络恢复提示）
        AppLifecycleMonitor.shared.start()
        // fix3cy8：启动即清理残留 VPN 配置（上次异常退出/旧版关 VPN 没删配置 → 残留隧道路由
        // 会把局域网 8790 黑洞；启动时后台查一次，存在残留即删，保证远程通道可靠）
        DispatchQueue.global(qos: .utility).async {
            VpnManager.cleanupStaleConfig()
        }
        // v9.4：启动静默更新检查随「检查更新」入口一起停用（没有入口，红点也无处可看）
        // v2.9.66：启动时上报设备信息到统计后台（安装量/机型分布，需在设置中开启并配置服务器地址）
        DeviceReporter.shared.reportIfNeeded()
        // v2.9.180：远程诊断——启动即开始轮询云端指令；上报安装信息 + 上次崩溃未上报的日志。
        // 只读白名单执行，无危险操作；配置在 设置 → 远程诊断。
        RemoteAgent.shared.start()
        RemoteAgent.shared.reportInstallIfNeeded()
        RemoteAgent.shared.reportPendingCrashes()

        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIHostingController(rootView: RootView())
        window?.makeKeyAndVisible()

        // v2.9.136：全局后台常驻开关（设置页「后台常驻」）——开启后 App 启动即启动静音保活引擎，
        // 与远程控制的临时保活互补，长任务/后台等待 AI 结果时不挂起。
        if UserDefaults.standard.bool(forKey: "xosvi.keepalive_global") {
            BackgroundKeepAlive.shared.start()
        }
        // v2.9.136：BGTask 周期唤醒（双保险，系统调度允许时后台刷新）
        BackgroundKeepAlive.registerBGTask()

        return true
    }

    // v2.9.10：进后台时申请后台任务，让正在进行的请求有保活窗口（最多 3 分钟）
    func applicationDidEnterBackground(_ application: UIApplication) {
        backgroundTask = application.beginBackgroundTask(withName: "xosvi.network") {
            application.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            if self.backgroundTask != .invalid {
                application.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
        // v2.9.136：切后台提交 BGTask 周期刷新（系统调度窗口内保持存活）
        BackgroundKeepAlive.scheduleRefresh()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        if backgroundTask != .invalid {
            application.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        BackgroundKeepAlive.cancelRefresh()
    }

    // MARK: v2.9.126 —— 深链导入模型 API 配置（对齐 cc-switch DeepLinkImportDialog）
    // 链接格式: xosvi://import?baseURL=...&apiKey=...&model=...&name=...&auth=Bearer&group=默认
    // 解析后存 pendingImport 并发通知，由 SwiftUI 层弹确认页（防误导入）
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme?.lowercased() == "xosvi" else { return false }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return false }

        func value(_ k: String) -> String? {
            items.first { $0.name == k }?.value?.removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let path = comps.host ?? ""
        // AI 聊天（主界面即聊天，唤起即达）——深链 xosvi://chat 保留（外部快捷指令也会用）
        if path == "chat" {
            return true
        }
        // 代开目标 app——深链 xosvi://open?bid=… 保留（快捷指令/外部调用通用）
        // 链接格式: xosvi://open?bid=<bundleId>&url=<scheme>
        if path == "open" {
            let bid = value("bid") ?? ""
            let urlStr = value("url") ?? ""
            if !bid.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    _ = ProcessHelper.launchApp(bundleId: bid)
                }
                return true
            }
            if !urlStr.isEmpty, let u = URL(string: urlStr) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    _ = UIThreadBridge.openURL(u, timeout: 3)
                }
                return true
            }
            return false
        }
        if path == "import" {
            let baseURL = value("baseURL") ?? ""
            let apiKey = value("apiKey") ?? ""
            let model = value("model") ?? ""
            guard !baseURL.isEmpty, !model.isEmpty else { return false }
            let name = value("name") ?? model
            let auth = value("auth") ?? "Bearer"
            let group = value("group") ?? "默认"
            let temp = value("temperature").flatMap(Double.init) ?? 0.7
            let maxTokens = value("maxTokens").flatMap(Int.init) ?? 2048
            let context = value("contextTokens").flatMap(Int.init) ?? 16000
            let protocolName = value("protocol") ?? "OpenAI Chat Completions"

            let config = ModelConfig(
                id: UUID(),
                name: name,
                provider: value("provider") ?? "custom",
                apiProtocol: protocolName,
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                authMethod: auth.isEmpty ? "Bearer" : auth,
                isDefault: false,
                temperature: temp,
                maxTokens: maxTokens,
                compatLevel: 0,
                contextTokens: context,
                group: group.isEmpty ? "默认" : group
            )
            PendingImport.shared.stage(config)
            return true
        }
        return false
    }
}
