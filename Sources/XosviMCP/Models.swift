import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 模型配置

struct ModelConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var provider: String          // openai / deepseek / anthropic / custom
    var apiProtocol: String       // OpenAI Chat Completions / OpenAI Responses / Anthropic / Custom
    var baseURL: String           // https://api.openai.com/v1
    var apiKey: String
    var model: String             // gpt-4o-mini
    var authMethod: String        // Bearer / API Key / Body api_key / Body token / Query token / None
    var isDefault: Bool = false
    var temperature: Double = 0.7
    var maxTokens: Int = 2048
    /// v2.9.11：输入上下文预算 (token 估算）。发送前按预算自动裁剪最旧消息，
    /// 避免长会话请求体无限增长导致"一直请求中"。
    var contextTokens: Int = 16000
    /// v2.8.4：中转站兼容级别 (由 OpenAIClient 自适应降级时写入并持久化）
    /// 0=完整载荷 1=互换token参数名 2=去掉tool_choice 3=去掉tools纯对话 4=最小载荷
    var compatLevel: Int = 0
    /// v2.9.107：分组名 (供应商分组管理，对齐 cc-switch provider groups）
    var group: String = "默认"
    /// v3.5.13：可配置的参数名别名映射（标准键 → 该供应商认的键），如
    /// {"max_tokens":"max_completion_tokens", "reasoning_effort":"reasoning"}。
    /// 覆盖"不同中转对同一参数名接受度不同"的场景，不只内置 max_tokens 互换。
    var paramAliases: [String: String] = [:]
    /// v3.1.1：是否支持视觉 (VLM），自动根据模型名判断
    var supportsVision: Bool {
        let m = model.lowercased()
        // 明确支持视觉的模型
        if m.contains("gpt-4o") || m.contains("gpt-4-vision") || m.contains("gpt-4v") { return true }
        if m.contains("claude-3") || m.contains("claude 3") { return true }
        if m.contains("gemini") { return true }
        if m.contains("qwen-vl") || m.contains("qwen2-vl") { return true }
        if m.contains("glm-4v") || m.contains("glm4v") { return true }
        if m.contains("vision") || m.contains("vl-") { return true }
        // 明确不支持的
        if m.contains("deepseek") { return false }
        if m.contains("gpt-3.5") || m.contains("gpt-35") { return false }
        // 默认：不支持 (保守策略，避免 API 报错）
        return false
    }

    init(id: UUID = UUID(), name: String, provider: String, apiProtocol: String = "OpenAI Chat Completions",
         baseURL: String, apiKey: String, model: String, authMethod: String = "Bearer",
         isDefault: Bool = false, temperature: Double = 0.7, maxTokens: Int = 2048, compatLevel: Int = 0,
         contextTokens: Int = 16000, group: String = "默认", paramAliases: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.provider = provider
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.authMethod = authMethod
        self.isDefault = isDefault
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.compatLevel = compatLevel
        self.contextTokens = contextTokens
        self.group = group
        self.paramAliases = paramAliases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decode(String.self, forKey: .provider)
        let decodedProtocol = (try? c.decode(String.self, forKey: .apiProtocol)) ?? "OpenAI Chat Completions"
        // v2.9.2：OpenAI Completions (旧版文本补全）已移除，旧配置迁移到 Chat Completions
        apiProtocol = decodedProtocol == "OpenAI Completions" ? "OpenAI Chat Completions" : decodedProtocol
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decode(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        let decodedAuthMethod = (try? c.decode(String.self, forKey: .authMethod)) ?? "Bearer"
        authMethod = decodedAuthMethod.trimmingCharacters(in: .whitespaces).isEmpty ? "Bearer" : decodedAuthMethod
        isDefault = (try? c.decode(Bool.self, forKey: .isDefault)) ?? false
        temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 0.7
        maxTokens = (try? c.decode(Int.self, forKey: .maxTokens)) ?? 2048
        contextTokens = (try? c.decode(Int.self, forKey: .contextTokens)) ?? 16000
        compatLevel = (try? c.decode(Int.self, forKey: .compatLevel)) ?? 0
        group = (try? c.decode(String.self, forKey: .group)) ?? "默认"
        paramAliases = (try? c.decode([String: String].self, forKey: .paramAliases)) ?? [:]
    }
}

// MARK: - 模型协议与鉴权方式

extension ModelConfig {
    static let apiProtocols = [
        "OpenAI Chat Completions",
        "OpenAI Responses",
        "Anthropic Messages",
        "Custom Endpoint"
    ]

    static let authMethods = ["Bearer", "API Key", "Body api_key", "Body token", "Query token", "None"]

    static let providerPresets: [(name: String, provider: String, protocol: String, baseURL: String, model: String, auth: String)] = [
        ("OpenAI", "openai", "OpenAI Chat Completions", "https://api.openai.com/v1", "gpt-4o-mini", "Bearer"),
        ("DeepSeek", "deepseek", "OpenAI Chat Completions", "https://api.deepseek.com", "deepseek-chat", "Bearer"),
        ("Anthropic", "anthropic", "Anthropic Messages", "https://api.anthropic.com/v1", "claude-3-5-sonnet-20240620", "API Key"),
        ("Botcf", "custom", "OpenAI Responses", "https://botcf.com/v1", "gpt-5.6-terra", "Bearer"),
        // v4.4.17：扩充主流 OpenAI 兼容预设 (GLM/Kimi/Qwen/MiniMax/阶跃/豆包)。模型名可在模型管理页改。
        ("智谱GLM", "zhipu", "OpenAI Chat Completions", "https://open.bigmodel.cn/api/paas/v4", "glm-4.5", "Bearer"),
        ("Kimi(Moonshot)", "moonshot", "OpenAI Chat Completions", "https://api.moonshot.cn/v1", "kimi-k3", "Bearer"),
        ("通义千问(Qwen)", "qwen", "OpenAI Chat Completions", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.8-max", "Bearer"),
        ("MiniMax", "minimax", "OpenAI Chat Completions", "https://api.minimax.chat/v1", "MiniMax-Text-01", "Bearer"),
        ("阶跃星辰(Step)", "step", "OpenAI Chat Completions", "https://api.stepfun.com/v1", "step-2-mini", "Bearer"),
        ("豆包(火山)", "doubao", "OpenAI Chat Completions", "https://ark.cn-beijing.volces.com/api/v3", "doubao-pro-32k", "Bearer")
    ]

    /// v4.4.17：Base URL 规范化——OpenAI 格式端点 (Chat/Responses) 自动补 /v1，
    /// 用户已填 v1/含版本路径(如 /api/paas/v4、/compatible-mode/v1) 则不重复补。
    /// Anthropic(/anthropic) 与自定义端点不自动补。
    static func normalizeBaseURL(_ base: String) -> String {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed) else { return base }
        let path = url.path
        // 纯主机级 (path 空 或 "/") → 补 /v1；已含路径段则尊重用户
        if path.isEmpty || path == "/" {
            return trimmed + "/v1"
        }
        return base
    }

    /// 推理系列模型 (GPT-5.x / o1 / o3 / o4）不接受 temperature 参数，
    /// 中转站会返回 "Invalid request parameter"。
    var sendsTemperature: Bool { !isReasoningModel && !model.lowercased().contains("reasoning") }

    /// v2.8.5：是否推理系列模型 (GPT-5.x / o1 / o3 / o4）。
    /// 这类模型默认 reasoning_effort=medium，回复前会长时间思考 (聊天转圈半天的主因），
    /// 请求时显式携带 reasoning_effort=none 提速。
    var isReasoningModel: Bool {
        let m = model.lowercased()
        // v7.15.1："gpt-5" 覆盖 gpt-5 / gpt-5-mini / gpt-5.1；旧表只认 "gpt-5."，
        // 中转站常见的裸 gpt-5 会被带上 temperature 而 400。
        let prefixes = ["gpt-5", "o1", "o3", "o4", "o1-", "o3-", "o4-"]
        return prefixes.contains(where: { m.hasPrefix($0) }) || m.contains("reasoning")
    }

    /// 推理系列模型使用 max_completion_tokens 而非 max_tokens
    var maxTokensKey: String {
        let m = model.lowercased()
        let reasoningPrefixes = ["gpt-5", "o1", "o3", "o4", "o1-", "o3-", "o4-"]   // v7.15.1：同 isReasoningModel
        if reasoningPrefixes.contains(where: { m.hasPrefix($0) }) { return "max_completion_tokens" }
        return "max_tokens"
    }

    /// v4.4.16：API 协议自动纠偏——用户配错协议(如把 deepseek 配成 OpenAI Responses)时，
    /// 请求前自动纠正到正确协议，无需用户手动调整(大部分用户不会去改配置)。
    /// 规则参考 Codex 端点分配：
    ///  - claude/anthropic → Anthropic Messages
    ///  - gpt-5.x / o1/o3/o4 (推理系列, Codex 走 responses) → OpenAI Responses
    ///  - deepseek → OpenAI Chat Completions (deepseek 在 chat/completions 就能用 tools, 走 responses 反而慢)
    ///  - Custom Endpoint 一律尊重用户, 不自动改
    static func autoCorrectProtocol(model: String, provider: String, current: String) -> String {
        let m = model.lowercased()
        let p = provider.lowercased()
        // 显式选的自定义端点尊重用户, 不自动纠正
        if current == "Custom Endpoint" { return current }
        // Anthropic 模型
        if p.contains("anthropic") || m.hasPrefix("claude") { return "Anthropic Messages" }
        // 推理系列 (Codex 同款 responses 端点)
        let reasoningPrefixes = ["gpt-5", "o1", "o3", "o4", "o1-", "o3-", "o4-"]   // v7.15.1：同 isReasoningModel
        if reasoningPrefixes.contains(where: { m.hasPrefix($0) }) || m.contains("reasoning") { return "OpenAI Responses" }
        // deepseek 对话模型 → Chat Completions
        if p.contains("deepseek") || m.contains("deepseek") { return "OpenAI Chat Completions" }
        // 其余尊重当前
        return current
    }
}

final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    @Published var configs: [ModelConfig] = []
    private let key = "xosvi.model_configs"    // v2.9.97：记住最近一次使用的模型，顶栏立即显示用户上次用的配置，不再回退到第一个 (旧 gpt4o）
    private let lastUsedKey = "xosvi.last_used_config_id"

    init() { load() }

    var lastUsedConfigId: String? {
        get { UserDefaults.standard.string(forKey: lastUsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastUsedKey) }
    }

    func markUsed(_ id: String) {
        lastUsedConfigId = id
    }

    func load() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ModelConfig].self, from: data) else {
            // v2.9.107：主数据损坏时从备份restored (最多试 4 份）
            for i in 0...3 {
                if let bak = ud.data(forKey: "\(key).bak.\(i)"),
                   let decoded = try? JSONDecoder().decode([ModelConfig].self, from: bak) {
                    configs = decoded
                    _purgeBlankConfigs()   // v8：备份恢复同样过滤空白配置
                    break
                }
            }
            _restoreApiKeysFromKeychain()
            return
        }
        configs = decoded
        _purgeBlankConfigs()   // v8：清理历史遗留的空白配置（截图里那条 "custom ·"）
        _restoreApiKeysFromKeychain()
    }

    /// v8：清理 name+model 均空的废配置（旧版编辑器/深链/导入三处都能写入）；
    /// 清掉后若没有默认项则把第一条设为默认，并落盘一次
    private func _purgeBlankConfigs() {
        let before = configs.count
        configs.removeAll {
            $0.name.trimmingCharacters(in: .whitespaces).isEmpty &&
            $0.model.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard configs.count != before else { return }
        if !configs.contains(where: { $0.isDefault }), !configs.isEmpty { configs[0].isDefault = true }
        save()
    }

    /// v6.1.5：apiKey Keychain 化——从 Keychain 恢复各 config 的 apiKey；
    /// 旧版明文（UserDefaults JSON）一次性迁移进 Keychain。
    private func _restoreApiKeysFromKeychain() {
        for i in configs.indices {
            let kc = kcKey(for: configs[i])
            if let k = KeychainStore.shared.string(forKey: kc) {
                configs[i].apiKey = k
            } else if !configs[i].apiKey.isEmpty {
                // 老版本明文 apiKey 还留在 UserDefaults → 迁到 Keychain（下次 save 会写脱敏副本）
                KeychainStore.shared.set(configs[i].apiKey, forKey: kc)
            }
        }
    }

    private func kcKey(for config: ModelConfig) -> String {
        "modelconfig.apikey.\(config.id.uuidString)"
    }

    /// v2.9.107：原子写前备份轮换 (保留最近 4 份）
    private func rotateBackup() {
        let ud = UserDefaults.standard
        guard let current = ud.data(forKey: key) else { return }
        for i in stride(from: 2, through: 0, by: -1) {
            if let old = ud.data(forKey: "\(key).bak.\(i)") {
                ud.set(old, forKey: "\(key).bak.\(i + 1)")
            }
        }
        ud.set(current, forKey: "\(key).bak.0")
    }

    func save() {
        // v6.1.5：apiKey 不再明文写 UserDefaults——逐条入 Keychain，UserDefaults 存脱敏副本
        // v6.2.0：Keychain 写入失败时回退明文存储，保证用户 key 不丢（TrollStore 环境
        // entitlement 受限时 SecItemAdd 可能失败，宁可降级也不丢配置）
        var sanitized = configs
        var allSaved = true
        for i in sanitized.indices {
            let ok = KeychainStore.shared.set(sanitized[i].apiKey, forKey: kcKey(for: sanitized[i]))
            if ok {
                sanitized[i].apiKey = ""
            } else {
                allSaved = false
            }
        }
        let payload = allSaved ? sanitized : configs
        if let data = try? JSONEncoder().encode(payload) {
            rotateBackup()
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: v2.9.107 —— 熔断器注册表 (运行时，不持久化；对齐 cc-switch circuit_breaker）

    private(set) var breakers: [UUID: CircuitBreaker] = [:]
    // v2.9.150：熔断器字典锁——ModelRow 渲染(主线程)与 AI 请求回调(后台线程)
    // 并发调 breaker(for:) 写同一字典 → 字典并发修改 SIGSEGV ("模型 API 页闪退"根因）
    private let breakerLock = NSLock()

    func breaker(for id: UUID) -> CircuitBreaker {
        breakerLock.lock()
        defer { breakerLock.unlock() }
        if let b = breakers[id] { return b }
        let b = CircuitBreaker(name: configs.first { $0.id == id }?.name ?? "model")
        breakers[id] = b
        return b
    }

    // MARK: v2.9.107 —— 配置导入 / 导出 (对齐 cc-switch import/export）

    func exportJSON() -> String {
        var items: [Any] = []
        for c in configs {
            if let d = try? JSONEncoder().encode(c),
               let obj = try? JSONSerialization.jsonObject(with: d) {
                items.append(obj)
            }
        }
        let payload: [String: Any] = [
            "app": "Xosvi", "type": "model_configs", "version": 1,
            "exportedAt": Int(Date().timeIntervalSince1970),
            "configs": items
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return ""
    }

    @discardableResult
    func importJSON(_ text: String) -> (ok: Int, failed: Int) {
        guard let data = text.data(using: .utf8) else { return (0, 0) }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["configs"] as? [[String: Any]] {
            var ok = 0, failed = 0
            for item in arr {
                if let d = try? JSONSerialization.data(withJSONObject: item),
                   let c = try? JSONDecoder().decode(ModelConfig.self, from: d) {
                    add(c); ok += 1
                } else { failed += 1 }
            }
            return (ok, failed)
        }
        // 兼容纯数组
        if let arr = try? JSONDecoder().decode([ModelConfig].self, from: data) {
            for c in arr { add(c) }
            return (arr.count, 0)
        }
        return (0, 0)
    }

    var defaultConfig: ModelConfig? {
        if let d = configs.first(where: { $0.isDefault }) { return d }
        // v2.9.97：其次取最近使用，最后回退第一个
        if let last = lastUsedConfigId, let m = configs.first(where: { $0.id.uuidString == last }) {
            return m
        }
        return configs.first
    }

    func add(_ config: ModelConfig) {
        var c = config
        // v8：防呆——name+model 均空的废配置拒收（编辑器校验漏网 / 导入文件缺字段）
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty,
           c.model.trimmingCharacters(in: .whitespaces).isEmpty {
            return
        }
        if c.name.isEmpty { c.name = c.model }
        if c.isDefault {
            for i in configs.indices { configs[i].isDefault = false }
        }
        if configs.isEmpty { c.isDefault = true }
        configs.append(c)
        save()
    }

    /// v2.9.126：深链导入专用——同 baseURL+model 去重 (重复导入不再堆积配置）
    /// v8：model 为空的深链直接拒收（缺参数的链接不再造出废配置）
    func importFromDeepLink(_ config: ModelConfig) -> Bool {
        guard !config.model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let dup = configs.contains { $0.baseURL == config.baseURL && $0.model == config.model }
        guard !dup else { return false }
        add(config)
        markUsed(config.id.uuidString)
        return true
    }

    func update(_ config: ModelConfig) {
        if config.isDefault {
            for i in configs.indices { configs[i].isDefault = (configs[i].id == config.id) }
        }
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
            save()
        }
    }

    func delete(at offsets: IndexSet) {
        configs.remove(atOffsets: offsets)
        if !configs.contains(where: { $0.isDefault }) && !configs.isEmpty {
            configs[0].isDefault = true
        }
        save()
    }
}

// MARK: - 模型列表获取与连接测试

enum ModelListResult {
    case success([String])
    case failure(String)
}

final class ModelAPIClient {
    static let shared = ModelAPIClient()

    func fetchModelList(config: ModelConfig, completion: @escaping (ModelListResult) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/models") else {
            completion(.failure("无效的 Base URL"))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        applyAuth(config: config, to: &request)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error.localizedDescription))
                    return
                }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let models = json["data"] as? [[String: Any]] else {
                    let raw = String(data: data ?? Data(), encoding: .utf8) ?? "(no data)"
                    completion(.failure("parse failed: \(raw.prefix(200))"))
                    return
                }
                let ids = models.compactMap { $0["id"] as? String }.sorted()
                completion(.success(ids))
            }
        }.resume()
    }

    func testConnection(config: ModelConfig, completion: @escaping (Result<String, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // v2.9.0：支持 Responses API 协议
        let endpoint: String
        if config.apiProtocol == "Anthropic Messages" {
            endpoint = "/messages"
        } else if config.apiProtocol == "OpenAI Responses" {
            endpoint = "/responses"
        } else {
            endpoint = "/chat/completions"
        }
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0, userInfo: [NSLocalizedDescriptionKey: "无效的 Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        // v2.8.4：测试连接使用最小载荷 (仅 model + messages）。
        // 旧版发送 max_completion_tokens=8，推理模型 (gpt-5.x 默认 medium 推理）
        // 的推理 token 预算远超 8，会直接报参数错误，导致误判为连接failed。
        let body: [String: Any]
        if config.apiProtocol == "Anthropic Messages" {
            // Anthropic 协议要求必须传 max_tokens
            body = [
                "model": config.model,
                "max_tokens": 64,
                "messages": [["role": "user", "content": "hi"]]
            ]
        } else if config.apiProtocol == "OpenAI Responses" {
            body = [
                "model": config.model,
                "input": [["role": "user", "content": "hi"]]
            ]
        } else {
            body = [
                "model": config.model,
                "messages": [["role": "user", "content": "hi"]]
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        completion(.success("连接OK (HTTP \(http.statusCode))"))
                    } else {
                        let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                        completion(.failure(NSError(domain: "ModelAPIClient", code: http.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(raw.prefix(200))"])))
                    }
                } else {
                    completion(.success("已收到响应"))
                }
            }
        }.resume()
    }


    // v2.9.100：通用轻量 chat 调用 (AI 分析引擎等内部工具用）。
    // 按 apiProtocol 自动选端点 (chat/completions / responses / messages），不触发工具循环。
    func sendChat(config: ModelConfig, messages: [[String: Any]],
                  timeout: TimeInterval = 90,
                  completion: @escaping (Result<String, Error>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint: String
        if config.apiProtocol == "Anthropic Messages" {
            endpoint = "/messages"
        } else if config.apiProtocol == "OpenAI Responses" {
            endpoint = "/responses"
        } else {
            endpoint = "/chat/completions"
        }
        guard let url = URL(string: base + endpoint) else {
            completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                        userInfo: [NSLocalizedDescriptionKey: "无效的 Base URL"])))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        setHTTPMethod("POST", on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(config: config, to: &request)

        let body: [String: Any]
        if config.apiProtocol == "Anthropic Messages" {
            body = ["model": config.model, "max_tokens": 4096, "messages": messages]
        } else if config.apiProtocol == "OpenAI Responses" {
            var msgs: [[String: Any]] = []
            for m in messages {
                msgs.append([
                    "role": (m["role"] as? String) ?? "user",
                    "content": [[ "type": "input_text", "text": (m["content"] as? String) ?? "" ]]
                ])
            }
            body = ["model": config.model, "input": msgs]
        } else {
            body = ["model": config.model, "messages": messages, "temperature": 0.3]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let data = data else {
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "no response数据"])))
                    return
                }
                var text = ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let msg = first["message"] as? [String: Any],
                       let content = msg["content"] as? String {
                        text = content
                    } else if let output = json["output"] as? [[String: Any]] {
                        for item in output {
                            if let content = item["content"] as? [[String: Any]] {
                                for cc in content {
                                    if let t = cc["text"] as? String { text += t }
                                }
                            }
                        }
                    } else if let content = json["content"] as? [[String: Any]] {
                        for cc in content {
                            if let t = cc["text"] as? String { text += t }
                        }
                    }
                }
                if !text.isEmpty {
                    completion(.success(text))
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "(no data)"
                    completion(.failure(NSError(domain: "ModelAPIClient", code: 0,
                                                userInfo: [NSLocalizedDescriptionKey: "parse failed: \(raw.prefix(200))"])))
                }
            }
        }.resume()
    }

    private func applyAuth(config: ModelConfig, to request: inout URLRequest) {
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = config.authMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        switch method {
        case "Bearer":
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case "API Key":
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case "None":
            break
        default:
            // 空/未知鉴权方式但填了 key 时，默认按 Bearer 发送 (兼容旧配置或 UI 异常）
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }
    }
}

// MARK: - 聊天消息

struct ToolCall: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var arguments: String
}

struct ChatMessage: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var role: String         // user / assistant / system / tool
    var content: String
    var timestamp: Date = Date()
    var isError: Bool = false
    var toolCalls: [ToolCall]?
    var toolCallId: String?
    var toolName: String?
    /// v3.1.26：工具调用参数摘要 (tool 消息专用），UI 里用特殊颜色显示
    var toolArgs: String? = nil
    /// v3.3.4：工具执行耗时（秒），UI 气泡显示 (如 0.3s）
    var toolDuration: Double? = nil
    /// v2.9.9：多模态附件。存 data URL (如 "data:image/jpeg;base64,..."）。
    /// 发送时若非空，OpenAIClient 把 content 序列化为多模态数组。
    var imageDataURLs: [String]? = nil
    /// v2.9.20：思考记录 (reasoning）。Responses API 返回的 reasoning 摘要，气泡内可展开。
    var thinking: String? = nil
    /// v7.8.1：思考分段（对齐 kelivo reasoningSegments）——工具轮之间可以有多个思考块
    var reasoningSegments: [ReasoningSegment]? = nil
    /// v7.8.1：首个思考 token 到达 / 思考结束时间，用于显示耗时
    var reasoningStartAt: Date? = nil
    var reasoningFinishedAt: Date? = nil
    var reasoningTokens: Int? = nil
    /// v7.8.1：同一语义位置的多版本消息（编辑重发 / 重新生成）
    var groupId: String? = nil
    var version: Int? = nil
    /// v2.9.127：执行轨迹 (对齐豆包工作任务/Codex turn 流）——AI 本次回复的
    /// 思考→工具调用→工具结果 全过程，随消息持久化，可展开回看。
    var trail: [TrailStep]? = nil
    /// v3.5.8：工具解说（模型写的"先解说后执行"正文）——Minis 式工具卡把它当步骤标题，
    /// 单独存在 tool 消息上，避免解说既出现在 assistant 气泡又出现在卡片里导致重复。
    var toolNarration: String? = nil
    /// v3.5.10：工具是否仍在执行中——true 表示这是一张"启动即上屏"的 running 步骤卡，
    /// 结果回来后置 false 并填内容。UI 据此在徽章处显示"执行中…/转圈"而非"✓完成/✗出错"。
    var isRunning: Bool = false
    /// v8：web.search 结果的 id→url 映射（挂在本条 tool 消息上）——UI 渲染 [cite:sN] 引用角标的命中态
    var citedURLs: [String: String]? = nil
    /// v9：结构化消息片段（移植 Kelivo MessagePart）。nil = 尚未迁移的旧消息，读取时走 effectiveParts
    var parts: [MessagePart]? = nil
    /// v9：这条 tool 消息的结果已回填进前文的 ToolCallPayload.result，渲染层应跳过它
    /// （不物理删除：会话导出/全文搜索/审计仍在用）。
    /// 注意用 Optional：Swift 合成的 Decodable **不会**使用属性默认值，
    /// 非可选字段会让所有老会话 JSON 解码失败（整库会话丢失）。读取统一走 isToolConsumed。
    var isConsumedTool: Bool? = nil

    var isTool: Bool { role == "tool" }

    /// v9：工具结果是否已被回填消费（老数据无该字段 → false）
    var isToolConsumed: Bool { isConsumedTool ?? false }
}

/// v2.9.127：执行轨迹单步 (思考/工具调用/工具结果/备注）
struct TrailStep: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: Kind
    var name: String
    var status: Status
    var detail: String
    var ts: Date = Date()

    enum Kind: String, Codable { case think, tool, result, note }
    enum Status: String, Codable { case running, success, failed }

    static func running(_ kind: Kind, _ name: String, detail: String = "") -> TrailStep {
        TrailStep(kind: kind, name: name, status: .running, detail: detail)
    }
    static func done(_ kind: Kind, _ name: String, detail: String = "", ok: Bool = true) -> TrailStep {
        TrailStep(kind: kind, name: name, status: ok ? .success : .failed, detail: detail)
    }
}

// MARK: - 单个会话

struct ChatConversation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    /// v7.8.1：每个 group 当前显示第几版（groupId → version）
    var versionSelections: [String: Int]? = nil
    /// v7.8.1：从第几条消息开始截断上下文（nil / 负数 = 不截断）
    var truncateIndex: Int? = nil
}

// MARK: - 会话管理

final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()

    @Published var conversations: [ChatConversation] = []
    @Published var selectedId: UUID?
    @Published var isLoading = false
    /// v2.8.5：当前请求的实时状态文案 (等待响应/降级重试中），展示在输入指示器旁
    @Published var statusText: String?
    /// v2.9.34：请求过程可视化——当前第几轮 (v4.3.71 起无轮次上限)
    @Published var requestRound = 0
    /// v4.3.71：0 = 无轮次上限（已移除 60 轮机制），UI 只显示"第 N 轮"
    @Published var requestRounds = 0
    /// v2.9.34：正在执行的工具名 (展示"正在执行工具 xxx…"）
    @Published var runningTool: String?
    /// v3.5.10：正在上屏的"工具启动即显示 running 步骤卡"的消息 id——
    /// 工具启动先 append 一张 isRunning=true 的占位卡（真实工具名+命令，机制保证每步可见，
    /// 不依赖模型解说），结果回来后在 handleDispatchResult 原地更新成完成/出错卡。
    var pendingToolMsgID: UUID?
    /// v2.9.127：执行轨迹 (实时）——当前请求的 思考→工具调用→工具结果 步骤流，
    /// 请求结束时随最后一条 assistant 消息持久化 (message.trail）。
    @Published var liveTrail: [TrailStep] = []

    // v3.0.3：保存当前请求的思考内容 (onThinking 流式累加），
    // toolCalls 时传到 tool 消息，前端在 toolBubble 顶部显示
    private var thinkBuffer: String = ""
    /// v7.8.1：当前请求的思考起止（对齐 kelivo reasoningStartAt/FinishedAt）
    private var liveReasonStart: Date? = nil

    /// 把本轮的思考时间戳与分段盖到消息上。
    private func stampReasoning(_ message: inout ChatMessage, thinking: String?) {
        guard let th = thinking, !th.isEmpty else { return }
        let finish = Date()
        let start = liveReasonStart ?? finish
        message.reasoningStartAt = start
        message.reasoningFinishedAt = finish
        message.reasoningSegments = [
            ReasoningSegment(text: th, startAt: start, finishedAt: finish)
        ]
    }

    // v2.9.87：网络恢复自动重试 ("切后台回来网络中断"补偿）——
    // 网络类错误且当前确认为断网时，等 AppLifecycleMonitor 广播 networkRestored 后自动重发一次。
    private var retryObserver: NSObjectProtocol?
    private var retriedNetworkOnce = false
    /// v2.9.13：当前正在进行的 OpenAIClient (支持取消）
    private var currentClient: OpenAIClient?
    /// v2.9.53：当前流式输出的消息 ID (逐字显示时跟踪，done后更新或清理）
    /// v3.4.5：改为 internal（ChatView 用它标记打字机效果的消息）
    var streamingMessageId: UUID?
    /// v6.2.7：流式渲染节流（参考 OpenMinis 的流式输出处理）——旧实现每个 delta 直接改
    /// @Published conversations → 整页消息列表重渲染，长输出时主线程每秒重绘上百次 → 会话页卡顿。
    /// 改为：delta 先进缓冲，80ms 合并 flush 一次（更新频率降一个数量级），
    /// completion 入口强制 flush 保证尾部不丢。thinkBuffer 仍即时累加（toolCalls 装配依赖）。
    // v6.5.7：自我批判精炼（Self-Refine）状态（OpenManus/DeepResearch 同款机制）
    private var refineInFlight = false
    private var didRefineThisMessage = false

    private var streamDeltaBuffer = ""
    private var streamThinkBuffer = ""
    /// v9：流式刷新节流器（150ms 基线，含换行时走 50ms 快速通道）
    private let streamThrottle = StreamThrottle()
    /// v9：流式增量投影——每条流式消息一个，只在尾部变化时重算（前面已渲染的块 id 不变）
    private var streamProjections: [UUID: StreamingProjection] = [:]

    /// v9：取某条消息的增量投影结果（非流式消息返回 nil，走缓存投影）
    func streamingBlocks(for id: UUID) -> [ProjectedBlock]? {
        streamProjections[id]?.blocks
    }
    private func scheduleStreamFlush() {
        // v9：改用 StreamThrottle（同一实例，后到的 delta 会顶掉前一批，不堆积）
        // v6.4.0（对齐 OpenMinis tiered flush throttle）：0.08s → 0.18s。
        // 每批"滑过"而不是高频重绘；结构化输出（含换行）走快速通道 0.05s 保证可读节奏。
        let delay: Double = streamDeltaBuffer.contains("\n") ? 0.05 : 0.18
        streamThrottle.schedule(delay: delay) { [weak self] in
            self?.flushStreamBuffers()
        }
    }
    /// v6.5.7：自我批判精炼——发一轮"批判并改进"，精炼版追加到原消息末尾。
    /// 触发条件：thinkEnabled + 原回答>120字 + 无工具轮 + 每消息一次。
    private func autoRefine(originalAnswer: String, appendTo sid: UUID) {
        guard let cfg = ModelStore.shared.defaultConfig else {
            refineInFlight = false
            return
        }
        let prompt = "对上一轮的回答做自我批判并改进：1) 指出逻辑错误、遗漏或可简化处；2) 若原回答已足够好，直接回复”原回答已完善”即可，不要强行改写；3) 若需改进，给出完整、准确、更有深度的最终回答。\n\n原回答：\n\(originalAnswer.prefix(6000))"
        let msgs = [ChatMessage(role: "user", content: prompt)]
        let client = OpenAIClient(cfg)
        client.send(messages: msgs, tools: nil, onStatus: { _ in }, onDelta: { _ in }, onThinking: { _ in }) { [weak self] result in
            guard let self = self else { return }
            self.refineInFlight = false
            guard case .success(.text(let newText, _)) = result,
                  !newText.contains("原回答已完善"), !newText.isEmpty else { return }
            let improved = "\n\n━━━\n🔍 精炼版（自我批判改进）\n\n" + newText
            DispatchQueue.main.async {
                if let ci = self.activeConvIndex,
                   let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                    self.conversations[ci].messages[mi].content += improved
                }
            }
        }
    }

    func flushStreamBuffers() {
        streamThrottle.cancelPending()
        flushStreamBuffers(into: streamingMessageId)
    }

    /// v9：把缓冲写入指定消息（停止/取消时 streamingMessageId 已被清，需要显式传 id）
    func flushStreamBuffers(into sid: UUID?) {
        let dBuf = streamDeltaBuffer
        let tBuf = streamThinkBuffer
        streamDeltaBuffer = ""
        streamThinkBuffer = ""
        guard let sid, let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == sid }) else { return }
        if !dBuf.isEmpty {
            conversations[idx].messages[mi].content += dBuf
            // v9：结构化 parts 同步增量追加——投影器据此避免每帧全文重解析
            var parts = conversations[idx].messages[mi].effectiveParts
            if case .text(let last)? = parts.last {
                parts[parts.count - 1] = .text(last + dBuf)
            } else {
                parts.append(.text(dBuf))
            }
            conversations[idx].messages[mi].parts = parts
        }
        if !tBuf.isEmpty {
            let existing = conversations[idx].messages[mi].thinking ?? ""
            conversations[idx].messages[mi].thinking = existing + tBuf
            // v9：思考单独成 reasoning part（在 text 之前插入，保持"先思考后正文"顺序）
            var parts = conversations[idx].messages[mi].effectiveParts
            if parts.count > 1, case .reasoning(let last) = parts[parts.count - 2],
               case .text = parts[parts.count - 1] {
                parts[parts.count - 2] = .reasoning(last + tBuf)
            } else if case .reasoning(let last)? = parts.last {
                parts[parts.count - 1] = .reasoning(last + tBuf)
            } else {
                parts.insert(.reasoning(tBuf), at: max(0, parts.count - 1))
            }
            conversations[idx].messages[mi].parts = parts
        }
        // v9：增量投影——只有尾部块重算，前面块 id 保持不变（LazyVStack 不重建）
        let mid = conversations[idx].messages[mi].id
        let projection: StreamingProjection
        if let existing = streamProjections[mid] {
            projection = existing
        } else {
            let created = StreamingProjection()
            streamProjections[mid] = created
            projection = created
        }
        projection.update(parts: conversations[idx].messages[mi].effectiveParts)
        ProjectedBlockCache.shared.invalidate(id: mid)
    }
    /// v3.4.9：本轮刚"生成完成"的 assistant 消息 ID（工具解说/整段到达的回复）。
    /// ChatView 用它给这些消息开打字机——它们 isStreaming=false 且内容在出现前已定好，
    /// 只能靠"本轮刚产出"这一信号触发逐字显示。请求整体结束后清空。
    var liveProducedID: UUID?
    /// v3.5.5：自适应纠正（对齐 Codex/agent-harness "机制决定行为"）——
    /// 模型直接发 tool_calls 但本轮没写可见正文解说时，不执行工具，注入纠正消息重跑一轮，
    /// 逼模型先写"先解说后执行"的正文。此字段为待注入的纠正消息（仅进 API 请求，不显示为 UI 气泡）。
    private var pendingNarrationCorrection: String? = nil
    /// v3.5.5：连续纠正次数——同一 tool 决策最多纠正 2 次仍不解说就放行执行，避免死循环。
    private var narrationCorrectionCount = 0
    /// v3.5.6：工具参数 schema 预校验——模型调工具但缺必填参数时，不执行，注入纠正消息重跑
    /// 一轮逼它补齐再调（对齐 harness "机制决定行为"，治"invalid params required 盲试"老毛病）。
    private var pendingParamCorrection: String? = nil
    /// v3.5.6：参数纠正连续次数——同一 tool 决策最多纠正 2 次仍缺参就放行执行，避免死循环。
    private var paramCorrectionCount = 0
    /// v4.3.25：空回复纠正——工具结果回来、模型最终却输出空文本时，注入"请给结论"纠正
    /// 重跑一轮，不再静默结束（用户实测"空结果会卡死，AI 不进行下一步，必须重新发消息"）。
    private var pendingEmptyReplyCorrection: String? = nil
    /// v4.3.25：空回复纠正连续次数——最多 2 次仍空就停止，避免无限重跑。
    private var emptyReplyCorrectionCount = 0
    /// v3.1.70：活动请求绑定的会话 ID——请求由哪个会话发起就写回哪个会话。
    /// 修复"请求进行中切换会话，AI 输出错位/写错会话" (用户实测：老会话未暂停，切换新会话后输出仍乱）。
    private var activeConvId: UUID?
    /// v4.5.8：永不清除的"发起请求的会话"锁定——activeConvId 会在停止/请求结束时清 nil，
    /// 若此刻流式仍在回调，activeConvIndex 兜底 selectedIndex 就会把 AI 输出写进切换后的会话 (用户实测)。
    /// requestSessionId 只在下一次 send() 时覆盖，不受停止/切换影响，保证流式始终写回发起会话。
    private var requestSessionId: UUID?
    /// v3.5.16：用户点了「停止」——设 true 后 runLoop 每轮开头检查，若已停止则不再继续递归
    /// (修复"点了暂停/停止还在继续发消息"：此前进度只取消当前 client，递归会新建 client 接着跑)。
    private(set) var stopRequested = false
    /// v4.3.77：工具批量循环需读（停止后跳出，不再装剩余包）
    /// v7.15.2：同时用作熔断作用域——每次 send 换新，旧 run 的熔断标记不影响本轮。
    private var runToken = UUID()

    private let key = "xosvi.conversations"

    /// v6.6.17：后台 worker——为"一个会话在跑时，另一个会话也能同时跑"而生。
    /// worker 持有独立的一套运行状态（isLoading/currentClient/流式缓冲/计数器），
    /// 因此两个会话互不干扰；它不读也不写共享存储，结果由 BackgroundRunManager 合并回主实例。
    let isBackgroundWorker: Bool

    init(background: Bool = false) {
        isBackgroundWorker = background
        if !background { load() }
    }

    var selectedIndex: Int? {
        conversations.firstIndex { $0.id == selectedId }
    }

    /// v3.1.70：活动请求的会话 index (优先活动会话，兜底当前选中会话）
    private var activeConvIndex: Int? {
        if let id = activeConvId ?? requestSessionId, let i = conversations.firstIndex(where: { $0.id == id }) {
            return i
        }
        // v6.6.26：运行期间**禁止**回退到 selectedIndex。
        // 真机现象：A 在跑时切到 B 发消息，由于 activeConvId 解析不到，
        // appendToCurrent 回退到"当前选中"，把 B 的消息/A 的输出写进了同一个会话。
        // 拿不到归属就返回 nil（调用方丢弃这次写入），宁可少一条也不写错会话。
        if isLoading { return nil }
        return selectedIndex
    }

    var currentMessages: [ChatMessage] {
        guard let idx = selectedIndex else { return [] }
        return conversations[idx].messages
    }

    var currentTitle: String {
        guard let idx = selectedIndex else { return "会话" }
        return conversations[idx].title
    }

    /// v4.5.8：当前选中会话是否正在请求——右下角"停止"按钮据此显示。
    /// 此前用全局 isLoading：请求中切到别的会话，新会话右下角也显示红色"停止"(该会话并无请求)，困惑。
    var selectedIsRequesting: Bool {
        isLoading && selectedIndex == activeConvIndex
    }

    func newConversation(title: String = "新会话") {
        let conv = ChatConversation(title: title, createdAt: Date(), updatedAt: Date(), messages: [])
        conversations.insert(conv, at: 0)
        selectedId = conv.id
        // v2.9.22：新会话清空工具会话授权 (AI 需重新搜索/决定）
        ToolRegistry.shared.clearSessionApproval()
        save()
    }

    func select(_ id: UUID) {
        // v2.9.12：打开会话即视为"最近使用"，刷新 updatedAt 并重排到最前
        if selectedId != id, let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].updatedAt = Date()
        }
        selectedId = id
        sortAndSave()
    }

    /// v3.1.70：写入活动请求的会话 (无活动请求时写入当前选中会话）


    func appendToCurrent(_ message: ChatMessage) {
        guard let idx = activeConvIndex else { return }
        var conv = conversations[idx]
        if conv.messages.isEmpty {
            conv.title = title(from: message.content)
        }
        // v7.9.11：把「被工具卡打断的半句话」接回去。
        //
        // 现场（截图）：AI 说「刚才发现白」→ 调 control → 再回「描里已经有 …」，
        // 一句话被拆到两三个气泡里，看起来像错位。
        // 根因：每一轮工具调用都会开一条新的 assistant 消息，模型跨轮写同一句话时就被切开。
        // 规则（保守）：新消息是纯文本、上一条 assistant 文本没写完（不以句末标点结尾）、
        // 且两者之间只有工具消息 —— 就接回上一条，不再新开气泡。
        if message.role == "assistant",
           message.toolCalls == nil,
           !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let prev = conv.messages.lastIndex(where: { $0.role == "assistant" }) {
            let between = conv.messages[(prev + 1)...]
            let onlyTools = between.allSatisfy { $0.role == "tool" }
            let prevText = conv.messages[prev].content
            // v9.1：结束符判定放宽。原来只认 。！？.!?: 和换行，以 ）」》】** … 代码块 结尾的
            // 句子被判成"没写完"，于是被无分隔符地并进下一段 → 用户看到的"断句不完整/串味"。
            let endings = ["。", "！", "？", ".", "!", "?", "：", ":", "\n",
                           "）", ")", "」", "》", "】", "”", "’", "…", "```", "**"]
            let unfinished = !endings.contains { prevText.hasSuffix($0) }
            if onlyTools, unfinished, !prevText.isEmpty {
                let glue = prevText.hasSuffix("\n") ? "" : ""
                conv.messages[prev].content = prevText + glue + message.content
                if let th = message.thinking, !th.isEmpty,
                   (conv.messages[prev].thinking ?? "").isEmpty {
                    conv.messages[prev].thinking = th
                }
                conv.updatedAt = Date()
                conversations[idx] = conv
                sortAndSave()
                return
            }
        }
        // v8.4：**永远 append，不再按时间戳回插**。
        //
        // 旧 v7.9.10 逻辑"按 timestamp 插到正确位置"正是「我发的消息跑到 AI 回复下面」的
        // 根因之一：旧轮的回复晚到时被插回用户消息之前 → 用户视角消息顺序错乱；
        // 且同秒时间戳（后台线程生成 Date）会让插入位置抖动。
        // 新规则：写入顺序 = 展示顺序。晚到的旧轮产物排在后面是可接受的
        // （同会话防重入已由 send 里的 cancelCurrent 保证，乱序窗口极小）；
        // 时序归位交给 UI 层不需要、也不应该做。
        conv.messages.append(message)
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
        // v9.1：不再调用 mergeSplitAssistantFragments()。
        // 它按「上一个 assistant 文本是否以句末标点结尾」猜两段该不该合并，以 ）」** ，、 结尾的
        // 句子全被判成"没写完"，然后**无分隔符**直接黏成一句——用户看到的"断句不完整/句子串味"
        // 就是它造成的。半句话被工具打断的问题应该在流式层用同一 message id 累积修，不能在落盘层猜。
    }

    /// v3.1.70：更新活动请求会话内消息内容 (无活动请求时用当前选中会话）
    func updateMessageContent(id: UUID, content: String) {
        guard let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages[mi].content = content
        // v9.1：覆盖时同步 parts 里的 text 段（保留 reasoning / toolCall 及其顺序与结果）。
        //
        // 旧写法 `parts[ti] = .text(content)` 把**整条内容**塞进最后一个 text 段。
        // 一条消息里若有多个 text 段（工具调用前后各一段），渲染按 effectiveParts 走，
        // 结果是「前面那段的文字还在 + 最后一段被换成全文」——同一句话重复、顺序看着像断裂，
        // 就是用户反馈的"断句不完整"。现在按段数分别处理：
        //   · 只有一段 text：直接覆盖（原行为）
        //   · 多段：只有当 content 确实以「前面各段拼接」为前缀时，才把增量写进最后一段；
        //           对不上就只更新 content，不动 parts（宁可少更新，也不制造重复/错位）
        var parts = conversations[idx].messages[mi].effectiveParts
        let textIndices = parts.indices.filter { if case .text = parts[$0] { return true }; return false }
        if textIndices.count == 1, let ti = textIndices.first {
            parts[ti] = .text(content)
            conversations[idx].messages[mi].parts = parts
        } else if let ti = textIndices.last {
            var prefix = ""
            for i in textIndices.dropLast() {
                if case .text(let t) = parts[i] { prefix += t }
            }
            if content.hasPrefix(prefix) {
                parts[ti] = .text(String(content.dropFirst(prefix.count)))
                conversations[idx].messages[mi].parts = parts
            }
        } else if !content.isEmpty {
            parts.append(.text(content))
            conversations[idx].messages[mi].parts = parts
        }
        ProjectedBlockCache.shared.invalidate(id: id)
        conversations[idx].updatedAt = Date()
    }

    /// v3.1.70：删除活动请求会话内的消息 (无活动请求时用当前选中会话）
    func removeMessage(id: UUID) {
        guard let idx = activeConvIndex,
              let mi = conversations[idx].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.remove(at: mi)
    }

    /// v2.9.13：取消当前进行中的请求 (ChatView 停止按钮）
    func cancelCurrent() {
        stopRequested = true          // v3.5.16：设停止标志，runLoop 递归到下一轮即停
        RunScope.clear(runToken)      // v7.15.2：清掉本轮可能残留的熔断标记
        // v7.3.0：Alpine 已移除，不再有需要中断的引擎进程
        cancelNetworkRetry()
        currentClient?.cancel()
        currentClient = nil
        // v7.9.9：清掉流式目标——旧流即使还有回调，也不会再往那条气泡里写
        // v9：先把已收到的尾部落盘（否则中断后气泡停在半句），再清流式态。
        // 用显式 sid 版本——下面马上会把 streamingMessageId 置 nil。
        let sidToFlush = streamingMessageId
        if Thread.isMainThread {
            streamThrottle.flushNow()
            flushStreamBuffers(into: sidToFlush)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.streamThrottle.flushNow()
                self.flushStreamBuffers(into: sidToFlush)
            }
        }
        if let sid = sidToFlush { streamProjections.removeValue(forKey: sid) }
        streamingMessageId = nil
        isLoading = false
        statusText = nil
        // v2.9.82：回收后台任务
        TaskNotify.shared.endBackground()
        // v3.1.70：停止——解除活动会话绑定
        activeConvId = nil
    }

    /// v6.6.17：把后台 worker 跑完的会话合并回主实例（整体替换 messages/title）。
    /// 冲突策略：以后台结果为准——它在启动时拿的是快照，期间用户在 B 里手改会被覆盖；
    /// 这是"后台跑任务"的正常取舍，UI 上后台会话只展示最终结果。
    func mergeBackgroundResult(_ conv: ChatConversation) {
        guard !isBackgroundWorker else { return }
        if let i = conversations.firstIndex(where: { $0.id == conv.id }) {
            var c = conv
            c.updatedAt = Date()
            conversations[i] = c
        }
        sortAndSave()
    }

    func clearCurrent() {
        guard let idx = selectedIndex else { return }
        var conv = conversations[idx]
        conv.messages.removeAll()
        conv.title = "新会话"
        conv.updatedAt = Date()
        conversations[idx] = conv
        sortAndSave()
    }

    func delete(at offsets: IndexSet) {
        conversations.remove(atOffsets: offsets)
        if selectedId != nil && !conversations.contains(where: { $0.id == selectedId }) {
            selectedId = conversations.first?.id
        }
        sortAndSave()
    }

    // MARK: - v6.9.12：对话列表（豆包式）配套操作

    /// 单个会话的消息（列表页做搜索命中时用，避免碰 selected 语义）
    func messages(in id: UUID) -> [ChatMessage] {
        conversations.first(where: { $0.id == id })?.messages ?? []
    }

    /// 会话标题重命名（空标题忽略，最多 60 字）
    func rename(_ id: UUID, to newTitle: String) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = String(t.prefix(60))
        sortAndSave()
    }

    /// 按 id 删除（列表页没有 IndexSet 上下文）
    func deleteConversations(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        conversations.removeAll { ids.contains($0.id) }
        if let sel = selectedId, ids.contains(sel) { selectedId = nil }
        if selectedId == nil { selectedId = conversations.first?.id }
        sortAndSave()
    }

    func send(_ text: String, using config: ModelConfig, imageDataURLs: [String]? = nil,
              reasoningLevel: Int = 0, smartSearch: Bool = true,
              appendUserMessage: Bool = true, in convId: UUID? = nil) {
        liveReasonStart = nil

        // v6.6.17：会话级并发——本实例正在跑 A，用户切到 B 又发消息时，
        // 把 B 交给独立的后台 worker（它有自己的整套运行状态），
        // 这里只负责把用户消息落到 B 的 UI 上，然后在完成时合并结果。
        if !isBackgroundWorker, isLoading,
           let running = activeConvId ?? requestSessionId,
           running != selectedId,
           let idx = selectedIndex {
            var queued = ChatMessage(role: "user", content: text)
            if let imgs = imageDataURLs, !imgs.isEmpty { queued.imageDataURLs = imgs }
            conversations[idx].messages.append(queued)
            conversations[idx].updatedAt = Date()
            let snapshot = conversations[idx]
            sortAndSave()
            BackgroundRunManager.shared.start(conversation: snapshot, config: config,
                                              reasoningLevel: reasoningLevel, smartSearch: smartSearch)
            return
        }
        // v7.9.9：同一会话里上一轮还在回复就再发一条 → 先把旧请求停掉。
        // 否则两条流会同时往同一个 messages 数组里写：旧回复继续更新它自己那条
        // （位置在用户新消息之前），等它写完，界面上就变成「我发的消息跑到 AI 回复下面」。
        if !isBackgroundWorker, isLoading,
           (activeConvId ?? requestSessionId) == (convId ?? selectedId) {
            cancelCurrent()
        }
        // v2.9.97：记住最近使用的模型，顶栏/下次启动立即恢复
        ModelStore.shared.markUsed(config.id.uuidString)
        // v7.15.2：换 run token——上一轮的熔断标记不能影响本轮
        runToken = UUID()
        refineInFlight = false
        didRefineThisMessage = false
        // v6.6.4：请求发出即开后台保活（旧逻辑等首个 delta 才开，
        // 等待首字期间切后台会被挂起 → "后台任务不继续"）
        BackgroundKeepAlive.shared.start()
        // v2.9.82：请求开始——首次要通知权限 + 开启后台任务延长
        TaskNotify.shared.requestPermissionIfNeeded()
        TaskNotify.shared.beginBackground()
        // v2.9.87：新一轮请求重置网络重试状态
        retriedNetworkOnce = false
        cancelNetworkRetry()
        // v3.1.70：请求绑定到发起时的会话——中途切换会话，输出仍写回该会话 (修复输出错位）
        // v6.6.26：写入目标由调用方显式给出（ChatView 知道自己显示哪个会话），
        // 不再依赖全局 selectedId —— 抽屉切换滞后时会把消息写进别的会话。
        let targetConvId = convId ?? selectedId
        activeConvId = targetConvId
        requestSessionId = targetConvId   // v4.5.8：永不清除的锁定兜底 (防 activeConvId 清 nil 后写错会话）
        // v3.4.9：新请求开始，清掉上一轮的"刚产出"标记（避免旧消息被重新打字）
        liveProducedID = nil
        // v3.5.5：新任务开始，重置"先解说后执行"自适应纠正状态（避免跨任务计数器残留）
        narrationCorrectionCount = 0
        pendingNarrationCorrection = nil
        // v3.5.16：新请求开始，清除上次的停止标志（让 runLoop 可继续）
        stopRequested = false
        // v3.5.6：重置工具参数预校验纠正状态
        paramCorrectionCount = 0
        pendingParamCorrection = nil
        // v4.3.25：重置空回复纠正状态（跨任务不残留）
        emptyReplyCorrectionCount = 0
        pendingEmptyReplyCorrection = nil
        var msg = ChatMessage(role: "user", content: text)
        if let imgs = imageDataURLs, !imgs.isEmpty {
            msg.imageDataURLs = imgs
        }
        if appendUserMessage { appendToCurrent(msg) }
        isLoading = true

        // v3.1.66：全量加载所有工具 (tool_search 已删除，不再渐进式披露）
        var baseTools = config.apiProtocol == "Anthropic Messages" ? nil : ToolRegistry.shared.enabledOpenAIToolSchema()
        // v7.1.0：搜索不再由用户开关控制——联网工具默认全开，AI 判断需要时自行调用
        // （web.search / haxbrowser / web.fetch 都在工具集里）。smartSearch 参数保留只为兼容旧调用。
        _ = smartSearch
        // v3.1.66：全量加载，disclosed 机制已不再新增工具 (tool_search 已删），
        // 保留仅为兼容会话内已授权工具 schema 的持久注入。
        let preDisclosed = ToolRegistry.shared.approvedToolNames()
        runLoop(config: config, tools: baseTools, disclosed: preDisclosed, depth: 0, reasoningLevel: reasoningLevel)
    }

    // MARK: - v2.9.87 网络恢复自动重试

    private func shouldRetryOnNetworkRestore(_ err: NSError) -> Bool {
        guard !retriedNetworkOnce, err.code != -999 else { return false }
        // 网络类错误码：断网/找不到主机/网络连接丢失/连接重置
        let networkCodes: Set<Int> = [-1009, -1003, -1005, -1004, -1001]
        let isNetworkError = err.domain == NSURLErrorDomain && networkCodes.contains(err.code)
        // 只对"当前确实断网"的情况等待重试 (确认不是中转站问题）
        return isNetworkError && !AppLifecycleMonitor.shared.isNetworkAvailable
    }

    private func scheduleRetryAfterNetworkRestore(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int) {
        retriedNetworkOnce = true
        retryObserver = NotificationCenter.default.addObserver(
            forName: AppLifecycleMonitor.networkRestored,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            if let o = self.retryObserver {
                NotificationCenter.default.removeObserver(o)
                self.retryObserver = nil
            }
            self.statusText = "网络已恢复，自动重试…"
            self.isLoading = true
            self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
        }
    }

    private func cancelNetworkRetry() {
        if let o = retryObserver {
            NotificationCenter.default.removeObserver(o)
            retryObserver = nil
        }
    }

    /// v2.9.127：新一轮请求开始——清空实时轨迹
    func beginTrail() {
        DispatchQueue.main.async {
            self.liveTrail = []
        }
    }

    /// v2.9.127：追加一条实时轨迹步骤
    func trailStep(_ step: TrailStep) {
        DispatchQueue.main.async {
            self.liveTrail.append(step)
        }
    }

    /// v2.9.127：把实时轨迹持久化到最后一条 assistant 消息 (AI 回复done后调用）
    /// thinking 非空时把"已思考"插到轨迹最前 (对齐豆包流程第一步）。
    /// 收尾：残留 running 步骤统一标OK/failed (消息报错则标failed）。
    func attachTrail(to messageId: UUID?, thinking: String? = nil) {
        guard let sid = messageId, !liveTrail.isEmpty else { return }
        DispatchQueue.main.async {
            if let idx = self.activeConvIndex,
               let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) {
                var trail = self.liveTrail
                let isErr = self.conversations[idx].messages[mi].isError
                for i in 0..<trail.count where trail[i].status == .running {
                    var s = trail[i]
                    s.status = isErr ? .failed : .success
                    trail[i] = s
                }
                // 思考去重：实时流已产生 think 步骤则不重复插入
                if let th = thinking, !th.isEmpty, !trail.contains(where: { $0.kind == .think }) {
                    trail.insert(TrailStep.done(.think, "已思考", detail: String(th.prefix(300))), at: 0)
                }
                self.conversations[idx].messages[mi].trail = trail
                self.save()
            }
        }
    }

    private func runLoop(config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int = 0) {
        // v3.5.16：用户点了「停止」——立即停，不再继续递归 (修复"停止后还在发消息")
        if stopRequested {
            isLoading = false
            statusText = nil
            requestRound = 0
            runningTool = nil
            currentClient?.cancel()
            currentClient = nil
            TaskNotify.shared.endBackground()
            activeConvId = nil
            self.liveTrail = []
            return
        }
        // v2.9.25：不再限制工具调用轮次 (用户可手动点「停止」）。
        // v4.3.71：移除 60 轮极端安全上限——长会话已由 LLM Compaction 控制上下文体积，
        // 不再需要轮次硬停（用户仍可随时点「停止」按钮中断；工具死循环仍由 _loop_hint 提示）。
        // v2.9.34：请求过程可视化
        DispatchQueue.main.async {
            self.requestRound = depth + 1
            self.requestRounds = 0   // v4.3.71：无轮次上限
            self.statusText = "已准备请求 (正在整理会话与可用工具)"
            self.liveTrail = []   // v2.9.127：新一轮清空实时轨迹
        }

        // 动态合并：白名单 schema + 已披露工具的 schema (去重）
        // v2.9.175：tools 为 nil (Anthropic 协议）时也走空数组合并——Anthropic 通道
        // 现在同样能拿到 coreTools + 已披露工具的 schema (OpenAIClient 已支持转换）。
        var effectiveTools = tools ?? []
        if !disclosed.isEmpty {
            var existing = Set<String>()
            for t in effectiveTools {
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String {
                    existing.insert(n)
                }
            }
            for name in disclosed {
                let apiName = name.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").inverted).joined(separator: "_")
                if existing.contains(apiName) { continue }
                if let schema = ToolRegistry.shared.openAISchema(for: name) {
                    effectiveTools.append(schema)
                    existing.insert(apiName)
                }
            }
        }

        let client = OpenAIClient(config)
        client.currentReasoningLevel = reasoningLevel
        currentClient = client
        let prepared = messagesForAPI(budget: config.contextTokens)
        var history = prepared.messages
        // v2.9.138：模块化 system prompt 组装 (稳定前缀工程）——
        // 稳定块 (系统指令→开发者指令）在前、动态状态块 (设备/App/工作区/会话）在后，
        // 稳定前缀保持字节一致 → 官方 API 前缀缓存可直接matched (Anthropic/OpenAI）。
        // v6.9.10：自动路由下，selected 固定用 default 作为"行为底盘"，
        // 具体模式由 routerBlock 让 AI 自行判定；手动模式下仍用用户选的模式。
        // 注意：必须走 mergedPrompt(base) 而不是直接取 builtin.content，
        // 否则会丢掉环境提示词（=== 环境提示词（系统层 ===）这一段。
        let basePrompt: SystemPrompts.Prompt
        if SystemPrompts.shared.autoRoutingEnabled,
           let def = SystemPrompts.builtin.first(where: { $0.id == "default" }) {
            basePrompt = SystemPrompts.shared.mergedPrompt(def)
        } else {
            basePrompt = SystemPrompts.shared.selected
        }
        // v9.1：**合并成一条 system 消息**。
        // 旧写法往 history 头插 4 条独立 system（base / router / 开发者指令 / 动态状态），
        // 多条 system 相互竞争语义，模型容易挑错的规则执行 → 表现为"跑偏、逻辑不严谨"。
        // 顺序仍是「稳定前缀在前、动态状态在后」（前缀缓存仍然命中），只是合并成一条。
        var systemBlocks: [String] = [basePrompt.content]
        if let router = SystemPrompts.shared.routerBlock(), !router.isEmpty {
            systemBlocks.append(router)
        }
        if let devInstr = DeveloperInstructionStore.shared.defaultInjectionContent(), !devInstr.isEmpty {
            systemBlocks.append("以下是开发者指令，请始终遵守：\n" + devInstr)
        }
        systemBlocks.append(Self.toolArbitration)
        systemBlocks.append(Self.dynamicStatePrompt())
        history.insert(ChatMessage(role: "system", content: systemBlocks.joined(separator: "\n\n---\n\n")), at: 0)
        // v3.5.5：自适应纠正注入——若上一轮模型漏了"先解说后执行"（直接发工具没写可见解说），
        // 把纠正消息拼到本次请求末尾（最新指令，模型必须回应）。仅进请求、不显示为 UI 用户气泡。
        if let correction = self.pendingNarrationCorrection, !correction.isEmpty {
            history.append(ChatMessage(role: "user", content: correction))
            self.pendingNarrationCorrection = nil
        }
        // v3.5.6：工具参数预校验纠正注入——上一轮调工具缺必填参数被拦，同样拼到请求末尾。
        if let pcorr = self.pendingParamCorrection, !pcorr.isEmpty {
            history.append(ChatMessage(role: "user", content: pcorr))
            self.pendingParamCorrection = nil
        }
        // v4.3.25：空回复纠正注入——上一轮工具执行后模型输出空白，拼到请求末尾逼其给结论。
        if let ecorr = self.pendingEmptyReplyCorrection, !ecorr.isEmpty {
            history.append(ChatMessage(role: "user", content: ecorr))
            self.pendingEmptyReplyCorrection = nil
        }

        client.send(messages: history, compactSource: prepared.compactSource, tools: effectiveTools, onStatus: { status in
            DispatchQueue.main.async {
                // v2.9.34：带轮次前缀；v4.3.71 无上限 (requestRounds==0) 时不显示 "/0"
                if self.requestRound > 0 && !status.contains("第 ") {
                    if self.requestRounds > 0 {
                        self.statusText = "正在请求模型 (第 \(self.requestRound)/\(self.requestRounds) 轮)· \(status)"
                    } else {
                        self.statusText = "正在请求模型 (第 \(self.requestRound) 轮)· \(status)"
                    }
                } else {
                    self.statusText = status
                }
            }
        }, onDelta: { delta in
            // v2.9.53：流式逐字显示
            // v6.2.7：节流——delta 进缓冲，80ms 合并 flush（见 scheduleStreamFlush），
            // 避免每个 token 都触发整页重渲染导致长输出卡顿
            DispatchQueue.main.async {
                if self.streamingMessageId == nil {
                    // 第一次 delta：创建流式消息（空内容，缓冲 flush 时填充）
                    let msg = ChatMessage(role: "assistant", content: "")
                    self.streamingMessageId = msg.id
                    self.liveProducedID = msg.id
                    self.appendToCurrent(msg)
                }
                self.streamDeltaBuffer += delta
                // v6.5.4：流式有活动 → 后台保活（复用 AppTools 的 BackgroundKeepAlive.shared：
                // 静音音频 + BGTask 双保险，切后台继续接收 AI 回复）
                BackgroundKeepAlive.shared.start()
                self.scheduleStreamFlush()
            }
        }, onThinking: { delta in
            // v3.5.4：思考只进黄泡(message.thinking) + thinkBuffer(供 toolCalls 装配)，
            // 不再写 liveTrail——否则实时轨迹卡也渲染思考，导致同一思考出现两次 (用户实测截图)。
            // 实时轨迹卡(liveTrail)只显示"工具执行步骤"：工具名/命令/结果，绝不显示思考文字。
            DispatchQueue.main.async {
                if self.liveReasonStart == nil { self.liveReasonStart = Date() }
                self.thinkBuffer += delta
                // v6.2.7：思考显示也走节流缓冲（thinkBuffer 即时累加供 toolCalls 装配）
                if self.streamingMessageId != nil {
                    self.streamThinkBuffer += delta
                    self.scheduleStreamFlush()
                } else {
                    // v3.5.16：防"思考重复两次"——.text 最终化(streamingMessageId=nil)后又来一段 onThinking 时，
                    // 会在这里再建一条空正文+思考消息，与上一条已含相同思考的 assistant 消息重复
                    // (顶部"已深度思考"+ 底部"思考中…"两遍)。新建前先查上一条是否已含这段思考，是则跳过。
                    var skipDup = false
                    if let ci = self.activeConvIndex, let li = self.conversations[ci].messages.indices.last {
                        let last = self.conversations[ci].messages[li]
                        if last.role == "assistant", let ex = last.thinking, !ex.isEmpty {
                            if ex == delta || ex.contains(delta) || delta.contains(ex) {
                                skipDup = true
                            }
                        }
                    }
                    if !skipDup {
                        let msg = ChatMessage(role: "assistant", content: "")
                        self.streamingMessageId = msg.id
                        self.liveProducedID = msg.id
                        self.appendToCurrent(msg)
                        self.streamThinkBuffer += delta
                        self.scheduleStreamFlush()
                    }
                }
            }
        }) { result in
            // v6.2.7：completion 入口同步 flush 节流缓冲尾部（必须在 finalize 改 streamingMessageId 之前）
            // v7.15.3：改 main.async——originally 用 main.sync，若 completion 恰在主线程
            // 同步等待某个后台队列（URLSession delegate / 自定义串行队列），就是经典死锁。
            // 牺牲尾部几微秒的顺序性，换绝不卡死。
            // v8.4：双保险——同步 flush 一次（在主线程时立即生效）+ 再 async 一次兜底
            // "completion 在主线程但 delta 还在别的队列里排队"的竞态。done 处理里随后
            // 还有"取更完整一方"的合并逻辑，最终内容以合并结果为准，不会丢字。
            if Thread.isMainThread {
                self.streamThrottle.flushNow()   // v9：立即执行挂起的最后一批
                self.flushStreamBuffers()
            }
            DispatchQueue.main.async {
                self.streamThrottle.flushNow()
                self.flushStreamBuffers()
            }
            // v6.5.4：流式结束 → 停后台保活
            BackgroundKeepAlive.shared.stop()
            DispatchQueue.main.async {
                self.statusText = nil
                switch result {
                case .success(.text(let text, let thinking)):
                    // v7.8.1：模型把思考写进正文时剥离出来（kelivo thinking_tag_parser 同款规则）
                    let inline = InlineThink.extract(text)
                    let wantsInline = (thinking?.isEmpty ?? true) && inline.hasThinking
                    let finalText = wantsInline ? inline.visible : text
                    let finalThinking: String? = (thinking?.isEmpty == false)
                        ? thinking
                        : (inline.hasThinking ? inline.thoughts.joined(separator: "\n\n") : thinking)
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    self.thinkBuffer = "" // 重置缓冲区
                    // v2.9.138：自动会话记忆——一轮完整回复后落库 (供下会话 BM25 检索）
                    if let idx = self.activeConvIndex {
                        let msgs = self.conversations[idx].messages
                        let lastUser = msgs.last { $0.role == "user" }?.content ?? ""
                        let usedTools = msgs.compactMap { $0.toolName }
                        KnowledgeStore.shared.appendSessionMemory(
                            user: String(lastUser.prefix(80)),
                            reply: String(text.prefix(150)),
                            tools: Array(Set(usedTools)).sorted().suffix(8))
                    }
                    // v2.9.127：轨迹——回复done，附到消息持久化
                    self.trailStep(.done(.note, "AI 回复done", detail: String(text.prefix(80))))
                    // v2.9.82：done通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "✅ AI 已回复", body: String(text.prefix(60)))
                    if let sid = self.streamingMessageId {
                        // v6.4.0：绝不因"最终文本为空/更短"丢失已流式输出（用户反馈"丢失输出会话"）。
                        // 旧实现直接用最终 text 覆盖流式内容——文本为空或 provider 只回摘要时，
                        // 用户已看到的内容被抹掉。改为取更完整的一方（合并而非覆盖）。
                        var merged = text
                        if let ci = self.activeConvIndex,
                           let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                            let streamed = self.conversations[ci].messages[mi].content
                            if streamed.count > merged.count { merged = streamed }
                        }
                        self.updateMessageContent(id: sid, content: merged)
                        if let idx = self.activeConvIndex,
                           let mi = self.conversations[idx].messages.firstIndex(where: { $0.id == sid }) {
                            if let th = finalThinking, !th.isEmpty {
                                self.conversations[idx].messages[mi].thinking = th
                                var m = self.conversations[idx].messages[mi]
                                self.stampReasoning(&m, thinking: th)
                                self.conversations[idx].messages[mi] = m
                            }
                        }
                        self.attachTrail(to: sid, thinking: thinking)
                        // v9：本轮结束——丢弃增量投影（完成态走 ProjectedBlockCache）
                        self.streamProjections.removeValue(forKey: sid)
                        self.streamingMessageId = nil
                        // v6.5.7：自我批判精炼——深度思考开、答案足够长、本轮未精炼过 → 追加一轮"批判→改进"
                        // v9.4：思考已内置自动——"自我批判精炼"也随之自动：深档（≥2）的回答才追加一轮批判，
                        // 且答案需足够长。chat_auto_refine 作为可选的强制开关注入保留，不再有设置界面。
                        let thinkOn = true
                        // v7.15.3：改为显式开关（默认关）。原来只要"思考开 + 答案 >120 字"就
                        // 静默再发一次完整 LLM 请求并把结果 += 追加到同一条消息：
                        // 用户看到两个答案、成本翻倍，且不可预期。
                        // 需要时在 设置 → 深度思考 里打开 chat_auto_refine。
                        let refineOn = UserDefaults.standard.bool(forKey: "chat_auto_refine")
                        if refineOn, thinkOn, !self.refineInFlight, !self.didRefineThisMessage,
                           text.count > 120 {
                            self.didRefineThisMessage = true
                            self.refineInFlight = true
                            self.autoRefine(originalAnswer: text, appendTo: sid)
                        }
                    } else {
                        // v3.5.16：修复"思考显示两次"——流式中 onThinking 可能已建了一条"空正文+思考"消息
                        // (思考先于正文到、且正文没进它），此时若直接 appendToCurrent 会再建第二条
                        // (顶部"已深度思考" + 底部"思考中"重复)。改为复用那条空思考消息填正文。
                        var reused = false
                        if let ci = self.activeConvIndex {
                            var msgs = self.conversations[ci].messages
                            if let li = msgs.indices.last,
                               msgs[li].role == "assistant",
                               msgs[li].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               msgs[li].thinking?.isEmpty == false {
                                msgs[li].content = finalText
                                if let th = finalThinking, !th.isEmpty {
                                    msgs[li].thinking = th
                                    self.stampReasoning(&msgs[li], thinking: th)
                                }
                                self.conversations[ci].messages = msgs
                                self.streamingMessageId = nil
                                self.liveProducedID = nil
                                self.attachTrail(to: msgs[li].id, thinking: thinking)
                                reused = true
                            }
                        }
                        if !reused {
                            var am = ChatMessage(role: "assistant", content: finalText)
                            if let th = finalThinking, !th.isEmpty {
                                am.thinking = th
                                self.stampReasoning(&am, thinking: th)
                            }
                            self.appendToCurrent(am)
                            self.liveProducedID = am.id
                            self.attachTrail(to: am.id, thinking: thinking)
                        }
                    }
                    // v4.3.25：空回复兜底——工具结果回来、模型最终却输出空文本时，
                    // 不再静默结束（用户实测"空结果会卡死，AI 不进行下一步，必须重新发消息"）。
                    // 若会话末尾是 tool 结果消息且本条回复为空白，注入纠正重跑一轮逼模型给结论；
                    // 最多 2 次仍空就停止，避免无限重跑。
                    let trimmedFinal = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    var lastMsgIsTool = false
                    if let ci = self.activeConvIndex {
                        if let last = self.conversations[ci].messages.last {
                            lastMsgIsTool = (last.role == "tool")
                        }
                    }
                    if trimmedFinal.isEmpty && lastMsgIsTool && self.emptyReplyCorrectionCount < 2 {
                        self.emptyReplyCorrectionCount += 1
                        self.pendingEmptyReplyCorrection = "你刚刚执行了工具但回复正文是空的。请基于已返回的工具结果，用一两句话向用户给出明确结论（或说明下一步该做什么），不要只回复空白或「Done」。"
                        self.trailStep(.done(.note, "空回复纠正", detail: "模型空文本回复，注入纠正重跑", ok: false))
                        // 清掉刚渲染的空 assistant 消息，避免界面残留空白气泡
                        if let sid = self.streamingMessageId {
                            self.removeMessage(id: sid)
                        } else if let ci = self.activeConvIndex {
                            var msgs = self.conversations[ci].messages
                            if let li = msgs.indices.last,
                               msgs[li].role == "assistant",
                               msgs[li].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                msgs.remove(at: li)
                                self.conversations[ci].messages = msgs
                            }
                        }
                        self.streamingMessageId = nil
                        self.liveProducedID = nil
                        self.thinkBuffer = ""
                        self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel)
                        return
                    }
                    self.emptyReplyCorrectionCount = 0
                    // v3.5.3：文本工具调用兜底——模型把 shell.exec("...")/shell_exec(...) 写成文本
                    // (而非结构化 tool_call) 时，系统本不执行、任务卡死。这里检测最终文本里的文本式
                    // shell 调用，提取命令并真正执行，继续 agent 循环（提示词兜底不住，代码兜底保证）。
                    self.runTextualShellIfNeeded(text: text, config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
                    // v3.1.70：整条请求链 (含工具递归）结束——解除活动会话绑定
                    self.activeConvId = nil
                case .success(.toolCalls(let calls, let thinking, let narrationContent)):
                    // v3.5.2：系统级"一次一个工具"硬约束——模型一次批几个 toolCalls，
                    // 都裁成第一个：assistant 消息与执行只带这一个，执行完回模型让它看到
                    // 结果再决定下一步（一个接一个）。依赖调用必须等前一个结果才能决定下一步，
                    // 合批执行会让模型猜结果(违规)；提示词不可靠，代码兜底强制一次一个。
                    // v7.15.3：保持"一次一个"（v3.5.2 的设计：依赖调用必须看到前一个结果
                    // 才能决定下一步），但把被裁掉的个数记下来——否则模型不知道自己发出的
                    // 第 2..N 个调用被静默丢弃，会反复重发同一批，白白多跑数轮。
                    // TODO(verify): 若要放开为整批执行，需同时改造：
                    //   ① 一次写回 N 条 tool 消息（sanitizeToolSequence 已支持 1:N）
                    //   ② 熔断计数口径（loopBlockedError 目前按单工具计）
                    //   ③ 循环提示 _loop_hint 的批次语义
                    //   ④ ToolDefinition.prerequisites 是否足以表达依赖顺序
                    let truncatedCalls = calls.count > 1 ? calls.count - 1 : 0
                    let calls = Array(calls.prefix(1))
                    // v3.1.72：思考(reasoning)与可见输出(content)分开存放——
                    // 旧逻辑把流式可见文本+思考合并成 thinkText 塞进 assistant.content，
                    // 又把同一 thinkText 塞进 tool 消息 thinking，导致 UI 上"回复内容"和
                    // "思考内容"显示一模一样、每轮工具调用重复一次 (用户实测反馈）。
                    var visibleText = ""
                    var reasoningText = self.thinkBuffer
                    if let th = thinking, !th.isEmpty {
                        reasoningText = reasoningText.isEmpty ? th : "\(reasoningText)\n\(th)"
                    }
                    // 先取流式可见文本（模型若已发解说则以其为准）
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        visibleText = self.conversations[ci].messages[mi].content
                    }
                    // v3.5.15：兜底——非流式 chat/completions 没有 streamingMessageId，
                    // 但模型写的正文解说已由 .toolCalls 的 content 透传出来，直接用当 visibleText。
                    if visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let nc = narrationContent, !nc.isEmpty {
                        visibleText = nc
                    }
                    // v3.5.5：自适应纠正（对齐 Codex / agent-harness "机制决定行为"）——
                    // 模型直接发 tool_calls 但本轮没写可见正文解说时，不执行工具，注入纠正消息
                    // 重跑一轮逼它先写"先解说后执行"的正文。这不是提示词，是机制：模型不解说就不放行。
                    let visibleTrim = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                    // v3.5.10：解说纠正上限 2→4（用户要求加强硬门槛"先解说后执行"）——
                    // 模型不解说就不放行，给到 4 次机会逼它写正文；仍不写则由 running 步骤卡兜底可见性。
                    if visibleTrim.isEmpty && self.narrationCorrectionCount < 4 {
                        self.narrationCorrectionCount += 1
                        self.pendingNarrationCorrection = "你准备调用工具，但还没有向用户说明要做什么。请先用一两句自然语言（写在回复正文 content 里，不要放进思考）向用户说明你正要做什么、为什么，然后再调用工具。"
                        // 清掉本轮只挂了思考、没写正文的孤立消息，避免"卡在思考中"的观感，再重跑
                        if let sid = self.streamingMessageId,
                           let ci = self.activeConvIndex,
                           let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }),
                           self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.conversations[ci].messages.remove(at: mi)
                        }
                        self.thinkBuffer = ""
                        self.streamingMessageId = nil
                        self.liveProducedID = nil
                        // 重跑下一轮（depth+1 防死循环；narrationCorrectionCount 上限 4 防无限纠正）
                        self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel)
                        return
                    }
                    self.narrationCorrectionCount = 0
                    // v3.5.4：正文解说只取模型自己写在 content 里的文本；模型若光思考没写正文解说，
                    // 正文就保持空(6.A)——不再用 reasoning 自动合成解说（用户明确：▶ 开始执行那种
                    // 机械合成是误解；思考归思考进黄泡，正文只放 AI 自己说的话，空就空着）。
                    if let sid = self.streamingMessageId,
                       let ci = self.activeConvIndex,
                       let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                        // 保留流式可见文本作为回复内容，思考进 thinking 字段，toolCalls 挂上 (不删除重建）
                        // 模型没写正文解说时 visibleText 为空 → content 保持空，只显示思考黄泡 + 工具步骤 (6.A)
                        if self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.conversations[ci].messages[mi].content = visibleText
                        }
                        self.conversations[ci].messages[mi].toolCalls = calls
                        // v9：结构化 parts 同步——toolCall 追加在已有 text 之后（真实产出顺序）
                        var p2 = self.conversations[ci].messages[mi].effectiveParts
                        // 去掉上一次残留的 toolCall 与 roundEnd（重发/重试场景），再按本次 calls 重建
                        p2.removeAll {
                            switch $0 {
                            case .toolCall, .roundEnd: return true
                            default: return false
                            }
                        }
                        for c in calls {
                            p2.append(.toolCall(ToolCallPayload(
                                id: c.id, name: c.name, arguments: c.arguments,
                                result: nil, isError: false, durationMs: nil, previewImage: nil)))
                        }
                        // v9：一轮结束的结构边界（模型这一轮说完了，接下来执行工具）。
                        // 不产生可见块，但让投影器按轮切段（任务视图也靠它分段）；
                        // 也不会回传给模型（MessagePart.isModelInput == false）。
                        p2.append(.roundEnd(reasoningDetails: nil))
                        self.conversations[ci].messages[mi].parts = p2
                        ProjectedBlockCache.shared.invalidate(id: self.conversations[ci].messages[mi].id)
                        // v3.5.4：思考始终写入黄色气泡(message.thinking)，不再要求 content 为空——
                        // 此前 reasoning 被 v3.5.1 打进正文使 content 非空，导致 thinking 永不写入、黄泡为空。
                        // 与正文去重：部分中转把完整回答写进 reasoning_content，与 content 相同则不展示思考。
                        let cText = self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim.isEmpty, !(cText == rTrim || rTrim.contains(cText) || cText.contains(rTrim)) {
                            self.conversations[ci].messages[mi].thinking = reasoningText
                        } else if !rTrim.isEmpty {
                            // 思考与正文重复(中转把完整回答写进 reasoning_content) → 清掉黄泡，避免重复展示
                            self.conversations[ci].messages[mi].thinking = nil
                        }
                    } else {
                        // 无流式消息 (流式未开始就被 toolCalls 打断）：新建 assistant 消息
                        var am = ChatMessage(role: "assistant", content: visibleText, toolCalls: calls)
                        // v9：直接给出结构化 parts（思考→正文→工具），渲染层无需再迁移
                        var ap: [MessagePart] = []
                        let rTrimA = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let vTrimA = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrimA.isEmpty, !(vTrimA == rTrimA || rTrimA.contains(vTrimA) || vTrimA.contains(rTrimA)) {
                            ap.append(.reasoning(reasoningText))
                        }
                        if !visibleText.isEmpty { ap.append(.text(visibleText)) }
                        for c in calls {
                            ap.append(.toolCall(ToolCallPayload(
                                id: c.id, name: c.name, arguments: c.arguments,
                                result: nil, isError: false, durationMs: nil, previewImage: nil)))
                        }
                        ap.append(.roundEnd(reasoningDetails: nil))
                        am.parts = ap
                        let vTrim = visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let rTrim2 = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rTrim2.isEmpty, !(vTrim == rTrim2 || rTrim2.contains(vTrim) || vTrim.contains(rTrim2)) {
                            am.thinking = reasoningText
                        }
                        self.appendToCurrent(am)
                        self.liveProducedID = am.id
                    }
                    self.thinkBuffer = "" // 重置缓冲区
                    self.streamingMessageId = nil
                    // v2.9.127：轨迹——AI 决定调用一批工具
                    self.trailStep(.done(.tool, "AI 选择调用 \(calls.count) 个工具",
                                         detail: calls.map { $0.name }.joined(separator: "、")))
                    // v2.9.31：递归处理一批工具调用 (后台执行，无授权弹窗）
                    // v3.1.72：thinkText 传可见文本 (工具调用前的说明），不再写入 tool 消息 thinking
                    self.processToolCalls(calls, index: 0, toolMessages: [], newlyDisclosed: [],
                                          config: config, tools: tools, disclosed: disclosed, depth: depth,
                                          reasoningLevel: reasoningLevel, thinkText: visibleText,
                                              truncatedCalls: truncatedCalls)
                case .failure(let error):
                    self.isLoading = false
                    self.currentClient = nil
                    self.requestRound = 0
                    self.runningTool = nil
                    self.thinkBuffer = "" // 重置缓冲区
                    self.liveProducedID = nil
                    // v2.9.13：用户主动取消 (-999）不追加错误气泡
                    let nsErr = error as NSError
                    if nsErr.code == -999 {
                        self.statusText = nil
                        self.streamingMessageId = nil
                        // v2.9.82：取消也算结束，回收后台任务但不通知
                        TaskNotify.shared.endBackground()
                        // v3.1.70：用户取消——解除活动会话绑定
                        self.activeConvId = nil
                        return
                    }
                    // v2.9.87：网络类错误 + 当前确认断网 → 等网络恢复自动重试一次
                    if self.shouldRetryOnNetworkRestore(nsErr) {
                        self.statusText = "网络不可用，等待恢复后自动重试…"
                        self.scheduleRetryAfterNetworkRestore(config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel)
                        return
                    }
                    // v2.9.82：failed通知 (后台时）
                    TaskNotify.shared.endBackground()
                    TaskNotify.shared.notifyIfBackground(title: "⚠️ 任务出错", body: String(error.localizedDescription.prefix(60)))
                    // 流式failed时保留已输出的部分文本，追加错误提示
                    if let sid = self.streamingMessageId {
                        // v8.4：断流时把已收到的部分落盘并标注中断——不再静默丢弃。
                        // （此前只置 streamingMessageId=nil，已流式上屏的内容没存进消息本体，
                        // 重发才看得到全文；用户反馈"回复断半句，重发才显示完整"）
                        if let ci = self.activeConvIndex,
                           let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == sid }) {
                            let partial = self.conversations[ci].messages[mi].content
                            if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.conversations[ci].messages[mi].content =
                                    partial + "\n\n[⚠️ 响应中断，以上为已收到部分：\(error.localizedDescription.prefix(80))]"
                                self.conversations[ci].messages[mi].isError = true
                            }
                        }
                        self.streamingMessageId = nil
                    }
                    let errMsg = ChatMessage(role: "assistant", content: "⚠️ \(error.localizedDescription)", isError: true)
                    self.appendToCurrent(errMsg)
                    self.trailStep(.done(.note, "请求failed", detail: String(error.localizedDescription.prefix(200)), ok: false))
                    self.attachTrail(to: errMsg.id)
                    // v3.1.70：请求链结束——解除活动会话绑定
                    self.activeConvId = nil
                }
            }
        }
    }

    /// v2.9.127：轨迹摘要——取 JSON 里 ok/message/status 等关键字段，超长截断
    static func trailSummary(_ json: String) -> String {
        let trimmed = json.count > 300 ? String(json.prefix(300)) : json
        // 去掉换行压扁，便于步骤行内展示
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    /// v3.1.26：把参数 JSON 转成简短摘要 (比如 "url: https://xxx"）
    /// UI 里用特殊颜色显示，太长就截断
    static func summarizeArgs(_ argsString: String) -> String? {
        guard let data = argsString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // 只取前 2 个参数，每个值截断到 50 字符
        let entries = json.prefix(2).map { key, value -> String in
            let val: String
            if let s = value as? String {
                val = s
            } else {
                val = "\(value)"
            }
            let truncated = val.count > 50 ? String(val.prefix(50)) + "..." : val
            return "\(key): \(truncated)"
        }
        return entries.joined(separator: ", ")
    }

    /// v2.9.31：递归处理一批工具调用。工具在后台线程执行 (避免耗时操作阻塞主线程），
    /// 结果经 handleDispatchResult 回主线程继续。
    /// v3.5.3：文本工具调用兜底——从最终文本里提取文本式 shell 调用命令（shell.exec("...") /
    /// shell_exec(command="...") 等）。模型把调用写成文本(而非结构化 tool_call)时系统不执行，
    /// 这里兜底提取出真实命令让 runTextualShellIfNeeded 真正执行。
    private static func extractTextualShellCommand(from text: String) -> String? {
        let patterns = [
            #"shell\.exec\s*\(\s*["']([^"']+?)["']\s*\)"#,          // shell.exec("cmd") / shell.exec('cmd')
            #"shell_exec\s*\(\s*command\s*[:=]\s*["']([^"']+?)["']"#, // shell_exec(command="cmd")
            #"shell_exec\s*\(\s*["']([^"']+?)["']\s*\)"#           // shell_exec("cmd")
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: []) else { continue }
            let ns = text as NSString
            if let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges > 1 {
                let c = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { return c }
            }
        }
        return nil
    }

    /// v3.5.3：执行文本兜底提取出的 shell 命令，把结果作为 tool 消息上屏并继续 agent 循环，
    /// 让模型看到结果后能继续下一步（而非卡死在"写了文本没执行"）。
    private func runTextualShellIfNeeded(text: String, config: ModelConfig, tools: [[String: Any]]?, disclosed: [String], depth: Int, reasoningLevel: Int) {
        guard let cmd = Self.extractTextualShellCommand(from: text) else { return }
        let cmdCopy = cmd
        DispatchQueue.global().async {
            let params: [String: Any] = ["command": cmdCopy]
            let result: Result<[String: Any], Error>
            do { result = .success(try ToolRegistry.shared.dispatch(name: "shell.exec", params: params)) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                var tm = ChatMessage(role: "tool", content: "", toolCallId: UUID().uuidString, toolName: "shell.exec")
                switch result {
                case .success(let r):
                    let raw = Self.jsonString(r)
                    tm.content = raw.count > 8000 ? raw.prefix(8000) + "\n... [工具结果已截断, total \(raw.count) 字符]" : raw
                    tm.toolArgs = String("命令: \(cmdCopy.prefix(120))")
                    tm.toolDuration = 0.01
                case .failure(let e):
                    tm.content = "执行失败: \(e.localizedDescription)"
                    tm.isError = true
                    tm.toolArgs = String("命令: \(cmdCopy.prefix(120))")
                }
                self.appendToCurrent(tm)
                self.liveProducedID = tm.id
                // 继续 agent 循环，模型看到结果后可决定下一步
                self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel)
            }
        }
    }

    private func processToolCalls(_ calls: [ToolCall],
                                  index: Int,
                                  toolMessages: [ChatMessage],
                                  newlyDisclosed: [String],
                                  config: ModelConfig,
                                  tools: [[String: Any]]?,
                                  disclosed: [String],
                                  depth: Int,
                                  reasoningLevel: Int,
                                  thinkText: String = "",
                                  truncatedCalls: Int = 0) {
        // 一次一个硬约束已在 .toolCalls 源头把批次裁成 prefix(1)，这里 calls.count==1，
        // 执行完 index=1 >= calls.count 即回模型。
        if index >= calls.count {
            // v3.4.1：工具气泡已在 handleDispatchResult 逐条实时上屏（对齐 OpenMinis 逐步展示），
            // 不再攒批到最后统一追加 —— 边做边说更接近"直播"。
            // v7.15.3：若上一轮模型一次发了多个调用而被裁成 1 个，明确告诉它还剩几个没执行，
            // 否则它会以为都没执行、反复重发同一批（每次重发又是一整轮往返）。
            if truncatedCalls > 0 {
                self.pendingParamCorrection = "你上次一次给出了多个工具调用，系统按「一次一个」只执行了第一个，"
                    + "另外 \(truncatedCalls) 个已被丢弃、不会自动补执行。请根据已拿到的结果决定下一步，"
                    + "需要的话逐个调用，不要把整批重新发一遍。"
            }
            let merged = Array(Set(disclosed + newlyDisclosed))
            self.runLoop(config: config, tools: tools, disclosed: merged, depth: depth + 1, reasoningLevel: reasoningLevel)
            return
        }
        let call = calls[index]
        let params = Self.parseArgs(call.arguments)
        // v3.5.6：工具参数 schema 预校验（机制级，治"缺参盲试"老毛病）——
        // 调工具前先用工具 schema 校验必填参数，缺了就不执行，注入纠正消息重跑一轮逼模型补齐。
        // 不再像以前那样直接执行→报"invalid params required"→靠提示词让模型自己改（常盲试好几次）。
        if let schema = ToolRegistry.shared.openAISchema(for: call.name),
           let fn = schema["function"] as? [String: Any],
           let ps = fn["parameters"] as? [String: Any],
           let required = ps["required"] as? [String] {
            let missing = required.filter { params[$0] == nil }
            if !missing.isEmpty && self.paramCorrectionCount < 2 {
                self.paramCorrectionCount += 1
                self.pendingParamCorrection = "你要调用的工具 \(call.name) 缺少必填参数: \(missing.joined(separator: "、"))。请补齐这些参数后再调用该工具，不要用同样方式反复重试同一个缺参调用。"
                self.trailStep(.done(.note, "工具参数缺失被拦", detail: "\(call.name) 缺: \(missing.joined(separator: "、"))", ok: false))
                // v3.5.6 审计修正：纠正重跑前，必须先清掉刚挂上但未执行的 toolCalls——
                // 否则会话里留下"assistant 带 toolCalls 却无 tool 结果"的非法历史序列，
                // OpenAI/Anthropic 会拒绝（tool_call 必须紧跟 tool message），纠正重跑会失败。
                if let ci = self.activeConvIndex {
                    let msgs = self.conversations[ci].messages
                    if let mi = msgs.lastIndex(where: { ($0.toolCalls ?? []).contains(where: { $0.id == call.id }) }) {
                        if self.conversations[ci].messages[mi].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            // 只挂了思考没正文 → 整条移除，避免"孤立思考块"观感
                            self.conversations[ci].messages.remove(at: mi)
                        } else {
                            // 已写了正文解说 → 保留正文，仅剥离未执行的 toolCalls
                            self.conversations[ci].messages[mi].toolCalls = nil
                        }
                    }
                }
                // 不执行工具，回模型补齐参数（depth+1 防死循环；paramCorrectionCount 上限 2）
                self.runLoop(config: config, tools: tools, disclosed: disclosed, depth: depth + 1, reasoningLevel: reasoningLevel)
                return
            }
            self.paramCorrectionCount = 0
        }
        // v2.9.34：展示"正在执行工具 xxx…"
        self.runningTool = call.name
        // v3.5.10：工具启动即上屏一张 running 步骤卡（机制保证每步可见，不依赖模型解说）。
        // 先把真实工具名+命令+解说(若有)做成 isRunning=true 的占位卡立即上屏；
        // 结果回来后在 handleDispatchResult 原地更新成完成/出错卡（同一张，不新增第二条）。
        do {
            var runMsg = ChatMessage(role: "tool", content: "", toolCallId: call.id, toolName: call.name)
            runMsg.toolArgs = Self.summarizeArgs(call.arguments)
            let nar = thinkText.trimmingCharacters(in: .whitespacesAndNewlines)
            runMsg.toolNarration = nar.isEmpty ? nil : thinkText
            runMsg.isRunning = true
            // v9：给这张卡也补 parts（tool 消息 = 一个 text 段，结果未到前为空）——
            // 渲染层已按 isConsumedTool 跳过它，这里只是保持数据模型一致，
            // 避免"部分消息有 parts、部分没有"导致迁移逻辑反复触发。
            runMsg.migrateToPartsIfNeeded()
            self.appendToCurrent(runMsg)
            self.pendingToolMsgID = runMsg.id
        }
        // v3.3.4：记录工具执行耗时（UI 气泡显示，对齐 OpenMinis 步骤耗时样式）
        let toolStart = CFAbsoluteTimeGetCurrent()
        // v2.9.127：轨迹——单工具开始执行 (参数序列化展示）
        self.trailStep(.running(.tool, call.name, detail: Self.jsonString(params)))
        do {
            // v2.9.29：工具执行放后台线程，避免注入/文件操作等耗时调用阻塞主线程
            //  (授权恢复后Run injection导致一直转圈 + 聊天框/输入框无响应）。
            // dispatch 在后台执行，结果/授权/错误统一回主线程继续递归。
            // v7.1.0：子代理每轮进度 → 状态栏（"子代理第 N 轮：tool …"），用户能看见它在忙什么
            if call.name == "subagent" {
                SubagentTool.progressHandler = { round, note in
                    DispatchQueue.main.async {
                        ConversationStore.shared.statusText = "子代理 第 \(round) 轮 · \(note)"
                    }
                }
            }
            DispatchQueue.global().async {
                // v7.15.2：把本轮 run token 带到工具执行的线程上——
                // dispatch 里触发熔断（loopBlockedError）时才知道该终止哪一轮。
                RunScope.currentToken = self.runToken
                defer { RunScope.currentToken = nil }
                let result: Result<[String: Any], Error>
                do {
                    result = .success(try ToolRegistry.shared.dispatch(name: call.name, params: params))
                } catch {
                    result = .failure(error)
                }
                if call.name == "subagent" { SubagentTool.progressHandler = nil }
                let toolDuration = CFAbsoluteTimeGetCurrent() - toolStart
                DispatchQueue.main.async {
                    self.runningTool = nil
                    self.handleDispatchResult(result, call: call, calls: calls, index: index,
                                              toolMessages: toolMessages, newlyDisclosed: newlyDisclosed,
                                              config: config, tools: tools,
                                              disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                              thinkText: thinkText, toolDuration: toolDuration)
                }
            }
        }
    }

    /// v2.9.29：在主线程处理一次工具执行结果，然后继续递归调用链
    /// v2.9.31：去掉授权弹窗分支 (工具搜索即自动授权，无需暂停等待用户选择）。
    private func handleDispatchResult(_ result: Result<[String: Any], Error>,
                                      call: ToolCall, calls: [ToolCall], index: Int,
                                      toolMessages: [ChatMessage], newlyDisclosed: [String],
                                      config: ModelConfig, tools: [[String: Any]]?,
                                      disclosed: [String], depth: Int, reasoningLevel: Int,
                                      thinkText: String = "", toolDuration: Double = 0) {
        switch result {
        case .success(let r):
            let rawContent = Self.jsonString(r)
            // v2.9.49：工具结果截断 (>8000字符），防止单条工具结果 (如 haxbrowser snapshot / injection.list）
            // 撑爆上下文导致后续请求巨慢。截断后加提示，模型可调用带分页/过滤参数的工具获取完整数据。
            let content: String
            if rawContent.count > 8000 {
                content = rawContent.prefix(8000) + "\n... [工具结果已截断，total \(rawContent.count) 字符。如需完整数据，请调用该工具时使用 limit/filter/query 等参数缩小范围。]"
            } else {
                content = rawContent
            }
            var next = toolMessages
            var toolMsg = ChatMessage(role: "tool", content: content, toolCallId: call.id, toolName: call.name)
            // v3.1.26：存参数摘要，UI 里用特殊颜色显示
            toolMsg.toolArgs = Self.summarizeArgs(call.arguments)
            // v3.3.4：耗时显示
            toolMsg.toolDuration = toolDuration
            // v8：web.search 结果 → id→url 映射挂在本条 tool 消息上（UI 渲染 [cite:sN] 角标）
            if call.name == "web.search" { toolMsg.citedURLs = Self.extractCitedURLs(from: r) }
            // v3.5.8：存解说（模型写的"先解说后执行"正文）到工具消息——Minis 式工具卡当步骤标题
            toolMsg.toolNarration = thinkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : thinkText
            // v3.1.72：不再写 toolMsg.thinking——思考已在 assistant 消息的 thinking 字段显示一次，
            // 旧逻辑把同一文本又塞进 tool 消息导致"回复内容和思考内容一模一样" (用户实测反馈）
            next.append(toolMsg)
            // v9：先把结果内联进 ToolCallPayload.result（投影层据此显示每步耗时/结果摘要），
            //     再把"启动即上屏"的 running 卡片更新为完成态；回填成功时那张卡片会被标记消费，
            //     渲染层只显示过程区里的步骤，不会双份。
            self.backfillToolResult(callId: call.id, toolName: call.name,
                                    result: content, isError: false,
                                    durationMs: Int((toolDuration * 1000).rounded()))
            // v3.5.10：原地更新"启动即上屏"的 running 步骤卡 → 完成卡（同一张，不再新增第二条）
            self.resolvePendingTool(content: content, toolDuration: toolDuration, isError: false, narration: toolMsg.toolNarration)
            // v2.9.127：轨迹——工具执行OK (结果摘要 200 字符，完整结果在 tool 消息里）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(rawContent),
                                 ok: true))
            var nextDisclosed = newlyDisclosed
            // v3.1.66：tool_search 已删除，全量加载所有工具，无需披露机制。
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: nextDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText)
        case .failure(let err as MCPError):
            // v2.9.125：failed也输出结构化 JSON (对齐 CLI 返回协议），AI 可直接解析分类与下一步
            var next = toolMessages
            let failureBody: [String: Any]
            if case MCPError.classified(let m, let code, let reason, let nextStep) = err {
                failureBody = ["ok": false, "message": m,
                               "error": ["code": code, "reason": reason, "next_step": nextStep]]
            } else if case MCPError.classifiedData(let m, let code, let reason, let nextStep, let extra) = err {
                var errorDict: [String: Any] = ["code": code, "reason": reason, "next_step": nextStep]
                if let kb = extra["kb_fix"] { errorDict["kb_fix"] = kb }
                if let unmet = extra["unmet_prerequisites"] { errorDict["unmet_prerequisites"] = unmet }
                failureBody = ["ok": false, "message": m, "error": errorDict]
            } else {
                failureBody = ["ok": false, "message": err.description]
            }
            let content = Self.jsonString(failureBody)
            var failMsg = ChatMessage(role: "tool", content: content, isError: true, toolCallId: call.id, toolName: call.name)
            // v3.1.72：不再写 failMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            // v3.3.4：耗时显示
            failMsg.toolDuration = toolDuration
            next.append(failMsg)
            // v9：失败结果同样回填，过程区显示红色步骤
            self.backfillToolResult(callId: call.id, toolName: call.name,
                                    result: content, isError: true,
                                    durationMs: Int((toolDuration * 1000).rounded()))
            // v3.5.10：原地更新 running 步骤卡 → 出错卡
            self.resolvePendingTool(content: content, toolDuration: toolDuration, isError: true, narration: nil)
            // v2.9.127：轨迹——工具执行failed (四分类错误摘要）
            self.trailStep(.done(.result, call.name,
                                 detail: Self.trailSummary(Self.jsonString(failureBody)),
                                 ok: false))
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText)
        case .failure(let err):
            var next = toolMessages
            // v3.0.77：智能错误诊断——AI 看到错误就知道为什么failed、下一步该做什么
            let errStr = err.localizedDescription.lowercased()
            var reason = "Tool execution failed"
            var nextStep = "Check the error message above. Try a different approach or tool."
            if errStr.contains("not found") || errStr.contains("no such file") {
                reason = "File or path does not exist"
                nextStep = "Check path with shell.exec or shell.exec. If app container, verify bundle_id."
            } else if errStr.contains("refused") || errStr.contains("connection") || errStr.contains("unreachable") {
                reason = "Target app or service not reachable"
                nextStep = "Start the target app first, or check if injection is active (injection.status)."
            } else if errStr.contains("permission") || errStr.contains("denied") {
                reason = "Permission denied"
                nextStep = "Check tool permissions in settings, or use a different approach."
            } else if errStr.contains("required") || errStr.contains("invalid") {
                reason = "Missing or wrong parameter"
                nextStep = "Check tool parameters. Required params are marked (REQUIRED) in the tool description."
            } else if errStr.contains("timeout") {
                reason = "Operation timed out"
                nextStep = "Try again with longer timeout, or check if the app is responsive."
            }
            let errBody: [String: Any] = [
                "ok": false,
                "tool": call.name,
                "error": err.localizedDescription,
                "reason": reason,
                "next_step": nextStep
            ]
            var errMsg = ChatMessage(role: "tool", content: Self.jsonString(errBody),
                                    isError: true, toolCallId: call.id, toolName: call.name)
            // v3.1.72：不再写 errMsg.thinking (思考只在 assistant 消息显示一次，避免重复）
            next.append(errMsg)
            // v9：通用失败分支同样回填（过程区标红）
            self.backfillToolResult(callId: call.id, toolName: call.name,
                                    result: Self.jsonString(errBody), isError: true,
                                    durationMs: Int((toolDuration * 1000).rounded()))
            // v3.5.10：原地更新 running 步骤卡 → 出错卡
            self.resolvePendingTool(content: Self.jsonString(errBody), toolDuration: toolDuration, isError: true, narration: nil)
            self.trailStep(.done(.result, call.name,
                                 detail: "❌ \(err.localizedDescription.prefix(200))",
                                 ok: false))
            // v6.6.21：熔断触发 → 终止本轮，不再把控制权交回模型。
            // 旧行为只是把"已停止本次调用"当普通工具结果喂回去，
            // 模型会继续同样参数重试（真机连续 13 次），用户只能干等。
            // v6.6.26：环境类错误（未登录 / iOS 17+ 不支持）重试必然同样失败，
            // 直接终止本轮，不再把错误文本交回模型（实测连试 18 次）。
            let em = err.localizedDescription
            if em.contains("[NOT_LOGGED_IN]") || em.contains("[UNSUPPORTED_ON_IOS17]")
                || em.contains("not logged in to GitHub") {
                RunScope.requestAbort(token: self.runToken)
            }
            // v7.15.2：必须用 consumeAbort(runToken)——主线程没绑 currentToken，
            // 读属性会落到全局兜底槽位，退化成旧语义。
            if RunScope.consumeAbort(self.runToken) {
                self.isLoading = false
                self.statusText = nil
                self.runningTool = nil
                self.currentClient?.cancel()
                self.currentClient = nil
                TaskNotify.shared.endBackground()
                var stopMsg = ChatMessage(role: "assistant",
                    content: "[[RUN_TERMINATED]] 已停止：\(call.name) 用相同参数连续失败，原因相同，我不再重复它。\n\n"
                           + "下一步给你三个选择：\n"
                           + "① 换工具/换参数（告诉我你想拿到什么结果，我换一种方式）\n"
                           + "② 我先解释这个错误意味着什么\n"
                           + "③ 先修环境（比如 iSH 引擎、登录状态）再继续")
                stopMsg.thinking = nil
                self.appendToCurrent(stopMsg)
                self.liveProducedID = stopMsg.id
                self.activeConvId = nil
                self.liveTrail = []
                self.sortAndSave()
                return
            }
            self.processToolCalls(calls, index: index + 1, toolMessages: next, newlyDisclosed: newlyDisclosed,
                                  config: config, tools: tools, disclosed: disclosed, depth: depth, reasoningLevel: reasoningLevel,
                                  thinkText: thinkText)
        }
    }

    /// v9：工具结果回填——把结果写进前文 ToolCallPayload.result，UI 立刻能看到
    ///（旧实现要等下次 load 才合并，运行中过程区一直显示"执行中"）
    @discardableResult
    func backfillToolResult(callId: String, toolName: String,
                            result: String, isError: Bool, durationMs: Int?) -> Bool {
        guard let ci = activeConvIndex else { return false }
        // 从后往前找最近的 assistant 消息，命中即改（并行调用按 id 精确匹配，不看顺序）
        for mi in conversations[ci].messages.indices.reversed() {
            guard var parts = conversations[ci].messages[mi].parts else { continue }
            var hit = false
            for pi in parts.indices {
                guard case .toolCall(var payload) = parts[pi] else { continue }
                if !callId.isEmpty {
                    guard payload.id == callId else { continue }
                } else {
                    // 老数据缺 id：按同名且尚无结果兜底
                    guard payload.name == toolName, payload.result == nil else { continue }
                }
                payload.result = result
                payload.isError = isError
                if let d = durationMs { payload.durationMs = d }
                parts[pi] = .toolCall(payload)
                hit = true
                break
            }
            if hit {
                conversations[ci].messages[mi].parts = parts
                ProjectedBlockCache.shared.invalidate(id: conversations[ci].messages[mi].id)
                // 结果已内联 → 独立的 tool 消息让位给过程区里的步骤（不删除，只标记；
                // 搜索/导出/审计仍用它，渲染层按 isConsumedTool 跳过，避免双份）
                if let ti = conversations[ci].messages.firstIndex(where: { $0.id == pendingToolMsgID }) {
                    conversations[ci].messages[ti].isConsumedTool = true
                }
                return true
            }
        }
        return false
    }

    /// v3.5.10：工具结果回来后，原地更新"启动即上屏"的 running 步骤卡（同一张卡变完成/出错）。
    private func resolvePendingTool(content: String, toolDuration: Double, isError: Bool, narration: String?) {
        guard let mid = self.pendingToolMsgID, let ci = self.activeConvIndex,
              let mi = self.conversations[ci].messages.firstIndex(where: { $0.id == mid }) else {
            self.pendingToolMsgID = nil
            return
        }
        self.conversations[ci].messages[mi].content = content
        self.conversations[ci].messages[mi].toolDuration = toolDuration
        self.conversations[ci].messages[mi].isError = isError
        self.conversations[ci].messages[mi].isRunning = false
        if let n = narration, !n.isEmpty {
            self.conversations[ci].messages[mi].toolNarration = n
        }
        // v9：同步该卡的 parts（tool 消息 = 一个 text 段）——回填失败时它仍会渲染，
        // 不能留空正文
        var tp = self.conversations[ci].messages[mi].effectiveParts
        if let ti = tp.lastIndex(where: { if case .text = $0 { return true }; return false }) {
            tp[ti] = .text(content)
        } else {
            tp.append(.text(content))
        }
        self.conversations[ci].messages[mi].parts = tp
        ProjectedBlockCache.shared.invalidate(id: mid)
        self.pendingToolMsgID = nil
    }

    /// v9.1：工具裁决表——工具描述里大量重叠（file/artifact/container、app/package、
    /// shell.exec/py），模型只能靠猜 → 选错工具是"跑偏"的头号来源。
    /// 这里只写**互斥裁决**，不重复各工具的用法说明，保持短。
    private static let toolArbitration = """
    === 工具裁决（按此优先级选，不要再猜）===
    · 读一个已知文件的文本 → shell.exec cat；看类型、字符串、架构等二进制特征 → file command:inspect；看包（.deb/.ipa）里有什么 → package。
    · 找 App 的安装路径/数据目录/entitlements → app command:info；找 App 容器里的文件 → container。
    · 执行系统命令 → shell.exec（iOS 原生优先；需要 Linux 工具链才 runtime:"alpine"）；算术/数据处理 → py。两者不要互相替代。
    · 需要 root → root command:exec；root command:status 只用来诊断通道，不用来干活。
    · 改 App 二进制/注入 → inject；改内存 → memory；抓 HTTPS → network.capture（App 内）/ vpn.capture（系统级）。三者互不替代。
    · 联网 → web.search 找、web.fetch 读正文；不要用 curl 抓搜索引擎结果。
    · 失败先读 code/reason/next_step：同一工具+同一参数+同一类错误连续 2 次即停，换工具或先诊断，不要重试第三次。
    """

    /// v2.9.138：动态会话状态块——设备/App/工作区/当前会话，injected system 最前
    ///  (位于稳定块之后，最新状态放最后）。让 AI 始终感知当前环境，不靠猜。
    private static func dynamicStatePrompt() -> String {
        var device = "iPhone"
        var os = ""
        #if canImport(UIKit)
        device = UIDevice.current.model
        os = UIDevice.current.systemName + " " + UIDevice.current.systemVersion
        #endif
        var appVer = ""
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { appVer = v }
        var parts = ["[当前环境] 设备: \(device)\(os.isEmpty ? "" : " · \(os)")"]
        if !appVer.isEmpty { parts.append("App: Xosvi \(appVer)") }
        parts.append("工作区: \(Workspace.root.path)")
        if let idx = ConversationStore.shared.selectedIndex,
           idx < ConversationStore.shared.conversations.count {
            parts.append("当前会话: \(ConversationStore.shared.conversations[idx].title)")
        }
        // v3.1.5: 自动提取的关键信息 (App 名、bundle id、文件路径等）
        if let hint = AutoContextExtractor.shared.contextHint() {
            parts.append(hint)
        }
        return parts.joined(separator: " | ")
    }

    /// v4.3.71：返回 (messages, compactSource) —— compactSource 是被裁掉的旧消息原文，
    /// 供 OpenAIClient 在发送主请求前交给模型生成结构化摘要 (LLM Compaction)。
    private func messagesForAPI(budget: Int) -> (messages: [ChatMessage], compactSource: [ChatMessage]) {
        var all = currentMessages.filter { !$0.isError }
        guard !all.isEmpty else { return ([], []) }
        // v2.9.138：工具结果修剪 (Claude Code Precision Forgetting Layer 1）——
        // 非最近 3 条 tool 消息、内容 > 300 字符的旧工具结果替换为紧凑占位符。
        // 零 LLM 成本回收上下文：AI 需要细节时可重新调用该工具。
        // v3.1.68：阈值 300 → 2000 (AI 实测"377 字符不该被截"属实，小结果不再替换）；
        // 替换时保留原内容前 500 字符 ("截空看不到主体"根因——占位符不再整条顶替，
        // 且后续预算裁剪/sanitize 删占位符时头部仍在，AI 不至于完全失去线索）。
        let toolIdx = all.enumerated().filter { $0.element.isTool }.map { $0.offset }
        let keepTool = Set(toolIdx.suffix(3))
        for (i, m) in all.enumerated() where m.isTool && !keepTool.contains(i) && m.content.count > 2000 {
            var nm = m
            let toolName = m.toolName ?? "tool"
            let head = String(m.content.prefix(500))
            nm.content = "[工具结果已修剪: \(toolName)，原\(m.content.count)字符，以下为头部]\n\(head)\n…如需完整结果请重新调用该工具并带 limit=20000 或 full=true"
            all[i] = nm
        }
        // v2.9.87：预算预留 30% 给 tools schema + 系统/开发者指令 + 请求开销。
        // 之前只按消息估算，tools (可能几十 KB JSON）+ 两条 system 前缀没算，
        // 长会话+多工具时实际请求体远超预算 → 中转处理慢 ("一直请求中"）。
        let theBudget = max(Int(Double(budget) * 0.7), 2000)
        // 估算总 token；低于预算直接返回 (短会话，无需压缩）
        let total = all.reduce(0) { $0 + Self.estimateTokens($1) }
        if total <= theBudget { return (all, []) }
        // 长会话：从旧到新裁剪，但始终保留最后 N 条核心消息
        let keepMin = 6
        var kept: [ChatMessage] = []
        // 先保留最新 keepMin 条 (含用户最新提问），其 token 计入预算
        let suffix = Array(all.suffix(keepMin))
        let prefix = Array(all.prefix(all.count - keepMin))
        var used = suffix.reduce(0) { $0 + Self.estimateTokens($1) }
        // 从旧到新累计到「预算 - suffix」内 (v2.9.16：suffix 计入预算，避免超发）
        for m in prefix {
            let t = Self.estimateTokens(m)
            if used + t > theBudget { break }
            kept.append(m)
            used += t
        }
        var result = kept + suffix
        // 清理孤立 tool 消息：裁剪可能导致 assistant(tool_calls) 被裁、其 tool 结果残留
        result = Self.sanitizeToolSequence(result)
        // 插入截断提示 (v2.9.88：本地生成话题摘要，而非简单丢弃 —— 不用额外请求，
        // 从被裁消息里提取用户提问/工具名作为"旧会话记忆"，AI 仍能感知上下文主题）
        let dropped = all.count - result.count
        // v4.3.71：被裁旧消息原文交给 LLM Compaction 生成结构化摘要（替换下方启发式摘要）
        let compactSource = dropped > 0 ? Array(all.prefix(all.count - result.count)) : []
        if dropped > 0 {
            let droppedMsgs = compactSource
            var topics: [String] = []
            var toolNames: Set<String> = []
            var idx = 0
            for m in droppedMsgs {
                idx += 1
                if m.role == "tool" { continue }
                if let calls = m.toolCalls, !calls.isEmpty {
                    for c in calls {
                        if !c.name.isEmpty {
                            toolNames.insert(c.name)
                        }
                    }
                    if topics.count < 8, idx % 4 == 0 { topics.append("工具调用") }
                    continue
                }
                if m.role == "user" || m.role == "assistant" {
                    let text = m.content.replacingOccurrences(of: "\n", with: " ")
                    if !text.isEmpty, topics.count < 8 {
                        topics.append(String(text.prefix(24)))
                    }
                }
            }
            var summaryParts: [String] = ["已省略最早 \(dropped) 条历史消息"]
            if !topics.isEmpty {
                summaryParts.append("话题: " + topics.prefix(6).joined(separator: " / "))
            }
            if !toolNames.isEmpty {
                summaryParts.append("涉及工具: " + toolNames.sorted().prefix(10).joined(separator: "、"))
            }
            summaryParts.append("如需旧细节，请直接提问，AI 会重新执行相关工具获取。")
            let hint = ChatMessage(role: "system", content: "[系统] " + summaryParts.joined(separator: "。"))
            result.insert(hint, at: 0)
        }
        return (result, compactSource)
    }

    /// 粗估 token：中文/日文等约 1 字≈1.5 token；ASCII 约 4 字符≈1 token；图片按固定值计
    private static func estimateTokens(_ m: ChatMessage) -> Int {
        var t = 0
        let content = m.content
        var cjk = 0
        for ch in content.unicodeScalars {
            if (ch.value >= 0x4E00 && ch.value <= 0x9FFF) || (ch.value >= 0x3040 && ch.value <= 0x30FF) || (ch.value >= 0xAC00 && ch.value <= 0xD7AF) {
                cjk += 1
            }
        }
        let ascii = content.count - cjk
        // v2.9.87：CJK 1.5→2.0 保守估算 (中文实际约 1.5~2 token/字），
        // 低估会让请求体超预算 → 中转处理慢。
        t += Int(Double(cjk) * 2.0) + ascii / 3
        t += (m.imageDataURLs?.count ?? 0) * 600   // 每张图约 600 token (低分辨率近似）
        return max(t, 8)
    }

    /// 保证 assistant tool_calls 与其 tool 结果成对存在；删掉孤立的 tool 消息
    private static func sanitizeToolSequence(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var pendingToolCalls = false
        for m in msgs {
            if m.role == "assistant", let calls = m.toolCalls, !calls.isEmpty {
                pendingToolCalls = true
                out.append(m)
            } else if m.role == "tool" {
                // 只有前面有未配对的 assistant tool_calls 才保留 tool 结果
                if pendingToolCalls {
                    out.append(m)
                }
                // 忽略孤立的 tool 消息
            } else {
                pendingToolCalls = false
                out.append(m)
            }
        }
        return out
    }

    private static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    // v2.9.171：工具结果序列化去掉 prettyPrinted → 紧凑 JSON (无缩进空格）。
    private static func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// v8：web.search 结果字典 → id→url 映射（results + pages），供 UI 渲染 [cite:sN] 引用角标
    private static func extractCitedURLs(from result: [String: Any]) -> [String: String]? {
        var urls: [String: String] = [:]
        if let results = result["results"] as? [[String: Any]] {
            for item in results {
                if let id = item["id"] as? String, let u = item["url"] as? String { urls[id] = u }
            }
        }
        if let pages = result["pages"] as? [[String: Any]] {
            for item in pages {
                if let id = item["id"] as? String, let u = item["url"] as? String { urls[id] = u }
            }
        }
        return urls.isEmpty ? nil : urls
    }

    private func sortAndSave() {
        conversations.sort { $0.updatedAt > $1.updatedAt }
        save()
    }

    private func title(from text: String) -> String {
        // v2.9.293：剔除附件描述，避免标题变成 "[📎 文件：全局加速+...2.deb]已保存到 /var/..."
        // 用正则兼容 [📎文件：/ [📎 文件：/ 中文冒号/英文冒号 所有变体
        var clean = text
        func stripTag(_ pattern: String) {
            guard let rx = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let ns = clean as NSString
            let range = NSRange(location: 0, length: ns.length)
            clean = rx.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        stripTag("\\[📎\\s*文件\\s*[：:][^\\]]*\\]")
        stripTag("\\[📱\\s*应用\\s*[：:][^\\]]*\\]")
        // 去掉 "已保存到 <路径>，可用..." 路径描述
        if let r = clean.range(of: "已保存到 ") {
            clean = String(clean[..<r.lowerBound])
        }
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "📎 文件" }
        let line = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return String(line.prefix(30))
    }

    // v4.3.66：会话存储从 UserDefaults 全量迁移到独立文件（对齐微信/WCDB：大对象不进
    // UserDefaults 同步 IO；文件原子写 + 备份轮换，编码/写盘放后台串行队列，不阻塞主线程）
    private var storeDir: String {
        let p = NSHomeDirectory().appending("/Documents/Workspace/store")
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }
    private var storeFile: String { storeDir.appending("/conversations.json") }
    private let saveQueue = DispatchQueue(label: "xosvi.conversations.save", qos: .utility)

    private func save() {
        // 后台 worker 的 conversations 只有一份临时副本，写盘会把真实历史覆盖掉
        guard !isBackgroundWorker else { return }
        let snapshot = conversations
        let dir = storeDir
        let path = storeFile
        saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            let fm = FileManager.default
            let bak1 = dir.appending("/conversations.bak.1.json")
            let bak2 = dir.appending("/conversations.bak.2.json")
            // 备份轮换：旧 bak1 → bak2，旧主文件 → bak1
            if fm.fileExists(atPath: bak1) {
                try? fm.removeItem(atPath: bak2)
                try? fm.moveItem(atPath: bak1, toPath: bak2)
            }
            if fm.fileExists(atPath: path) {
                try? fm.moveItem(atPath: path, toPath: bak1)
            }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func decodeFile(_ path: String) -> [ChatConversation]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode([ChatConversation].self, from: data)
    }

    private func applyLoaded(_ decoded: [ChatConversation]) {
        // v6.2.2：修复"闪退后会话卡在工具执行中"——工具 running 占位卡随请求持久化，
        // 若工具执行中 App 闪退/被杀，恢复会话时 isRunning=true 永远悬挂（UI 显示"执行中"却无停止按钮）。
        // 恢复时把所有悬挂的 running 工具卡标记为中断态，避免误导。
        var cleaned = decoded
        for ci in cleaned.indices where ci < cleaned.count {
            for mi in cleaned[ci].messages.indices {
                if cleaned[ci].messages[mi].isRunning {
                    cleaned[ci].messages[mi].isRunning = false
                    cleaned[ci].messages[mi].isError = true
                    if cleaned[ci].messages[mi].content.isEmpty {
                        cleaned[ci].messages[mi].content = "工具执行已中断（App 在运行中被终止）"
                    }
                }
            }
        }
        // v9：迁移到结构化 parts + 回填工具结果（一次到位，渲染层之后只认 parts）
        //   · migrateToPartsIfNeeded：content/thinking/toolCalls → [MessagePart]（幂等）
        //   · mergingToolResultsIsolated：role == "tool" 的结果内联进 ToolCallPayload.result，
        //     并把那条 tool 消息标记 isConsumedTool（渲染层跳过，不物理删除——搜索/审计还要用）
        // 迁移前先记一笔：有未迁移的消息就要落盘，否则每次启动都重跑一遍
        //（isConsumedTool 也必须持久化，否则下次启动工具结果会双份显示）
        let needsMigration = cleaned.contains { conv in
            conv.messages.contains { $0.parts == nil }
        }
        var migrated = cleaned
        for ci in migrated.indices {
            migrated[ci].messages = migrated[ci].messages.mergingToolResultsIsolated()
        }
        conversations = migrated.sorted { $0.updatedAt > $1.updatedAt }
        ProjectedBlockCache.shared.clear()
        selectedId = conversations.first?.id
        // 悬挂工具卡被纠正 / 首次迁移 → 落盘一次保持持久一致
        var needSave = needsMigration
        for conv in decoded where !needSave {
            if conv.messages.contains(where: { $0.isRunning }) { needSave = true; break }
        }
        if needSave { save() }
    }

    private func load() {
        let fm = FileManager.default
        // 1. 文件主数据
        if fm.fileExists(atPath: storeFile), let d = decodeFile(storeFile), !d.isEmpty {
            applyLoaded(d); return
        }
        // 2. 文件备份
        for i in 1...2 {
            let bak = storeDir.appending("/conversations.bak.\(i).json")
            if fm.fileExists(atPath: bak), let d = decodeFile(bak), !d.isEmpty {
                applyLoaded(d); save(); return
            }
        }
        // 3. 一次性迁移：旧 UserDefaults 主数据 + 其备份（迁移后写入文件，旧数据保留不删）
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ChatConversation].self, from: data),
           !decoded.isEmpty {
            applyLoaded(decoded); save(); return
        }
        for i in 1...2 {
            if let bak = UserDefaults.standard.data(forKey: key + ".bak.\(i)"),
               let decoded = try? JSONDecoder().decode([ChatConversation].self, from: bak),
               !decoded.isEmpty {
                applyLoaded(decoded); save(); return
            }
        }

        // 从旧版单一会话记录迁移
        if let oldData = UserDefaults.standard.data(forKey: "xosvi.transcript"),
           let messages = try? JSONDecoder().decode([ChatMessage].self, from: oldData),
           !messages.isEmpty {
            let first = messages.first!
            let title = String(first.content.prefix(30))
            let conv = ChatConversation(
                title: title,
                createdAt: first.timestamp,
                updatedAt: messages.last?.timestamp ?? Date(),
                messages: messages
            )
            conversations = [conv]
            selectedId = conv.id
            save()
            UserDefaults.standard.removeObject(forKey: "xosvi.transcript")
        } else {
            newConversation()
        }
    }
}

// MARK: - 熔断器 (v2.9.107，对齐 cc-switch circuit_breaker 三态机）

enum CircuitState: String {
    case closed = "closed", open = "open", halfOpen = "half_open"
    var label: String {
        switch self {
        case .closed: return "正常"
        case .open: return "已熔断"
        case .halfOpen: return "探测中"
        }
    }
}

final class CircuitBreaker {
    private let lock = NSLock()
    private var state: CircuitState = .closed
    private var consecutiveFailures = 0
    private var consecutiveSuccesses = 0
    private var totalRequests = 0
    private var failedRequests = 0
    private var lastOpenedAt: Date?
    private var halfOpenRequests = 0

    var failureThreshold = 4          // 连续failed阈值 → Open
    var successThreshold = 2          // HalfOpen OK次数 → Closed
    var timeoutSeconds: TimeInterval = 60  // Open 后多久尝试 HalfOpen
    var errorRateThreshold = 0.6      // 错误率阈值 → Open
    var minRequests = 10              // 计算错误率前最少请求数

    let name: String
    init(name: String) { self.name = name }

    var stateInfo: (state: CircuitState, failures: Int, total: Int, failRate: Double) {
        lock.lock(); defer { lock.unlock() }
        let rate = totalRequests > 0 ? Double(failedRequests) / Double(totalRequests) : 0
        return (state, consecutiveFailures, totalRequests, rate)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        state = .closed
        consecutiveFailures = 0
        consecutiveSuccesses = 0
        totalRequests = 0
        failedRequests = 0
        halfOpenRequests = 0
        lastOpenedAt = nil
    }

    /// 路由可用性判断 (不占 HalfOpen 探测名额）
    func isAvailable() -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed, .halfOpen:
            return true
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
                return true
            }
            return false
        }
    }

    /// 请求前调用：是否放行 (HalfOpen 限流 1 个探测请求）
    func allowRequest() -> (allowed: Bool, usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        switch state {
        case .closed:
            return (true, false)
        case .open:
            if let opened = lastOpenedAt, Date().timeIntervalSince(opened) >= timeoutSeconds {
                state = .halfOpen
                consecutiveSuccesses = 0
                halfOpenRequests = 0
            } else {
                return (false, false)
            }
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        case .halfOpen:
            if halfOpenRequests < 1 {
                halfOpenRequests += 1
                return (true, true)
            }
            return (false, false)
        }
    }

    func recordSuccess(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures = 0
        totalRequests += 1
        if state == .halfOpen {
            consecutiveSuccesses += 1
            if consecutiveSuccesses >= successThreshold {
                state = .closed
                consecutiveSuccesses = 0
                totalRequests = 0
                failedRequests = 0
                halfOpenRequests = 0
            }
        }
    }

    func recordFailure(usedHalfOpenPermit: Bool) {
        lock.lock(); defer { lock.unlock() }
        if usedHalfOpenPermit, halfOpenRequests > 0 { halfOpenRequests -= 1 }
        consecutiveFailures += 1
        consecutiveSuccesses = 0
        totalRequests += 1
        failedRequests += 1
        switch state {
        case .halfOpen:
            state = .open
            lastOpenedAt = Date()
            consecutiveFailures = 0
        case .closed:
            if consecutiveFailures >= failureThreshold {
                state = .open
                lastOpenedAt = Date()
                consecutiveFailures = 0
            } else if totalRequests >= minRequests {
                let rate = Double(failedRequests) / Double(totalRequests)
                if rate >= errorRateThreshold {
                    state = .open
                    lastOpenedAt = Date()
                    consecutiveFailures = 0
                }
            }
        case .open:
            break
        }
    }
}

// MARK: - v2.9.126 深链导入暂存 (对齐 cc-switch DeepLinkImportDialog）

/// AppDelegate 收到 xosvi://import?... 后暂存配置，发通知；SwiftUI 层弹确认页。
/// 确认才写入 ModelStore (防误导入），取消即丢弃。
final class PendingImport: ObservableObject {
    static let shared = PendingImport()
    static let didStageNotification = Notification.Name("xosvi.pendingImport.staged")

    @Published var staged: ModelConfig?

    private init() {}

    func stage(_ config: ModelConfig) {
        staged = config
        NotificationCenter.default.post(name: Self.didStageNotification, object: config)
    }

    func confirm() {
        guard let c = staged else { return }
        let ok = ModelStore.shared.importFromDeepLink(c)
        staged = nil
        // 通知 UI 显示结果 (导入OK/已存在重复）
        NotificationCenter.default.post(name: Self.didStageNotification,
                                        object: nil,
                                        userInfo: ["result": ok ? "imported" : "duplicate"])
    }

    func cancel() {
        staged = nil
    }
}
