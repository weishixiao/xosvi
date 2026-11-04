import Foundation

// MARK: - v7.8.0 推理方言（移植自 Kelivo lib/core/models/model_spec.dart + reasoning_dialects.dart）
//
// 原来本项目只会写一个字段 `reasoning_effort`，而且 Anthropic 分支完全没有 thinking 参数
// —— 用 Claude 时它根本不思考。这里补上按模型选择「方言」的机制：
//
//   · 方言决定「思考强度用什么字段表达」
//   · 档位可选「按 token 预算」而非 effort 字符串
//   · 切换档位前先清掉该方言拥有的键，避免旧参数残留打架
//   · 采样参数策略：思考开着时自动剥离 temperature / top_p 等（很多推理模型会因此报 400）
//   · 思考内容回传策略：Anthropic 的工具轮必须把 thinking block 带回去

// MARK: - 档位

enum ReasoningLevel: String, CaseIterable, Identifiable, Codable {
    case auto, off, minimal, low, medium, high, xhigh, max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动"
        case .off: return "关闭"
        case .minimal: return "最低"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "最高"
        case .max: return "极限"
        }
    }

    /// Kelivo 的固定预算表（可被模型自定义覆盖）
    var defaultBudget: Int? {
        switch self {
        case .auto, .off: return nil
        case .minimal: return 512
        case .low: return 1024
        case .medium: return 4096
        case .high: return 8192
        case .xhigh: return 16000
        case .max: return 32000
        }
    }

    /// 映射到 OpenAI 的 reasoning_effort 字符串
    var effortName: String? {
        switch self {
        case .auto, .off: return nil
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max: return "high"       // OpenAI 只认到 high；靠 budget 提量
        }
    }

    /// 兼容旧 UI 的 0-5 整数
    init(legacyIndex: Int) {
        switch legacyIndex {
        case 0: self = .low
        case 1: self = .medium
        case 2: self = .high
        case 3: self = .xhigh
        case 4: self = .max
        default: self = .medium
        }
    }
    var legacyIndex: Int {
        switch self {
        case .minimal, .low: return 0
        case .medium: return 1
        case .high, .auto: return 2
        case .xhigh: return 3
        case .max: return 4
        case .off: return 5
        }
    }
}

// MARK: - 方言

enum ReasoningDialect: String, CaseIterable, Codable {
    case none
    case openaiReasoningEffort          // reasoning_effort
    case openaiResponsesReasoning       // reasoning: {effort, summary}
    case openrouterReasoning            // reasoning: {enabled, effort}
    case anthropicBudget                // thinking: {type: enabled, budget_tokens}
    case anthropicAdaptiveEffort        // thinking: {type: adaptive, display: summarized}
    case anthropicBetweenTools          // 工具轮之间也允许思考
    case anthropicEffort                // thinking: {type: enabled} + effort
    case geminiThinkingBudget           // generationConfig.thinkingConfig.thinkingBudget
    case geminiThinkingLevel            // generationConfig.thinkingConfig.thinkingLevel
    case qwenEnableThinking             // enable_thinking / qwenEnableThinking
    case thinkingType                   // reasoning: {effort}（Responses 下的变体）
    case siliconflowEnableThinking
    case kimiThinking
    case custom

    var displayName: String {
        switch self {
        case .none: return "不支持思考"
        case .openaiReasoningEffort: return "OpenAI · reasoning_effort"
        case .openaiResponsesReasoning: return "OpenAI Responses · reasoning"
        case .openrouterReasoning: return "OpenRouter · reasoning"
        case .anthropicBudget: return "Claude · thinking budget"
        case .anthropicAdaptiveEffort: return "Claude 4.x · adaptive"
        case .anthropicBetweenTools: return "Claude · 工具轮间思考"
        case .anthropicEffort: return "Claude · thinking + effort"
        case .geminiThinkingBudget: return "Gemini · thinkingBudget"
        case .geminiThinkingLevel: return "Gemini 3 · thinkingLevel"
        case .qwenEnableThinking: return "通义千问 · enable_thinking"
        case .thinkingType: return "Responses · thinking type"
        case .siliconflowEnableThinking: return "硅基流动 · enable_thinking"
        case .kimiThinking: return "Kimi · thinking"
        case .custom: return "自定义"
        }
    }

    /// 按模型名猜一个合理方言（用户可在设置里改）
    static func infer(model: String, protocol proto: String) -> ReasoningDialect {
        let m = model.lowercased()
        if proto == "Anthropic Messages" {
            if m.contains("claude") {
                // 4.x 用 adaptive；3.7 及更早用 budget
                if m.contains("opus-4") || m.contains("sonnet-4") || m.contains("haiku-4") || m.contains("4-5") {
                    return .anthropicAdaptiveEffort
                }
                return .anthropicBudget
            }
            return .none
        }
        if m.contains("gemini") { return .geminiThinkingBudget }
        if m.contains("qwen") || m.contains("qwq") { return .qwenEnableThinking }
        if m.contains("kimi") || m.contains("moonshot") { return .kimiThinking }
        if m.contains("grok") { return .openaiReasoningEffort }
        // DeepSeek / OpenAI o 系列 / GPT-5 / GLM 等走标准 effor
        if m.contains("o1") || m.contains("o3") || m.contains("o4")
            || m.contains("gpt-5") || m.contains("deepseek") || m.contains("reasoner")
            || m.contains("glm") || m.contains("seed") {
            return proto == "OpenAI Responses" ? .openaiResponsesReasoning : .openaiReasoningEffort
        }
        return .openaiReasoningEffort
    }
}

// MARK: - 采样参数策略

enum SamplingPolicy: String, Codable, CaseIterable {
    case always           // 始终发送
    case onlyWhenReasoningOff   // 思考关闭时才发送（推理模型常见要求）
    case never            // 从不发送

    var displayName: String {
        switch self {
        case .always: return "始终发送"
        case .onlyWhenReasoningOff: return "仅在思考关闭时"
        case .never: return "从不发送"
        }
    }
}

// MARK: - 思考回传策略

enum ReasoningReplayPolicy: String, Codable, CaseIterable {
    case none        // 不回传
    case toolTurns   // 只在工具轮回传（Anthropic 必须）
    case all         // 每轮都回传

    var displayName: String {
        switch self {
        case .none: return "不回传"
        case .toolTurns: return "仅工具轮"
        case .all: return "每轮都回传"
        }
    }
}

enum ReasoningReplayField: String, Codable, CaseIterable {
    case reasoningContent   // reasoning_content
    case reasoning          // reasoning
    case reasoningDetails   // reasoning_details
}

// MARK: - 按模型存配置

struct ReasoningSpec: Codable, Equatable {
    var dialect: ReasoningDialect = .openaiReasoningEffort
    var sampling: SamplingPolicy = .always
    var replay: ReasoningReplayPolicy = .none
    var replayField: ReasoningReplayField = .reasoningContent
    /// 覆盖默认预算（nil = 用档位默认值）
    var budgets: [String: Int] = [:]
    /// 是否支持思考
    var supportsReasoning: Bool = true

    func budget(for level: ReasoningLevel) -> Int? {
        budgets[level.rawValue] ?? level.defaultBudget
    }
}

final class ReasoningSettings {
    static let shared = ReasoningSettings()

    /// 当前全局档位（UI 的「思考 · 档位」胶囊用这个）
    var level: ReasoningLevel {
        get {
            if let raw = UserDefaults.standard.string(forKey: "reasoning.level"),
               let l = ReasoningLevel(rawValue: raw) { return l }
            // 兼容旧值：chat_reasoning 是 0-4 的整数
            let legacy = UserDefaults.standard.integer(forKey: "chat_reasoning")
            return ReasoningLevel(legacyIndex: legacy)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "reasoning.level")
            UserDefaults.standard.set(newValue.legacyIndex, forKey: "chat_reasoning")
        }
    }

    var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "chat_think_enabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "chat_think_enabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "chat_think_enabled") }
    }

    /// 实际生效的档位（开关关掉就是 off）
    var effectiveLevel: ReasoningLevel { enabled ? level : .off }

    /// v9.4：思考改为内置自动——界面上不再有开关/强度胶囊。
    /// 按请求内容判强度（返回 chat_reasoning 的旧整数档位）：
    ///   0 低 · 1 中 · 2 高 · 3 最高 · 4 极限
    /// 判据只看用户本轮文字，不看历史，避免"聊久了永远拉满"。
    ///   · 极短寒暄/确认 → 低
    ///   · 含代码/日志/逆向/排查类词 → 高
    ///   · 明确要求"仔细/深入/逐步分析/写代码/为什么" → 最高
    ///   · 长文本（>400 字）或多段 → 至少中
    static func autoLevel(for text: String) -> Int {
        let t = text.lowercased()
        let n = text.count
        let heavyWords = ["深入", "仔细", "详细", "逐步", "分析", "为什么", "原理", "逆向",
                          "反汇编", "崩溃", "闪退", "排查", "调试", "写个", "写一个", "实现",
                          "重构", "优化", "架构", "证明", "推导", "漏洞", "越狱"]
        let lightWords = ["你好", "hi", "hello", "在吗", "谢谢", "好的", "ok", "嗯", "收到", "继续"]
        if n <= 8, lightWords.contains(where: { t.contains($0) }) { return 0 }
        if heavyWords.contains(where: { t.contains($0) }) { return n > 120 ? 3 : 2 }
        if n > 400 { return 2 }
        if n > 120 { return 1 }
        return 0
    }

    func spec(for model: String, protocol proto: String) -> ReasoningSpec {
        let key = "reasoning.spec.\(proto).\(model)"
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(ReasoningSpec.self, from: data) {
            return s
        }
        var s = ReasoningSpec()
        s.dialect = ReasoningDialect.infer(model: model, protocol: proto)
        s.supportsReasoning = s.dialect != .none
        // Anthropic 工具轮必须回传 thinking，否则下一次请求会被拒
        if proto == "Anthropic Messages" { s.replay = .toolTurns }
        // 推理模型通常不接受 temperature
        s.sampling = (s.dialect == .qwenEnableThinking || s.dialect == .openaiReasoningEffort)
            ? .onlyWhenReasoningOff : .always
        return s
    }

    func setSpec(_ spec: ReasoningSpec, for model: String, protocol proto: String) {
        let key = "reasoning.spec.\(proto).\(model)"
        if let data = try? JSONEncoder().encode(spec) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - v8.1：深度思考专用模型（nil = 跟随当前模型）
    //
    // 设计（对齐 Kelivo）：不用"切换时同步改选择"的事件方案（activate/markUsed/顶栏三个
    // 切换入口都要埋钩子，漏一处就串），而是**请求时动态解析**——任何时刻不存在需要同步的
    // 状态，天然免疫悬空引用/导入顺序问题。
    //
    //   deepThinkModelIdRaw == nil  → 跟随 ModelStore.defaultConfig（isDefault→最近使用→第一个）
    //   非 nil                      → 手动锁定；对应配置被删则自动回退跟随

    /// 深度思考专用模型配置 id（原始存储；nil/空 = 跟随当前模型）
    var deepThinkModelIdRaw: String? {
        get {
            let s = UserDefaults.standard.string(forKey: "xosvi.deep_think_model_id")
            return (s?.isEmpty == true) ? nil : s
        }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: "xosvi.deep_think_model_id")
            } else {
                UserDefaults.standard.removeObject(forKey: "xosvi.deep_think_model_id")
            }
        }
    }

    /// 是否处于"跟随当前模型"模式（设置页说明文案用）
    var isFollowCurrent: Bool { deepThinkModelIdRaw == nil }

    /// 请求时解析深度思考用哪个配置：手动锁定 > 跟随当前
    /// 锁定的配置已被删除时自动回退跟随（不悬空）。
    func effectiveDeepThinkConfig() -> ModelConfig? {
        let store = ModelStore.shared
        if let id = deepThinkModelIdRaw,
           let m = store.configs.first(where: { $0.id.uuidString == id }) {
            return m
        }
        // 跟随：defaultConfig 已含 isDefault → 最近使用 → 第一个 的回退链。
        // 当前模型本身就是推理系列时也用它自己（避免"聊天用 A、思考用 B"的怪组合；
        // 保留分支便于以后给推理模型加差异化参数，如自动拉高 reasoning 档）。
        let current = store.defaultConfig
        if current?.isReasoningModel == true { return current }
        return current
    }
}

// MARK: - 写入请求体

enum ReasoningWriter {

    /// 把思考强度写进 body。返回实际生效的解析结果，供采样策略使用。
    @discardableResult
    static func apply(_ body: inout [String: Any],
                      spec: ReasoningSpec,
                      level: ReasoningLevel,
                      transport: String) -> ReasoningLevel {
        guard spec.supportsReasoning, spec.dialect != .none else { return .off }

        // auto：不写死强度，只补"允许思考"的表面开关，且不删用户设的键
        if level == .auto {
            switch spec.dialect {
            case .openrouterReasoning:
                var r = body["reasoning"] as? [String: Any] ?? [:]
                if r["enabled"] == nil { r["enabled"] = true }
                body["reasoning"] = r
            case .openaiResponsesReasoning:
                var r = body["reasoning"] as? [String: Any] ?? [:]
                if r["summary"] == nil { r["summary"] = "auto" }
                body["reasoning"] = r
            case .anthropicAdaptiveEffort, .anthropicBetweenTools:
                if body["thinking"] == nil {
                    body["thinking"] = ["type": "adaptive", "display": "summarized"]
                }
            case .geminiThinkingBudget, .geminiThinkingLevel:
                var gc = body["generationConfig"] as? [String: Any] ?? [:]
                var tc = gc["thinkingConfig"] as? [String: Any] ?? [:]
                if tc["includeThoughts"] == nil { tc["includeThoughts"] = true }
                gc["thinkingConfig"] = tc
                body["generationConfig"] = gc
            default:
                break
            }
            return .auto
        }

        // 明确档位 / 关闭：先清场，再写
        strip(&body, spec: spec, transport: transport)
        guard level != .off else { return .off }

        let effort = level.effortName
        let budget = spec.budget(for: level)

        switch spec.dialect {
        case .none:
            break

        case .openaiReasoningEffort, .anthropicEffort:
            if let e = effort { body["reasoning_effort"] = e }

        case .openaiResponsesReasoning:
            var r = body["reasoning"] as? [String: Any] ?? [:]
            if let e = effort { r["effort"] = e }
            if r["summary"] == nil { r["summary"] = "auto" }
            body["reasoning"] = r

        case .openrouterReasoning:
            var r = body["reasoning"] as? [String: Any] ?? [:]
            r["enabled"] = true
            if let e = effort { r["effort"] = e }
            body["reasoning"] = r

        case .anthropicBudget, .anthropicBetweenTools:
            // Claude 要求 budget_tokens 至少 1024，且必须小于 max_tokens
            var b = max(budget ?? 4096, 1024)
            if let maxTokens = body["max_tokens"] as? Int, b >= maxTokens {
                b = max(1024, maxTokens - 1024)
            }
            body["thinking"] = ["type": "enabled", "budget_tokens": b]

        case .anthropicAdaptiveEffort:
            var t: [String: Any] = ["type": "adaptive", "display": "summarized"]
            if let e = effort { t["effort"] = e }
            body["thinking"] = t

        case .geminiThinkingBudget:
            var gc = body["generationConfig"] as? [String: Any] ?? [:]
            var tc = gc["thinkingConfig"] as? [String: Any] ?? [:]
            tc["thinkingBudget"] = budget ?? 4096
            tc["includeThoughts"] = true
            gc["thinkingConfig"] = tc
            body["generationConfig"] = gc

        case .geminiThinkingLevel:
            var gc = body["generationConfig"] as? [String: Any] ?? [:]
            var tc = gc["thinkingConfig"] as? [String: Any] ?? [:]
            tc["thinkingLevel"] = (level == .minimal || level == .low) ? "low" : "high"
            tc["includeThoughts"] = true
            gc["thinkingConfig"] = tc
            body["generationConfig"] = gc

        case .qwenEnableThinking, .siliconflowEnableThinking:
            body["enable_thinking"] = true

        case .thinkingType:
            var r = body["reasoning"] as? [String: Any] ?? [:]
            if let e = effort { r["effort"] = e }
            body["reasoning"] = r

        case .kimiThinking:
            body["thinking"] = ["type": "enabled"]

        case .custom:
            if let e = effort { body["reasoning_effort"] = e }
            if let b = budget { body["thinking_budget"] = b }
        }
        return level
    }

    /// 清掉该方言负责的键（切换档位时避免残留）
    private static func strip(_ body: inout [String: Any],
                              spec: ReasoningSpec,
                              transport: String) {
        switch spec.dialect {
        case .none:
            return
        case .openaiReasoningEffort, .custom:
            body.removeValue(forKey: "reasoning_effort")
        case .openaiResponsesReasoning, .openrouterReasoning, .thinkingType:
            body.removeValue(forKey: "reasoning")
            body.removeValue(forKey: "reasoning_effort")
        case .anthropicBudget, .anthropicAdaptiveEffort, .anthropicBetweenTools,
             .anthropicEffort, .kimiThinking:
            body.removeValue(forKey: "thinking")
            body.removeValue(forKey: "reasoning_effort")
        case .geminiThinkingBudget, .geminiThinkingLevel:
            if var gc = body["generationConfig"] as? [String: Any] {
                gc.removeValue(forKey: "thinkingConfig")
                if gc.isEmpty { body.removeValue(forKey: "generationConfig") }
                else { body["generationConfig"] = gc }
            }
        case .qwenEnableThinking, .siliconflowEnableThinking:
            body.removeValue(forKey: "enable_thinking")
            body.removeValue(forKey: "thinking_budget")
            body.removeValue(forKey: "qwenEnableThinking")
        }
    }

    /// 采样参数：按策略决定是否剥离 temperature / top_p 等
    static func applySamplingPolicy(_ body: inout [String: Any],
                                    spec: ReasoningSpec,
                                    effective: ReasoningLevel,
                                    transport: String) {
        let strip: Bool
        switch spec.sampling {
        case .always: strip = false
        case .never: strip = true
        case .onlyWhenReasoningOff: strip = (effective != .off && effective != .auto)
        }
        guard strip else { return }
        let keys: [String]
        if transport == "Anthropic Messages" {
            keys = ["temperature", "top_p", "top_k"]
        } else if transport == "Gemini" {
            if var gc = body["generationConfig"] as? [String: Any] {
                ["temperature", "topP", "topK", "candidateCount"].forEach { gc.removeValue(forKey: $0) }
                body["generationConfig"] = gc
            }
            return
        } else {
            keys = ["temperature", "top_p", "top_k", "logprobs", "top_logprobs"]
        }
        keys.forEach { body.removeValue(forKey: $0) }
    }
}
