import SwiftUI
import Combine

// MARK: - v9：搜索服务设置页（移植 Kelivo search_services_page）
//
// 页面结构（对齐文档一节的截图）：
//   搜索服务 [+]
//     ── 搜索服务商 ──
//     ① Tavily   已连接 ›
//     ② Brave    未测试 ›
//     ── 网页读取 ──
//     读取方式   跟随搜索·Tavily ›
//     ── 通用设置 ──
//     启动时自动测连 [开关] / 最大结果数 − 5 + / 超时 − 30s +
//
// 与旧版（v7.5.0 WebSearchSettingsView）的差别：
//   · 服务商是**实例**（可多套并存、可增删、可改显示名），不再是 enum 单例
//   · 新增「网页读取方式」——跟随 / 本地 / 指定实例 / 关闭，跟随不支持 reader 时优雅降级
//   · 新增测连状态胶囊、启动自动测连、可调超时
//   · 至少保留一个服务商（删除按钮在只剩一个时禁用）

struct SearchServicesView: View {
    @ObservedObject private var cfg = SearchSettings.shared

    @State private var editing: SearchServiceOptions?
    @State private var isNew = false
    @State private var showFetchModeSheet = false
    @State private var testing: Set<String> = []
    @State private var testQuery = "TrollStore 最新版本"
    @State private var testResult = ""
    @State private var showDeleteConfirm: SearchServiceOptions?
    /// 跟随模式下当前服务商不支持 reader 时的显示名（抽出来，避免字符串插值里嵌字面量）
    private var fallbackFollowName: String { "本地抓取" }

    var body: some View {
        List {
            // v10：页首大标题卡（与「环境」页同一套排版）
            Section {
                XHeroHeader(icon: "magnifyingglass",
                            title: "搜索服务",
                            subtitle: "联网搜索与网页正文抓取")
            }
            servicesSection
            fetchModeSection
            generalSection
            testSection
        }
        .xGroupedPage()
        .navigationTitle("搜索服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isNew = true
                    editing = SearchServiceOptions(kind: .tavily)
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { svc in
            SearchServiceEditorView(service: isNew ? nil : svc,
                                    existing: isNew ? svc : nil,
                                    canDelete: cfg.services.count > 1,
                                    onDone: { apply($0) })
        }
        .confirmationDialog("网页读取方式", isPresented: $showFetchModeSheet, titleVisibility: .visible) {
            Button("跟随搜索 · \(cfg.followTarget?.displayName ?? fallbackFollowName)") {
                cfg.webFetchModeValue = nil
                cfg.save()
            }
            Button("本地直连抓取") {
                cfg.webFetchModeValue = "local"
                cfg.save()
            }
            ForEach(cfg.services.filter { $0.supportsReader }) { s in
                Button("指定 · \(s.displayName)") {
                    cfg.webFetchModeValue = s.id
                    cfg.save()
                }
            }
            Button("关闭（只给摘要）", role: .destructive) {
                cfg.webFetchModeValue = "off"
                cfg.save()
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("删除这个服务商？",
                            isPresented: Binding(get: { showDeleteConfirm != nil },
                                                 set: { if !$0 { showDeleteConfirm = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let s = showDeleteConfirm { cfg.delete(id: s.id) }
                showDeleteConfirm = nil
            }
            Button("取消", role: .cancel) { showDeleteConfirm = nil }
        } message: {
            if let s = showDeleteConfirm {
                Text("\(s.displayName) 的 Key 与配置会一起删除，不影响其它服务商。")
            }
        }
        .onAppear { autoTestIfNeeded() }
    }

    // MARK: 搜索服务商

    @ViewBuilder
    private var servicesSection: some View {
        Section {
            ForEach(Array(cfg.services.enumerated()), id: \.element.id) { idx, svc in
                SearchProviderRow(
                    service: svc,
                    isSelected: idx == cfg.selectedIndex,
                    status: status(of: svc),
                    onTap: {
                        isNew = false
                        editing = svc
                    },
                    onTest: { test(svc) },
                    onSelect: { cfg.select(id: svc.id) },
                    onDelete: { showDeleteConfirm = svc }
                )
            }
            .onDelete { offsets in
                // 至少留一个：删到只剩 0 个时直接拒绝（文档：至少保留一个服务商）
                guard cfg.services.count > offsets.count else { return }
                // 先把要删的 id 收集出来再删——每删一个数组就变短，
                // 边删边按下标取会拿到错的元素（甚至越界）
                let ids = offsets.compactMap { i -> String? in
                    guard cfg.services.indices.contains(i) else { return nil }
                    return cfg.services[i].id
                }
                for id in ids { cfg.delete(id: id) }
            }
            if cfg.services.isEmpty {
                Text("还没有服务商。点右上角 + 添加；必应 / DuckDuckGo 免费无需 Key。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            sectionHeader("搜索服务商")
        } footer: {
            Text("点行进入编辑；右侧 ⋯ 可测连 / 设为当前 / 删除。当前服务商决定 web.search 默认走哪家，失败仍会自动回退到其它可用引擎。至少保留一个。")
                .font(XType.section)
        }
    }

    // MARK: 网页读取

    @ViewBuilder
    private var fetchModeSection: some View {
        Section {
            Button { showFetchModeSheet = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                        .frame(width: 24)
                    Text("读取方式").font(XType.body).foregroundColor(.primary)
                    Spacer()
                    Text(cfg.webFetchModeLabel)
                        .font(XType.body)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            if cfg.effectiveWebFetchMode == .follow, cfg.followTarget == nil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("当前服务商不支持读取网页，已自动降级为本地抓取（JS 页面可能读不到）。")
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            sectionHeader("网页读取")
        } footer: {
            Text("snippet 不够时用此方式读取网页正文。跟随搜索 = 用当前搜索服务商的 reader（需支持）；不支持则退回本地直连抓取，JS 页面可能失败。")
                .font(XType.section)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 通用设置

    @ViewBuilder
    private var generalSection: some View {
        Section {
            Toggle(isOn: Binding(get: { cfg.autoTestOnLaunch },
                                 set: { cfg.autoTestOnLaunch = $0; cfg.save() })) {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 16))
                        .frame(width: 24)
                    Text("启动时自动测连")
                }
            }

            stepperRow(icon: "list.number", title: "最大结果数",
                       value: cfg.resultSize, unit: "",
                       min: 1, max: 20) { v in
                cfg.resultSize = v
                cfg.objectWillChange.send()
            }

            stepperRow(icon: "clock", title: "超时",
                       value: cfg.timeoutSeconds, unit: "s",
                       min: 5, max: 120, step: 5) { v in
                cfg.timeoutSeconds = v
                cfg.save()
                cfg.objectWillChange.send()
            }

            Stepper("搜索后自动读前 \(cfg.autoFetchTop) 条正文",
                    value: Binding(get: { cfg.autoFetchTop },
                                   set: { cfg.autoFetchTop = $0 }),
                    in: 0...3)
        } header: {
            sectionHeader("通用设置")
        } footer: {
            Text("自动读正文最多 3 条、每条 4000 字，并行抓取；值越大回复越慢。")
                .font(XType.section)
        }
    }

    // MARK: 实测

    @ViewBuilder
    private var testSection: some View {
        Section {
            HStack {
                TextField("测试搜索词", text: $testQuery)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                Button(testing.contains("__query__") ? "测试中…" : "测试") { runTest() }
                    .disabled(testing.contains("__query__") || testQuery.isEmpty)
            }
            if !testResult.isEmpty {
                Text(testResult)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            sectionHeader("实测")
        } footer: {
            Text("用当前选中的服务商跑一次真实搜索（含回退链），确认 Key 与网络可用。")
                .font(XType.section)
        }
    }

    // MARK: 组件

    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(XType.note).fontWeight(.semibold).foregroundColor(.secondary)
    }

    private func stepperRow(icon: String, title: String, value: Int, unit: String,
                            min lo: Int, max hi: Int, step: Int = 1,
                            onChange: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).frame(width: 24)
            Text(title).font(XType.body)
            Spacer()
            HStack(spacing: 10) {
                Button { if value - step >= lo { onChange(value - step) } } label: {
                    Image(systemName: "minus.circle").font(.system(size: 19))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(value - step >= lo ? .primary : .secondary.opacity(0.4))

                Text("\(value)\(unit)")
                    .font(XType.mono)
                    .frame(minWidth: 38)

                Button { if value + step <= hi { onChange(value + step) } } label: {
                    Image(systemName: "plus.circle").font(.system(size: 19))
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(value + step <= hi ? .primary : .secondary.opacity(0.4))
            }
        }
    }

    private func status(of svc: SearchServiceOptions) -> SearchRowStatus {
        if testing.contains(svc.id) { return .testing }
        switch cfg.connection[svc.id] {
        case .some(true): return .connected
        case .some(false): return .failed
        case .none: return .untested
        }
    }

    private func test(_ svc: SearchServiceOptions) {
        testing.insert(svc.id)
        SearchClient.testConnection(service: svc) { ok in
            testing.remove(svc.id)
            cfg.setConnection(ok, for: svc.id)
        }
    }

    private func runTest() {
        testing.insert("__query__")
        let q = testQuery
        DispatchQueue.global(qos: .userInitiated).async {
            let r = WebSearchService.search(query: q, provider: cfg.selectedService?.kind, limit: 5)
            DispatchQueue.main.async {
                testing.remove("__query__")
                if let err = r.error, r.hits.isEmpty {
                    testResult = "✗ \(r.provider)：\(err)"
                } else {
                    testResult = "✓ \(r.provider)：\(r.hits.count) 条"
                        + (r.answer?.isEmpty == false ? " · 带答案摘要" : "")
                }
            }
        }
    }

    private func autoTestIfNeeded() {
        guard cfg.autoTestOnLaunch else { return }
        for svc in cfg.services where svc.isUsable && cfg.connection[svc.id] == nil {
            test(svc)
        }
    }

    private func apply(_ result: SearchEditorResult) {
        if result.deleted {
            if let s = result.service { cfg.delete(id: s.id) }
            return
        }
        guard let s = result.service else { return }
        cfg.upsert(s)
    }
}

// MARK: - 服务商行（对应 _iosProviderRow）

enum SearchRowStatus {
    case testing, connected, failed, untested

    var label: String {
        switch self {
        case .testing: return "测试中"
        case .connected: return "已连接"
        case .failed: return "失败"
        case .untested: return "未测试"
        }
    }

    var fg: Color {
        switch self {
        case .testing: return DoubaoTheme.accent
        case .connected: return .green
        case .failed: return .orange
        case .untested: return .secondary
        }
    }
}

struct SearchProviderRow: View {
    let service: SearchServiceOptions
    let isSelected: Bool
    let status: SearchRowStatus
    var onTap: () -> Void
    var onTest: () -> Void
    var onSelect: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(service.displayName)
                        .font(.system(size: 17, weight: isSelected ? .medium : .regular))
                        .foregroundColor(.primary)
                    if isSelected {
                        Text("当前")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(UIColor.separator).opacity(0.7), lineWidth: 0.6))
                    }
                }
                HStack(spacing: 6) {
                    Text(status.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(status.fg)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(status.fg.opacity(0.12)))
                    Text(detailText)
                        .font(XType.note)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Menu {
                Button { onTest() } label: { Label("测试连接", systemImage: "bolt.horizontal") }
                if !isSelected {
                    Button { onSelect() } label: { Label("设为当前", systemImage: "checkmark") }
                }
                Divider()
                Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var detailText: String {
        if service.kind.needsEndpoint {
            return service.endpoint.isEmpty ? "未配置实例地址" : service.endpoint
        }
        if service.kind.needsKey {
            let n = service.apiKeys.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return n == 0 ? "未配置 API Key" : "\(n) 个 Key"
        }
        return "免费 · 无需配置"
    }
}

// MARK: - 编辑页（对应 search_service_editor_page）

struct SearchEditorResult {
    var service: SearchServiceOptions?
    var deleted: Bool = false
}

struct SearchServiceEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let service: SearchServiceOptions?
    /// 新建时预填的模板（kind 已选好）
    let existing: SearchServiceOptions?
    let canDelete: Bool
    var onDone: (SearchEditorResult) -> Void

    @State private var kind: SearchProvider
    @State private var customName: String
    @State private var keys: [String]
    @State private var endpoint: String
    @State private var user: String
    @State private var password: String
    @State private var enabled: Bool
    @State private var showKeys = false
    @State private var testStatus = ""
    @State private var testColor: Color = .secondary
    @State private var isTesting = false
    @State private var confirmDelete = false

    private let id: String

    init(service: SearchServiceOptions?, existing: SearchServiceOptions?,
         canDelete: Bool, onDone: @escaping (SearchEditorResult) -> Void) {
        self.service = service
        self.existing = existing
        self.canDelete = canDelete
        self.onDone = onDone
        let base = service ?? existing
        _kind = State(initialValue: base?.kind ?? .tavily)
        _customName = State(initialValue: base?.customName ?? "")
        _keys = State(initialValue: {
            let k = base?.apiKeys.filter { !$0.isEmpty } ?? []
            return k.isEmpty ? [""] : k
        }())
        _endpoint = State(initialValue: base?.endpoint ?? "")
        _user = State(initialValue: base?.basicUser ?? "")
        _password = State(initialValue: base?.basicPassword ?? "")
        _enabled = State(initialValue: base?.enabled ?? true)
        id = base?.id ?? UUID().uuidString
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(SearchProvider.allCases) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    TextField("显示名（可选）", text: $customName)
                        .autocorrectionDisabled()
                } header: {
                    Text("服务商")
                } footer: {
                    Text(kind.hint).font(XType.section)
                }

                if kind.needsKey {
                    Section {
                        ForEach(keys.indices, id: \.self) { i in
                            HStack {
                                if showKeys {
                                    TextField(i == 0 ? "主 API Key" : "备用 Key \(i)", text: $keys[i])
                                        .textFieldStyle(.plain)
                                        .autocapitalization(.none)
                                        .disableAutocorrection(true)
                                        .font(.system(.body, design: .monospaced))
                                } else {
                                    SecureField(i == 0 ? "主 API Key" : "备用 Key \(i)", text: $keys[i])
                                        .textFieldStyle(.plain)
                                        .font(.system(.body, design: .monospaced))
                                }
                                if i > 0 {
                                    Button { keys.remove(at: i) } label: {
                                        Image(systemName: "minus.circle").foregroundColor(.secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        Button { keys.append("") } label: {
                            Label("再加一个 Key（轮询使用）", systemImage: "plus")
                        }
                        Button { showKeys.toggle() } label: {
                            Label(showKeys ? "隐藏 Key" : "显示 Key", systemImage: showKeys ? "eye.slash" : "eye")
                        }
                    } header: {
                        Text("凭据")
                    } footer: {
                        Text("多个 Key 会按请求轮换，分摊额度。Key 只存在本机，不上传。")
                            .font(XType.section)
                    }
                }

                if kind.needsEndpoint {
                    Section {
                        TextField("https://searx.be", text: $endpoint)
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("用户名（可选）", text: $user)
                            .textFieldStyle(.plain)
                            .autocapitalization(.none)
                        TextField("密码（可选）", text: $password)
                            .textFieldStyle(.plain)
                    } header: {
                        Text("实例地址")
                    } footer: {
                        Text("需要在实例的 settings.yml 里开启 json 格式输出。")
                            .font(XType.section)
                    }
                }

                Section {
                    Toggle("启用此服务商", isOn: $enabled)
                    Button { test() } label: {
                        HStack {
                            Text("测试连接")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting)
                    if !testStatus.isEmpty {
                        Text(testStatus).font(XType.note).foregroundColor(testColor)
                    }
                } header: {
                    Text("操作")
                } footer: {
                    Text("测连会用当前填写的 Key 发一次最小搜索（1 条结果）。")
                        .font(XType.section)
                }

                if canDelete && service != nil {
                    Section {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Text("删除此服务商")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .xGroupedPage()
            .navigationTitle(service == nil ? "添加服务商" : "编辑服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                }
            }
            .confirmationDialog("删除服务商？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    onDone(SearchEditorResult(service: service, deleted: true))
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
    }

    private func makeService() -> SearchServiceOptions {
        var s = service ?? SearchServiceOptions(kind: kind, id: id)
        s.id = id
        s.kind = kind
        s.customName = customName.trimmingCharacters(in: .whitespaces)
        s.apiKeys = keys.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.endpoint = endpoint.trimmingCharacters(in: .whitespaces)
        s.basicUser = user
        s.basicPassword = password
        s.enabled = enabled
        return s
    }

    private func save() {
        onDone(SearchEditorResult(service: makeService()))
        dismiss()
    }

    private func test() {
        isTesting = true
        testStatus = "正在测试…"
        testColor = .secondary
        let svc = makeService()
        SearchClient.testConnection(service: svc) { ok in
            isTesting = false
            testStatus = ok ? "连接成功" : "连接失败：检查 Key / 网络 / 实例地址"
            testColor = ok ? .green : .red
        }
    }
}

// MARK: - 测连实现（对应 _testConnection）

enum SearchClient {
    /// 用 1 条结果的最小查询验证连通性。
    /// 直接打该实例的接口（不走 WebSearchService 的回退链），否则别的引擎成功会掩盖这把 Key 失效。
    static func testConnection(service: SearchServiceOptions,
                               completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = probe(service)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private static func probe(_ s: SearchServiceOptions) -> Bool {
        switch s.kind {
        case .bing:
            let (html, _) = WebSearchService.getText("https://cn.bing.com/search?q=test&count=1")
            return (html?.count ?? 0) > 200
        case .duckduckgo:
            let (html, _) = WebSearchService.getText("https://html.duckduckgo.com/html/?q=test")
            return (html?.count ?? 0) > 200
        case .searxng:
            var base = s.endpoint.trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty else { return false }
            if base.hasSuffix("/") { base.removeLast() }
            var headers: [String: String] = [:]
            if !s.basicUser.isEmpty {
                let token = Data("\(s.basicUser):\(s.basicPassword)".utf8).base64EncodedString()
                headers["Authorization"] = "Basic \(token)"
            }
            let (json, _) = WebSearchService.getJSON("\(base)/search?q=test&format=json", headers: headers)
            return json != nil
        default:
            guard s.hasKey else { return false }
            // 用各家的最小搜索请求探测（与真实搜索同一条路径，测出来的结果才算数）
            let r = WebSearchService.search(query: "connectivity test",
                                            provider: s.kind,
                                            limit: 1,
                                            serviceOverride: s)
            // 有结果 / 有答案摘要 / 没报错（有的引擎空结果不报错）都算通
            if !r.hits.isEmpty { return true }
            if r.answer?.isEmpty == false { return true }
            return r.error == nil
        }
    }
}
