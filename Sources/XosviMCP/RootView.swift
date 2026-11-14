import SwiftUI
import UIKit

final class AppUIState: ObservableObject {
    static let shared = AppUIState()
    @Published var drawerOpen = false
    @Published var settingsPresented = false
    @Published var settingsJumpToModels = false
    // v4.4.16：底部"指令"胶囊 → 打开设置并跳到系统指令(SystemPromptsView)页
    @Published var settingsJumpToSystemPrompts = false
    @Published var macroPresented = false
    // v3.0.76：输入框上方快捷标签
    @Published var quickTerminalPresented = false
    @Published var quickToolsPresented = false
    @Published var quickSkillsPresented = false
    @Published var quickFilesPresented = false
}

/// v7.6.2：会话列表按日期分组的容器
struct DateGroup: Identifiable {
    let key: String
    var items: [ChatConversation]
    var id: String { key }
}

struct RootView: View {
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var lang = LanguageManager.shared   // v2.9.76：语言切换全局刷新
    // v2.9.126：深链导入确认页（xosvi://import?...）
    @ObservedObject private var pendingImport = PendingImport.shared
    @State private var importResult: String?
    // v4.3.44：QuickLook 分享中间层状态（侧载环境分享面板安全路径）
    @ObservedObject private var shareCenter = ShareCenter.shared

    var body: some View {
        ZStack {
            ChatRootView()
                .disabled(ui.drawerOpen)

            if ui.drawerOpen {
                Color.black
                    .opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { ui.drawerOpen = false } }
            }

            GeometryReader { geo in
                HStack(spacing: 0) {
                    ConversationDrawerView()
                        .frame(width: drawerWidth(for: geo))
                        .offset(x: ui.drawerOpen ? 0 : -drawerWidth(for: geo))
                        .animation(.easeInOut)
                        .edgesIgnoringSafeArea(.vertical)
                        .allowsHitTesting(ui.drawerOpen)
                    Spacer()
                }
            }
        }
        // v7.5.0：内置浏览器已整体删除（用户要求）
        // v2.9.76：设置改全屏（去掉 sheet 半屏 + 顶部 grabber），子页面头部对齐
        .fullScreenCover(isPresented: Binding(
            get: { ui.settingsPresented },
            set: { ui.settingsPresented = $0 }
        )) {
            SettingsView()
        }
        // v2.9.142：宏管理页（聊天输入框「🎬 宏」入口）
        .fullScreenCover(isPresented: Binding(
            get: { ui.macroPresented },
            set: { ui.macroPresented = $0 }
        )) {
            MacroView()
        }
        // v2.9.76：语言切换后全局重建视图
        .id(lang.language.rawValue)
        // v2.9.126：深链导入确认页——暂存配置后弹窗，确认才写入
        .onReceive(NotificationCenter.default.publisher(for: PendingImport.didStageNotification)) { note in
            if let result = note.userInfo?["result"] as? String {
                importResult = result == "imported" ? "已导入并切换" : "重复配置，未导入"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { importResult = nil }
            }
        }
        .alert(isPresented: Binding(
            get: { pendingImport.staged != nil },
            set: { if !$0 { pendingImport.cancel() } }
        )) {
            if let cfg = pendingImport.staged {
                return Alert(
                    title: Text(L10n.t("ui_49")),
                    message: Text(L10n.t("ui_170", cfg.name, cfg.model, cfg.baseURL)),
                    primaryButton: .default(Text(L10n.t("ui_48")), action: { pendingImport.confirm() }),
                    secondaryButton: .cancel(Text(L10n.t("ui_40")), action: { pendingImport.cancel() })
                )
            }
            return Alert(title: Text(""), dismissButton: .default(Text("OK")))
        }
        .overlay(Group {
            if let result = importResult {
                Text(result)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.bottom, 120)
                    .transition(.opacity)
            }
        }, alignment: .bottom)
        // v4.3.44：剪贴板/写入提示（分享降级或失败时的用户反馈）
        .overlay(alignment: .bottom) {
            if let notice = shareCenter.clipboardNotice {
                Text(notice)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.blue.opacity(0.85))
                    .cornerRadius(10)
                    .padding(.bottom, 100)
                    .transition(.opacity)
            }
        }
    }

    private func drawerWidth(for geo: GeometryProxy) -> CGFloat {
        // v7.6.0（DeepSeek）：抽屉加宽，对齐参考截图（左侧留出窄条主界面）
        min(geo.size.width * 0.86, 380)
    }
}

struct ConversationDrawerView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var ui = AppUIState.shared
    @ObservedObject private var probe = DeviceProbe.shared
    @State private var searchText = ""
    // v6.9.11：侧滑删除——记录当前滑开的会话 id 与位移（同一时间只允许一行滑开）。
    // 会话列表用 ScrollView+VStack 而非 List（为去掉行间分隔线），
    // List 的 .swipeActions 用不了，只能自己做手势。
    // 注意：这些状态必须在 ConversationDrawerView 内——会话列表属于本视图，
    // 放到 RootView 里会 cannot find in scope。
    // v9.15：位移已下放到每一行内部（ConversationRow 的 @State），这里只留「哪一行被滑开」
    // 这个全局唯一标记——手势过程中不再逐帧改父视图状态，整张列表不会被反复重算。
    @State private var swipedId: UUID?
    // v2.9.166：deviceReady 改为计算属性直接读 DeviceProbe.shared.lastReport——
    // 旧版 @State 只在 onAppear 读一次：用户点开检测页跑完（全绿）返回后，
    // 左下角仍是旧感叹号，这就是"环境通过了还显示感叹号"的根因。
    // @ObservedObject 观察 lastReport @Published，检测页/启动检测完成自动同步。
    private var deviceReady: Bool? { probe.lastReport?.ready }

    private var filtered: [ChatConversation] {
        if searchText.isEmpty { return store.conversations }
        return store.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.messages.contains { $0.content.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // v7.6.1：搜索框并入 header 同一行
            header
            conversationList
            bottomWorkbench
        }
        .background(XColor.page)   // 与设置页/二级页同一底色（v10.2：走底座令牌）
        .onAppear(perform: refreshReadiness)
    }

    /// v9.11：顶部统一头部 + 搜索框（搜索框独占一行）
    /// 右上角圆圈 X 关闭键已删除；抽屉用点遮罩/侧滑关闭。
    /// v10.5：新建会话键移到底栏设置齿轮右侧（用户要求），头部只留标题与搜索框。
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 抽屉顶部统一头部（与设置页二级页同一套 XHeroHeader）
            XHeroHeader(icon: "bubble.left.and.bubble.right",
                        title: L10n.t("drawer_title"),
                        subtitle: L10n.t("drawer_count")
                            .replacingOccurrences(of: "{n}", with: "\(store.conversations.count)"))
            searchBar
        }
        .padding(.horizontal, 16)
        .padding(.top, topSafeArea + 6)
        .padding(.bottom, 10)
    }

    /// v2.9.12：状态栏安全区高度（抽屉 ignoredSafeArea 后需手动避让系统时间）
    private var topSafeArea: CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.top ?? 0
    }

    /// v7.6.0：底部安全区（底栏不再写死 24pt，避免刘海机型被 Home 条压住）
    private var bottomSafeArea: CGFloat {
        UIApplication.shared.windows.first?.safeAreaInsets.bottom ?? 0
    }

    /// v10.2：搜索框改用底座令牌（Minis 侧栏同款：36 高 / 12 圆角 / 次级填充），
    /// 页面里不再手写 HStack + Capsule。
    private var searchBar: some View {
        XSearchField(text: $searchText, placeholder: L10n.t("drawer_search"))
    }

    private var countLabel: some View {
        HStack {
            Text(L10n.t("drawer_count").replacingOccurrences(of: "{n}", with: "\(store.conversations.count)"))
                .font(XType.note)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var conversationList: some View {
        // v7.6.2：按日期分组，每组上方一条灰色分组标题（今天 / 昨天 / 30 天内 / 2026 年 9 月 …）
        // v9.15：由 LazyVStack 换成普通 VStack。
        // 原实现里滚动会「重影 / 折叠」：延迟容器按可见范围创建、滚出即销毁格子，
        // 而行上挂着 DragGesture + 行内 offset 动画，格子被回收重建时上一屏的渲染没清干净，
        // 就叠在新行下面。普通 VStack 一次性布局、格子不复用，从根上不会出现这种叠影。
        // 代价是会话多时要一次建完（只有标题一行文本，几十上百条的开销可以忽略）。
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groupedConversations, id: \.key) { group in
                    // 分组标题单独成块，滚动时不会和行混在一起
                    VStack(alignment: .leading, spacing: 0) {
                        Text(group.key)
                            .font(XType.groupHeader)
                            .foregroundColor(XColor.subtext)
                            .padding(.horizontal, XMetric.gutter)
                            .padding(.top, 14)
                            .padding(.bottom, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(group.items) { conv in
                                DrawerConversationRow(
                                    title: conv.title,
                                    subtitle: Self.previewText(conv),
                                    meta: Self.rowTime(conv.updatedAt),
                                    selected: store.selectedId == conv.id,
                                    deleteTitle: L10n.t("drawer_delete"),
                                    reveal: swipeReveal,
                                    commit: swipeCommit,
                                    isSwiped: swipedId == conv.id,
                                    onSwipeChange: { open in
                                        if open {
                                            swipedId = conv.id
                                        } else if swipedId == conv.id {
                                            swipedId = nil
                                        }
                                    },
                                    onOpen: {
                                        store.select(conv.id)
                                        withAnimation { ui.drawerOpen = false }
                                    },
                                    onDelete: { deleteSingle(conv.id) },
                                    onExport: {
                                        // v10.5：先收抽屉再弹自建分享菜单（ShareCenter 自己延迟 0.28s 呈现）
                                        withAnimation { ui.drawerOpen = false }
                                        AuditLog.shared.log("drawer.export", detail: conv.title)
                                        ConversationExport.present(conv)
                                    },
                                    exportTitle: L10n.t("btn_export")
                                )
                                .id(conv.id)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    /// 日期分组键（按 updatedAt 倒序，组内同样倒序）
    private var groupedConversations: [DateGroup] {
        var groups: [DateGroup] = []
        for conv in filtered {
            let key = Self.groupKey(conv.updatedAt)
            if let i = groups.firstIndex(where: { $0.key == key }) {
                groups[i].items.append(conv)
            } else {
                groups.append(DateGroup(key: key, items: [conv]))
            }
        }
        return groups
    }

    /// 分组规则：今天 / 昨天 / 30 天内 / 「yyyy 年 M 月」
    static func groupKey(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 30 {
            return "30 天内"
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy 年 M 月"
        return f.string(from: d)
    }

    /// v10.2：行内预览——取最后一条有正文的消息，压平换行（Minis SessionRow 的 subtitle）
    static func previewText(_ conv: ChatConversation) -> String {
        for msg in conv.messages.reversed() {
            let flat = msg.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !flat.isEmpty {
                return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
            }
        }
        return "还没有消息"
    }

    /// v10.2：尾部相对时间（Minis SessionRow 的 relativeDate）——今天只给时刻，
    /// 昨天给「昨天」，更早给「M月d日」。分组标题已经给了大粒度，这里只做细分。
    static func rowTime(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: d)
    }

    private func deleteSingle(_ id: UUID) {
        guard let idx = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.delete(at: IndexSet(integer: idx))
    }

    // MARK: - 侧滑删除行的常量

    private let swipeReveal: CGFloat = 76    // 删除按钮露出宽度
    private let swipeCommit: CGFloat = 132   // 超过则直接触发删除

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { filtered[$0].id }
        let idxSet = IndexSet(store.conversations.enumerated().compactMap { ids.contains($0.element.id) ? $0.offset : nil })
        store.delete(at: idxSet)
    }

    private var deviceReadinessBar: some View {
        // 已并入 bottomWorkbench 精简入口（v2.9.9），此实现保留备用
        EmptyView()
    }

    private var readinessText: String {
        if let ready = deviceReady { return ready ? L10n.t("drawer_ready") : L10n.t("drawer_env_limited") }
        return L10n.t("drawer_probe")
    }

    /// v2.9.166：环境未就绪时显示首个失败项简短原因（如"Entitlements 未生效"），
    /// 而不是笼统感叹号——用户要求"不打X✔只做简单提醒"。
    private var failureHint: String {
        if deviceReady == true { return L10n.t("drawer_ready_short") }
        if let report = probe.lastReport {
            for c in report.checks where !c.passed && !c.infoOnly {
                return c.label
            }
        }
        return "检测环境"
    }

    private func refreshReadiness() {
        // 轻量读取缓存报告，避免每次打开抽屉都全量扫描
        // （@ObservedObject 已自动同步，此方法仅用于首次出现时兜底）
        _ = probe.lastReport?.ready
    }

    /// 设置齿轮（左下角第一枚）
    private var settingsButton: some View {
        Button(action: {
            withAnimation { ui.drawerOpen = false }
            ui.settingsPresented = true
        }) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(XColor.text)
                .frame(width: XMetric.fab, height: XMetric.fab)
                .background(
                    RoundedRectangle(cornerRadius: XRadius.row, style: .continuous)
                        .fill(XColor.fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(L10n.t("settings"))
    }

    /// 新建会话（v10.5：由头部右上角移到底栏、设置齿轮右侧，同尺寸同间距）
    /// v10.6：反色实心底（浅色下是纯黑块）太扎眼，改回次级填充，与齿轮只差一档灰度。
    private var newConversationButton: some View {
        Button(action: {
            withAnimation { ui.drawerOpen = false }
            store.newConversation()
            NotificationCenter.default.post(name: .tmNewConversation, object: nil)
        }) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(XColor.text)
                .frame(width: XMetric.fab, height: XMetric.fab)
                .background(
                    RoundedRectangle(cornerRadius: XRadius.row, style: .continuous)
                        .fill(XColor.fillStrong)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(L10n.t("drawer_new"))
    }

    private var bottomWorkbench: some View {
        // v6.6.7：删除本机环境入口卡片
        // v10.5：新建会话键从头部移来，紧挨齿轮右侧——两枚同 52×52、间距 12
        // v10.6：整组靠右（用户要求「设置键往右移」），黑底实心改次级填充
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            settingsButton
            newConversationButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // v10.2：底栏改用底座面修饰器（Minis 的 surface 三件套之一）
        .xSurface(radius: XRadius.sheet, fill: XColor.card, stroke: XColor.hairline)
        .padding(.horizontal, XMetric.gutter)
        .padding(.bottom, max(bottomSafeArea, 12))
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
