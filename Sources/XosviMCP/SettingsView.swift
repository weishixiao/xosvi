import SwiftUI
import UIKit

// MARK: - 设置项数据（列表/卡片双视图共用，永不脱节）

struct SettingsItem: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var destination: AnyView?
    var action: (() -> Void)?
    var isOn: (() -> Bool)?
    var onToggle: ((Bool) -> Void)?
    /// v4.3.39：行尾红点（新版提醒等），闭包返回是否显示
    var redDot: (() -> Bool)?
}

struct SettingsGroup {
    let header: String
    var items: [SettingsItem]
}

struct SettingsView: View {
    @Environment(\.presentationMode) var presentationMode
    // v2.9.72：开发者模式开关，开启后显示高级选项
    // v6.0.28：默认开启，去掉开关UI
    @AppStorage("developer_mode") private var developerMode = true
    // v2.9.76：语言选择弹窗
    @State private var showLanguagePicker = false
    // v2.9.84：聊天框「在设置中管理模型」→ 打开设置并自动跳到模型 API 页
    @State private var jumpToModels = false
    // v4.4.16：底部"指令"胶囊 → 打开设置并自动跳到系统指令(SystemPromptsView)页
    @State private var jumpToSystemPrompts = false
    // v3.3.2：抓包 VPN 开关失败提示
    @State private var vpnToggleError = ""
    // v9.4：更新管理器的订阅与镜像编辑器随「检查更新」入口删除
    var body: some View {
        // v2.9.247：GeometryReader 拿真实全屏尺寸——fullScreenCover+NavigationStack 组合下 List 高度被解析为内容高度(内容不满一屏时列表只占上半屏、下半空白),外层 frame 也无效;改用几何尺寸显式强制 List 与 NavigationStack 铺满全屏,所有机型一致
        GeometryReader { geo in
            CompatNav {
                listBody
                    .frame(minHeight: geo.size.height)
                    .navigationTitle(L10n.t("settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        // v8.4：左上角返回键（chevron 图标，对齐系统返回样式）——
                        // 旧"完成"文字按钮换成返回箭头；点击仍=关闭设置回聊天
                        // （设置页是全屏 cover 呈现，返回键即关闭入口；列表左滑删除不受影响）
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.primary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(Text("返回"))
                    }
                    // v2.9.245：移除右上角卡片/列表切换按钮——卡片模式在部分机型(iPhone XS等小屏)渲染不稳定(图标/文字显示不全/内容裁剪),统一为列表模式
                }
                // v2.9.234：跳转模型API页——iOS16 navigationDestination(修被弹回), iOS15 NavigationLink兜底
                // v4.4.16：追加"跳系统指令"跳转(底部"指令"胶囊)——与模型跳转对称的 iOS16/iOS15 双兜底
                .background(
                    Group {
                        if #available(iOS 16.0, *) {
                            EmptyView()
                        } else {
                            NavigationLink(destination: ModelsView(), isActive: $jumpToModels) { EmptyView() }.hidden()
                            NavigationLink(destination: SystemPromptsView(), isActive: $jumpToSystemPrompts) { EmptyView() }.hidden()
                        }
                    }
                )
            if #available(iOS 16.0, *) {
                Color.clear.navigationDestination(isPresented: $jumpToModels) { ModelsView() }
                Color.clear.navigationDestination(isPresented: $jumpToSystemPrompts) { SystemPromptsView() }
            }
        }
            .frame(width: geo.size.width, height: geo.size.height)   // NavigationStack 显式全屏
        }
        .navigationViewStyle(.stack)
        .onAppear {
            triggerProbe()   // v2.9.18：进入设置页自动探测一次，更新环境状态色
        }
        .onAppear {
            if AppUIState.shared.settingsJumpToModels {
                AppUIState.shared.settingsJumpToModels = false
                jumpToModels = true
            }
            // v4.4.16：底部"指令"胶囊 → 跳到系统指令页
            // v4.4.21：延迟一帧触发——iOS16 navigationDestination(isPresented:) 在设置页首帧出现时目标未注册,
            // 立即设 true 会被 SwiftUI 吞掉不跳(用户实测'点指令没真正跳到系统指令页'); 延迟到下一帧目标注册后再跳
            if AppUIState.shared.settingsJumpToSystemPrompts {
                AppUIState.shared.settingsJumpToSystemPrompts = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    jumpToSystemPrompts = true
                }
            }
        }
    }

    // MARK: - 数据源（两种视图共用）

    private func makeGroups() -> [SettingsGroup] {
        var groups: [SettingsGroup] = []

        // 模型
        groups.append(SettingsGroup(header: L10n.t("sec_models"), items: [
            // v7.13.0：恢复原来的模型 API 页（LiteLLM 网关那套已撤回）
            SettingsItem(title: L10n.t("row_model_api"),
                         subtitle: "\(ModelStore.shared.configs.count) 个 · \(modelProviderName())",
                         icon: "rectangle.stack.badge.person.crop", color: .blue,
                         destination: AnyView(ModelsView())),
            // v6.9.10：删除"系统指令"设置入口——模式已由 AI 自动路由（见 SystemPrompts.routerPrompt）。
            // 仅移除入口，SystemPromptsView / 7 个模式的提示词内容全部保留，
            // 需要恢复时把本段加回即可。
            SettingsItem(title: L10n.t("row_dev_instructions"),
                         subtitle: devInstructionsSubtitle(),
                         icon: "doc.text.magnifyingglass", color: .orange,
                         destination: AnyView(DeveloperInstructionsView()))
        ]))

        // 网络与抓包（v3.3.1：独立分组，不依赖开发者模式——普通用户也能直接看到抓包入口）
        groups.append(SettingsGroup(header: "网络与抓包", items: [
            // v3.3.2：开关 + 点击进详情（Toggle 一键开/关，NavigationLink 进详情页）
            SettingsItem(title: "抓包 VPN",
                         subtitle: vpnActiveSubtitle(),
                         icon: "antenna.radiowaves.left.and.right", color: .tmCyan,
                         destination: AnyView(VpnCaptureView()),
                         isOn: { VpnManager.shared.vpnActive },
                         onToggle: { on in
                             VpnManager.shared.toggleVpn { err in
                                 if let e = err {
                                     DispatchQueue.main.async {
                                         vpnToggleError = e
                                     }
                                 }
                             }
                         })
            // v8.2：「网络兼容日志」入口已删（NetworkDebugView 整个移除）。
            // NetworkLog 记录层保留（OpenAIClient 降级链路仍在写，lastCompatNote 副标题仍用）。
        ]))

        // v7.6.5：线上编译 / GitHub 账号 / 下载管理已按用户要求整体移除

        // 环境（v6.6.19：环境变量）
        groups.append(SettingsGroup(header: "环境", items: [
            // v7.16.2：shell.exec 是否把需要完整 Linux 的命令交给 iSH 引擎。
            // 关闭后只跑原生命令（ls/find/plutil/sqlite3/bsdtar），apk/git 之类会明确报错。
            SettingsItem(title: "使用 iSH 引擎",
                         subtitle: "apk / git / 完整 Linux 工具链（关闭则仅原生）",
                         icon: "terminal", color: .gray,
                         isOn: {
                             UserDefaults.standard.object(forKey: "shell_use_ish") == nil
                                 ? true : UserDefaults.standard.bool(forKey: "shell_use_ish")
                         },
                         onToggle: { UserDefaults.standard.set($0, forKey: "shell_use_ish") }),
            SettingsItem(title: "环境变量",
                         subtitle: "注入子进程与进程内 Python · \(EnvVars.current().count) 项",
                         icon: "key.fill", color: .gray,
                         destination: AnyView(EnvVarsView()))
        ]))

        // v7.10.0：远程控制 + AI 控制中心已按用户要求整块删除（含源码）
        // 开发者（v6.0.28：默认开启，去掉开关）
        var devItems: [SettingsItem] = [
                // v4.3.53：图标主题功能彻底移除（含 Resources 残留图标文件）。
                // 侧载环境下动态图标注册可能干扰 MobileIcons 图标缓存（分享面板崩溃嫌疑项）。
                // v7.16.11：按用户要求删除「工具权限」入口。
                // 实测它只是工具清单展示（开关早已移除，isEnabled 由白名单决定），
                // 对用户没有任何可操作项，属纯信息噪音。
                // v8.4：「会话记录」入口已删（ConversationTranscriptView 整个移除——
                // 聊天页本身可见全部历史，独立存档页冗余）
                SettingsItem(title: "远程访问",
                             subtitle: "SSH 连接远程服务器 · 远程终端被控制",
                             icon: "terminal.fill", color: .teal,
                             destination: AnyView(RemoteAccessView())),
                // v7.16.11：按用户要求删除「构建与注入」入口（JBPlotSettingsView 一并删除）
                // v7.5.0：内置浏览器已删除；改为「联网搜索」（多服务商 + 全文读取）
                SettingsItem(title: "联网搜索",
                             subtitle: "服务商 / 读取方式 / 测连 / 超时",
                             icon: "magnifyingglass", color: .gray,
                             destination: AnyView(SearchServicesView())),
                // v8.4：知识库——FTS5 索引管理 + 试检索
                SettingsItem(title: "知识库",
                             subtitle: "内置知识包 · FTS5 检索 · 试查询",
                             icon: "books.vertical", color: .tmCyan,
                             destination: AnyView(KnowledgeSettingsView())),
                // v7.11.0：控制台——把 control 的 10 个子命令做成可点操作
                SettingsItem(title: "控制台",
                             subtitle: "注入 · UI 树 · 截图 · 点按 · 滑动 · 输入 · 按键",
                             icon: "slider.horizontal.3", color: .gray,
                             destination: AnyView(ControlConsoleView())),
                // v9.4：MCP 服务入口（原有 MCPGatewayServer 一直没有界面，用户以为本机没有 MCP）
                SettingsItem(title: "MCP 服务",
                             subtitle: "外部客户端连本机工具 · JSON-RPC · 令牌",
                             icon: "point.3.connected.trianglepath.dotted", color: .gray,
                             destination: AnyView(MCPServerView())),
                // v9.4：按用户要求删除「深度思考」入口（ReasoningSettingsView 源文件一并删除）——
                // 思考改为内置自动：按请求内容判强度（ReasoningSettings.autoLevel），用户无需配置。
                // 方言/采样策略等 ReasoningSpec 兼容层仍在 ReasoningDialects.swift 里，供协议层使用。
                // v7.6.0：环境（移植 Kelivo 的 Environment 页：环境预设 / 镜像 / 挂载 / 修复）
                SettingsItem(title: "环境",
                             subtitle: "Python · Node · Git · 镜像 · 挂载",
                             icon: "cube.box", color: .gray,
                             destination: AnyView(EnvironmentView())),
                // v7.5.0：工作区（移植 Kelivo workspace）
                SettingsItem(title: "工作区",
                             subtitle: "绑定目录 · 命令执行 · 文件读写",
                             icon: "folder", color: .gray,
                             destination: AnyView(WorkspaceSettingsView())),
                SettingsItem(title: L10n.t("row_agents"),
                             subtitle: "隔离指令 · 工作流",
                             icon: "person.3.fill", color: .indigo,
                             destination: AnyView(AgentsAndSkillsView()))
                // v9.4：按用户要求删除「本机知识库」入口——其导入能力并入上面的「知识库」页
                // （KnowledgeSettingsView），KnowledgeBaseView 源码一并移除。
            ]
            groups.append(SettingsGroup(header: "工具与管理", items: devItems))

        // v9.4：按用户要求删除「安全」分组里的「本机工具审计」入口，AuditLogView / ToolAuditView /
        // CrashLogsView 三个页面源码一并移除（MoreViews.swift 1–491 行）。分组随之清空，整块删除。
        // AuditLog 记录层（AuditLog.shared.log 各处调用）保留，不影响任何功能。
        // v7.16.11：按用户要求删除「重置所有数据」入口（含 resetAllData 实现）。
        // 卸载即清空数据已由 AppDelegate 的「首装检测」接管，不再需要手动重置。
        // v7.16.11：按用户要求删除「工作区文件」入口（WorkspaceBrowserView 已从设置移除）。
        // v7.4.1：清理中心（含系统清理 / App 清理）整块删除（用户要求）
        // v6.9.15：Coruna 安全盾 / Web 注入已按用户要求删除

        // 关于
        // v9.4：版本文本统一走 appVersionText()（不再用局部 ver 变量）
        var aboutItems: [SettingsItem] = [
            // v7.16.11：按用户要求删除「关于作者」入口（AboutAuthorView 源文件一并删除）
            SettingsItem(title: L10n.t("row_lang"),
                         subtitle: LanguageManager.shared.language.displayName,
                         icon: "globe", color: .purple,
                         action: { showLanguagePicker = true }),
            // v9.4：按用户要求删除「检查更新」入口与 UpdateView 页面源码。
            // UpdateManager 本身保留（侧载环境下不再自动检查），只是不再有界面入口。
            // v9.4：版本行——读数失败时回退到 bundle 版本号/构建号，不再显示 "unknown"
            SettingsItem(title: L10n.t("version"),
                         subtitle: Self.appVersionText(), icon: "number.circle.fill", color: .gray,
                         destination: nil)
        ]
        groups.append(SettingsGroup(header: L10n.t("sec_about"), items: aboutItems))

        return groups
    }

    // MARK: - 列表模式

    // v4.3.64：已移除 testShareSheet（系统分享面板在本设备侧载环境必崩，无诊断价值）

    private var listBody: some View {
        List {
            // v4.3.64：移除"测试系统分享面板（Debug）"——本设备侧载环境任何系统分享面板
            // 都崩（MobileIcons/CoreImage SIGSEGV，v4.3.43-63 全部真机证伪），
            // 该按钮只会闪退，无诊断价值。分享统一走 ShareCenter 自建菜单（存储到文件/拷贝）。
            ForEach(makeGroups(), id: \.header) { group in
                Section(header: SettingSectionHeader(title: group.header)) {
                    ForEach(group.items) { item in
                        listRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .deepseekList()
        .actionSheet(isPresented: $showLanguagePicker) {
            ActionSheet(
                title: Text(L10n.t("row_lang")),
                buttons: AppLanguage.allCases.map { lang in
                    .default(Text(lang.displayName)) {
                        LanguageManager.shared.language = lang
                    }
                } + [.cancel(Text(L10n.t("cancel")))]
            )
        }
        .alert("抓包 VPN", isPresented: Binding(
            get: { !vpnToggleError.isEmpty },
            set: { if !$0 { vpnToggleError = "" } }
        )) {
            Button("好", role: .cancel) { vpnToggleError = "" }
        } message: {
            Text(vpnToggleError)
        }
        // v9.4：更新镜像源弹窗随「检查更新」入口一起删除
    }

    /// v9.4：每一行改用圆框卡片（灰底 + 黑细描边），不再用系统分隔线。
    /// rowCard 统一处理背景、圆角、描边与行间距。
    @ViewBuilder
    private func listRow(_ item: SettingsItem) -> some View {
        rowCard {
            // 开关优先：Toggle 项同时带 destination 时用 NavigationLink 包 Toggle（如抓包 VPN 开关）
            if let isOn = item.isOn, let onToggle = item.onToggle {
                let toggle = Toggle(isOn: Binding(get: isOn, set: onToggle)) {
                    SettingRowContent(item: item)
                }
                .accentColor(.primary)   // v7.1.1：开关也走黑白，不再用青色
                if let dest = item.destination {
                    NavigationLink(destination: dest) { toggle }
                } else {
                    toggle
                }
            } else if let dest = item.destination {
                NavigationLink(destination: dest) {
                    SettingRowContent(item: item)
                }
            } else if let action = item.action {
                Button(action: action) {
                    SettingRowContent(item: item)
                }
            } else {
                SettingRowContent(item: item)
            }
        }
    }

    /// 行卡片的容器修饰（所有行共用，保证圆框/描边/间距一致）
    private func rowCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 行底用抬升面灰、白页上才有边界；与对话页聊天气泡同色系
            .background(MonoChat.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(MonoChat.stroke, lineWidth: 0.8)
            )
            // 圆框之间留 8pt 空隙，替代原来的分隔线
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    // MARK: - 动态值

    @State private var lastProbe: DeviceProbe.Report?

    private func envSubtitle() -> String {
        if let r = lastProbe {
            let failed = r.checks.filter { !$0.passed }.count
            return r.ready ? "就绪 · 可注入" : "需检查 \(failed) 项"
        }
        return "点击探测"
    }

    private func envIcon() -> String {
        if let r = lastProbe {
            return r.ready ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
        }
        return "shield.lefthalf.filled"
    }

    private func envColor() -> Color {
        if let r = lastProbe {
            return r.ready ? .green : .red
        }
        return .gray
    }

    // v2.9.144：探测含 spawnRoot/文件遍历，主线程同步会卡死被看门狗杀（表现为闪退）
    private func triggerProbe() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DeviceProbe.shared.run()
            DispatchQueue.main.async {
                self.lastProbe = r
            }
        }
    }

    private func modelProviderName() -> String {
        ModelStore.shared.configs.first(where: { $0.isDefault })?.provider ?? ModelStore.shared.configs.first?.provider ?? "未配置"
    }

    private func permissionCount() -> Int {
        7
    }

    private func devInstructionsSubtitle() -> String {
        let count = DeveloperInstructionStore.shared.list().count
        return "\(count) 条 · 长按设默认"
    }

    private func sshConfigSubtitle() -> String {
        let host = UserDefaults.standard.string(forKey: "ssh.host") ?? ""
        return host.isEmpty ? "未配置" : host
    }

    /// v9.4：版本显示——CFBundleShortVersionString 为空时用构建号补齐，
    /// 两者都缺才退回 "—"，不再把 "unknown" 显示给用户。
    static func appVersionText() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        func s(_ k: String) -> String {
            (info[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let short = s("CFBundleShortVersionString")
        let build = s("CFBundleVersion")
        if !short.isEmpty {
            return build.isEmpty || short.contains(build) ? short : "\(short) (\(build))"
        }
        return build.isEmpty ? "—" : build
    }

        return String(raw.dropLast(5))
    }

    var body: some View {
        // v7.1.1（DeepSeek 风格）：彩色方块 + 白色重图标 → 黑白简洁版（裸线条图标）
        HStack(spacing: 12) {
            Image(systemName: lineIcon)
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)
                // v7.3.0：只保留主设置名，副标题说明小字不再显示（用户要求）
            }
            Spacer(minLength: 0)
            // v4.3.39：行尾红点提醒（新版更新等）——红点在行尾右侧，点击行即处理
            if let redDot = item.redDot, redDot() {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
            }
        }
    }
}

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.system(.footnote, design: .monospaced))
        }
    }
}

// v2.9.68：SSH 远程连接设置
struct SSHSettingsView: View {
    @State private var host: String = ""
    @State private var port: String = "22"
    @State private var user: String = ""
    @State private var password: String = ""
    @State private var keyPath: String = ""
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        Form {
            Section(header: Text(L10n.t("ui_137"))) {
                HStack {
                    Text(L10n.t("ui_20")).frame(width: 80, alignment: .leading)
                    TextField("如 192.168.1.100", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                HStack {
                    Text(L10n.t("ui_119")).frame(width: 80, alignment: .leading)
                    TextField("22", text: $port)
                        .keyboardType(.numberPad)
                }
                HStack {
                    Text(L10n.t("ui_112")).frame(width: 80, alignment: .leading)
                    TextField("如 root", text: $user)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section(header: Text(L10n.t("ui_131"))) {
                HStack {
                    Text(L10n.t("ui_46")).frame(width: 80, alignment: .leading)
                    SecureField("密码", text: $password)
                }
                HStack {
                    Text(L10n.t("ui_117")).frame(width: 80, alignment: .leading)
                    TextField("可选，如 /var/mobile/.ssh/id_rsa", text: $keyPath)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }

            Section {
                Button("保存配置") {
                    let defaults = UserDefaults.standard
                    defaults.set(host, forKey: "ssh_host")
                    defaults.set(Int(port) ?? 22, forKey: "ssh_port")
                    defaults.set(user, forKey: "ssh_user")
                    defaults.set(password, forKey: "ssh_password")
                    defaults.set(keyPath, forKey: "ssh_key_path")
                    presentationMode.wrappedValue.dismiss()
                }
                .foregroundColor(.blue)
            }

            Section(header: Text(L10n.t("ui_24"))) {
                Text(L10n.t("ui_140"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("SSH 远程连接")
        .onAppear {
            let defaults = UserDefaults.standard
            host = defaults.string(forKey: "ssh_host") ?? ""
            port = "\(defaults.integer(forKey: "ssh_port") == 0 ? 22 : defaults.integer(forKey: "ssh_port"))"
            user = defaults.string(forKey: "ssh_user") ?? ""
            password = defaults.string(forKey: "ssh_password") ?? ""
            keyPath = defaults.string(forKey: "ssh_key_path") ?? ""
        }
    }
}
