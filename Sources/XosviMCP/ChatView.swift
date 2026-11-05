import SwiftUI
import UIKit
import RSKGrowingTextView
import UniformTypeIdentifiers

/// v7.2.1：**启动直接进聊天页**——原来 v6.9.12 让 App 先落在一个"对话列表页"，
/// 用户反馈那个页面是多余的（历史会话在抽屉里已经有了），所以默认值改成 true。
/// 列表页代码保留（ChatRootView 仍能切过去），只是不再作为启动首屏。
struct ChatRootView: View {
    @ObservedObject private var store = ConversationStore.shared
    @State private var chatHome = true

    var body: some View {
        Group {
            if chatHome {
                ChatView()
            } else {
                ConversationListView(
                    onOpen: { id in
                        store.select(id)
                        chatHome = true
                    },
                    onClose: { chatHome = true }
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmOpenConversationList)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { chatHome = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tmNewConversation)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { chatHome = true }
        }
    }
}

extension Notification.Name {
    /// 请求回到对话列表页（聊天页左上角按钮 / 抽屉关闭后用）
    static let tmOpenConversationList = Notification.Name("xosvi.openConversationList")
    /// 请求新建对话并进入聊天页
    static let tmNewConversation = Notification.Name("xosvi.newConversation")
}

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared
    // v8.4：TTSService 观察已随朗读功能删除
    @ObservedObject private var uiState = AppUIState.shared   // v7.1.2：抽屉开关（顶部栏 ≡ 键要用）
    // v9：搜索服务（输入框「搜索·xx」胶囊要跟着设置页改）
    @ObservedObject private var searchCfg = SearchSettings.shared

    @State private var inputText = ""
    @State private var inputHeight: CGFloat = 36
    // v2.9.234：推理强度/智能搜索持久化(@AppStorage)——之前纯@State,关app重开必丢
    @AppStorage("chat_reasoning") private var reasoning = 0   // 0=低 1=中 2=高 3=最高(xhigh) 4=极限(max)
    // v7.1.0：搜索不再有开关——联网检索默认全开，由 AI 自己判断何时搜（见 SearchAlwaysOn.apply()）。
    // v3.1.25：思考模型总开关——关闭时完全不思考，直接回复（reasoning_effort=none）
    @AppStorage("chat_think_enabled") private var thinkEnabled = true
    @State private var keyboardHeight: CGFloat = 0   // v2.9.234：键盘高度(消息列表跟随上移)
    @State private var attachmentSheet: AttachmentSheet?
    // v3.1.67：文件选择改用 UIKit UIDocumentPickerViewController（asCopy: true）从顶层 VC present——
    // .fileImporter 在真机 iPhone 上有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    // UIKit 方案真机稳定。标记位 + sheet onDismiss 触发，保证面板完全关闭后再 present（不再猜时间延迟）。
    @State private var pendingFilePick = false
    @State private var showModelPicker = false  // v2.9.36：聊天框切换上游模型
    // v9：搜索服务快捷切换半屏（临时换服务商，不改设置里的默认值以外的任何东西）
    @State private var showSearchQuickSheet = false
    // v6.6.11：右上角 + 号菜单入口
    // v3.3.4：输入框 + 号展开"应用/相册/文件/浏览器"快捷行（点 + 变 x 收起）
    @State private var attachExpanded = false

    // v2.9.9：多模态图片（data URL）。选择相册图片后转 base64 暂存，发送时随消息传给模型
    @State private var pendingImages: [String] = []
    // v2.9.10：统一待发送附件（图片缩略图 / 应用图标 / 文件），输入栏上方预览
    @State private var pendingAttachments: [PendingAttachment] = []

    // v2.9.2：多选模式（勾选会话内容 → 复制 / 分享到其他 App）
    @State private var selectionMode = false
    @State private var selectedIds = Set<UUID>()
    @State private var showToast = false
    @State private var toastText = "已复制"

    /// v7.1.2：iOS16+ 顶部栏自绘 → 隐藏系统导航栏。`#available` 不能直接当值用，
    /// 必须放进 if 表达式里（CI 报 "may only be used as condition of an 'if'"）。
    private var isNavBarHidden: Bool {
        if #available(iOS 16.0, *) { return true }
        return false
    }

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                // v6.9.16（DeepSeek 风格）：会话页顶部栏自绘——任务名居中 + 下方一行快速切换模型；
                // 两侧是悬浮圆形功能键（左「≡」抽屉、右「＋」浏览器）。
                if #available(iOS 16.0, *) {
                    DeepSeekTopBar(
                        centerTitle: selectionMode ? "已选 \(selectedIds.count) 条" : store.currentTitle,
                        showModelChip: !selectionMode,
                        onLeft: {
                            if selectionMode { exitSelection() }
                            else { withAnimation { uiState.drawerOpen = true } }
                        },
                        leftIcon: selectionMode ? nil : "line.3.horizontal",
                        trailing: selectionMode ? nil : AnyView(
                            // v7.9.5：+ 号 = 直接开一个临时会话（原来弹菜单且只有「联网搜索」→ 打开设置页）
                            // v7.16.11：按用户要求把 + 号换成匿名（人形剪影）图标
                            Button {
                                store.newConversation(title: "临时会话")
                            } label: {
                                FloatingCircleButton(icon: "person.crop.circle")
                            }
                        )
                    )
                }
                if modelStore.configs.isEmpty {
                    emptyState
                } else if store.currentMessages.isEmpty {
                    homeState
                } else {
                    messageList
                }
                // v9.4：按用户要求移除「处理请求」工作流步骤条（WorkflowProgressView）——
                // 它和消息里的「过程 N 步」重复展示同一批工具调用，属于噪声。
            }
            // v2.9.244：输入框改用 safeAreaInset 挂底部——标准键盘避让，不再手动 padding 双重压缩内容区
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            // v6.9.16：iOS16+ 顶部栏自绘，系统导航栏整条隐藏（iOS15 仍走系统导航栏）
            .navigationBarHidden(isNavBarHidden)
            // v9.2：聊天页黑白主题——纯白底 + 黑字，仅本页强制浅色环境
            // 用 environment(而不是 preferredColorScheme)：只影响聊天页子树，
            // 设置页等其他页面仍跟随系统；同时 .primary/.secondary 在本页自动变黑/灰。
            .background(MonoChat.bg.ignoresSafeArea())
            .environment(\.colorScheme, .light)

            .navigationTitle(selectionMode ? "已选 \(selectedIds.count) 条" : store.currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v3.4.3：标题 + 模型名（🟢 deepseek v4 ▽）与右侧图标放同一平行线（导航栏 principal）
                ToolbarItem(placement: .principal) {
                    // v6.6.11：模型快速切换从右上角移到任务名下方（用户要求）
                    VStack(spacing: 1) {
                        Text(selectionMode ? "已选 \(selectedIds.count) 条" : store.currentTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        if !selectionMode {
                            Button(action: { showModelPicker = true }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 5))
                                        .foregroundColor(MonoChat.subtext)
                                    Text(modelStore.defaultConfig?.name ?? "未选择模型")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectionMode {
                        Button("取消") { exitSelection() }
                    } else {
                        HStack(spacing: 14) {
                            Button(action: { withAnimation { AppUIState.shared.drawerOpen.toggle() } }) {
                                Image(systemName: "line.horizontal.3")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            // v6.6.8：左上角 + 号新建会话按钮用户要求再删除
                            // （新建入口保留在侧滑抽屉头部 + 抽屉内长按管理）
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectionMode {
                        HStack(spacing: 14) {
                            Button(action: copySelected) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .disabled(selectedIds.isEmpty)
                            SharePresenter.toolbarShare(text: exportText())
                                .disabled(selectedIds.isEmpty)
                        }
                    } else {
                        // v7.9.5：+ 号 = 直接开临时会话
                        // v7.16.11：按用户要求换成匿名（人形剪影）图标
                        Button {
                            store.newConversation(title: "临时会话")
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 18, weight: .semibold))
                        }
                    }
                }
            }
            // v2.9.244：删除手动 keyboardHeight padding（会与键盘避让叠加导致内容区被拉高/压缩），键盘避让交给 safeAreaInset
            // v2.9.235：键盘监听仍保留——用于键盘弹出时消息列表滚到底部

            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = h }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
            }
            .overlay(Group {
                if showToast {
                    // v9.1：纯黑页面上黑底 toast 看不见 → 白底黑字
                    Text(toastText)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(MonoChat.invertBg.opacity(0.95))
                        .foregroundColor(MonoChat.invertText)
                        .cornerRadius(10)
                        .padding(.top, 8)
                }
            }, alignment: .top)
            // v6.2.7：边缘侧滑开关会话抽屉（用户反馈"会话页侧滑无法打开添加新对话页"）。
            // v6.6.9：① 触发区放宽到左侧 60% 屏、阈值降到 40、minimumDistance 12；
            //         ② 另加左侧 28pt 边缘拖拽带（highPriorityGesture）兜底——
            //            ScrollView 的滚动手势会吃掉 simultaneousGesture 的 onEnded，
            //            边缘带保证"从左边往右划"一定打开抽屉。
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        guard abs(dx) > abs(dy) * 1.4, abs(dx) > 40 else { return }
                        let ui = AppUIState.shared
                        let leftHalfThreshold: CGFloat = UIScreen.main.bounds.width * 0.6
                        if value.startLocation.x < leftHalfThreshold && dx > 0 && !ui.drawerOpen {
                            withAnimation { ui.drawerOpen = true }
                        } else if dx < 0 && ui.drawerOpen {
                            withAnimation { ui.drawerOpen = false }
                        }
                    }
            )
            // v6.6.9：左侧边缘 28pt 高优先级拖拽带（兜底，防 ScrollView 抢手势）
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 28)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .onEnded { value in
                                let dx = value.translation.width
                                let dy = value.translation.height
                                guard dx > 30, abs(dx) > abs(dy) * 1.2 else { return }
                                let ui = AppUIState.shared
                                if !ui.drawerOpen {
                                    withAnimation { ui.drawerOpen = true }
                                }
                            }
                    )
            }
        }
        .navigationViewStyle(.stack)
        // v2.9.31：授权弹窗已整体移除（工具搜索即自动授权，无弹窗）。
        .sheet(item: $attachmentSheet, onDismiss: {
            // v3.1.67：面板完全关闭后再触发文件选择（UIKit 从顶层 VC present，真机稳定）
            // v3.1.70：延迟 0.6s 再 present——onDismiss 触发时 SwiftUI sheet 的关闭动画
            // （约 0.5s）还没完全结束，立即 present 的 UIDocumentPicker 会被 sheet 收尾逻辑
            // 顶掉，表现为"弹出 0.5 秒后自动退回聊天界面"（真机实测 bug）
            if pendingFilePick {
                pendingFilePick = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Self.presentDocumentPicker { urls in
                        handlePickedFiles(urls)
                    }
                }
            }
        }) { sheet in
            switch sheet {
            case .panel:
                // v2.9.35：传已选数量，面板右上角显示"已选 N"（对齐老 MCP）
                // 紧凑半屏（老 MCP"添加内容"卡片式）；presentationDetents 需 iOS16+
                if #available(iOS 16.0, *) {
                    AttachmentPanelView(onPick: { pick in
                        // v2.9.39：浏览器入口直接开悬浮窗（不占 sheet）
                        // v3.1.67：文件入口不再用 .fileImporter（真机有 bug），改记 pendingFilePick，
                        // 由 sheet onDismiss 在面板完全关闭后触发 UIKit 文档选择器
                        if pick == .browser {
                            // v7.5.0：内置浏览器已删除，网页由 web.search / web.fetch 处理
                            self.attachmentSheet = nil
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                        .sheetDetentsHeight(340)   // v2.9.37：4 入口 2×2 网格需更高
                } else {
                    AttachmentPanelView(onPick: { pick in
                        if pick == .browser {
                            // v7.5.0：内置浏览器已删除，网页由 web.search / web.fetch 处理
                            self.attachmentSheet = nil
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                }
            case .browser:
                // v2.9.39：浏览器已改为悬浮窗，面板入口在 onPick 闭包里直接开悬浮窗
                EmptyView()
            case .appPicker:
                AppPickerView { app in
                    // v2.9.10：应用选择 → 附件预览（图标 + 名称 + bundleId）
                    let icon = Self.appIcon(for: app.path)
                    let att = PendingAttachment(
                        kind: .app,
                        displayName: app.name,
                        dataURL: nil,
                        thumbnail: icon,
                        bundleId: app.bundleId,
                        fileURL: nil
                    )
                    self.pendingAttachments.append(att)
                    // v2.9.61：不再往输入框塞 [📱应用] 标签，附件只在上方预览条显示（微信风格），发送时自动生成描述
                }
            case .photoPicker:
                PhotoPickerView { urls in
                    // v2.9.9：真正把图片内容转 base64 传给模型（不再只是文件名）
                    var dataURLs: [String] = []
                    var names: [String] = []
                    for u in urls {
                        if let d = Self.imageDataURL(for: u) {
                            dataURLs.append(d)
                            names.append(u.lastPathComponent)
                            // v2.9.10：同时生成带缩略图的附件，输入栏预览
                            let thumb = UIImage(contentsOfFile: u.path)
                            self.pendingAttachments.append(PendingAttachment(
                                kind: .image,
                                displayName: u.lastPathComponent,
                                dataURL: d,
                                thumbnail: thumb,
                                bundleId: nil,
                                fileURL: u
                            ))
                        }
                    }
                    // v2.9.61：图片缩略图在预览条显示，不再往输入框塞 [🖼图片] 标签
                    if dataURLs.isEmpty {
                        self.pendingImages = []
                    } else {
                        self.pendingImages = dataURLs
                    }
                }
            case .documentPicker:
                // v3.1.67：文件选择已改用 UIKit UIDocumentPickerViewController（见 onDismiss + presentDocumentPicker），
                // .fileImporter 在真机 iPhone 有已知 bug，弃用
                EmptyView()
            }
        }
        // v2.9.36：聊天框切换上游模型（点"当前模型"弹出，老 MCP 风格半屏）
        // v9：搜索服务快捷切换（半屏）
        .sheet(isPresented: $showSearchQuickSheet) {
            ChatSearchQuickSheet(onDone: {
                showSearchQuickSheet = false
            })
        }
        .sheet(isPresented: $showModelPicker) {
            // 老 MCP 半屏；presentationDetents 需 iOS16+
            if #available(iOS 16.0, *) {
                ChatModelPickerSheet { cfg in
                    // 点选即切换默认模型
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast("已切换：\(cfg.name)")
                }
                .sheetDetentsHeight(360)
            } else {
                ChatModelPickerSheet { cfg in
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast("已切换：\(cfg.name)")
                }
            }
        }
        // v3.0.76：快捷标签 sheet
        // v6.9.11：修复"点终端闪退"——RemoteTerminalView 由 sheet 呈现且内容没有
        // NavigationView，却用了 .navigationTitle；更关键的是 RemoteAccessView 里
        // 通过 NavigationLink 进入它，在没有导航容器时 NavigationLink 触发崩溃。
        // 统一在 present 处包一层 NavigationView（stack 样式，iOS 15 可用）。
        // v7.3.0：本地终端已移除（引擎不可用），此入口整段删除
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickToolsPresented }, set: { AppUIState.shared.quickToolsPresented = $0 })) {
            ToolsView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickSkillsPresented }, set: { AppUIState.shared.quickSkillsPresented = $0 })) {
            AgentsAndSkillsView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickFilesPresented }, set: { AppUIState.shared.quickFilesPresented = $0 })) {
            // v6.4.8：包一层 NavigationView——否则 sheet 内没有导航栏，
            // 工作区的"完成/上一级/上传/新建"工具栏按钮全都不显示（用户实测）。
            NavigationView {
                WorkspaceBrowserView(onClose: { AppUIState.shared.quickFilesPresented = false })
            }
            .navigationViewStyle(.stack)
        }
        // v2.9.10：网络恢复 / 回前台提示（配合后台自动重连）
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.networkRestored)) { _ in
            showToast("网络已恢复")
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.willEnterForeground)) { _ in
            if AppLifecycleMonitor.shared.isNetworkAvailable {
                showToast("已回到前台")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.badge")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(L10n.t("home_empty_title"))
                .font(.headline)
            Text(L10n.t("home_empty_sub"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var homeState: some View {
        // v6.6.14：按用户要求——新会话页只保留空白（欢迎语 / 主卡 / 快捷卡片都在 git 历史里，提交 8d59de6）。
        // v6.9.15：「技能」从输入框挪出后，首页右上角留一个入口（v6.9.16 起是悬浮圆钮），功能不丢。
        // v6.9.19：左下角设置圆钮用户要求删除——设置入口只保留在抽屉底部。
        // v7.3.0：右上角闪电图标的「技能」指令入口已按要求删除，新会话页回到纯空白。
        // 技能面板本身还在（quickSkillsPresented），只是不再从这里进入。
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// v2.9.78：首页能力小卡片（两列网格）
    /// v3.1.1: 点卡片时自动切换到对应的系统指令模式
    private func miniCard(_ icon: String, _ title: String, _ subtitle: String, _ colors: [Color], promptId: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            // 自动切换到对应的系统指令模式
            if let pid = promptId {
                SystemPrompts.shared.select(pid)
            }
            action()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.headline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(MonoChat.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors[0].opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func runQuickPrompt(_ text: String) {
        guard let cfg = modelStore.defaultConfig else { return }
        if store.selectedId == nil { store.newConversation() }
        inputText = ""
        store.send(text, using: cfg,
                   reasoningLevel: ReasoningSettings.autoLevel(for: text),
                   smartSearch: true, in: store.selectedId)
    }

    /// v7.9.12：只渲染最近 N 条。会话几百条时，任何一次流式 delta 都会让整列 body 重算，
    /// LazyVStack 也救不了已经实例化过的行 —— 表现就是"聊久了越来越卡"。
    @State private var visibleMessageLimit = 60

    private var visibleMessages: [ChatMessage] {
        // v7.16.9：渲染前按时间戳兜底排序（同时间戳再按 id 稳定），
        // 不依赖"插入顺序恰好正确"——任何绕过 insertSorted 的写入路径
        // （导入会话/重载/工具循环回写）都会造成「我的消息跑到回复下面」。
        let raw = store.currentMessages
        var all = raw
        // 只在检测到乱序时才排序——O(n) 扫描，避免每个流式帧都 sort 整段历史
        if zip(raw, raw.dropFirst()).contains(where: { $0.timestamp > $1.timestamp }) {
            all = raw.sorted {
                $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString
                                             : $0.timestamp < $1.timestamp
            }
        }
        // v9：跳过已被回填消费的 tool 消息（结果已住在 ToolCallPayload.result 里，
        // 再显示一遍就是双份；不物理删除——搜索/导出/审计还在用）
        all = all.filter { !$0.isToolConsumed }
        guard all.count > visibleMessageLimit else { return all }
        return Array(all.suffix(visibleMessageLimit))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // v8.5：消息间距 12 → ChatMetrics.messageGap(18)——与块内 10 / 段落 9 形成层次
                LazyVStack(spacing: ChatMetrics.messageGap) {
                    if store.currentMessages.count > visibleMessageLimit {
                        Button {
                            visibleMessageLimit += 60
                        } label: {
                            Text("显示更早的 \(min(60, store.currentMessages.count - visibleMessageLimit)) 条")
                                .font(.footnote)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                    ForEach(visibleMessages) { msg in
                        MessageBubble(
                            message: msg,
                            selectionMode: selectionMode,
                            isSelected: selectedIds.contains(msg.id),
                            onToggleSelect: { toggleSelect(msg.id) },
                            onCopy: { copyMessage(msg) },
                            onShare: { shareMessage(msg) },
                            onDelete: { store.removeMessage(id: msg.id) },
                            isStreaming: store.streamingMessageId == msg.id,
                            forceType: store.liveProducedID == msg.id,
                            // v9.4：思考内置自动，始终展示模型返回的思考块
                            thinkEnabled: true
                        )
                        .id(msg.id)
                    }
                    if store.isLoading {
                        // v2.9.34：请求过程可视化（对齐老 MCP 的"正在思考"面板）
                        // v2.9.127：改为实时执行轨迹（豆包工作任务/Codex 式步骤流）
                        // v8.4：指示器移到左边（原 trailing 靠右，用户要求左对齐）
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(L10n.t("home_thinking"))
                                    .font(.footnote.weight(.medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            // v9.1：黑白主题——近黑抬升面
                            .background(MonoChat.surfaceRaised)
                            .cornerRadius(14)
                            .padding(.leading, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if store.isLoading, !store.liveTrail.isEmpty {
                                LiveTrailCard(steps: store.liveTrail)
                            }
                            if let status = store.statusText {
                                Text(status)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 16)
                            }
                            if store.requestRound > 0 {
                                // v4.3.71：无轮次上限 (requestRounds==0) 只显示"第 N 轮"
                                if store.requestRounds > 0 {
                                    Text(L10n.t("ui_157", store.requestRound, store.requestRounds))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 16)
                                } else {
                                    Text("第 \(store.requestRound) 轮")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 16)
                                }
                            }
                        }
                    }
                }
                // v3.4.0：去掉整行水平 padding —— AI 气泡改为真正占满左右屏边缘；
                // 用户气泡的右留白由 MessageBubble 内部按 isUser 处理
                .padding(.vertical, 12)
            }
            // 点击聊天区空白处收起键盘（v2.9.9）
            .simultaneousGesture(
                TapGesture().onEnded { dismissKeyboard() }
            )
            .onChange(of: store.currentMessages.count) { _ in
                if let last = store.currentMessages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            // v2.9.12：打开/切换会话时自动滚到底（老会话不再停在顶部）
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: store.selectedId) { _ in
                scrollToBottom(proxy)
            }
            // v2.9.72：AI 回复完成时结束工作流
            .onChange(of: store.isLoading) { loading in
                if !loading {
                    WorkflowManager.shared.finishRun(success: true)
                }
            }
            // v2.9.235：键盘高度变化→自动滚到底（高度本身由外层 VStack 监听，空会话也能避让键盘）
            .onChange(of: keyboardHeight) { _ in
                if keyboardHeight > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let last = store.currentMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    /// v2.9.12：滚到当前会话最新一条
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            if let last = store.currentMessages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // v6.9.14：底部功能胶囊行（推理/思考/搜索/技能/工作区）已整行删除——
    // 推理与思考合并为「思考」，思考/搜索挪到输入框下方，技能并入输入框工具行。

    private var inputBar: some View {
        // v6.9.14（DeepSeek 风格）：整块输入区重排——
        //   ① 删除底部那一排功能胶囊（推理·高 / 思考·开 / 搜索·开 / 技能）；"推理"与"思考"合并成「思考」；
        //   ② 输入框变成大圆角方框：首行多行输入，次行左「+ 附件 / 思考 / 搜索」，右「发送」；
        //   ③ v6.9.15：思考 / 搜索两个开关放进输入框的工具行（替换原来的「技能」），下方不再单独一行；
        //   ④ 删除输入框左边的远程终端入口（v7.3.0：终端本身也已移除）。
        VStack(spacing: 0) {
            // v2.9.10：待发送附件预览（图片缩略图 / 应用图标 / 文件）
            AttachmentPreviewStrip(attachments: pendingAttachments) { att in
                withAnimation { pendingAttachments.removeAll { $0.id == att.id } }
            }

            // v9：输入框上方状态条——模型胶囊 + 余额胶囊（文档第三节「挂到输入框」）
            // 形态 A/B 是独立一行；形态 C 由 BalanceChipBar 自己缩成右下角小字（仍是这一行，只是右对齐）
            // 数据源是当前默认模型；点胶囊强制刷新，长按看详情/复制/隐藏。
            BalanceChipBar(config: modelStore.defaultConfig)

            VStack(spacing: 6) {
                ChatInputTextView(text: $inputText, onSend: { send() }, height: $inputHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: inputHeight)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)

                HStack(spacing: 10) {
                    // v9.4：按用户要求删除「思考·强度」胶囊——思考改为内置自动：
                    // 由 ReasoningSettings.autoEnabledForRequest 按请求内容决定强度，
                    // 界面上不再暴露开关（用户指定"默认为自动，根据情况自动调整强度"）。

                    // v9：搜索服务快捷切换（Kelivo 的 search_settings_sheet）——
                    // 联网检索仍然默认全开，这个胶囊只用来「临时换一家服务商」和看读取方式。
                    DeepSeekPillButton(
                        icon: "magnifyingglass",
                        title: "搜索·\(searchCfg.selectedService?.displayName ?? Self.defaultSearchName)",
                        isOn: true
                    ) {
                        showSearchQuickSheet = true
                    }
                    .contextMenu {
                        Button { showSearchQuickSheet = true } label: {
                            Label("切换搜索服务商", systemImage: "magnifyingglass")
                        }
                        Button {
                            AppUIState.shared.settingsPresented = true
                        } label: {
                            Label("打开搜索设置", systemImage: "gearshape")
                        }
                    }

                    Spacer(minLength: 0)

                    if store.selectedIsRequesting {
                        Button(action: { store.cancelCurrent() }) {
                            // v9.3：停止键改灰底黑方块（去黑底）
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(MonoChat.text)
                                .frame(width: 32, height: 32)
                                .background(MonoChat.surfaceRaised)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: send) {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 14, weight: .semibold))
                                // v9.3：可发送=黑箭头灰底，空输入=灰箭头灰底（去黑底圆）
                                .foregroundColor(inputText.isEmpty ? MonoChat.subtext : MonoChat.text)
                                .frame(width: 32, height: 32)
                                .background(MonoChat.surfaceRaised)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(inputText.isEmpty)
                    }

                    // v7.3.0：+ 号从工具行最左边移到发送键左侧，两者用固定间距并排
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            attachExpanded.toggle()
                        }
                    }) {
                        Image(systemName: attachExpanded ? "xmark" : "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(MonoChat.subtext)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(MonoChat.surfaceRaised))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            // v9.1：黑白输入卡——近黑底 + 白色细描边（不用阴影，纯黑上阴影看不出来）
            .background(MonoChat.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(MonoChat.stroke, lineWidth: 0.8)
            )
            // v9：余额形态 C（最轻）——小字挂在输入卡内右下角，不额外占一行
            .overlay(alignment: .bottomTrailing) {
                BalanceCornerOverlay(config: modelStore.defaultConfig)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // 点 + 底部弹出 应用/相册/文件/浏览器（位于输入框下方）
            if attachExpanded {
                attachQuickRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 8)
        // v9.1：输入区与整页统一纯黑（向下延伸盖住底部安全区，否则 Home 指示条那一条会是系统白）
        .background(MonoChat.bg.ignoresSafeArea(edges: .bottom))
        // v2.9.30：授权弹窗已移出到 NavigationView 外层（见 body 链），
        // 此处不再挂 actionSheet，避免与上方 +号 的 actionSheet 同 view 覆盖。
    }

    /// v6.9.15：推理档位名（思考胶囊长按菜单用）
    /// v7.8.0：档位改用 ReasoningLevel（自动/关/最低/低/中/高/最高/极限）
    private var reasoningNames: [String] { ReasoningLevel.allCases.map { $0.displayName } }

    /// v9：搜索胶囊的兜底名（抽成常量，避免字符串插值里嵌字面量）
    private static let defaultSearchName = "必应"

    private func reasoningLabel() -> String {
        // v7.8.0：直接读 ReasoningSettings（兼容旧 chat_reasoning 整数）
        ReasoningSettings.shared.level.displayName
    }

    /// v3.3.4：+ 展开的快捷附件行（应用 / 相册 / 文件 / 浏览器），对齐微信式附件栏
    /// v3.4.2：从左屏幕边缘到右屏幕边缘均匀分布——四格等宽、间隙一致（含两侧边缘间隙）
    private var attachQuickRow: some View {
        HStack(spacing: 12) {
            attachQuickButton("apps.iphone", "应用") {
                withAnimation { attachExpanded = false }
                attachmentSheet = .appPicker
            }
            .frame(maxWidth: .infinity)
            attachQuickButton("photo.on.rectangle", "相册") {
                withAnimation { attachExpanded = false }
                attachmentSheet = .photoPicker
            }
            .frame(maxWidth: .infinity)
            attachQuickButton("folder", "文件") {
                withAnimation { attachExpanded = false }
                // v3.3.4：快捷行直接弹 UIKit 文档选择器（无需半屏面板中转）
                Self.presentDocumentPicker { urls in
                    handlePickedFiles(urls)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        // v3.4.8：附件行与输入框之间留出明显间隔（参考图）
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private func attachQuickButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // v3.4.8：方形圆角瓦片（参考图：相机/图片/文件/打电话样式），不再是圆形
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(MonoChat.text)
                    .frame(width: 52, height: 52)
                    .background(MonoChat.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// v2.9.93：按模型名识别供应商图标
    private func modelIcon(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("deepseek") { return "d.circle.fill" }
        if m.contains("claude") { return "c.circle.fill" }
        if m.contains("gpt") || m.contains("o1") || m.contains("o3") || m.contains("o4") { return "sparkles" }
        if m.contains("glm") || m.contains("qwen") || m.contains("kimi") { return "brain" }
        if m.contains("gemini") { return "sparkle.magnifyingglass" }
        return "cpu"
    }

    private func send() {
        guard let cfg = modelStore.defaultConfig,
              (!inputText.isEmpty || !pendingAttachments.isEmpty || !pendingImages.isEmpty) else { return }
        // v3.1.5: 自动提取关键信息（App 名、bundle id、文件路径等）
        AutoContextExtractor.shared.extract(from: inputText)
        // v3.1.1: 模型不支持视觉时，自动 OCR 识别图片文字，拼到消息里
        var imagesToSend = pendingImages
        if !pendingImages.isEmpty && !cfg.supportsVision {
            // 自动 OCR：把图片文字识别出来，拼到消息里
            var ocrTexts: [String] = []
            for (i, imgData) in pendingImages.enumerated() {
                if let data = Data(base64Encoded: imgData.replacingOccurrences(of: "data:image/png;base64,", with: "").replacingOccurrences(of: "data:image/jpeg;base64,", with: "")) {
                    let tmpPath = NSTemporaryDirectory() + "ocr_\(i).png"
                    try? data.write(to: URL(fileURLWithPath: tmpPath))
                    if let ocrResult = try? OCRImageTool().invoke(["path": tmpPath]),
                       let text = ocrResult["text"] as? String, !text.isEmpty {
                        ocrTexts.append("📷 图片\(i+1) 识别到的文字：\n\(text)")
                    }
                    try? FileManager.default.removeItem(atPath: tmpPath)
                }
            }
            if !ocrTexts.isEmpty {
                inputText = inputText + "\n\n" + ocrTexts.joined(separator: "\n\n")
                imagesToSend = [] // 去掉图片，只发文字
                showToast("🔍 已自动 OCR 识别图片文字")
            }
        }
        // v2.9.72：启动工作流可视化
        WorkflowManager.shared.startRun("处理请求")
        if store.selectedId == nil { store.newConversation() }
        var text = inputText
        let imgs = pendingImages
        // v2.9.61：输入框不再有 [📱应用] 占位标签，发送时自动把应用/文件附件拼成描述文字
        let appAtts = pendingAttachments.filter { if case .app = $0.kind { return true }; return false }
        let fileAtts = pendingAttachments.filter { if case .file = $0.kind { return true }; return false }
        var attDesc: [String] = []
        for att in appAtts {
            let bid = att.bundleId ?? "unknown"
            attDesc.append("[📱应用：\(att.displayName)（\(bid)）]")
        }
        for att in fileAtts {
            // v2.9.291：文件附件自动复制到工作区 uploads/ 并附加路径——
            // 之前只发 [📎文件：xxx] 描述，AI 根本没有文件内容/路径可读，
            // 导致"找不到 .deb"（文件在用户本地文件App里，AI 视野外）
            let saved = Self.saveAttachmentToWorkspace(att)
            if let sp = saved {
                // v3.1.70：去掉"可用 artifact / shell.exec 读取分析"工具残留（用户反馈），
                // 只保留路径——AI 的 fs 工具集本身就能读，无需在消息里提示
                attDesc.append("[📎文件：\(att.displayName)] 已保存到 \(sp)")
            } else {
                attDesc.append("[📎文件：\(att.displayName)]（复制到工作区失败，请手动放入 \(Workspace.root.path)）")
            }
        }
        if !attDesc.isEmpty {
            text = text.isEmpty ? attDesc.joined(separator: " ") : text + " " + attDesc.joined(separator: " ")
        }
        inputText = ""
        pendingImages = []
        // v2.9.10：附件预览与发送联动——从附件里取图片 dataURL（若预览被删则不再发送）
        let attImgs = pendingAttachments.compactMap { $0.dataURL }
        pendingAttachments = []
        let finalImgs = attImgs.isEmpty ? imagesToSend : attImgs
        // v9.4：思考内置自动——按本轮文字判断强度（原来读输入框胶囊的开关+档位）
        store.send(text, using: cfg, imageDataURLs: finalImgs,
                   reasoningLevel: ReasoningSettings.autoLevel(for: text),
                   smartSearch: true, in: store.selectedId)
        AuditLog.shared.log("chat", detail: "发送消息")
    }

    /// v2.9.9：图片文件 → base64 data URL
    /// v2.9.292：降采样到最长边 1200px + JPEG q60 压缩——之前只限 3MB 不压缩，
    /// 单张原图 base64 可达 2-4MB，历史里每张图每次请求全量重发 → 卡住/超时。
    /// 压缩后单张 ~100-250KB，省 token 且不卡。
    static func imageDataURL(for url: URL) -> String? {
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        let maxDim: CGFloat = 1200
        var out = img
        if max(img.size.width, img.size.height) > maxDim {
            let scale = maxDim / max(img.size.width, img.size.height)
            let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            img.draw(in: CGRect(origin: .zero, size: newSize))
            out = UIGraphicsGetImageFromCurrentImageContext() ?? img
            UIGraphicsEndImageContext()
        }
        guard let data = out.jpegData(compressionQuality: 0.6) else { return nil }
        let limit = 3 * 1024 * 1024
        if data.count > limit { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    /// v2.9.291：把聊天文件附件复制到工作区 uploads/ 目录，返回保存后的绝对路径
    /// - 处理 security-scoped URL（UIDocumentPicker 返回的 URL 需 startAccessing）
    /// - 文件名冲突时追加时间戳，避免覆盖
    static func saveAttachmentToWorkspace(_ att: PendingAttachment) -> String? {
        guard let src = att.fileURL else { return nil }
        var scoped = false
        if src.startAccessingSecurityScopedResource() { scoped = true }
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: src), data.count > 0 else { return nil }
        let uploads = Workspace.root.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        var name = src.lastPathComponent
        if name.isEmpty { name = att.displayName }
        var dest = uploads.appendingPathComponent(name)
        // 重名冲突：追加 -<时间戳>
        if FileManager.default.fileExists(atPath: dest.path) {
            let ts = Int(Date().timeIntervalSince1970)
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            dest = uploads.appendingPathComponent("\(base)-\(ts).\(ext)")
        }
        do {
            try data.write(to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    /// v2.9.10：读取应用图标（用于输入栏附件预览）
    // v6.0.30: app图标内存缓存，所有用到图标的地方自动秒开
    private static let iconCache = NSCache<NSString, UIImage>()
    static func appIcon(for path: String) -> UIImage? {
        // 先查缓存
        if let cached = iconCache.object(forKey: path as NSString) {
            return cached
        }
        guard let info = Bundle(path: path)?.infoDictionary,
              let icons = info["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        let p = (path as NSString).appendingPathComponent(last + "@2x.png")
        let img = UIImage(contentsOfFile: p) ?? UIImage(contentsOfFile: (path as NSString).appendingPathComponent(last + ".png"))
        if let img = img {
            iconCache.setObject(img, forKey: path as NSString)
        }
        return img
    }

    // MARK: - v3.1.67：UIKit 文档选择器（真机稳定方案，替代 .fileImporter）

    /// 从顶层 VC present UIDocumentPickerViewController（asCopy: true）。
    /// - 真机 iPhone 上 .fileImporter 有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    ///   UIKit 方案在真机完全正常（最早版本能打开文件就是用的 UIKit 方案）。
    /// - asCopy: true 让系统把所选文件复制进 App 沙盒，返回的 URL 直接可读、不会失效，
    ///   无需 startAccessingSecurityScopedResource，也彻底绕开"临时 URL 失效"问题。
    static func presentDocumentPicker(onPick: @escaping ([URL]) -> Void) {
        guard let top = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.modalPresentationStyle = .formSheet
        // coordinator 必须被强引用，否则 delegate 回调不触发
        let coordinator = DocumentPickerCoordinator(onPick: onPick)
        picker.delegate = coordinator
        objc_setAssociatedObject(picker, &DocumentPickerCoordinator.assocKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
    }

    /// 找到当前最顶层的 UIViewController（绕开 SwiftUI sheet 层级问题，直接往 key window 上 present）
    private static func topViewController() -> UIViewController? {
        var vc: UIViewController?
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        }
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    /// 选择完成：复制到工作区 uploads/（asCopy 已复制进沙盒，这里再落到 uploads 统一管理 + 防重名）
    private func handlePickedFiles(_ urls: [URL]) {
        for u in urls {
            let att = PendingAttachment(
                kind: .file,
                displayName: u.lastPathComponent,
                dataURL: nil,
                thumbnail: nil,
                bundleId: nil,
                fileURL: u
            )
            if let saved = Self.saveAttachmentToWorkspace(att) {
                self.pendingAttachments.append(PendingAttachment(
                    kind: .file,
                    displayName: u.lastPathComponent,
                    dataURL: nil,
                    thumbnail: nil,
                    bundleId: nil,
                    fileURL: URL(fileURLWithPath: saved)
                ))
            } else {
                self.pendingAttachments.append(att)
            }
        }
    }

    // MARK: - 多选 / 复制 / 分享（v2.9.2）

    private func enterSelection() {
        selectionMode = true
        selectedIds = []
    }

    private func exitSelection() {
        selectionMode = false
        selectedIds = []
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func copyMessage(_ m: ChatMessage) {
        UIPasteboard.general.string = m.content
        showToast("已复制")
    }

    private func shareMessage(_ m: ChatMessage) {
        presentShareSheet(text: m.content)
    }

    private func copySelected() {
        let count = selectedIds.count
        UIPasteboard.general.string = exportText()
        exitSelection()
        showToast(count > 0 ? "已复制 \(count) 条内容" : "已复制")
    }

    private func shareSelected() {
        presentShareSheet(text: exportText())
    }

    // v4.3.46：文字分享 → 自建分享菜单（拷贝 / 存储到文件），绕开 ShareSheet
    private func presentShareSheet(text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            showToast("没有可分享的内容")
            return
        }
        ShareCenter.shared.presentShareMenuText(content)
    }

    /// 把勾选的消息拼成可读文本（按会话内顺序），用于复制 / 分享。
    private func exportText() -> String {
        let msgs = store.currentMessages.filter { selectedIds.contains($0.id) }
        guard !msgs.isEmpty else { return "" }
        var parts: [String] = []
        let title = store.currentTitle
        if !title.isEmpty && title != "新会话" {
            parts.append("【\(title)】")
        }
        for m in msgs {
            parts.append(formatted(m))
        }
        return parts.joined(separator: "\n\n")
    }

    private func formatted(_ m: ChatMessage) -> String {
        switch m.role {
        case "user":
            return "我：\(m.content)"
        case "tool":
            let name = m.toolName.map { "（\($0)）" } ?? ""
            return "工具结果\(name)：\(m.content)"
        default:
            return m.content
        }
    }

    private func showToast(_ text: String) {
        toastText = text
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showToast = false }
        }
    }
}

/// v6.9.16（DeepSeek 风格）：悬浮圆形功能键——白/深灰底 + 细描边 + 轻阴影，浮在内容上，没有文字按钮的框感
struct FloatingCircleButton: View {
    let icon: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(MonoChat.text)
            .frame(width: size, height: size)
            .background(Circle().fill(MonoChat.surfaceRaised))
            .overlay(Circle().stroke(MonoChat.stroke, lineWidth: 0.8))
            .contentShape(Circle())
    }
}

/// v6.9.16（DeepSeek 风格）：会话页顶部栏——任务名居中，快速切换模型放在任务名下面一行；
/// 左上角悬浮圆形「≡」进抽屉，右上角悬浮圆形「＋」进终端 / Hax 电脑。
struct DeepSeekTopBar: View {
    @ObservedObject private var modelStore = ModelStore.shared
    @State private var showPicker = false

    var centerTitle: String
    var showModelChip: Bool
    var onLeft: () -> Void
    /// nil 表示左侧不用圆形图标、改显示文字（多选模式的「取消」）
    var leftIcon: String? = "line.3.horizontal"
    var trailing: AnyView? = nil

    var body: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(centerTitle.isEmpty ? "新对话" : centerTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: 200)

                if showModelChip {
                    Button(action: { showPicker = true }) {
                        HStack(spacing: 3) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .foregroundColor(MonoChat.subtext)
                            Text(modelStore.defaultConfig?.name ?? "未选择模型")
                                .font(.system(size: 11))
                                .foregroundColor(DoubaoTheme.subText)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(DoubaoTheme.subText)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                if let icon = leftIcon {
                    Button(action: onLeft) { FloatingCircleButton(icon: icon) }
                        .buttonStyle(PlainButtonStyle())
                } else {
                    Button(action: onLeft) {
                        Text("取消")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(MonoChat.text)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Spacer(minLength: 0)
                if let trailing = trailing { trailing }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 46)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .sheet(isPresented: $showPicker) {
            // v7.1.2：ChatModelPickerSheet 需要 onSelect（漏传会报 missing argument）
            ChatModelPickerSheet { cfg in
                var c = cfg
                c.isDefault = true
                ModelStore.shared.update(c)   // 点选即切换默认模型（与导航栏那份保持一致）
                showPicker = false
            }
        }
    }
}

/// v6.9.14：iOS16+ 才有的 SF Symbol 做版本兜底（DeepSeek 输入框下方那两个按钮要用）
private func dsSymbol(_ name: String, fallback: String) -> String {
    if #available(iOS 16.0, *) { return name }
    return fallback
}

/// v6.9.14：DeepSeek 式输入框下方按钮（思考 / 搜索）——细线轮廓胶囊，关闭=灰底灰字，开启=蓝底浅蓝字
struct DeepSeekPillButton: View {
    let icon: String
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            // v9.3：胶囊开启=灰底黑字（用户要求去掉黑底），关闭=浅灰底灰字
            .foregroundColor(isOn ? MonoChat.text : MonoChat.subtext)
            .background(
                Capsule().fill(isOn ? MonoChat.surfaceRaised : MonoChat.surfaceRaised)
            )
            .overlay(
                Capsule().stroke(isOn ? MonoChat.stroke : MonoChat.stroke, lineWidth: 0.8)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ChatChip: View {
    let label: String
    let action: () -> Void
    // v2.9.36：浅蓝=开启/强调，灰=关闭（老 MCP 风格）
    var accent: Bool = true
    // v2.9.79：前置小图标（推理强度 / 智能搜索）
    var icon: String = ""

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(accent ? MonoChat.surfaceRaised : MonoChat.surfaceRaised)
            // v9.3：去黑底——强调态也用灰底黑字
            .foregroundColor(accent ? MonoChat.text : MonoChat.subtext)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(MonoChat.stroke, lineWidth: 1)
            )
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v3.0.76：输入框上方快捷标签按钮
struct QuickTabButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(height: 36)
            // v3.4.4：与 ChatChip 统一内边距/圆角，保证滑动模块比例一致
            .padding(.horizontal, 10)
            .background(MonoChat.surfaceRaised)
            .foregroundColor(.secondary)
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v2.9.36：聊天框"当前模型"点击弹出的上游模型选择（老 MCP 风格半屏）
struct ChatModelPickerSheet: View {
    @ObservedObject private var modelStore = ModelStore.shared
    @Environment(\.dismiss) private var dismissSheet
    let onSelect: (ModelConfig) -> Void

    // v6.3.2：按用户思路重构——"选择模型"面板列出已保存模型，点进去即进入该站详情页，
    // 详情页自动获取该中转站的上游模型列表，点选某个模型就切换到它。
    @State private var search = ""

    private var filteredConfigs: [ModelConfig] {
        guard !search.isEmpty else { return modelStore.configs }
        return modelStore.configs.filter {
            ($0.name + " " + $0.model + " " + $0.provider).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        TextField("搜索模型", text: $search)
                            .font(.subheadline)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if !search.isEmpty {
                            Button { search = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Section(header: Text("已保存的模型"),
                        footer: Text("点某个模型 → 进入该站点，自动获取其上游模型列表，可直接切换")) {
                    ForEach(filteredConfigs) { cfg in
                        NavigationLink {
                            UpstreamModelsView(config: cfg) { picked, model in
                                switchTo(picked, model: model)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: cfg.isDefault ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundColor(cfg.isDefault ? .primary : Color(UIColor.tertiaryLabel))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cfg.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text("\(cfg.provider) · \(cfg.model)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                        ForEach(ModelTags.tags(for: cfg.model), id: \.self) { t in
                                            Text(t)
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color(UIColor.secondarySystemFill))
                                                .foregroundColor(.secondary)
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }
                Section {
                    Button(action: {
                        dismissSheet()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            AppUIState.shared.settingsJumpToModels = true
                            AppUIState.shared.settingsPresented = true
                        }
                    }) {
                        Label("在设置中管理模型", systemImage: "gearshape.fill")
                            .font(.footnote)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismissSheet() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func switchTo(_ cfg: ModelConfig, model: String?) {
        var c = cfg
        if let m = model { c.model = m }
        c.isDefault = true
        modelStore.update(c)
        onSelect(c)
        dismissSheet()
    }
}

/// v6.3.2：某个已保存模型的详情页——进入即自动获取该中转站上游模型列表，
/// 点选即切换到对应模型（同时支持"直接用该配置"）。
struct UpstreamModelsView: View {
    let config: ModelConfig
    let onPick: (ModelConfig, String?) -> Void

    @State private var models: [String] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var search = ""

    private var filtered: [String] {
        guard !search.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                Button { onPick(config, nil) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: config.isDefault ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(config.isDefault ? .primary : Color(UIColor.tertiaryLabel))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("使用该配置")
                                .foregroundColor(.primary)
                            Text(config.model)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            Section(header: HStack(spacing: 6) {
                Text("上游模型")
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button { fetch() } label: {
                        Image(systemName: "arrow.clockwise").font(.caption)
                    }
                }
            }, footer: Text(config.baseURL).font(.caption2)) {
                if let e = loadError {
                    Text(e).font(.caption).foregroundColor(.red).lineLimit(3)
                }
                if !loading && models.isEmpty && loadError == nil {
                    Text("未返回模型列表（该站可能不支持 /models）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ForEach(filtered, id: \.self) { m in
                    Button { onPick(config, m) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: config.model == m ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(config.model == m ? .primary : Color(UIColor.tertiaryLabel))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !ModelTags.tags(for: m).isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(ModelTags.tags(for: m), id: \.self) { t in
                                            Text(t)
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Color(UIColor.secondarySystemFill))
                                                .foregroundColor(.secondary)
                                                .cornerRadius(4)
                                        }
                                    }
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索模型")
        .navigationTitle(config.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if models.isEmpty { fetch() }
        }
    }

    private func fetch() {
        loading = true
        loadError = nil
        ModelAPIClient.shared.fetchModelList(config: config) { result in
            loading = false
            switch result {
            case .success(let list):
                models = list
                if list.isEmpty { loadError = nil }
            case .failure(let e):
                loadError = e
            }
        }
    }
}

/// v6.3.1：模型能力标签（按模型名启发式，用于选择面板展示 img/video/pdf/img-out）
enum ModelTags {
    static func tags(for model: String) -> [String] {
        let m = model.lowercased()
        var t: [String] = []
        if m.contains("vl") || m.contains("vision") || m.contains("-image") || m.contains("image-")
            || m.contains("gpt-4o") || m.contains("gemini") || m.contains("o4-") { t.append("img") }
        if m.contains("video") { t.append("video") }
        if m.contains("pdf") { t.append("pdf") }
        if m.contains("dall") || m.contains("flux") || m.contains("image-out") || m.contains("-img-out") { t.append("img-out") }
        return t
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var colors: [Color] = []   // v7.4.1：已废弃（统一黑白），保留签名兼容
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors[0])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(MonoChat.surfaceRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(colors[0].opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v4.4.15：气泡点击手势——仅 tool 折叠 / 多选模式注册 onTapGesture；
// 纯文本气泡(非tool非selection)不注册任何点击手势，否则父级 contentShape+onTapGesture
// 的手势识别器会抢占内部 Text 的 textSelection 长按 → AI 回复一大段文字长按选字失效(用户实测)
private struct MessageTapModifier: ViewModifier {
    let isTool: Bool
    let selectionMode: Bool
    let onToggleSelect: (() -> Void)?
    let onToolToggle: () -> Void
    func body(content: Content) -> some View {
        if isTool || selectionMode {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectionMode { onToggleSelect?() }
                    else { onToolToggle() }
                }
        } else {
            content
        }
    }
}

/// 打字机的节拍器（v9.1）。
///
/// 为什么不用 `@State var timer: Timer?`：SwiftUI 的 `View` 是值类型，每轮 `body`
/// 都会复制一份；`@State` 的写入又**不同步**——同一个 runloop 里连着调两次 `start`，
/// 两次都还读到 `nil`，于是留下两个 Timer。每个 Timer 每 0.02 秒回调一次并改
/// `@State`，改完又触发重绘，重绘里 `.onAppear` / `.onChange` 再开会话……
/// 实测卡住时 360 wakeups/s（系统上限 150/s），落盘 `Xosvi.wakeups_resource-*.ips`。
///
/// 这个类只有一个任务：保证**同一时刻最多一个** Timer。`start` 幂等，
/// `tick` 返回 `false` 时自己停掉，不留悬挂。
final class TypewriterDriver {
    private var timer: Timer?
    /// 当前已显示的字符数，由 tick 的返回值推进。
    private var revealed = 0
    /// 每 tick 做什么。参数是当前已显示字符数，返回下一次的字符数；
    /// 返回 `nil` 表示打完了，driver 自动停止。
    typealias Tick = (_ revealed: Int) -> Int?

    func start(total: Int, tick: @escaping Tick) {
        // 已经在跑就不重开——这是修复的关键：以前这个判断放在 @State 上不可靠。
        guard timer == nil else { return }
        revealed = 0
        DispatchQueue.main.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard let next = tick(self.revealed) else { self.stop(); return }
                self.revealed = min(next, total)
                // 追平就收工，绝不多转一圈
                if self.revealed >= total { self.stop() }
            }
            // 兜底：总长 0 时不必空转
            if total <= 0 { self.stop() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        revealed = 0
    }

    deinit { timer?.invalidate() }
}

struct MessageBubble: View {
    let message: ChatMessage
    // v4.3.77：安装进度——工具"执行中"气泡渲染实时进度条（引用处位于本 struct）
    @ObservedObject private var installRegistry = InstallationRegistry.shared
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    // v6.2.7：长按气泡删除单条消息（用户要求"长按会话框弹出删除功能"——
    // 顶栏勾选选择模式已移除，删除入口改长按菜单）
    var onDelete: (() -> Void)? = nil
    // v3.4.5：当前正在流式生成的 AI 消息 → 打字机逐字显示
    var isStreaming: Bool = false
    // v3.4.9：本轮刚生成完成的消息（工具解说/整段到达的回复）也要逐字打出——
    // 这些消息 isStreaming=false 且内容在出现前已定好，靠 onAppear 强制启动打字机
    var forceType: Bool = false
    // v3.5.31：思考开关——思考关时隐藏思考块（API 仍可能返回 thinking，UI 一律不显示）
    var thinkEnabled: Bool = true

    // v6.0.28：工具结果默认折叠，用户手动点才展开
    @State private var expanded = false
    @State private var expandedToolIds: Set<String> = []
    // v8.6：点 [cite:sN] 角标 → 待打开的引用原文（确认后走系统浏览器）
    @State private var pendingCitation: CitationLink?
    // v9：投影过程区里点工具步骤 → 待展示的完整结果
    @State private var toolResultRef: ToolStepRef?
    /// v7.6.0：工具结果半屏面板是否打开
    @State private var showToolResult = false
    // v3.4.5：打字机效果——已显示字符数 + 定时器（显示与网络解耦，逐字稳定刷出）
    // v3.4.7：降速到 25 字/秒(0.04s/字)让打字感清晰可见；且不依赖 isStreaming——
    // 只要内容在增长就持续打字到完整，兼容"整段一次性到达"的中转
    // v3.5.4：用户反馈太慢 → 提速到 ~133 字/秒 (0.015s/tick × 2 字符），快但仍看得出打字感
    @State private var revealedCount = 0
    // v9.1：typeTimer 从 @State 改为引用类型持有。
    // 旧实现把 Timer 存进 @State：每轮 body 重绘都会复制结构体，而 SwiftUI 的 @State
    // 写入是异步生效的，`guard typeTimer == nil` 会在同一帧里放行多次 startTypeTimer，
    // 于是多个 Timer 并存、互相叠加；每个 0.02s 的 Timer 又都在改 @State 触发重绘，
    // 形成「重绘 → 再启动 → 再重绘」。实测卡住时 360 wakeups/s（系统上限 150），
    // 落盘 Xosvi.wakeups_resource-*.ips。引用类型不受结构体复制影响，跨重绘唯一。
    @State private var typer = TypewriterDriver()
    // v8.4：autoSpokenUpTo 已随 TTS 删除

    // v3.5.4：自适应打字机（业界：平时 ~50 字/秒舒适，积压多自动提速追平网络，标点/换行稍停顿更自然）。
    // 不像固定 133 字/秒那样一快到底；也不像 25 字/秒那样拖沓。
    // v9.1：Timer 由 TypewriterDriver 持有（引用类型，跨重绘唯一），这里只负责喂数据。
    private func startTypeTimer() {
        let content = message.content
        typer.start(total: content.count) { [content] revealed in
            guard revealed < content.count else { return nil }      // 追平 → 让 driver 自毁
            let backlog = content.count - revealed
            let idx = content.index(content.startIndex, offsetBy: revealed)
            let ch = content[idx]
            let isPause = ch == "\n" || "，。；：！？、,.。;:!?… ".contains(ch)
            let step: Int
            if backlog > 60 { step = 8 }        // 积压很多 → 大幅提速追平
            else if backlog > 30 { step = 4 }   // 积压多 → 提速
            else if backlog > 12 { step = 2 }   // 稍积压 → 中速
            else if isPause { step = 1 }        // 标点/换行 → 慢速停顿(真人感)
            else { step = 1 }                    // 常规 ~50 字/秒(0.02s/字)
            let next = min(content.count, revealed + step)
            revealedCount = next
            return next
        }
    }
    private func stopTypeTimer() {
        typer.stop()
    }
    // v8.4：autoSpeak 函数已随 TTS 功能删除
    // v3.5.4：思考黄泡——思考进行中(isStreaming)自动展开让用户看到模型在动；
    // 思考结束自动收起(除非用户手动展开)。业界(掘金/Koder/DeepSeek Harness)一致做法。
    private var thinkingExpanded: Bool {
        isStreaming ? true : expandedToolIds.contains(message.id.uuidString)
    }
    /// v7.7.0：ReasoningBlock 需要可写绑定（原 thinkingExpanded 是只读计算属性）
    private var thinkingExpandedBinding: Binding<Bool> {
        Binding(get: { thinkingExpanded },
                set: { newValue in
                    if newValue != thinkingExpanded { toggleThinking() }
                })
    }

    private func toggleThinking() {
        let id = message.id.uuidString
        if expandedToolIds.contains(id) { expandedToolIds.remove(id) }
        else { expandedToolIds.insert(id) }
    }

    private var isUser: Bool { message.role == "user" }
    private var isTool: Bool { message.isTool }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                if selectionMode { selectionBadge }
                Spacer(minLength: 50)
            }

            if isTool {
                toolBubble
            } else {
                textBubble
            }

            if !isUser {
                // v8.6：气泡自身已卡 86% 屏宽（bubbleChrome），这里留极少余量即可
                Spacer(minLength: 0)
                if selectionMode { selectionBadge }
            }
        }
        // v3.4.4：AI/工具气泡左右各留 16 边距（用户反馈 10 仍太小）；用户气泡右侧留白 12
        .padding(.horizontal, isUser ? 12 : 16)
        // v4.4.15：条件点击手势——tool/多选才注册，纯文本气泡不注册(让 textSelection 长按生效)
        .modifier(MessageTapModifier(
            isTool: isTool,
            selectionMode: selectionMode,
            onToggleSelect: onToggleSelect,
            onToolToggle: {
                // v7.6.0：点工具卡弹半屏结果
                if !message.isRunning { showToolResult = true }
            }
        ))
        // v6.2.7：长按气泡菜单（复制/分享/删除）——用户要求"长按会话框弹出删除功能"。
        // 历史 v4.4.13 曾移除 contextMenu 保文字选择；现按用户新要求恢复长按菜单，
        // 菜单含"复制全文"补偿部分复制需求。
        .contextMenu {
            if let onCopy = onCopy {
                Button(action: onCopy) { Label("复制全文", systemImage: "doc.on.doc") }
            }
            if let onShare = onShare {
                Button(action: onShare) { Label("分享", systemImage: "square.and.arrow.up") }
            }
            if let onDelete = onDelete {
                Button(action: onDelete) { Label("删除此消息", systemImage: "trash") }
            }
        }
        // v3.4.5：打字机效果——内容增长即逐字显示，直到完整
        .onAppear {
            if (isStreaming || forceType), revealedCount < message.content.count { startTypeTimer() }
        }
        .onDisappear { stopTypeTimer() }
        .onChange(of: isStreaming) { streaming in
            if streaming, revealedCount < message.content.count {
                startTypeTimer()
            } else if !streaming {
                // v6.6.4：流式结束立即补齐剩余文字。旧行为：forceType 要整轮结束才清，
                // 期间仍按 prefix(revealedCount) 渲染 → 打字机没跟上就停在半句，
                // 必须等下一轮输出/重绘才显示全（用户实测）。
                revealedCount = message.content.count
                stopTypeTimer()
            }
        }
        .onChange(of: message.content) { _ in
            if revealedCount < message.content.count { startTypeTimer() }
        }
        // v9：投影过程区里点工具步骤 → 完整结果面板
        .sheet(item: $toolResultRef) { ref in
            ToolStepResultSheet(name: ref.name,
                                args: ref.argumentsFull.isEmpty ? ref.argumentsPreview : ref.argumentsFull,
                                result: ref.resultFull ?? ref.resultPreview,
                                isError: ref.isError,
                                isRunning: ref.isRunning,
                                durationMs: ref.durationMs)
        }
        // v8.6：点引用角标 → 确认后打开原文（先确认再离开 App，避免误触）
        .alert(item: $pendingCitation) { link in
            Alert(title: Text("打开引用来源"),
                  message: Text(link.url.host ?? link.url.absoluteString),
                  primaryButton: .default(Text("打开")) {
                      _ = UIThreadBridge.openURL(link.url, timeout: 3)
                  },
                  secondaryButton: .cancel(Text("取消")))
        }
    }

    /// v8.6：分层气泡容器（文档要求）——
    ///   · 用户：accent 实色 + 白字
    ///   · AI：卡片底 + 0.6pt 描边
    ///   两者都贴合内容宽度、上限 86% 屏宽（ChatMetrics.bubbleMaxWidth），
    ///   长文在 86% 处换行，短句不会拉成一条空卡片。
    private func bubbleChrome<V: View>(_ content: V) -> some View {
        let cap = UIScreen.main.bounds.width * ChatMetrics.bubbleMaxWidth
        // 统一链路：内边距 → 背景/圆角（贴合内容）→ 宽度上限 86%
        // 顺序很关键：background 在 frame 之前，短消息的气泡才不会被拉成一条空卡片。
        return content
            .padding(.horizontal, ChatMetrics.bubblePaddingH)
            .padding(.vertical, ChatMetrics.bubblePaddingV)
            .background(bubbleFill)
            .clipShape(RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChatMetrics.bubbleRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.secondary.opacity(0.5) : bubbleStroke,
                                  lineWidth: isSelected ? 2 : 0.6)
            )
            .frame(maxWidth: cap, alignment: isUser ? .trailing : .leading)
    }

    /// v8.6：气泡正文——流式/打字机走轻量 Text，完成态走分块富文本
    @ViewBuilder
    private func bubbleContent(_ shown: String) -> some View {
        // v9：投影器分派（text / steps[reasoning|tool|toolGroup] / image / file）。
        // 过程区（思考+工具）折叠成一行摘要——这是"层次"的来源，正文永远是视觉焦点。
        // · 纯正文的流式/打字机 → 轻量 Text（避免 UITextView 高频刷新闪跳）
        // · 带工具调用的消息 → 必须走投影器，否则过程区不显示，只剩空气泡
        let hasToolParts = message.effectiveParts.contains {
            if case .toolCall = $0 { return true }
            return false
        }
        if isUser {
            CollapsibleUserText(text: shown)
        } else if (isStreaming || forceType) && !hasToolParts {
            messageTextView(shown)
        } else {
            projectedContent
        }
    }

    /// v9：投影渲染——后端只认 ProjectedBlock，不再关心 content/toolCalls/thinking 的存储细节
    private var projectedContent: some View {
        let urls = isUser ? [:] : CitationRenderer.collectURLs(
            around: message, in: ConversationStore.shared.currentMessages)
        // v9：思考块与图片条由气泡自己渲染（带耗时/token 的折叠块、横滑缩略图），
        // 投影器只负责「工具过程区 + 正文」——否则同一个思考/图片会出现两次。
        let settings = TimelineSettings(showReasoning: false,
                                        showToolCalls: true,
                                        showImages: false)
        return ProjectedMessageView(
            msg: message,
            citedURLs: urls,
            settings: settings,
            // v9：流式期间用增量投影结果（只重算尾部块）；完成后走 ProjectedBlockCache
            precomputed: ConversationStore.shared.streamingBlocks(for: message.id),
            renderText: { s in
                // v9：投影出来的每个正文块仍走富文本渲染（保住加粗/行内代码/引用角标/表格）
                AnyView(richText(s))
            },
            onTapTool: { ref in
                // v9：点过程区里的工具步骤 → 打开完整结果面板
                toolResultRef = ref
            }
        )
    }

    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundColor(isSelected ? .primary : Color.secondary)
            .padding(.top, 8)   // v8.6：HStack 改 .top 对齐后徽标贴顶部，与气泡首行齐平
    }

    // v4.4.11：AI 正文行内代码(反引号)→橙色(与"已深度思考"同色)。手动正则解析，
    // 容错流式打字机未闭合反引号(不配对则视为普通文本)。仅 assistant 生效, user 保持纯文本。
    // v4.4.12：正文 markdown 加粗(**xx**)→粗体(semibold)。代码段优先(橙色)，代码段外再匹配粗体。
    /// v9：正文富文本渲染（投影器的 renderText 注入点）
    /// 保留分块能力：MessageBlockParser 负责 text/code/list/heading/quote/table 切分。
    @ViewBuilder
    private func richText(_ s: String) -> some View {
        let blocks = MessageBlockParser.parse(s)
        let urls = isUser ? [:] : CitationRenderer.collectURLs(
            around: message, in: ConversationStore.shared.currentMessages)
        let body = self.attributedBody
        let userFlag = self.isUser
        MessageBodyView(
            blocks: blocks,
            isUser: isUser,
            citedURLs: urls,
            // v9.1：黑白主题——用户气泡深灰(0.20)+白字，AI 气泡近黑(0.06)+白字
            textColor: isUser ? MonoChat.userText : MonoChat.text,
            renderText: { t in
                AnyView(
                    Group {
                        if userFlag {
                            CollapsibleUserText(text: t)
                        } else if t.count > 20000 {
                            // v9：超长单块 → 分块渲染，避免单 Text 布局/命中测试过慢
                            BoundedLargeText(text: t)
                        } else {
                            SelectableText(
                                attributed: urls.isEmpty ? body(t)
                                    : CitationRenderer.apply(to: body(t), urls: urls),
                                textColor: .black,
                                onTapCitation: { url in
                                    pendingCitation = CitationLink(url: url)
                                })
                        }
                    }
                )
            }
        )
    }

    /// v4.4.21：消息文本视图——流式/打字机/用户消息用轻量 Text（避免 UITextView 高频刷新闪跳）；assistant 完成消息用 SelectableText(UITextView) 长按选字/划词/复制
    @ViewBuilder
    private func messageTextView(_ shown: String) -> some View {
        // v6.2.8（对齐 OpenMinis）：正文字号 16.5；超长文本（>5 万字）截断渲染，
        // 避免单条消息超长文本拖垮 SwiftUI 布局（崩溃 3 巨型递归栈的可疑诱因之一）
        let capped = shown.count > 50000
            ? String(shown.prefix(50000)) + "\n\n…[内容过长，仅渲染前 5 万字；完整内容见会话数据]"
            : shown
        if isStreaming || forceType {
            // v6.4.0（对齐 OpenMinis：流式期间用廉价渲染，完成后才上富文本）：
            // 旧实现在每个 delta 都跑 coloredBody（正则解析代码段/加粗）→ 长输出卡顿。
            // 流式期间直接 Text(纯文本)，完成后再走 attributed/SelectableText 富文本路径。
            Text(AttributedString(capped))
                .font(.system(size: 16.5))
                .foregroundColor(MonoChat.text)
                .textSelection(.enabled)
        } else {
            // v4.5.0：完成消息用原生 NSAttributedString 富文本（加粗/橙色/暗黑模式都正确渲染），避免 SwiftUI AttributedString 桥接丢失样式
            // v8：正文含 [cite:sN] 时替换为引用角标（本轮 web.search 结果命中蓝标，未命中灰标）
            if capped.contains("[cite:") {
                let urls = CitationRenderer.collectURLs(around: message, in: ConversationStore.shared.currentMessages)
                SelectableText(attributed: CitationRenderer.apply(to: attributedBody(capped), urls: urls),
                               textColor: .black,
                               onTapCitation: { url in pendingCitation = CitationLink(url: url) })
            } else {
                SelectableText(attributed: attributedBody(capped), textColor: .black)
            }
        }
    }

    private func coloredBody(_ text: String) -> AttributedString {
        var out = AttributedString()
        let pattern = "`([^`]+)`"
        var pos = text.startIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: pos..<text.endIndex) {
            if pos < range.lowerBound { out += styledBold(text[pos..<range.lowerBound]) }
            let inner = text[text.index(after: range.lowerBound)..<text.index(before: range.upperBound)]
            var c = AttributedString(inner)
            // v7.4.1：行内代码不再用橙色装饰——等宽 + 浅灰底，和黑块代码保持一致的中性风
            c.foregroundColor = .primary
            c.font = .system(.body, design: .monospaced)
            c.backgroundColor = MonoChat.surfaceRaised
            out += c
            pos = range.upperBound
        }
        if pos < text.endIndex { out += styledBold(text[pos..<text.endIndex]) }
        return out
    }

    // v4.4.12：代码段外的 markdown 加粗(**xx**)→粗体；未闭合的 ** 容错为普通文本
    private func styledBold(_ s: Substring) -> AttributedString {
        var out = AttributedString()
        let boldPat = "\\*\\*([^*]+)\\*\\*"
        var pos = s.startIndex
        while let r = s.range(of: boldPat, options: .regularExpression, range: pos..<s.endIndex) {
            if pos < r.lowerBound { out += AttributedString(s[pos..<r.lowerBound]) }
            let inner = s[s.index(after: r.lowerBound)..<s.index(before: r.upperBound)]
            var b = AttributedString(inner)
            b.font = .system(size: 17, weight: .semibold) // v4.4.14: .system(_:weight:) 需 iOS16+, 改 system(size:weight:) 兼容更低部署目标
            out += b
            pos = r.upperBound
        }
        if pos < s.endIndex { out += AttributedString(s[pos..<s.endIndex]) }
        return out
    }

    // v4.5.0：原生 NSAttributedString 富文本——给 SelectableText(UITextView) 用。
    // 解析 **加粗** 与 `代码`(橙色)；直接写 UIKit font + UIColor（动态 .label 适配暗黑模式），
    // 不走 SwiftUI AttributedString 桥接（会丢橙色/加粗样式，导致暗黑下看不清、字体变小）。
    private func attributedBody(_ text: String) -> NSAttributedString {
        // v9.2：白底黑字——正文纯黑；行内代码用深灰（不再用橙色装饰）
        let baseColor = UIColor.black
        let orangeColor = UIColor(white: 0.30, alpha: 1)
        let regular = UIFont.systemFont(ofSize: 17)
        let bold = UIFont.boldSystemFont(ofSize: 17)
        let mono = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)

        let base: [NSAttributedString.Key: Any] = [.font: regular, .foregroundColor: baseColor]
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: baseColor]
        let orangeAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: orangeColor]

        let ns = text as NSString
        let pattern = #"\*\*([^*]+)\*\*|`([^`]+)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let ms = NSMutableAttributedString()
        var pos = 0
        for m in matches {
            if m.range.location > pos {
                ms.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), attributes: base))
            }
            // 捕获组编号：组1 = **加粗** 内容，组2 = `代码` 内容（共2组，无组3）
            let boldGroup = m.range(at: 1)
            if boldGroup.location != NSNotFound {
                ms.append(NSAttributedString(string: ns.substring(with: boldGroup), attributes: boldAttrs))
            } else {
                ms.append(NSAttributedString(string: ns.substring(with: m.range(at: 2)), attributes: orangeAttrs))
            }
            pos = m.range.location + m.range.length
        }
        if pos < ns.length {
            ms.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: ns.length - pos)), attributes: base))
        }
        return ms
    }

    /// v9.2：白底黑字——用户纯黑（白字）、AI 纯白（黑字 + 细描边）、出错浅红提示
    @ViewBuilder
    private var bubbleFill: some View {
        if isUser {
            MonoChat.userBubble
        } else if message.isError {
            Color(red: 0.99, green: 0.93, blue: 0.93)
        } else {
            MonoChat.surface
        }
    }

    /// v9.2：气泡描边色——AI 黑色细描边，用户黑底不需要
    private var bubbleStroke: Color {
        if isUser { return MonoChat.userStroke }
        if message.isError { return Color.red.opacity(0.30) }
        return MonoChat.stroke
    }

    /// v8.6：分层气泡容器（文档要求）——思考块 / 附件 / 正文同处一张卡片
    ///   · 用户：accent 实色 + 白字
    ///   · AI：卡片底 + 0.6pt 描边
    ///   两者都贴合内容宽度、上限 86% 屏宽（ChatMetrics.bubbleMaxWidth）。
    private var textBubble: some View {
        let shown = (isStreaming || forceType)
            ? String(message.content.prefix(revealedCount))
            : message.content
        let imgs = message.imageDataURLs ?? []
        let hasImages = !imgs.isEmpty
        let thinkingText = (thinkEnabled && !isUser) ? (message.thinking ?? "") : ""
        let hasThinking = !thinkingText.isEmpty
        let hasBody = !message.content.isEmpty
        // v9：只有工具调用、没有正文的消息（模型直接发 tool_calls）也要渲染过程区
        let hasToolParts = message.effectiveParts.contains {
            if case .toolCall = $0 { return true }
            return false
        }

        return Group {
            if hasImages || hasThinking || hasBody || hasToolParts {
                bubbleChrome(
                    VStack(alignment: isUser ? .trailing : .leading,
                           spacing: ChatMetrics.blockGap) {
                        // ① 附件（图片排在正文前，缩略图横排）
                        if hasImages {
                            messageImageStrip(imgs)
                        }
                        // ② 思考块（最轻：无边框、灰字、默认折叠）
                        if hasThinking {
                            thinkingView(thinkingText, message: message)
                        }
                        // ③ 过程区（工具步骤，默认折叠成一行）+ 正文（最重：16pt / 行距 6.5）
                        if hasBody || hasToolParts {
                            bubbleContent(shown)
                        }
                    }
                )
            }
        }
    }

    /// v2.9.20：思考记录（reasoning）折叠视图
    private func thinkingView(_ text: String, message: ChatMessage) -> some View {
        // v7.7.0：统一走 ReasoningBlock（preview 渐变折叠 / 展开全量 + 代码块渲染）
        // v8.5：思考块视觉权重最轻——水平内缩 6、与正文之间留 blockGap（由外层 VStack 统一给）
        return ReasoningBlock(
            text: text,
            isStreaming: isStreaming,
            expanded: thinkingExpandedBinding,
            startAt: message.reasoningStartAt,
            finishedAt: message.reasoningFinishedAt,
            tokens: message.reasoningTokens
        )
            .padding(.horizontal, 6)
    }

    /// v2.9.10：data URL → UIImage
    private func messageImageStrip(_ dataURLs: [String]) -> some View {
        let images = dataURLs.compactMap { Self.uiImage(fromDataURL: $0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 140)
                        .cornerRadius(12)
                        .clipped()
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    /// v2.9.10：data URL → UIImage（用于消息气泡图片显示）
    static func uiImage(fromDataURL s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    /// v3.5.16：卡片标题只显示工具名（去掉"命令符/命令"），像 Minis 步骤标签那样简洁。
    /// 具体命令/参数仍在卡片下方 args 等宽行完整显示，标题不再拼命令，避免命令符状态占据标题。
    private func toolShortLabel() -> String {
        message.toolName ?? "工具"
    }

    private var toolBubble: some View {
        // v7.4.1（AI Agent 调试会话风格）：工具调用收成一张干净的圆角卡片——
        // 图标 + 名称 + 耗时，状态只用 ✓ / ✗ / 转圈，不再有蓝底、蓝色文字、彩色徽章。
        // 展开后才是参数与结果，默认收起（避免一屏全是工具噪声）。
        VStack(alignment: .leading, spacing: 8) {
            if thinkEnabled, let thinking = message.thinking, !thinking.isEmpty {
                thinkingMiniBubble(thinking, message: message)
            }

            ToolCallCard(
                name: message.toolName ?? "工具",
                args: message.toolArgs,
                duration: message.toolDuration,
                isRunning: message.isRunning,
                isError: message.isError,
                expanded: false,
                // v7.6.0：点工具卡直接弹半屏结果面板（用户要求，取消气泡内折叠）
                onTap: { if !message.isRunning { showToolResult = true } }
            )

            // 结果首行摘要（常显，方便在长对话里快速扫）
            if !message.isRunning, !message.content.isEmpty {
                Text(Self.toolSummaryLine(message.content))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(MonoChat.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 27)
            }
        }
        // v8.6：工具卡与气泡同一宽度上限（86% 屏宽），整列视觉对齐
        .frame(maxWidth: UIScreen.main.bounds.width * ChatMetrics.bubbleMaxWidth, alignment: .leading)
        .sheet(isPresented: $showToolResult) {
            ToolResultSheet(message: message)
        }
    }

    /// v7.6.0：工具结果首行摘要（跳过空行，最多 120 字）
    static func toolSummaryLine(_ text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        return ""
    }

    // 📝 思考过程迷你气泡
    private func thinkingMiniBubble(_ text: String, message: ChatMessage) -> some View {
        // v7.7.0：与正文里的思考块同一套渲染
        ReasoningBlock(
            text: text,
            isStreaming: isStreaming,
            expanded: thinkingExpandedBinding,
            startAt: message.reasoningStartAt,
            finishedAt: message.reasoningFinishedAt,
            tokens: message.reasoningTokens
        )
    }


}

// v3.1.6: 聊天里的文件卡片 —— 点了直接 QuickLook 预览
struct FileCardRow: View {
    let url: URL
    @State private var showPreview = false

    private var fileName: String { url.lastPathComponent }
    private var ext: String { (fileName as NSString).pathExtension.lowercased() }
    private var isImage: Bool { ["png","jpg","jpeg","gif","webp","heic"].contains(ext) }

    private var iconName: String {
        if isImage { return "photo" }
        switch ext {
        case "ipa","tipa": return "shippingbox"
        case "deb","zip","tar","gz": return "archivebox"
        case "dylib","framework": return "hammer"
        case "plist","json": return "doc.text"
        case "pdf": return "doc.richtext"
        case "swift","h","m","c","cpp": return "chevron.left.slash.chevron.right"
        default: return "doc"
        }
    }

    private var sizeText: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        if size > 1024*1024 { return String(format: "%.1f MB", Double(size)/1024/1024) }
        if size > 1024 { return String(format: "%.0f KB", Double(size)/1024) }
        return "\(size) B"
    }

    var body: some View {
        Button(action: { showPreview = true }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(MonoChat.surfaceRaised)
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundColor(MonoChat.text)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(sizeText)
                        .font(.caption2)
                        .foregroundColor(MonoChat.secondaryText)
                }
                Spacer()
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundColor(MonoChat.subtext)
            }
            .padding(10)
            // v9.1：黑白主题——抬升面
            .background(MonoChat.surfaceRaised)
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            SharePresenter.menuShare(url: url)
            // v4.3.46：用 TrollStore 安装 → 打开方式（UIDocumentInteractionController）。
            // TrollStore 注册了 .tipa/.ipa 的打开方式，不经过 ShareSheet（系统分享面板
            // 在本设备侧载环境 MobileIcons/CoreImage SIGSEGV，任何路径都崩）。
            // v4.3.51：URL scheme 直调 TrollStore 安装（不渲染 App 图标列表，安全）
            if ext == "tipa" || ext == "ipa" {
                Button(action: { ShareCenter.shared.openInTrollStore(url) }) {
                    Label("用 TrollStore 安装", systemImage: "shippingbox")
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            QLFilePreview(urls: [url])
        }
    }
}

struct TypingIndicator: View {
    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(MonoChat.secondaryText)
                    .offset(y: offset)
                    .animation(Animation.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15), value: offset)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(MonoChat.surfaceRaised)
        .cornerRadius(18)
        .onAppear { offset = -4 }
    }
}

// MARK: - v2.9.127 执行轨迹组件（豆包工作任务/Codex 式过程流）

/// 实时轨迹卡片：请求进行中，在"正在思考"下方竖排显示步骤流
struct LiveTrailCard: View {
    let steps: [TrailStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                TrailRow(step: step)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v9.1：黑白主题——抬升面
        .background(MonoChat.surfaceRaised)
        .cornerRadius(12)
    }
}

/// 历史轨迹卡片：assistant 消息气泡内，可折叠展开执行全过程
struct TrailCard: View {
    let steps: [TrailStep]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: 13))
                    Text(L10n.t("ui_158", steps.count))
                        .font(.caption.weight(.medium))
                        .foregroundColor(MonoChat.secondaryText)
                    Spacer()
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundColor(MonoChat.secondaryText)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        TrailRow(step: step)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MonoChat.surfaceRaised)
        .cornerRadius(12)
    }

    private var summaryText: String {
        let ok = steps.filter { $0.status == .success }.count
        let fail = steps.filter { $0.status == .failed }.count
        if fail > 0 { return "✅\(ok) ❌\(fail)" }
        return "✅ \(ok) 步成功"
    }
}

/// 单步行：图标 + 名称 + 状态色 + 可展开 detail
struct TrailRow: View {
    let step: TrailStep
    @State private var detailExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconFor)
                .font(.system(size: 12))
                .foregroundColor(colorFor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(.caption)
                    .fontWeight(step.status == .running ? .medium : .regular)
                    .foregroundColor(step.status == .running ? .primary : (step.status == .failed ? .red : .primary))
                    .lineLimit(1)
                if step.status == .running {
                    Text(L10n.t("ui_64"))
                        .font(.caption2)
                        .foregroundColor(MonoChat.secondaryText)
                } else if !step.detail.isEmpty {
                    if detailExpanded {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(MonoChat.secondaryText)
                            .lineLimit(6)
                            .onTapGesture { detailExpanded = false }
                    } else {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(MonoChat.secondaryText)
                            .lineLimit(1)
                            .onTapGesture { detailExpanded = true }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var iconFor: String {
        switch step.kind {
        case .think: return "brain"
        case .tool: return "wrench.and.screwdriver"
        case .result: return step.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill"
        case .note: return "flag"
        }
    }

    private var colorFor: Color {
        switch step.status {
        case .running: return .secondary
        case .success: return .secondary
        case .failed: return .red
        }
    }
}

// MARK: - v2.9.234 输入框：UITextView 包装(检测 markedText，修复"没打完自动回车")
// SwiftUI TextField 读不到输入法 markedText(拼音未上屏)，iOS16+第三方输入法组合下
// 按回车会直接 submit → 发出去一串拼音。UITextView delegate 可读 markedTextRange：
// 组词中按回车=上屏候选词(return true)，无组词按回车=发送(return false)。

struct ChatInputTextView: UIViewRepresentable {
    @Binding var text: String
    var onSend: () -> Void
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> RSKGrowingTextView {
        let tv = RSKGrowingTextView()
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = .black
        tv.keyboardAppearance = .light   // v9.2：白底黑字——键盘浅色
        tv.placeholder = "输入消息..."
        tv.placeholderColor = UIColor(white: 0.62, alpha: 1)
        tv.minimumNumberOfLines = 1
        tv.maximumNumberOfLines = 4
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ uiView: RSKGrowingTextView, context: Context) {
        uiView.text = text
        height = uiView.intrinsicContentSize.height
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, RSKGrowingTextViewDelegate {
        var parent: ChatInputTextView
        init(_ p: ChatInputTextView) { parent = p }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.height = textView.intrinsicContentSize.height
        }
    }
}

// MARK: - v3.1.67：UIKit 文档选择器 delegate（真机稳定，替代 .fileImporter）

final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    static var assocKey = "DocumentPickerCoordinatorKey"
    let onPick: ([URL]) -> Void

    init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 用户取消，无操作
    }
}
