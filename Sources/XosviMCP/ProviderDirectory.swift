import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - v9.8 服务商目录（卡片 + 一键连接）
//
// 目标：把「先建配置 → 再逐项填字段」变成「点服务商 → 只贴密钥 → 选模型」。
// 设计约束：
//  - iOS 15 最低版本：不用 NavigationStack / presentationDetents / scrollContentBackground 等 16+ API；
//  - 不引入网络依赖：连接校验复用 ModelAPIClient.fetchModelList / testConnection；
//  - 不新增存储：仍然写进 ModelStore（同一个 UserDefaults 域），密钥仍旧随 ModelConfig 落库，
//    与既有编辑流程完全一致，避免出现「两套配置」。

// MARK: 预设的品牌展示（只影响 UI，不影响协议）

extension ModelConfig {
    /// 预设名 → SF Symbol 图标
    static func presetSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("openai") { return "circle.hexagongrid" }
        if n.contains("deepseek") { return "water.waves" }
        if n.contains("anthropic") { return "a.circle" }
        if n.contains("botcf") { return "bolt.horizontal.circle" }
        if n.contains("glm") || n.contains("智谱") { return "brain" }
        if n.contains("kimi") || n.contains("moonshot") { return "moon.stars" }
        if n.contains("qwen") || n.contains("通义") { return "cloud" }
        if n.contains("minimax") { return "waveform" }
        if n.contains("step") || n.contains("阶跃") { return "figure.stairs" }
        if n.contains("豆包") || n.contains("火山") { return "flame" }
        return "cpu"
    }

    /// 预设 → 图标底色（稳定、低饱和，深浅色模式都可用）
    static func presetColor(_ name: String) -> Color {
        let n = name.lowercased()
        if n.contains("openai") { return Color(red: 0.18, green: 0.62, blue: 0.52) }
        if n.contains("deepseek") { return Color(red: 0.30, green: 0.42, blue: 0.96) }
        if n.contains("anthropic") { return Color(red: 0.82, green: 0.50, blue: 0.32) }
        if n.contains("botcf") { return Color(red: 0.55, green: 0.35, blue: 0.85) }
        if n.contains("glm") || n.contains("智谱") { return Color(red: 0.20, green: 0.45, blue: 0.85) }
        if n.contains("kimi") || n.contains("moonshot") { return Color(red: 0.25, green: 0.28, blue: 0.45) }
        if n.contains("qwen") || n.contains("通义") { return Color(red: 0.62, green: 0.42, blue: 0.95) }
        if n.contains("minimax") { return Color(red: 0.90, green: 0.45, blue: 0.35) }
        if n.contains("step") || n.contains("阶跃") { return Color(red: 0.20, green: 0.55, blue: 0.70) }
        if n.contains("豆包") || n.contains("火山") { return Color(red: 0.32, green: 0.55, blue: 0.95) }
        return Color.gray
    }
}

// MARK: 错误诊断（401 引导用）

enum ModelErrorHint {
    /// 从错误里取出 HTTP 状态码（OpenAIClient 用 code = 状态码，网络错误是 -1001 等）
    static func httpStatus(_ error: Error) -> Int? {
        let ns = error as NSError
        if ns.domain == "OpenAIClient" || ns.domain == "ModelAPIClient" {
            if ns.code >= 100, ns.code < 600 { return ns.code }
            return nil
        }
        // 有些路径直接把 "HTTP 401" 写进文案
        let text = ns.localizedDescription
        guard let r = text.range(of: "HTTP ") else { return nil }
        let digits = text[r.upperBound...].prefix(3)
        return Int(digits)
    }

    /// 是否是「密钥/额度」类错误（不是参数错、也不是网络错）
    static func isAuthError(_ error: Error) -> Bool {
        guard let c = httpStatus(error) else { return false }
        return c == 401 || c == 402 || c == 403
    }

    /// 给用户的一句话说明 + 建议动作
    static func explanation(status: Int) -> (title: String, detail: String) {
        switch status {
        case 401:
            return ("密钥无效或已失效",
                    "上游拒绝了这个 API 密钥（HTTP 401）。检查是否复制完整、是否已过期，或换一个密钥后重试。")
        case 402:
            return ("账户余额不足",
                    "上游返回 HTTP 402，通常是余额/额度用完。充值或换一个可用账户。")
        case 403:
            return ("密钥没有该模型权限",
                    "上游返回 HTTP 403，这个密钥可能没有权限调用当前模型，或请求被风控拦截。")
        case 429:
            return ("触发限流",
                    "上游返回 HTTP 429，请求太频繁或额度耗尽，稍后再试。")
        default:
            return ("请求被拒绝（HTTP \(status)）", "上游返回了错误，详情见上方错误信息。")
        }
    }
}

// MARK: 服务商卡片数据

struct ProviderCardModel: Identifiable {
    let id: String            // provider 键（openai / deepseek / …），同一家的多个账号共用
    let title: String         // 展示名
    let baseURL: String
    let defaultModel: String
    let protocolName: String
    let apiKeyURL: String?    // 拿密钥的页面（只给用户复制链接，不自动打开）
    let configs: [ModelConfig]

    var isConfigured: Bool { !configs.isEmpty }
    var configuredCount: Int { configs.count }
    var defaultConfig: ModelConfig? { configs.first(where: { $0.isDefault }) ?? configs.first }

    init(preset p: (name: String, provider: String, protocol: String, baseURL: String, model: String, auth: String),
         configs: [ModelConfig]) {
        self.id = p.provider
        self.title = p.name
        self.baseURL = p.baseURL
        self.defaultModel = p.model
        self.protocolName = p.protocol
        self.apiKeyURL = ProviderCardModel.keyPage(for: p.provider)
        self.configs = configs
    }

    init(customProvider provider: String, configs: [ModelConfig]) {
        self.id = provider
        self.title = ProviderCardModel.displayTitle(provider, configs: configs)
        self.baseURL = configs.first?.baseURL ?? ""
        self.defaultModel = configs.first?.model ?? ""
        self.protocolName = configs.first?.apiProtocol ?? "OpenAI Chat Completions"
        self.apiKeyURL = ProviderCardModel.keyPage(for: provider)
        self.configs = configs
    }

    static func displayTitle(_ provider: String, configs: [ModelConfig]) -> String {
        switch provider {
        case "openai": return "OpenAI"
        case "deepseek": return "DeepSeek"
        case "anthropic": return "Anthropic"
        case "custom": return "自定义 / 中转"
        case "zhipu": return "智谱GLM"
        case "moonshot": return "Kimi(Moonshot)"
        case "qwen": return "通义千问(Qwen)"
        case "minimax": return "MiniMax"
        case "step": return "阶跃星辰(Step)"
        case "doubao": return "豆包(火山)"
        default:
            return configs.first?.name ?? provider
        }
    }

    /// 各家的密钥申请页（只用于「去哪里拿密钥」提示与复制）
    static func keyPage(for provider: String) -> String? {
        switch provider {
        case "openai": return "https://platform.openai.com/api-keys"
        case "deepseek": return "https://platform.deepseek.com/api_keys"
        case "anthropic": return "https://console.anthropic.com/settings/keys"
        case "zhipu": return "https://open.bigmodel.cn/usercenter/apikeys"
        case "moonshot": return "https://platform.moonshot.cn/console/api-keys"
        case "qwen": return "https://bailian.console.aliyun.com/"
        case "minimax": return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case "step": return "https://platform.stepfun.com/interface-key"
        case "doubao": return "https://console.volcengine.com/ark"
        default: return nil
        }
    }
}

/// 目录数据组装：预设在前、目录外的已配置服务商在后
enum ProviderDirectory {
    static func cards(configs: [ModelConfig]) -> [ProviderCardModel] {
        var out: [ProviderCardModel] = []
        var usedKeys = Set<String>()
        for p in ModelConfig.providerPresets {
            let key = "\(p.provider)|\(p.baseURL)"
            guard !usedKeys.contains(key) else { continue }
            usedKeys.insert(key)
            let matched = configs.filter { c in
                c.provider == p.provider
                    || c.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        == p.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            out.append(ProviderCardModel(preset: p, configs: matched))
        }
        // 预设之外的（用户自建的中转 / 自定义）
        var extras: [String] = []
        for c in configs {
            let known = out.contains { card in card.configs.contains(where: { $0.id == c.id }) }
            if !known && !extras.contains(c.provider) { extras.append(c.provider) }
        }
        for key in extras {
            let list = configs.filter { $0.provider == key }
            out.append(ProviderCardModel(customProvider: key, configs: list))
        }
        return out
    }
}

// MARK: - 目录主视图

struct ProviderDirectoryView: View {
    @ObservedObject private var store = ModelStore.shared
    @Environment(\.presentationMode) private var presentationMode
    /// 点「配置」/「管理」时的回调——交给宿主（ModelsView）打开编辑器或模型管理页
    var onEdit: (ModelConfig?) -> Void
    var onBrowseModels: (ModelConfig) -> Void

    @State private var search = ""
    @State private var connecting: ProviderCardModel?
    /// 编辑已有账号的菜单（多个账号时先选哪个）
    @State private var managingAccounts: ProviderCardModel?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var allCards: [ProviderCardModel] {
        ProviderDirectory.cards(configs: store.configs)
    }

    private var cards: [ProviderCardModel] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return allCards }
        return allCards.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
                || $0.configs.contains(where: { $0.model.localizedCaseInsensitiveContains(q) })
        }
    }

    private var configuredCount: Int {
        allCards.filter { $0.isConfigured }.count
    }

    private var totalAccounts: Int { store.configs.count }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    searchBar
                    if cards.isEmpty {
                        emptyHint
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(cards) { card in
                                cardView(card)
                            }
                        }
                    }
                    Text("卡片上的「默认」表示这家有当前默认模型；「可用/重试中/请求失败」来自熔断器。点卡片可添加账号、切换默认或编辑。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(DoubaoTheme.bg)
        }
        .navigationTitle("服务商")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { presentationMode.wrappedValue.dismiss() }
            }
        }
        .sheet(item: $connecting) { card in
            ProviderConnectSheet(card: card) { saved in
                connecting = nil
                // 第一个配置自动成为默认；其余保持用户选择
                var cfg = saved
                if ModelStore.shared.configs.isEmpty { cfg.isDefault = true }
                if ModelStore.shared.configs.contains(where: { $0.id == cfg.id }) {
                    ModelStore.shared.update(cfg)
                } else {
                    ModelStore.shared.add(cfg)
                }
            }
            .sheetDetentsHeight(520)
        }
        .actionSheet(item: $managingAccounts) { card in
            ActionSheet(title: Text(card.title),
                        message: Text("这家有 \(card.configuredCount) 个账号"),
                        buttons: actionButtons(for: card))
        }
    }
    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("点一下服务商，只填密钥就能用")
                .font(.headline)
            Text(configuredCount > 0
                 ? "已连接 \(configuredCount) 家 · 共 \(totalAccounts) 个账号"
                 : "还没有连接任何服务商")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            TextField("搜索服务商或模型", text: $search)
                .font(.subheadline)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !search.isEmpty {
                Button(action: { search = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DoubaoTheme.card)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DoubaoTheme.hairline, lineWidth: 1)
        )
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("没有匹配的服务商")
                .font(.footnote)
                .foregroundColor(.secondary)
            Button("用自定义 API 添加") {
                onEdit(nil)
                presentationMode.wrappedValue.dismiss()
            }
            .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: 单张卡片

    private func cardView(_ card: ProviderCardModel) -> some View {
        Button(action: {
            if card.isConfigured {
                managingAccounts = card
            } else {
                connecting = card
            }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(ModelConfig.presetColor(card.title))
                            .frame(width: 30, height: 30)
                        Image(systemName: ModelConfig.presetSymbol(card.title))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    Spacer(minLength: 0)
                    if card.isConfigured {
                        statusDot(for: card)
                    }
                }
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(card.isConfigured ? (card.defaultConfig?.model ?? card.defaultModel) : card.defaultModel)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if card.isConfigured {
                        Text(card.configuredCount > 1 ? "\(card.configuredCount) 个账号" : "已配置")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                    } else {
                        Text("未配置")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(DoubaoTheme.accent)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DoubaoTheme.card)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DoubaoTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// 状态小圆点：默认账号 + 熔断状态（复用 ModelStore.breaker）
    private func statusDot(for card: ProviderCardModel) -> some View {
        var color = Color.green
        var label = "可用"
        if let cfg = card.defaultConfig {
            let state = ModelStore.shared.breaker(for: cfg.id).stateInfo.state
            switch state {
            case .open:
                color = .red; label = "请求失败"
            case .halfOpen:
                color = .orange; label = "重试中"
            default:
                color = .green; label = "可用"
            }
        }
        return HStack(spacing: 4) {
            if card.configs.contains(where: { $0.isDefault }) {
                Text("默认").font(.system(size: 9.5)).foregroundColor(.secondary)
            }
            Text(label)
                .font(.system(size: 9.5))
                .foregroundColor(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(color.opacity(0.12))
                .cornerRadius(4)
        }
    }

    private func actionButtons(for card: ProviderCardModel) -> [ActionSheet.Button] {
        var buttons: [ActionSheet.Button] = []
        buttons.append(.default(Text("添加新账号")) { connecting = card })
        if let cfg = card.defaultConfig {
            buttons.append(.default(Text("设为默认并聊天（\(cfg.name)）")) {
                var c = cfg
                c.isDefault = true
                ModelStore.shared.update(c)
                ModelStore.shared.markUsed(c.id.uuidString)
            })
            buttons.append(.default(Text("浏览上游模型")) { onBrowseModels(cfg) })
        }
        for cfg in card.configs {
            buttons.append(.default(Text("编辑：\(cfg.name)")) { onEdit(cfg) })
        }
        buttons.append(.cancel(Text("取消")))
        return buttons
    }
}

// MARK: - 一键连接向导（只贴密钥）

struct ProviderConnectSheet: View {
    let card: ProviderCardModel
    let onSave: (ModelConfig) -> Void
    @Environment(\.presentationMode) private var presentationMode

    @State private var apiKey = ""
    @State private var baseURL: String
    @State private var fetching = false
    @State private var status = ""
    @State private var statusColor: Color = .secondary
    @State private var models: [String] = []
    @State private var picked: String = ""
    @State private var pickedTouched = false
    @State private var showKey = false

    init(card: ProviderCardModel, onSave: @escaping (ModelConfig) -> Void) {
        self.card = card
        self.onSave = onSave
        _baseURL = State(initialValue: card.baseURL)
        _picked = State(initialValue: card.defaultModel)
    }

    private var authMethod: String {
        if let p = ModelConfig.providerPresets.first(where: { $0.name == card.title }) { return p.auth }
        if card.protocolName == "Anthropic Messages" { return "API Key" }
        return "Bearer"
    }

    private var canFetch: Bool {
        !fetching
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        CompatNav {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(ModelConfig.presetColor(card.title))
                                .frame(width: 42, height: 42)
                            Image(systemName: ModelConfig.presetSymbol(card.title))
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title).font(.headline)
                            Text("只填密钥，模型自动拉取")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                    }

                    // 1. 密钥
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API 密钥").font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            if showKey {
                                TextField("sk-…", text: $apiKey)
                                    .font(.system(.body, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } else {
                                SecureField("sk-…", text: $apiKey)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Button(action: { showKey.toggle() }) {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            Button(action: {
                                if let s = UIPasteboard.general.string?
                                    .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                                    apiKey = s
                                }
                            }) {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundColor(DoubaoTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(DoubaoTheme.card)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DoubaoTheme.hairline, lineWidth: 1))

                        if let page = card.apiKeyURL {
                            Button(action: {
                                // v9.8：改为剪贴板复制。iOS 16+ 的 OpenURLButton 需 Scenes，
                                // 旧系统上 isAvailable 也可能非空，会崩在 scene 获取上——这里不冒这个险。
                                UIPasteboard.general.string = page
                                status = "申请页链接已复制：\(page)"
                                statusColor = .secondary
                            }) {
                                Text("没有密钥？复制申请页链接")
                                    .font(.caption)
                                    .foregroundColor(DoubaoTheme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 2. 基础 URL（预设已填，可改）
                    VStack(alignment: .leading, spacing: 6) {
                        Text("基础 URL").font(.caption).foregroundColor(.secondary)
                        TextField("https://…/v1", text: $baseURL)
                            .font(.system(.footnote, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(DoubaoTheme.card)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DoubaoTheme.hairline, lineWidth: 1))
                    }

                    // 3. 获取模型
                    Button(action: fetchModels) {
                        HStack(spacing: 8) {
                            if fetching { ProgressView().scaleEffect(0.8) }
                            Text(fetching ? "正在获取模型…" : (models.isEmpty ? "获取模型" : "重新获取模型"))
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if !models.isEmpty {
                                Text("\(models.count)").font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(canFetch ? .white : .secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(canFetch ? DoubaoTheme.accent : DoubaoTheme.card)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canFetch)

                    if !status.isEmpty {
                        Label(status, systemImage: statusColor == .red ? "exclamationmark.triangle.fill" : "info.circle")
                            .font(.caption)
                            .foregroundColor(statusColor)
                    }

                    // 4. 模型列表（取到才显示；点一下即选）
                    if !models.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("选择模型").font(.caption).foregroundColor(.secondary)
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(models, id: \.self) { m in
                                        Button(action: {
                                            picked = m
                                            pickedTouched = true
                                        }) {
                                            HStack {
                                                Text(m)
                                                    .font(.system(.footnote, design: .monospaced))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Spacer()
                                                if picked == m {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 12, weight: .semibold))
                                                        .foregroundColor(DoubaoTheme.accent)
                                                }
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                        }
                                        .buttonStyle(.plain)
                                        Divider().opacity(0.5)
                                    }
                                }
                            }
                            .frame(maxHeight: 240)
                            .background(DoubaoTheme.card)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DoubaoTheme.hairline, lineWidth: 1))
                        }
                    }
                }
                .padding(16)
            }
            .background(DoubaoTheme.bg)
            .navigationTitle(card.title)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .disabled(picked.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    // MARK: 操作

    private func draftConfig() -> ModelConfig {
        ModelConfig(name: card.title, provider: card.id, apiProtocol: card.protocolName,
                    baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    model: picked.trimmingCharacters(in: .whitespacesAndNewlines),
                    authMethod: authMethod, isDefault: false)
    }

    private func fetchModels() {
        fetching = true
        status = "正在连接上游…"
        statusColor = .secondary
        let cfg = draftConfig()
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            fetching = false
            switch result {
            case .success(let list):
                models = list
                if list.isEmpty {
                    status = "连接成功，但这个地址没有返回任何模型；可手动在模型管理里填模型名"
                    statusColor = .orange
                } else {
                    status = "连接成功，共 \(list.count) 个模型，选一个后保存"
                    statusColor = .green
                    if !list.contains(picked) || !pickedTouched {
                        // 优先选预设默认模型，其次第一个
                        if let pref = list.first(where: { $0 == card.defaultModel }) {
                            picked = pref
                        } else {
                            picked = list[0]
                        }
                    }
                }
            case .failure(let msg):
                // 401 引导：直说问题在哪，而不是抛原始解析错误
                if msg.contains("401") {
                    status = "密钥无效（HTTP 401）：检查是否复制完整，或去申请页重新生成"
                } else if msg.contains("connect") || msg.contains("网络") {
                    status = "连不上 \(baseURL)：检查网络或 URL 是否写错"
                } else {
                    status = "获取失败：\(msg)"
                }
                statusColor = .red
            }
        }
    }

    private func save() {
        let cfg = draftConfig()
        guard !cfg.apiKey.isEmpty, !cfg.baseURL.isEmpty, !cfg.model.isEmpty else {
            status = "密钥、URL、模型都要有才能保存"
            statusColor = .red
            return
        }
        onSave(cfg)
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - 「OpenAI 兼容 API」新增模型（两输入框 + 右上角获取模型）

struct CompatAPIAddSheet: View {
    @ObservedObject private var store = ModelStore.shared
    @Environment(\.presentationMode) private var presentationMode
    /// 保存成功后的回调（宿主用它选中/提示）
    var onAdded: ((ModelConfig) -> Void)?

    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var fetching = false
    @State private var errorText = ""
    @State private var models: [String] = []
    @State private var showKey = false

    private var canFetch: Bool {
        !fetching
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        CompatNav {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(title: "API 密钥") {
                        HStack(spacing: 8) {
                            if showKey {
                                TextField("sk-…", text: $apiKey)
                                    .font(.system(.body, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } else {
                                SecureField("sk-…", text: $apiKey)
                                    .font(.system(.body, design: .monospaced))
                            }
                            Button(action: { showKey.toggle() }) {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    field(title: "基础 URL") {
                        TextField("https://api.openai.com/v1", text: $baseURL)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                    }

                    if fetching {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("正在获取模型…").font(.caption).foregroundColor(.secondary)
                        }
                    }

                    if !errorText.isEmpty {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    if !models.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("选择模型").font(.caption).foregroundColor(.secondary)
                            ForEach(models, id: \.self) { m in
                                Button(action: { add(model: m) }) {
                                    HStack {
                                        Text(m)
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 14))
                                            .foregroundColor(DoubaoTheme.accent)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                                Divider().opacity(0.5)
                            }
                        }
                        .background(DoubaoTheme.card)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DoubaoTheme.hairline, lineWidth: 1))
                    }

                    Text("只填这两项即可。点右上角「获取模型」拉出该地址可用的模型，选一个就完成添加。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(16)
            }
            .background(DoubaoTheme.bg)
            .navigationTitle("OpenAI 兼容 API")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: fetch) {
                        if fetching {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text("获取模型")
                        }
                    }
                    .disabled(!canFetch)
                }
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(DoubaoTheme.card)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(DoubaoTheme.hairline, lineWidth: 1))
        }
    }

    /// 密钥/URL 都在时，用表单值拼一个临时配置（不落库）去拉模型列表
    private func draft(model: String = "") -> ModelConfig {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = base.lowercased()
        // v9.8：只给主机名（如 api.xxx.com）时补 https://；OpenAI 兼容端点自动补 /v1
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            base = "https://" + base
        }
        base = ModelConfig.normalizeBaseURL(base)
        return ModelConfig(name: "", provider: "custom",
                           apiProtocol: "OpenAI Chat Completions",
                           baseURL: base,
                           apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                           model: model, authMethod: "Bearer")
    }

    private func fetch() {
        fetching = true
        errorText = ""
        ModelAPIClient.shared.fetchModelList(config: draft()) { result in
            fetching = false
            switch result {
            case .success(let list):
                models = list
                if list.isEmpty {
                    errorText = "连接成功，但这个地址没有返回模型列表（可换一个 URL 试试）"
                }
            case .failure(let msg):
                if msg.contains("401") {
                    errorText = "密钥无效（HTTP 401）：检查是否复制完整"
                } else {
                    errorText = "获取失败：\(msg)"
                }
            }
        }
    }

    private func add(model: String) {
        var cfg = draft(model: model)
        if cfg.name.isEmpty {
            cfg.name = URL(string: cfg.baseURL)?.host ?? model
        }
        if store.configs.isEmpty { cfg.isDefault = true }
        store.add(cfg)
        onAdded?(cfg)
        presentationMode.wrappedValue.dismiss()
    }
}

// MARK: - 聊天里的「密钥/额度」引导卡片

struct AuthErrorCard: View {
    let message: String
    let status: Int
    var onFix: () -> Void

    var body: some View {
        let info = ModelErrorHint.explanation(status: status)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "key.slash")
                .font(.system(size: 18))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(info.title)
                    .font(.subheadline.weight(.semibold))
                Text(info.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(action: onFix) {
                        Text("去检查密钥")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DoubaoTheme.card)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16)
    }
}
