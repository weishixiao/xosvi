import Foundation

// MARK: - v9：模型 API 余额查询（移植 Kelivo balance_checker + 文档四种接口形态）
//
// 没有统一余额接口，各服务商协议不同：
//   策略 1  DeepSeek 官方      GET /user/balance → balance_infos[0].total_balance + currency
//   策略 2  new-api / one-api  GET /api/user/self → data.quota（内部额度单位，默认 500000 = $1）
//   策略 3  one-api 早期        GET /dashboard/billing/subscription → hard_limit_usd
//                              + /dashboard/billing/usage → total_usage（美分）
//   兜底    统一失败文案——比假装查出个数字诚实。
// OpenAI / Anthropic 官方没有可用余额端点，会落到兜底（安静失败，不影响发消息）。
//
// 关键约束（文档第七节「几个坑」）：
//   · 缓存 5 分钟（中转站普遍限流）；force 才绕过
//   · 同一 config 并发只打一次（inflight 去重）
//   · 失败要静默：返回 .failure，调用方只显示「余额 ?」灰胶囊
//   · new-api 部分部署要求 New-Api-User 头（用户 ID），设置里填过一次即可

struct BalanceInfo: Equatable {
    /// 展示文本，如 "$ 12.34" / "¥ 86.20"
    var text: String
    /// 数值（用于低额告警）；解析不出来时 nil
    var remaining: Double?
    var currency: String        // "$" / "¥" / ""
    var via: String             // 命中的策略
    var updatedAt: Date = Date()
    /// 详情（如 "$ 12.34 / $ 20.00" 的总额度部分）
    var detail: String? = nil

    /// 低额阈值：美元 < 1、人民币 < 5（Kelivo 同款判断）
    var isLow: Bool {
        guard let r = remaining else { return false }
        return currency == "¥" ? r < 5.0 : r < 1.0
    }
}

/// Result 的 Failure 必须遵循 Error——String 不行，包一层
enum BalanceError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}

final class BalanceChecker {
    static let shared = BalanceChecker()
    private init() {}

    /// 缓存有效期（秒）
    static let cacheTTL: TimeInterval = 300

    /// 内存缓存：configID → BalanceInfo
    private var cache: [UUID: BalanceInfo] = [:]
    private var inflight: Set<UUID> = []
    /// 同一 config 的并发请求：正在飞的那次完成后统一回调，避免第二个调用静默丢失
    private var pending: [UUID: [(Result<BalanceInfo, BalanceError>) -> Void]] = [:]
    private let lock = NSLock()

    /// new-api 默认 500000 单位 = $1，可在设置里改
    static var quotaPerUnit: Double {
        let v = UserDefaults.standard.double(forKey: "xosvi.quota_per_unit")
        return v > 0 ? v : 500_000
    }

    /// 部分 new-api 部署要求带用户 ID
    static var newAPIUserID: String {
        (UserDefaults.standard.string(forKey: "xosvi.newapi_user_id") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 缓存 / 查询

    func cached(_ id: UUID) -> BalanceInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let c = cache[id],
              Date().timeIntervalSince(c.updatedAt) < Self.cacheTTL else { return nil }
        return c
    }

    /// 无视 TTL 的旧值（失败时给 UI 一个「上次是多少」的兜底）
    func lastKnown(_ id: UUID) -> BalanceInfo? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]
    }

    func isQuerying(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inflight.contains(id)
    }

    func invalidate(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cache.removeValue(forKey: id)
    }

    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        inflight.removeAll()
        pending.removeAll()
    }

    /// 查询余额；force=false 时 5 分钟内的缓存直接返回
    /// 参数标签用 `config:`——调用点写 `check(config: cfg, ...)`，与仓库其它
    /// 单参方法（如 BalanceChecker 老版 `check(config:completion:)`）保持一致。
    func check(config: ModelConfig, force: Bool = false,
               completion: @escaping (Result<BalanceInfo, BalanceError>) -> Void) {
        lock.lock()
        if !force, let c = cache[config.id],
           Date().timeIntervalSince(c.updatedAt) < Self.cacheTTL {
            lock.unlock(); completion(.success(c)); return
        }
        // 同一配置并发只打一次：后来的挂到 pending，飞完一起回调
        if inflight.contains(config.id) {
            pending[config.id, default: []].append(completion)
            lock.unlock()
            return
        }
        inflight.insert(config.id)
        pending[config.id, default: []].append(completion)
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let result = BalanceChecker.query(config)
            self.lock.lock()
            self.inflight.remove(config.id)
            if case .success(let info) = result { self.cache[config.id] = info }
            let waiters = self.pending.removeValue(forKey: config.id) ?? []
            self.lock.unlock()
            DispatchQueue.main.async {
                for cb in waiters { cb(result) }
            }
        }
    }

    // MARK: 策略链

    private static func query(_ config: ModelConfig) -> Result<BalanceInfo, BalanceError> {
        let host = hostOf(config.baseURL)
        let provider = config.provider.lowercased()
        let isDeepSeek = host.contains("deepseek") || provider.contains("deepseek")

        // 策略 1：DeepSeek 官方
        if isDeepSeek {
            if let json = get(config, "/user/balance"),
               let infos = json["balance_infos"] as? [[String: Any]],
               let f = infos.first,
               let total = f["total_balance"] as? String,
               let cur = f["currency"] as? String {
                let sym = symbolFor(cur)
                let value = Double(total)
                return .success(BalanceInfo(text: "\(sym) \(total)",
                                            remaining: value,
                                            currency: sym,
                                            via: "deepseek"))
            }
            // DeepSeek 站也可能是中转（很多 one-api 部署也叫 deepseek）→ 继续往下试
        }

        // 策略 2：new-api / one-api 新版（/api/user/self）
        if let json = get(config, "/api/user/self"),
           let data = json["data"] as? [String: Any],
           let quotaRaw = data["quota"] {
            let quota = numeric(quotaRaw)
            if quota > 0 || data["used_quota"] != nil {
                let dollars = quota / quotaPerUnit
                let text = String(format: "$ %.2f", dollars)
                var detail: String? = nil
                if let usedRaw = data["used_quota"] {
                    let used = numeric(usedRaw) / quotaPerUnit
                    detail = String(format: "已用 $ %.2f · 额度 $ %.2f", used, dollars + used)
                }
                if let group = data["group"] as? String, !group.isEmpty {
                    detail = (detail.map { $0 + " · " } ?? "") + "分组 \(group)"
                }
                return .success(BalanceInfo(text: text,
                                            remaining: dollars,
                                            currency: "$",
                                            via: "new-api",
                                            detail: detail))
            }
        }

        // 策略 3：one-api 早期（billing/subscription + usage）
        if let sub = get(config, "/dashboard/billing/subscription"),
           let hard = numericOptional(sub["hard_limit_usd"]) {
            var used: Double = 0
            if let usage = get(config, "/dashboard/billing/usage"),
               let cents = numericOptional(usage["total_usage"]) {
                used = cents / 100.0
            }
            let remain = max(0, hard - used)
            return .success(BalanceInfo(
                text: String(format: "$ %.2f", remain),
                remaining: remain,
                currency: "$",
                via: "one-api",
                detail: String(format: "总额 $ %.2f · 已用 $ %.2f", hard, used)))
        }

        return .failure(.message("该服务商不提供余额接口（OpenAI / Anthropic 官方需去控制台查看）"))
    }

    /// 统一 GET：base + path，鉴权按 config.authMethod（与 ModelRow.speedTest 同一模式）
    private static func get(_ config: ModelConfig, _ path: String) -> [String: Any]? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        setHTTPMethod("GET", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch config.authMethod {
        case "API Key":
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case "None":
            break
        default:
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        // new-api 部分部署要求额外带用户 ID；没有就不带，多数站靠 key 即可
        let uid = newAPIUserID
        if !uid.isEmpty { req.setValue(uid, forHTTPHeaderField: "New-Api-User") }

        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            out = json
        }.resume()
        _ = sem.wait(timeout: .now() + 13)
        return out
    }

    // MARK: 工具

    private static func hostOf(_ s: String) -> String {
        (URL(string: s)?.host ?? "").lowercased()
    }

    private static func symbolFor(_ currency: String) -> String {
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        default: return currency
        }
    }

    /// JSON 数字可能是 Int / Double / String（不少中转站把 quota 序列化成字符串）
    private static func numeric(_ v: Any) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }

    private static func numericOptional(_ v: Any?) -> Double? {
        guard let v else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - 请求完成通知（余额自动刷新用）

extension Notification.Name {
    /// 一次模型请求真正结束（成功或失败）——余额可能已变。
    /// 刻意不用 delta：流式中途刷新会打爆中转站限流。
    static let xosviRequestFinished = Notification.Name("xosvi.requestFinished")
}
