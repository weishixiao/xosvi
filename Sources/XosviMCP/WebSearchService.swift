import Foundation
import Combine

// MARK: - v7.5.0 联网检索（移植自 Kelivo 的 search services）
//
// 原项目的 web.search 只做了「百度 → 必应 → DuckDuckGo」三家 HTML 抓取，
// 关键限制：拿不到 answer、没有引用、结果质量靠正则。
// 这里按 Kelivo 的做法重做：
//   · 一套 `SearchProvider` 抽象，每个服务商只实现自己的 HTTP 调用
//   · 免费本地引擎（Bing / DuckDuckGo / SearXNG）+ 带 Key 的服务商（Tavily / Exa / Brave /
//     Serper / 博查 / 秘塔 / 智谱 / Jina / Firecrawl / Perplexity / Linkup / You.com）
//   · 多 Key 轮询（同名服务商可配多个 Key，按轮转分摊额度）
//   · 搜索返回 answer + 结构化结果（标题/URL/摘要），供 AI 引用
//
// 全文读取见 WebFetchService：搜索完还能把命中页面的正文抓回来。

// MARK: - 结果模型

struct SearchHit {
    var title: String
    var url: String
    var snippet: String
    /// v8：稳定短 id（s1/s2/...），搜索工具按 URL 去重后编号——模型引用时写 [cite:sN]
    var id: String = ""
}

struct SearchResponse {
    var provider: String
    /// 服务商直接给出的答案摘要（Tavily/Perplexity/Jina 等有）
    var answer: String?
    var hits: [SearchHit]
    var error: String?
}

// MARK: - 服务商

enum SearchProvider: String, CaseIterable, Identifiable, Codable {
    // 免费本地引擎（无需 Key）
    case bing
    case duckduckgo
    case searxng          // 需要实例地址，可填公共实例
    // 需要 API Key
    case tavily
    case exa
    case brave
    case serper
    case bocha            // 博查
    case metaso           // 秘塔
    case zhipu            // 智谱
    case jina
    case firecrawl
    case perplexity
    case linkup
    case you

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bing: return "必应"
        case .duckduckgo: return "DuckDuckGo"
        case .searxng: return "SearXNG"
        case .tavily: return "Tavily"
        case .exa: return "Exa"
        case .brave: return "Brave"
        case .serper: return "Serper"
        case .bocha: return "博查"
        case .metaso: return "秘塔"
        case .zhipu: return "智谱"
        case .jina: return "Jina"
        case .firecrawl: return "Firecrawl"
        case .perplexity: return "Perplexity"
        case .linkup: return "LinkUp"
        case .you: return "You.com"
        }
    }

    var needsKey: Bool {
        switch self {
        case .bing, .duckduckgo: return false
        case .searxng: return false       // 只需实例地址（可带基础认证）
        default: return true
        }
    }

    var needsEndpoint: Bool { self == .searxng }

    /// 是否支持「把页面正文读回来」（Kelivo 的 WebFetchCapable）
    var supportsFetch: Bool {
        switch self {
        case .tavily, .exa, .jina, .metaso, .firecrawl, .bocha: return true
        default: return false
        }
    }

    var hint: String {
        switch self {
        case .bing, .duckduckgo: return "免费，直接抓结果页，无需配置"
        case .searxng: return "填一个 SearXNG 实例地址（如 https://searx.be），可选用户名密码"
        case .tavily: return "https://tavily.com · 每月有免费额度，带 answer 摘要"
        case .exa: return "https://exa.ai · 语义检索"
        case .brave: return "https://brave.com/search/api"
        case .serper: return "https://serper.dev · Google 结果"
        case .bocha: return "https://open.bochaai.com · 国内可用"
        case .metaso: return "https://metaso.cn · 国内可用，支持读全文"
        case .zhipu: return "https://open.bigmodel.cn · 智谱搜索"
        case .jina: return "https://jina.ai/reader · 搜索 + 读全文"
        case .firecrawl: return "https://firecrawl.dev · 搜索 + 抓取"
        case .perplexity: return "https://perplexity.ai · 带答案摘要"
        case .linkup: return "https://linkup.so"
        case .you: return "https://you.com · YDC API"
        }
    }
}

// v9：配置层已迁到 SearchSettings.swift（多实例服务商 + 网页读取模式 + 兼容层）。

// MARK: - 执行

enum WebSearchService {

    /// 统一入口：指定服务商失败时按「可用服务商顺序」自动回退
    /// v9：serviceOverride —— 用指定实例的凭据执行（测连 / 多实例并存时按实例走）
    ///     allowFallback=false —— 只打这一家，失败就报错（测连必须这样，否则别家成功会掩盖失效的 Key）
    static func search(query: String,
                       provider preferred: SearchProvider?,
                       limit: Int,
                       serviceOverride: SearchServiceOptions? = nil,
                       allowFallback: Bool = true) -> SearchResponse {
        if let ov = serviceOverride {
            // 单表达式闭包：多语句闭包在旧 Swift 上要显式标注返回类型
            return SearchSettings.withServiceOverride(ov) {
                callProvider(ov.kind, query: query, limit: limit)
            }
        }
        let settings = SearchSettings.shared
        var order: [SearchProvider] = [preferred ?? settings.defaultProvider]
        // v7.16.11：开箱可用（无需 Key）的引擎排在前面——用户没配任何 Key 时，
        // 不应该先拿空 Key 去撞 Tavily/Exa 之类的接口，白等一轮超时。
        let free: [SearchProvider] = [.bing, .duckduckgo]
        for p in free where !order.contains(p) { order.append(p) }
        for p in settings.usableProviders() where !order.contains(p) { order.append(p) }
        for p in free where !order.contains(p) { order.append(p) }

        var lastErr = ""
        // v7.13.2：必应改版后经常只给 1 条，不该就此打住——少于 2 条继续问下一个引擎，
        // 全程都弱时退回"最好的那条"，不至于空手而归。
        // v9：同 kind 可能有多个实例（一主一备），命中当前选中实例时必须用它自己的 Key，
        // 否则「设为当前」在界面上生效、实际仍打第一套 Key。
        let selected = settings.selectedService
        var best: SearchResponse?
        for p in order {
            let override: SearchServiceOptions? = (selected?.kind == p) ? selected : nil
            let r: SearchResponse = SearchSettings.withServiceOverride(override) {
                callProvider(p, query: query, limit: limit)
            }
            if r.hits.count >= 2 || (r.answer?.isEmpty == false) { return r }
            if r.hits.count == 1, best == nil { best = r }
            lastErr = r.error ?? "无结果"
            if !allowFallback { break }
        }
        if let b = best { return b }
        return SearchResponse(provider: preferred?.displayName ?? "本地", answer: nil, hits: [], error: lastErr)
    }

    private static func callProvider(_ p: SearchProvider, query: String, limit: Int) -> SearchResponse {
        switch p {
        case .bing:        return BingLocal.search(query: query, limit: limit)
        case .duckduckgo:  return DuckLocal.search(query: query, limit: limit)
        case .searxng:     return SearXNG.search(query: query, limit: limit)
        case .tavily:      return Tavily.search(query: query, limit: limit)
        case .exa:         return Exa.search(query: query, limit: limit)
        case .brave:       return Brave.search(query: query, limit: limit)
        case .serper:      return Serper.search(query: query, limit: limit)
        case .bocha:       return Bocha.search(query: query, limit: limit)
        case .metaso:      return Metaso.search(query: query, limit: limit)
        case .zhipu:       return Zhipu.search(query: query, limit: limit)
        case .jina:        return Jina.search(query: query, limit: limit)
        case .firecrawl:   return Firecrawl.search(query: query, limit: limit)
        case .perplexity:  return Perplexity.search(query: query, limit: limit)
        case .linkup:      return Linkup.search(query: query, limit: limit)
        case .you:         return YouCom.search(query: query, limit: limit)
        }
    }

    // MARK: HTTP 工具

    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// v9：全局超时（设置页可调 5–120s）。各 HTTP 调用默认走它，工具显式传参可覆盖。
    static var defaultTimeout: TimeInterval {
        let t = SearchSettings.shared.timeoutSeconds
        return TimeInterval(max(5, min(t, 120)))
    }

    static func http(_ req: URLRequest, timeout: TimeInterval? = nil) -> (Data?, Int, String) {
        var data: Data?
        var code = -1
        var errText = ""
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let task = URLSession.shared.dataTask(with: req) { d, resp, err in
                data = d
                code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                if let e = err { errText = e.localizedDescription }
                sem.signal()
            }
            task.resume()
        }
        _ = sem.wait(timeout: .now() + (timeout ?? defaultTimeout))
        return (data, code, errText)
    }

    static func getJSON(_ url: String, headers: [String: String] = [:]) -> (Any?, String) {
        guard let u = URL(string: url) else { return (nil, "URL 非法") }
        var req = URLRequest(url: u, timeoutInterval: defaultTimeout)
        req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, code, err) = http(req)
        guard let d = data, code >= 200, code < 300 else {
            return (nil, "HTTP \(code) \(err)")
        }
        return (try? JSONSerialization.jsonObject(with: d), "")
    }

    static func postJSON(_ url: String, body: [String: Any], headers: [String: String]) -> (Any?, String) {
        guard let u = URL(string: url) else { return (nil, "URL 非法") }
        var req = URLRequest(url: u, timeoutInterval: max(defaultTimeout, 30))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, code, err) = http(req)
        guard let d = data, code >= 200, code < 300 else {
            let detail = data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(200)) } ?? ""
            return (nil, "HTTP \(code) \(err) \(detail)")
        }
        return (try? JSONSerialization.jsonObject(with: d), "")
    }

    static func getText(_ url: String, headers: [String: String] = [:]) -> (String?, String) {
        guard let u = URL(string: url) else { return (nil, "URL 非法") }
        var req = URLRequest(url: u, timeoutInterval: defaultTimeout)
        req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, code, err) = http(req)
        guard let d = data, code >= 200, code < 300 else { return (nil, "HTTP \(code) \(err)") }
        // 百度/部分站点是 GBK
        if let s = String(data: d, encoding: .utf8), !s.isEmpty { return (s, "") }
        let enc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: d, encoding: String.Encoding(rawValue: enc)) { return (s, "") }
        return (String(data: d, encoding: .isoLatin1), "")
    }
}

// MARK: - 免费本地引擎

enum BingLocal {
    static func search(query: String, limit: Int) -> SearchResponse {
        // v9.4：先走 RSS 接口（稳定、结构化、不受改版与反爬影响）；
        // 实测 https://cn.bing.com/search?q=..&format=rss 在本机网络可直接出 XML。
        // 原来只解析 HTML 的 b_algo 块，必应改版或返回验证页时一条也拿不到。
        let rss = rssSearch(query: query, limit: limit)
        if !rss.hits.isEmpty { return rss }
        let html = htmlSearch(query: query, limit: limit)
        if !html.hits.isEmpty { return html }
        // 两个都空：把 RSS 的错误优先报出去（HTML 多半是被拦成验证页）
        return SearchResponse(provider: "必应", answer: nil, hits: [],
                              error: rss.error ?? html.error ?? "无结果")
    }

    /// v9.4：RSS 通道——<item><title/><link/><description/></item>
    private static func rssSearch(query: String, limit: Int) -> SearchResponse {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (xml, err) = WebSearchService.getText("https://cn.bing.com/search?q=\(q)&format=rss&count=\(limit)")
        guard let x = xml else { return SearchResponse(provider: "必应", answer: nil, hits: [], error: err) }
        var hits: [SearchHit] = []
        for block in x.components(separatedBy: "<item>").dropFirst() {
            if hits.count >= limit { break }
            guard let link = block.firstCapture(pattern: "<link>([\\s\\S]*?)</link>")?
                              .trimmingCharacters(in: .whitespacesAndNewlines),
                  link.hasPrefix("http") else { continue }
            let title = (block.firstCapture(pattern: "<title>([\\s\\S]*?)</title>") ?? "")
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
                .stripHTMLTags()
            let desc = (block.firstCapture(pattern: "<description>([\\s\\S]*?)</description>") ?? "")
                .replacingOccurrences(of: "<![CDATA[", with: "")
                .replacingOccurrences(of: "]]>", with: "")
                .stripHTMLTags()
            guard !title.isEmpty else { continue }
            if hits.contains(where: { $0.url == link }) { continue }
            hits.append(SearchHit(title: title, url: link, snippet: desc))
        }
        return SearchResponse(provider: "必应", answer: nil, hits: hits,
                              error: hits.isEmpty ? "RSS 无结果" : nil)
    }

    /// 旧通道：HTML 的 b_algo 块（RSS 不可用时兜底）
    private static func htmlSearch(query: String, limit: Int) -> SearchResponse {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (html, err) = WebSearchService.getText("https://cn.bing.com/search?q=\(q)&count=\(limit)")
        guard let h = html else { return SearchResponse(provider: "必应", answer: nil, hits: [], error: err) }
        var hits: [SearchHit] = []
        // 结果块：<li class="b_algo"> … <h2><a href="…">标题</a></h2> … 摘要
        let blocks = h.components(separatedBy: "<li class=\"b_algo")
        for b in blocks.dropFirst() {
            if hits.count >= limit { break }
            guard let url = b.firstCapture(pattern: "<a[^>]+href=\"(https?://[^\"]+)\""),
                  let title = b.firstCapture(pattern: "<h2[^>]*>[\\s\\S]*?<a[^>]*>([\\s\\S]*?)</a>")?.stripHTMLTags(),
                  !title.isEmpty else { continue }
            let snippet = (b.firstCapture(pattern: "<p[^>]*>([\\s\\S]*?)</p>")
                ?? b.firstCapture(pattern: "<div class=\"b_caption\"[^>]*>[\\s\\S]*?<p[^>]*>([\\s\\S]*?)</p>") ?? "")
                .stripHTMLTags()
            if hits.contains(where: { $0.url == url }) { continue }
            hits.append(SearchHit(title: title, url: url, snippet: snippet))
        }
        return SearchResponse(provider: "必应", answer: nil, hits: hits, error: hits.isEmpty ? "解析不到结果" : nil)
    }
}

enum DuckLocal {
    static func search(query: String, limit: Int) -> SearchResponse {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (html, err) = WebSearchService.getText("https://html.duckduckgo.com/html/?q=\(q)")
        guard let h = html else { return SearchResponse(provider: "DuckDuckGo", answer: nil, hits: [], error: err) }
        var hits: [SearchHit] = []
        let blocks = h.components(separatedBy: "result__body")
        for b in blocks.dropFirst() {
            if hits.count >= limit { break }
            guard let raw = b.firstCapture(pattern: "href=\"(//duckduckgo\\.com/l/\\?uddg=[^\"]+|https?://[^\"]+)\""),
                  let title = b.firstCapture(pattern: "result__a[^>]*>([\\s\\S]*?)</a>")?.stripHTMLTags(),
                  !title.isEmpty else { continue }
            var url = raw.replacingOccurrences(of: "&amp;", with: "&")
            if url.hasPrefix("//duckduckgo.com/l/?uddg="),
               let enc = url.components(separatedBy: "uddg=").last,
               let decoded = enc.removingPercentEncoding {
                url = decoded.components(separatedBy: "&rut=").first ?? decoded
            }
            if !url.hasPrefix("http") { continue }
            let snippet = (b.firstCapture(pattern: "result__snippet[^>]*>([\\s\\S]*?)</a>") ?? "").stripHTMLTags()
            if hits.contains(where: { $0.url == url }) { continue }
            hits.append(SearchHit(title: title, url: url, snippet: snippet))
        }
        return SearchResponse(provider: "DuckDuckGo", answer: nil, hits: hits, error: hits.isEmpty ? "解析不到结果" : nil)
    }
}

enum SearXNG {
    static func search(query: String, limit: Int) -> SearchResponse {
        let cfg = SearchSettings.shared.config(for: .searxng)
        var base = cfg.endpoint.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { return SearchResponse(provider: "SearXNG", answer: nil, hits: [], error: "未配置实例地址") }
        if base.hasSuffix("/") { base.removeLast() }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var headers: [String: String] = [:]
        if !cfg.basicUser.isEmpty {
            let token = Data("\(cfg.basicUser):\(cfg.basicPassword)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(token)"
        }
        let (json, err) = WebSearchService.getJSON("\(base)/search?q=\(q)&format=json&safesearch=0", headers: headers)
        guard let d = json as? [String: Any], let arr = d["results"] as? [[String: Any]] else {
            return SearchResponse(provider: "SearXNG", answer: nil, hits: [], error: err.isEmpty ? "实例未开启 JSON 输出" : err)
        }
        var hits: [SearchHit] = []
        for r in arr where hits.count < limit {
            guard let u = r["url"] as? String, let t = r["title"] as? String, !u.isEmpty else { continue }
            hits.append(SearchHit(title: t, url: u, snippet: (r["content"] as? String) ?? ""))
        }
        return SearchResponse(provider: "SearXNG", answer: nil, hits: hits, error: hits.isEmpty ? "无结果" : nil)
    }
}

// MARK: - 带 Key 的服务商

enum Tavily {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .tavily)
        guard !key.isEmpty else { return SearchResponse(provider: "Tavily", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://api.tavily.com/search",
            body: ["query": query, "max_results": limit, "include_answer": true],
            headers: ["Authorization": "Bearer \(key)"])
        guard let d = json as? [String: Any], let arr = d["results"] as? [[String: Any]] else {
            return SearchResponse(provider: "Tavily", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["url"] as? String else { return nil }
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: (r["content"] as? String) ?? "")
        }
        return SearchResponse(provider: "Tavily", answer: d["answer"] as? String, hits: Array(hits), error: nil)
    }
}

enum Exa {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .exa)
        guard !key.isEmpty else { return SearchResponse(provider: "Exa", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://api.exa.ai/search",
            body: ["query": query, "numResults": limit, "contents": ["text": ["maxCharacters": 1200]]],
            headers: ["x-api-key": key])
        guard let d = json as? [String: Any], let arr = d["results"] as? [[String: Any]] else {
            return SearchResponse(provider: "Exa", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["url"] as? String else { return nil }
            let text = (r["text"] as? String) ?? (r["summary"] as? String) ?? ""
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: String(text.prefix(400)))
        }
        return SearchResponse(provider: "Exa", answer: nil, hits: Array(hits), error: nil)
    }
}

enum Brave {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .brave)
        guard !key.isEmpty else { return SearchResponse(provider: "Brave", answer: nil, hits: [], error: "未配置 API Key") }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (json, err) = WebSearchService.getJSON(
            "https://api.search.brave.com/res/v1/web/search?q=\(q)&count=\(limit)",
            headers: ["X-Subscription-Token": key, "Accept": "application/json"])
        guard let d = json as? [String: Any],
              let web = d["web"] as? [String: Any],
              let arr = web["results"] as? [[String: Any]] else {
            return SearchResponse(provider: "Brave", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["url"] as? String else { return nil }
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: (r["description"] as? String) ?? "")
        }
        return SearchResponse(provider: "Brave", answer: nil, hits: Array(hits), error: nil)
    }
}

enum Serper {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .serper)
        guard !key.isEmpty else { return SearchResponse(provider: "Serper", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://google.serper.dev/search",
            body: ["q": query, "num": limit],
            headers: ["X-API-KEY": key])
        guard let d = json as? [String: Any], let arr = d["organic"] as? [[String: Any]] else {
            return SearchResponse(provider: "Serper", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["link"] as? String else { return nil }
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: (r["snippet"] as? String) ?? "")
        }
        let answer = (d["answerBox"] as? [String: Any])?["answer"] as? String
        return SearchResponse(provider: "Serper", answer: answer, hits: Array(hits), error: nil)
    }
}

enum Bocha {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .bocha)
        guard !key.isEmpty else { return SearchResponse(provider: "博查", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://api.bochaai.com/v1/web-search",
            body: ["query": query, "count": limit, "summary": true],
            headers: ["Authorization": "Bearer \(key)"])
        guard let d = json as? [String: Any],
              let data = d["data"] as? [String: Any],
              let web = data["webPages"] as? [String: Any],
              let arr = web["value"] as? [[String: Any]] else {
            return SearchResponse(provider: "博查", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["url"] as? String else { return nil }
            return SearchHit(title: (r["name"] as? String) ?? u, url: u,
                             snippet: (r["summary"] as? String) ?? (r["snippet"] as? String) ?? "")
        }
        return SearchResponse(provider: "博查", answer: nil, hits: Array(hits), error: nil)
    }
}

enum Metaso {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .metaso)
        guard !key.isEmpty else { return SearchResponse(provider: "秘塔", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://metaso.cn/api/v1/search",
            body: ["q": query, "scope": "webpage", "includeSummary": true, "size": String(limit)],
            headers: ["Authorization": "Bearer \(key)"])
        guard let d = json as? [String: Any], let arr = d["webpages"] as? [[String: Any]] else {
            return SearchResponse(provider: "秘塔", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["link"] as? String else { return nil }
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: (r["snippet"] as? String) ?? "")
        }
        return SearchResponse(provider: "秘塔", answer: nil, hits: Array(hits), error: nil)
    }
}

enum Zhipu {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .zhipu)
        guard !key.isEmpty else { return SearchResponse(provider: "智谱", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://open.bigmodel.cn/api/paas/v4/web_search",
            body: ["search_engine": "search_std", "search_query": query, "count": limit],
            headers: ["Authorization": "Bearer \(key)"])
        guard let d = json as? [String: Any], let arr = d["search_result"] as? [[String: Any]] else {
            return SearchResponse(provider: "智谱", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["link"] as? String else { return nil }
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: (r["content"] as? String) ?? "")
        }
        return SearchResponse(provider: "智谱", answer: nil, hits: Array(hits), error: nil)
    }
}

enum Jina {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .jina)
        var headers: [String: String] = ["Accept": "application/json"]
        if !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (json, err) = WebSearchService.getJSON("https://s.jina.ai/\(q)", headers: headers)
        guard let d = json as? [String: Any], let arr = d["data"] as? [[String: Any]] else {
            return SearchResponse(provider: "Jina", answer: nil, hits: [], error: err.isEmpty ? "需要 Jina API Key" : err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["url"] as? String else { return nil }
            let desc = (r["description"] as? String) ?? (r["content"] as? String) ?? ""
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: String(desc.prefix(400)))
        }
        return SearchResponse(provider: "Jina", answer: nil, hits: Array(hits), error: hits.isEmpty ? "无结果" : nil)
    }
}

enum Firecrawl {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .firecrawl)
        guard !key.isEmpty else { return SearchResponse(provider: "Firecrawl", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://api.firecrawl.dev/v1/search",
            body: ["query": query, "limit": limit, "scrapeOptions": ["formats": ["markdown"]]],
            headers: ["Authorization": "Bearer \(key)"])
        guard let d = json as? [String: Any], let arr = d["data"] as? [[String: Any]] else {
            return SearchResponse(provider: "Firecrawl", answer: nil, hits: [], error: err)
        }
        let hits = arr.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["url"] as? String else { return nil }
            let md = (r["markdown"] as? String) ?? ""
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: String(md.prefix(400)))
        }
        return SearchResponse(provider: "Firecrawl", answer: nil, hits: Array(hits), error: nil)
    }
}

enum Perplexity {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .perplexity)
        guard !key.isEmpty else { return SearchResponse(provider: "Perplexity", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://api.perplexity.ai/chat/completions",
            body: ["model": "sonar", "messages": [["role": "user", "content": query]]],
            headers: ["Authorization": "Bearer \(key)"])
        guard let d = json as? [String: Any],
              let choices = d["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            return SearchResponse(provider: "Perplexity", answer: nil, hits: [], error: err)
        }
        let answer = (msg["content"] as? String) ?? ""
        // Perplexity 把引用放在 search_results
        var hits: [SearchHit] = []
        if let results = d["search_results"] as? [[String: Any]] {
            for r in results.prefix(limit) {
                guard let u = r["url"] as? String else { continue }
                hits.append(SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: ""))
            }
        }
        return SearchResponse(provider: "Perplexity", answer: answer, hits: hits, error: nil)
    }
}

enum Linkup {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .linkup)
        guard !key.isEmpty else { return SearchResponse(provider: "LinkUp", answer: nil, hits: [], error: "未配置 API Key") }
        let (json, err) = WebSearchService.postJSON(
            "https://api.linkup.so/v1/search",
            body: ["q": query, "depth": "standard", "outputType": "sourcedAnswer"],
            headers: ["Authorization": "Bearer \(key)"])
        guard let d = json as? [String: Any] else {
            return SearchResponse(provider: "LinkUp", answer: nil, hits: [], error: err)
        }
        var hits: [SearchHit] = []
        if let sources = d["sources"] as? [[String: Any]] {
            for s in sources.prefix(limit) {
                guard let u = s["url"] as? String else { continue }
                hits.append(SearchHit(title: (s["name"] as? String) ?? u, url: u, snippet: (s["snippet"] as? String) ?? ""))
            }
        }
        return SearchResponse(provider: "LinkUp", answer: d["answer"] as? String, hits: hits, error: nil)
    }
}

enum YouCom {
    static func search(query: String, limit: Int) -> SearchResponse {
        let key = SearchSettings.shared.nextKey(for: .you)
        guard !key.isEmpty else { return SearchResponse(provider: "You.com", answer: nil, hits: [], error: "未配置 API Key") }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let (json, err) = WebSearchService.getJSON(
            "https://ydc-index.io/v1/search?query=\(q)&count=\(limit)",
            headers: ["X-API-Key": key])
        guard let d = json as? [String: Any],
              let results = d["results"] as? [String: Any],
              let web = results["web"] as? [[String: Any]] else {
            return SearchResponse(provider: "You.com", answer: nil, hits: [], error: err)
        }
        let hits = web.prefix(limit).compactMap { r -> SearchHit? in
            guard let u = r["url"] as? String else { return nil }
            let snippets = (r["snippets"] as? [String])?.joined(separator: " ") ?? ""
            return SearchHit(title: (r["title"] as? String) ?? u, url: u, snippet: snippets)
        }
        return SearchResponse(provider: "You.com", answer: nil, hits: Array(hits), error: nil)
    }
}
