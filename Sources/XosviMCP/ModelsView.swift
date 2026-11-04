import SwiftUI
import UIKit   // v2.9.85：UIPasteboard 复制推荐链接
import UniformTypeIdentifiers  // v2.9.107：配置导入/导出

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var editing: ModelConfig?
    @State private var isNewModel = false
    // v2.9.107：用量统计 / 导入导出
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDoc: ConfigDoc?
    @State private var importMessage = ""
    @State private var showImportMessage = false

    var body: some View {
        VStack(spacing: 0) {
            // v6.2.8：按用户要求删除两张推广卡片（推荐破甲站/推荐中转站）
            // RecommendCardArea()  ← 已移除

            List {
                if store.configs.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text(L10n.t("ui_50"))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 40)
                            Spacer()
                        }
                    }
                } else {
                    // v2.9.107：按分组展示（默认组优先，其余按字典序）
                    let groups = groupedKeys()
                    ForEach(groups, id: \.self) { g in
                        Section(header: HStack {
                            Text(g)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(L10n.t("ui_155", count(in: g)))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }) {
                            ForEach(configs(in: g)) { cfg in
                                ModelRow(config: cfg)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        isNewModel = false
                                        editing = cfg
                                    }
                            }
                            .onDelete { offsets in delete(in: g, at: offsets) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
        }
        .navigationTitle("模型 API")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // v7.13.1：右上角只留「+」——剪贴板导入与用量统计入口删掉（用户要求）
                Button(action: {
                    isNewModel = true
                    editing = ModelConfig(name: "", provider: "custom", apiProtocol: "OpenAI Chat Completions", baseURL: "", apiKey: "", model: "")
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        // v7.13.1：用量统计入口已按用户要求删除
        .sheet(item: $editing, onDismiss: { editing = nil }) { cfg in
            // v2.9.14：改用 .sheet(item:) 绑定。iOS14 的 .sheet(isPresented:)+闭包捕获
            // 存在时序竞争——sheet 内容首次构建可能读到旧 editing(nil)，先用默认预设渲染，
            // 之后才切到真实配置（表现为"先显示 gpt-4o，很久才变成 5.6"）。
            // .sheet(item:) 在 item 变化时以新值重建内容，机制上消除该问题。
            // 注：iOS 14.0-14.4 多 sheet 只生效最后一个声明，因此编辑弹窗必须放最后。
            ModelEditorView(config: isNewModel ? nil : cfg) { newCfg in
                if ModelStore.shared.configs.contains(where: { $0.id == newCfg.id }) {
                    ModelStore.shared.update(newCfg)
                } else {
                    ModelStore.shared.add(newCfg)
                }
            }
            .id(cfg.id)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        let r = store.importJSON(text)
                        if r.failed > 0 {
                            importMessage = "导入完成：成功 \(r.ok) 个，失败 \(r.failed) 个"
                        } else {
                            importMessage = "导入完成：成功 \(r.ok) 个"
                        }
                    } else {
                        importMessage = "无法读取所选文件"
                    }
                } else {
                    importMessage = "无法访问所选文件"
                }
            case .failure:
                importMessage = "已取消导入"
            }
            showImportMessage = true
        }
        .fileExporter(isPresented: $showingExporter, document: exportDoc, contentType: .json, defaultFilename: "Xosvi-models-\(Date().timeIntervalSince1970)") { _ in }
        .alert(isPresented: $showImportMessage) {
            Alert(title: Text(L10n.t("ui_100")), message: Text(importMessage), dismissButton: .default(Text(L10n.t("ui_44"))))
        }
    }

    // MARK: v2.9.107 分组辅助

    private func groupedKeys() -> [String] {
        var seen: [String] = []
        for c in store.configs where !seen.contains(c.group) { seen.append(c.group) }
        return seen.sorted {
            if $0 == "默认" { return true }
            if $1 == "默认" { return false }
            return $0 < $1
        }
    }

    private func configs(in group: String) -> [ModelConfig] {
        store.configs.filter { $0.group == group }
    }

    private func count(in group: String) -> Int {
        store.configs.filter { $0.group == group }.count
    }

    private func delete(in group: String, at offsets: IndexSet) {
        for i in offsets {
            let list = configs(in: group)
            if i < list.count, let idx = store.configs.firstIndex(where: { $0.id == list[i].id }) {
                store.delete(at: IndexSet(integer: idx))
            }
        }
    }
}

struct ModelRow: View {
    let config: ModelConfig
    // v2.9.107：行内测速 + 熔断状态 + 一键切换
    @State private var testing = false
    @State private var latencyText = ""
    @State private var latencyColor: Color = .secondary

    var body: some View {
        let info = ModelStore.shared.breaker(for: config.id).stateInfo
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(config.name)
                        .font(.system(size: 15, weight: config.isDefault ? .medium : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if config.isDefault {
                        Text("默认")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(UIColor.separator).opacity(0.7), lineWidth: 0.6)
                            )
                    }
                    if info.state != .closed {
                        Text(info.state.label)
                            .font(.system(size: 10.5))
                            .foregroundColor(.red)
                    }
                }
                Text("\(config.provider) · \(config.model)")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !latencyText.isEmpty {
                    Text(latencyText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(latencyColor)
                }
            }

            Spacer(minLength: 6)

            if testing {
                ProgressView().scaleEffect(0.7)
            }

            // 四个动作收进一个菜单，行里只剩文字（原来 4 个彩色图标太吵）
            Menu {
                Button {
                    speedTest()
                } label: { Label("测速", systemImage: "gauge") }
                Button {
                    duplicate()
                } label: { Label("复制为副本", systemImage: "doc.on.doc") }
                Button {
                    ShareCenter.shared.presentShareMenuText(makeDeepLink())
                } label: { Label("分享配置链接", systemImage: "link") }
                if !config.isDefault {
                    Divider()
                    Button {
                        activate()
                    } label: { Label("设为当前模型", systemImage: "checkmark") }
                }
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
    }


    /// v2.9.107：一键切换为当前使用模型
    private func activate() {
        var c = config
        c.isDefault = true
        ModelStore.shared.update(c)
        ModelStore.shared.markUsed(config.id.uuidString)
        ModelStore.shared.breaker(for: config.id).reset()
    }

    /// v2.9.108：复制为副本（快速起一个新配置改参数，借鉴 cc-switch duplicate）
    private func duplicate() {
        var c = config
        c.id = UUID()
        c.name = config.name + " 副本"
        c.isDefault = false
        ModelStore.shared.add(c)
        AuditLog.shared.log("model.duplicate", detail: config.name)
    }

    /// v2.9.126：生成导入深链（v4.3.42 改为纯函数，由 ShareLink/按钮调用）
    private func makeDeepLink() -> String {
        let enc = { (s: String) in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        var link = "xosvi://import?baseURL=\(enc(config.baseURL))&model=\(enc(config.model))&name=\(enc(config.name))"
        if !config.apiKey.isEmpty { link += "&apiKey=\(enc(config.apiKey))" }
        link += "&auth=\(enc(config.authMethod))&group=\(enc(config.group))&protocol=\(enc(config.apiProtocol))"
        if config.temperature != 0.7 { link += "&temperature=\(config.temperature)" }
        if config.maxTokens != 2048 { link += "&maxTokens=\(config.maxTokens)" }
        if config.contextTokens != 16000 { link += "&contextTokens=\(config.contextTokens)" }
        return link
    }

    /// v2.9.107：供应商测速（GET /models，8s 超时）
    private func speedTest() {
        testing = true
        latencyText = ""
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            latencyText = "Base URL 无效"
            latencyColor = .red
            testing = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        setHTTPMethod("GET", on: &req)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                testing = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    latencyText = "测速失败 · \(ms)ms"
                    latencyColor = .red
                } else {
                    latencyText = "延迟 \(ms)ms"
                    latencyColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}

// MARK: - v4.3.28 推荐卡片区（圆角 + 距屏幕边缘留空隙；破甲站第一、中转站第二）
// 说明：卡片保持移出 List 内框（无分组白框），但恢复圆角并左右留边距，
// 渐变卡片距屏幕边缘约 16pt，视觉上不再贴边。

struct RecommendCardArea: View {
    var body: some View {
        VStack(spacing: 10) {
            // 推荐破甲站（第一张）
            RecommendCard(
                icon: "shield.fill",
                title: L10n.t("armor_card_title"),
                message: L10n.t("armor_card_body"),
                link: "https://caibaizz.xyz/register?aff=9MBDRSGSARN7",
                colors: [Color(red: 0.55, green: 0.28, blue: 0.85),
                         Color(red: 0.86, green: 0.30, blue: 0.55)])
            // 推荐中转站（第二张）
            RecommendCard(
                icon: "sparkles",
                title: L10n.t("relay_card_title"),
                message: L10n.t("relay_card_body"),
                link: "https://botcf.com/register?aff=bJMk",
                colors: [Color(red: 0.16, green: 0.44, blue: 0.92),
                         Color(red: 0.0, green: 0.74, blue: 0.95)])
        }
        .padding(.horizontal, 16)   // v4.3.28：左右距屏幕边缘留空隙
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// 通用推荐卡片：圆角渐变背景 + 距边缘空隙，标题+正文+可复制链接
/// 注意：正文属性命名 message——不能叫 body（与 View.body 计算属性重名，编译报
/// "invalid redeclaration of 'body'"，CI 实测踩坑）。
struct RecommendCard: View {
    let icon: String
    let title: String
    let message: String
    let link: String
    let colors: [Color]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
            }
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(link)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = link
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Label(copied ? L10n.t("relay_card_copied") : L10n.t("relay_card_copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(copied ? .white : Color(red: 0.82, green: 0.95, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: colors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(14)   // v4.3.28：卡片圆角（不再贴边直角）
    }
}

// MARK: - 模型 API 编辑器（原版风格）

struct ModelEditorView: View {
    @Environment(\.presentationMode) var presentationMode
    let config: ModelConfig?
    let onSave: (ModelConfig) -> Void

    @State private var name: String
    @State private var provider: String
    @State private var apiProtocol: String
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var model: String
    @State private var authMethod: String
    @State private var isDefault: Bool
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var contextTokens: Int
    @State private var group: String
    /// v3.5.13：参数名别名映射编辑（"标准键:供应商键"逗号分隔，如 max_tokens:max_completion_tokens）
    @State private var paramAliasesText: String

    @State private var showKey = false
    @State private var testStatus = ""
    @State private var testColor: Color = .secondary
    @State private var isTesting = false
    @State private var fetchedModels: [String] = []
    @State private var showingModelPicker = false
    @State private var savedFlag = false
    /// v8：表单校验错误提示（防呆——空配置不再落库）
    @State private var validationError = ""

    private let providers = ["openai", "deepseek", "anthropic", "custom"]

    // 在 init 中一次性初始化，避免 iOS 14 上 .onAppear 重复触发把用户输入冲回默认值
    init(config: ModelConfig?, onSave: @escaping (ModelConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        let p = ModelConfig.providerPresets.first
        _name = State(initialValue: config?.name ?? (p?.name ?? ""))
        _provider = State(initialValue: config?.provider ?? (p?.provider ?? "custom"))
        _apiProtocol = State(initialValue: config?.apiProtocol ?? (p?.protocol ?? "OpenAI Chat Completions"))
        _baseURL = State(initialValue: config?.baseURL ?? (p?.baseURL ?? ""))
        _apiKey = State(initialValue: config?.apiKey ?? "")
        _model = State(initialValue: config?.model ?? (p?.model ?? ""))
        _authMethod = State(initialValue: config?.authMethod ?? (p?.auth ?? "Bearer"))
        _isDefault = State(initialValue: config?.isDefault ?? false)
        _temperature = State(initialValue: config?.temperature ?? 0.7)
        _maxTokens = State(initialValue: config?.maxTokens ?? 2048)
        _contextTokens = State(initialValue: config?.contextTokens ?? 16000)
        _group = State(initialValue: config?.group ?? "默认")
        _paramAliasesText = State(initialValue: ModelEditorView.aliasesString(config?.paramAliases))
    }

    var body: some View {
        CompatNav {
            List {
                Section(header: sectionHeader(apiProtocol.uppercased())) {
                    editorRow("名称", text: $name, placeholder: "Botcf")
                    pickerRow("API 协议", selection: $apiProtocol, options: ModelConfig.apiProtocols)
                }

                Section(header: sectionHeader("API 配置")) {
                    editorRow("Base URL", text: $baseURL, placeholder: "https://botcf.com/v1")
                    editorRow("模型名", text: $model, placeholder: "gpt-5.6-terra")
                    pickerRow("鉴权方式", selection: $authMethod, options: ModelConfig.authMethods)
                    tokenRow
                    // v3.5.13：可配置参数名别名（适配不同中转对参数名接受度不同）
                    editorRow("参数别名", text: $paramAliasesText, placeholder: "max_tokens:max_completion_tokens")
                    // v2.9.107：供应商分组（管理页按分组折叠展示）
                    editorRow("分组", text: $group, placeholder: "默认")
                }

                Section(header: sectionHeader("参数")) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $temperature, in: 0...2, step: 0.1)
                    Stepper("Max Tokens: \(maxTokens)", value: $maxTokens, in: 256...32768, step: 256)
                    Stepper("上下文预算: \(contextTokens)", value: $contextTokens, in: 4000...128000, step: 2000)
                }
                Section(header: sectionHeader("参数说明")) {
                    Text(L10n.t("ui_7"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_18"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_72"))
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                if !validationError.isEmpty {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section(header: sectionHeader("操作")) {
                    Button(action: fetchUpstreamModels) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                            Text(L10n.t("ui_128"))
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting && fetchedModels.isEmpty {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    Button(action: saveOnly) {
                        Text(L10n.t("ui_26"))
                            .foregroundColor(.blue)
                    }

                    Button(action: saveAndTest) {
                        HStack {
                            Text(L10n.t("ui_27"))
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                    // v2.9.107：测速（只测延迟，不保存）
                    Button(action: speedTestOnly) {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge")
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                            Text(L10n.t("ui_105"))
                                .foregroundColor(.orange)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                }

                if savedFlag {
                    Section(header: sectionHeader("状态")) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(L10n.t("ui_52"))
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }

                if !testStatus.isEmpty {
                    Section(header: sectionHeader("连接测试")) {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundColor(testColor)
                    }
                }

                Section(header: sectionHeader("说明")) {
                    Text(L10n.t("ui_138"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
            .navigationTitle(config == nil ? "添加模型" : name)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { saveOnly() }
                }
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet(models: fetchedModels, selected: $model)
            }
        }
    }

    // MARK: - 子视图

    private func editorRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
    }

    private func pickerRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .frame(maxWidth: 220)
            .labelsHidden()
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(authMethod == "None" ? "无需鉴权" : "\(authMethod) Token")
                    .font(.body)
                if showKey {
                    TextField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Spacer()
            Button(action: { showKey.toggle() }) {
                Image(systemName: showKey ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    // MARK: - 操作

    private func applyPreset(at index: Int) {
        let p = ModelConfig.providerPresets[min(index, ModelConfig.providerPresets.count - 1)]
        name = p.name
        provider = p.provider
        apiProtocol = p.protocol
        baseURL = p.baseURL
        model = p.model
        authMethod = p.auth
    }

    private func applyPreset(name presetName: String) {
        if let p = ModelConfig.providerPresets.first(where: { $0.name == presetName }) {
            name = p.name
            provider = p.provider
            apiProtocol = p.protocol
            baseURL = p.baseURL
            model = p.model
            authMethod = p.auth
        }
    }

    /// v8：宽松构造（不做校验）——fetchUpstreamModels 也要用表单值拉列表
    private func makeConfigRelaxed() -> ModelConfig {
        ModelConfig(
            id: config?.id ?? UUID(),
            name: name.isEmpty ? model : name,
            provider: provider,
            apiProtocol: apiProtocol,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model.trimmingCharacters(in: .whitespaces),
            authMethod: authMethod,
            isDefault: isDefault,
            temperature: temperature,
            maxTokens: maxTokens,
            contextTokens: contextTokens,
            group: group,
            paramAliases: ModelEditorView.parseAliases(paramAliasesText)
        )
    }

    /// v8：可失败版本——名称/模型名/Base URL 校验不过返回 nil，杜绝空配置落库
    private func makeConfig() -> ModelConfig? {
        let finalName = name.isEmpty ? model : name
        guard !finalName.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "名称和模型名不能都为空，至少填一个"
            return nil
        }
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "Base URL 不能为空"
            return nil
        }
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "模型名不能为空（可先填 Base URL 点「获取模型列表」再选）"
            return nil
        }
        validationError = ""
        return makeConfigRelaxed()
    }

    /// v3.5.13：字典 → 编辑文本（"key:value,key2:value2"）
    private static func aliasesString(_ aliases: [String: String]?) -> String {
        guard let a = aliases, !a.isEmpty else { return "" }
        return a.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
    }

    /// v3.5.13：编辑文本 → 字典（容忍中文逗号/空格，跳过非法项）
    private static func parseAliases(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in text.components(separatedBy: CharacterSet(charactersIn: ",，;")) {
            let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = p.firstIndex(of: ":") else { continue }
            let k = String(p[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let v = String(p[p.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, !v.isEmpty, k != v { out[k] = v }
        }
        return out
    }

    private func saveOnly() {
        guard let cfg = makeConfig() else { return }
        onSave(cfg); savedFlag = true
        presentationMode.wrappedValue.dismiss()
    }

    private func saveAndTest() {
        guard let cfg = makeConfig() else { return }
        onSave(cfg); savedFlag = true
        isTesting = true
        testStatus = "正在测试..."
        testColor = .secondary
        ModelAPIClient.shared.testConnection(config: cfg) { result in
            isTesting = false
            switch result {
            case .success(let msg):
                testStatus = msg
                testColor = .green
            case .failure(let error):
                testStatus = error.localizedDescription
                testColor = .red
            }
        }
    }

    private func fetchUpstreamModels() {
        // v8：不再先落库——Base URL 校验通过后直接用表单值拉列表，保存交给用户点「保存」。
        // （旧版一进来就 onSave(cfg)：新建后没填任何东西就点获取列表，空配置直接入库）
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "Base URL 不能为空，先填好再获取模型列表"
            return
        }
        validationError = ""
        let cfg = makeConfigRelaxed()
        isTesting = true
        testStatus = "正在获取模型列表..."
        testColor = .secondary
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            isTesting = false
            switch result {
            case .success(let models):
                fetchedModels = models
                if models.isEmpty {
                    testStatus = "未返回任何模型"
                    testColor = .orange
                } else {
                    testStatus = "获取到 \(models.count) 个模型"
                    testColor = .green
                    showingModelPicker = true
                }
            case .failure(let error):
                testStatus = error
                testColor = .red
            }
        }
    }

    /// v2.9.107：只测接口延迟（不保存）
    private func speedTestOnly() {
        isTesting = true
        testStatus = "正在测速..."
        testColor = .secondary
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            isTesting = false
            testStatus = "Base URL 无效"
            testColor = .red
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        setHTTPMethod("GET", on: &req)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                isTesting = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    testStatus = "测速失败 · \(ms)ms"
                    testColor = .red
                } else {
                    testStatus = "接口延迟 \(ms)ms"
                    testColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}


// MARK: - 模型选择 Sheet

struct ModelPickerSheet: View {
    let models: [String]
    @Binding var selected: String
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        CompatNav {
            List(models, id: \.self) { m in
                Button(action: {
                    selected = m
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Text(m)
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                        if selected == m {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
            .navigationTitle("选择模型")
            .toolbar {
                Button("关闭") { presentationMode.wrappedValue.dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - v2.9.107 配置导入导出（FileDocument）

struct ConfigDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - v2.9.107 用量统计页（聚合本地 usage.jsonl）

struct UsageStatsView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var records: [[String: Any]] = []

    var body: some View {
        CompatNav {
            List {
                let agg = aggregate()
                Section(header: Text(L10n.t("ui_60"))) {
                    HStack {
                        statCell(title: "请求数", value: "\(agg.total)", color: .blue)
                        statCell(title: "成功率", value: agg.total > 0 ? "\(Int(Double(agg.ok) / Double(agg.total) * 100))%" : "-", color: .green)
                        statCell(title: "平均耗时", value: agg.total > 0 ? "\(agg.elapsed / agg.total)ms" : "-", color: .orange)
                        statCell(title: "输入 token 估算", value: "\(fmtK(agg.inputTokens))", color: .purple)
                    }
                }

                if !agg.byProvider.isEmpty {
                    Section(header: Text(L10n.t("ui_69"))) {
                        ForEach(agg.byProvider.sorted(by: { $0.total > $1.total }), id: \.self) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.name).font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(L10n.t("ui_156", row.total, row.ok))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                ProgressView(value: row.total > 0 ? Double(row.ok) / Double(row.total) : 0)
                                    .accentColor(DoubaoTheme.accent)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !records.isEmpty {
                    Section(header: Text(L10n.t("ui_96"))) {
                        ForEach(0..<min(records.count, 30), id: \.self) { i in
                            requestRow(records[i])
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
            .navigationTitle("用量统计")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清除记录") {
                        UsageRecorder.shared.clear()
                        records = []
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onAppear {
                // 后台线程读取，避免主线程卡死
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = UsageRecorder.shared.records
                    DispatchQueue.main.async {
                        records = result
                    }
                }
            }
        }
    }

    private func fmtK(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }

    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func requestRow(_ r: [String: Any]) -> some View {
        let ts = r["ts"] as? Double ?? 0
        let ok = r["ok"] as? Bool ?? false
        let el = r["elapsedMs"] as? Int ?? 0
        let name = r["name"] as? String ?? "-"
        let model = r["model"] as? String ?? "-"
        let error = r["error"] as? String ?? ""
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(ok ? .green : .red)
                    .font(.system(size: 13))
                Text(name).font(.subheadline).lineLimit(1)
                Spacer()
                Text("\(el)ms").font(.caption).foregroundColor(.secondary)
                Text(f.string(from: d)).font(.caption2).foregroundColor(.secondary)
            }
            Text(model).font(.caption).foregroundColor(.secondary).lineLimit(1)
            if !ok, !error.isEmpty {
                Text(error).font(.caption2).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private struct ProviderAgg: Hashable {
        let name: String
        var total: Int = 0
        var ok: Int = 0
        var elapsed: Int = 0
        var inputTokens: Int = 0
    }

    private func aggregate() -> (total: Int, ok: Int, elapsed: Int, inputTokens: Int, byProvider: [ProviderAgg]) {
        var total = 0, ok = 0, elapsed = 0, inputTokens = 0
        var map: [String: ProviderAgg] = [:]
        for r in records {
            total += 1
            let o = r["ok"] as? Bool ?? false
            if o { ok += 1 }
            elapsed += r["elapsedMs"] as? Int ?? 0
            inputTokens += r["estInputTokens"] as? Int ?? 0
            let name = r["name"] as? String ?? "-"
            var a = map[name] ?? ProviderAgg(name: name)
            a.total += 1
            if o { a.ok += 1 }
            a.elapsed += r["elapsedMs"] as? Int ?? 0
            a.inputTokens += r["estInputTokens"] as? Int ?? 0
            map[name] = a
        }
        return (total, ok, elapsed, inputTokens, Array(map.values))
    }
}
