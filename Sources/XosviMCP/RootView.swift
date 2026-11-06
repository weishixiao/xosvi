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
    // 会话列表用 ScrollView+LazyVStack 而非 List（为去掉行间分隔线），
    // List 的 .swipeActions 用不了，只能自己做手势。
    // 注意：这些状态必须在 ConversationDrawerView 内——会话列表属于本视图，
    // 放到 RootView 里会 cannot find in scope。
    @State private var swipedId: UUID?
    @State private var swipeOffset: CGFloat = 0
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
        .background(Color(uiColor: .systemGroupedBackground))   // 与设置页/二级页同一底色
        .onAppear(perform: refreshReadiness)
    }

    /// v9.11：顶部统一头部 + 搜索框/编辑键同一行（搜索框与编辑键仍并排）
    /// 右上角圆圈 X 关闭键已删除；抽屉用点遮罩/侧滑关闭。
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 抽屉顶部统一头部（与设置页二级页同一套 XHeroHeader）
            XHeroHeader(icon: "bubble.left.and.bubble.right",
                        title: L10n.t("drawer_title"),
                        subtitle: L10n.t("drawer_count")
                            .replacingOccurrences(of: "{n}", with: "\(store.conversations.count)"))
            HStack(spacing: 10) {
                searchBar
                // 编辑（新建会话）——移到最右侧，与搜索框同一条水平线
                Button(action: {
                    withAnimation { ui.drawerOpen = false }
                    store.newConversation()
                    NotificationCenter.default.post(name: .tmNewConversation, object: nil)
                }) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
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

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(XType.note)
            TextField(L10n.t("drawer_search"), text: $searchText)
                .font(XType.body)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        // 胶囊形，填充用系统卡片色（深色模式自适应）
        .background(Capsule(style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground)))
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(groupedConversations, id: \.key) { group in
                    Text(group.key)
                        .font(XType.section)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 4)

                    ForEach(group.items) { conv in
                        swipableRow(conv)
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

    private func deleteSingle(_ id: UUID) {
        guard let idx = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.delete(at: IndexSet(integer: idx))
        if swipedId == id { swipedId = nil; swipeOffset = 0 }
    }

    // MARK: - v6.9.11 侧滑删除行

    /// 会话列表用的是 ScrollView+LazyVStack（为去掉 List 的分隔线），
    /// `.swipeActions` 只对 List 生效，所以这里自己做左滑：
    /// - 左滑超过阈值 → 停靠到露出删除按钮的位置
    /// - 再左滑一点或点删除按钮 → 删除
    /// - 右滑或点其他行 → 收回
    /// 同一时刻只允许一行滑开（swipedId 全局唯一）。
    private let swipeReveal: CGFloat = 76    // 删除按钮露出宽度
    private let swipeCommit: CGFloat = 132   // 超过则直接触发删除

    @ViewBuilder
    private func swipableRow(_ conv: ChatConversation) -> some View {
        let isOpen = swipedId == conv.id
        let offset = isOpen ? swipeOffset : 0

        ZStack(alignment: .trailing) {
            // 底层：删除按钮
            Button {
                withAnimation(.easeOut(duration: 0.18)) { deleteSingle(conv.id) }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill").font(.system(size: 15, weight: .semibold))
                    Text(L10n.t("drawer_delete")).font(.system(size: 10))
                }
                .foregroundColor(.white)
                .frame(width: swipeReveal)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(offset < -8 ? 1 : 0)
            .allowsHitTesting(offset < -8)

            // 上层：会话行，可左右拖
            Button(action: {
                // 已滑开时点击先收回，不切换会话
                if isOpen {
                    withAnimation(.easeOut(duration: 0.2)) { swipedId = nil; swipeOffset = 0 }
                } else {
                    store.select(conv.id)
                    withAnimation { ui.drawerOpen = false }
                }
            }) {
                conversationRow(conv)
                    .background(
                        Group {
                            if store.selectedId == conv.id {
                                // 选中行：白色卡片叠加一层淡墨色高亮（深色模式自适应）
                                Color(uiColor: .systemBackground)
                                    .overlay(Color.primary.opacity(0.07))
                            } else {
                                Color(uiColor: .systemBackground)
                            }
                        }
                    )
                    // 行卡片外框：系统分隔色描边，与设置页卡片观感一致
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(store.selectedId == conv.id
                                        ? Color.primary.opacity(0.22)
                                        : Color(uiColor: .separator).opacity(0.6),
                                    lineWidth: 0.8)
                    )
                    .cornerRadius(16)
            }
            .buttonStyle(PlainButtonStyle())
            .offset(x: offset)
            .highPriorityGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        // 只响应水平拖，且左滑为主；右滑用于收回已滑开的行
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        let base: CGFloat = isOpen ? -swipeReveal : 0
                        // 越界阻尼：最多滑到 swipeCommit*1.3
                        var t = base + value.translation.width
                        t = min(0, max(t, -swipeCommit * 1.3))
                        swipedId = conv.id
                        swipeOffset = t
                    }
                    .onEnded { value in
                        let final = swipeOffset
                        if final < -swipeCommit {
                            withAnimation(.easeOut(duration: 0.18)) { deleteSingle(conv.id) }
                        } else if final < -swipeReveal * 0.5 {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                swipedId = conv.id
                                swipeOffset = -swipeReveal
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                swipedId = nil
                                swipeOffset = 0
                            }
                        }
                    }
            )
            .contextMenu {
                // iOS14 兼容：不用 Button(role:)
                Button(action: { deleteSingle(conv.id) }) {
                    Label(L10n.t("drawer_delete"), systemImage: "trash")
                }
            }
        }
        .clipped()
    }

    /// v7.6.1：会话行只显示标题 + 右侧时间/•••
    private func conversationRow(_ conv: ChatConversation) -> some View {
        let isSel = store.selectedId == conv.id
        return HStack(alignment: .center, spacing: 8) {
            // v7.6.1：只显示标题（用户要求去掉消息内容预览）
                Text(conv.title)
                    .font(XType.body)
                    .fontWeight(isSel ? .semibold : .regular)
                    // 标题用系统主文字色（深色模式自适应）
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            Spacer(minLength: 6)
            // v7.6.2：标题右侧不再显示时间（分组标题已表明日期）；选中行保留 ••• 菜单
            if isSel {
                Menu {
                    Button(action: { deleteSingle(conv.id) }) {
                        Label("删除对话", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        // v9.3：固定行高——选中行多出 ••• 菜单会改变行高，LazyVStack 滚动复用时
        // 行高突变导致标题重叠；固定高度后复用稳定。
        .frame(minHeight: 50)
    }

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

    private var bottomWorkbench: some View {
        // v6.6.7：删除本机环境入口卡片；设置齿轮移到此界面左边（用户要求）
        HStack(spacing: 12) {
            Button(action: {
                withAnimation { ui.drawerOpen = false }
                ui.settingsPresented = true
            }) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .cornerRadius(14)
                    .contentShape(Rectangle())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, max(bottomSafeArea, 12))
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}
