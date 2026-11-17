import Foundation

// v10.13（会话运行重设计 · L3 意图判定）
//
// 四层设计：
//   L1 提示词分层   —— 常驻会话核心 + 工作层（环境提示词/模式/技能卡）按档位注入
//   L2 工具渐进披露 —— chat 不给工具 schema，lookup 只给联网两件套，operate 才全量
//   L3 意图判定     —— 本文件：每条用户消息先判「聊天 / 查证 / 干活」
//   L4 纠正门控     —— 解说/参数/批量/空回复纠正只在干活档生效
//
// 设计要点：判定放在本地（纯字符串规则，零网络零延迟），判错时向「聊天」侧兜底——
// 用户抱怨的正是「一开口就调工具」，宁可多聊一句让用户补一句「去做」，也不要上来就开工具。

/// 一轮消息的运行档位
enum RunIntent: String {
    /// 闲聊 / 问答 / 出主意：不给任何工具，模型不能调用
    case chat
    /// 联网查证：只给 web.search / web.fetch
    case lookup
    /// 动手干活：全量已启用工具 + 完整工作层 + 纠正机制
    case operate

    var label: String {
        switch self {
        case .chat: return "聊天"
        case .lookup: return "查证"
        case .operate: return "干活"
        }
    }
}

/// 由意图派生的一轮运行策略（纯值类型，每轮重算，不落盘）
struct RunPolicy {
    var intent: RunIntent = .operate

    /// 查证档唯一放行的工具（联网两件套）
    static let lookupTools: Set<String> = ["web.search", "web.fetch"]

    init(intent: RunIntent = .operate) {
        self.intent = intent
    }

    /// 这轮允不允许模型调用工具
    var allowsTools: Bool { intent != .chat }
    /// 这轮是否注入完整工作层（环境提示词 / 模式清单 / 工具裁决 / 动态状态 / 技能卡）
    var usesWorkLayers: Bool { intent != .chat }
    /// 这轮是否启用自适应纠正（解说 / 参数 / 批量 / 空回复）
    var usesCorrections: Bool { intent != .chat }
    /// 这轮是否给全量已启用工具（只有干活档）
    var allowsAllTools: Bool { intent == .operate }
    /// 文本式工具调用兜底（模型把 shell 命令写成正文）是否可执行
    var allowsTextualToolFallback: Bool { intent == .operate }

    /// 这轮给模型的工具白名单（nil = 全量已启用工具）
    var toolWhitelist: Set<String>? {
        switch intent {
        case .chat: return Set<String>()
        case .lookup: return RunPolicy.lookupTools
        case .operate: return nil
        }
    }
}

// MARK: - 意图判定

enum IntentClassifier {

    // MARK: 词表

    /// 出现即认定为「干活」：动设备 / 动文件 / 动工程
    /// 注意：纯 ASCII 词（app / ci / ipa / grep …）按词边界匹配，"ci" 不会命中 "decision"。
    private static let operateWords: [String] = [
        // 文件与工程
        "文件", "目录", "文件夹", "路径", "工作区", "workspace", "代码", "编译", "构建", "打包",
        "安装", "卸载", "解压", "解包", "删除", "删掉", "移除", "改名", "重命名", "写入", "写进",
        "修改", "改成", "替换", "创建", "新建", "下载", "上传", "导入", "导出", "运行", "执行",
        "脚本", "命令", "终端", "shell", "grep", "cat", "ls", "chmod", "sudo",
        // 设备与 App
        "app", "应用", "启动", "重启", "关闭", "截图", "截屏", "截个图", "录屏", "点击", "点一下", "点开",
        "输入框", "滑动", "滚动", "注入", "hook", "调试", "debug", "崩溃", "crash", "闪退", "卡死",
        "日志", "报错", "错误", "exception", "修复", "签名", "越狱", "root", "ssh", "设备信息",
        "进程", "内存", "改机", "抓包", "证书",
        // 逆向与发布
        "砸壳", "脱壳", "反编译", "反汇编", "符号表", "macho", "dylib", "tweak", "二进制", "ipa", "deb",
        "github", "提交", "推送", "分支", "对比", "diff", "ci", "流水线",
        // 明确要求动手的句式
        "帮我做", "帮我改", "帮我写", "帮我弄", "处理一下",
        "跑一遍", "试一下", "验证一下", "装一下", "读一下"
    ]

    /// 出现即认定为「联网查证」（仅在无干活词时生效）
    private static let lookupWords: [String] = [
        "查一下", "查查", "帮我查", "你们查", "搜一下", "搜搜", "搜索", "联网", "上网", "网上", "在线查",
        "最新", "近期", "新闻", "多少钱", "价格", "行情", "发布", "版本号", "官网", "资料",
        "百科", "是谁", "论文", "文献", "统计数据", "http://", "https://", "www.",
        "什么时候出", "有什么区别", "推荐哪个"
    ]

    /// 否定 / 身份：用户明确不让动手，或问「你是谁」——问身份是聊天，不该去联网查。
    private static let chatOverrideWords: [String] = [
        "别调工具", "不要调工具", "不要调用工具", "别用工具", "不用工具", "别去查", "不要联网",
        "直接回答", "就聊聊", "随便聊聊", "先别动手", "别动手",
        "你是谁", "你叫什么", "你是什么", "你是ai"
    ]

    /// 肯定续做：「好 / 去吧 / 动手吧」
    private static let agreementWords: [String] = [
        "好", "好的", "好啊", "可以", "行", "去吧", "去", "做吧", "来吧", "继续", "开始",
        "嗯", "对", "要", "嗯嗯", "ok", "okay", "go", "yes", "确定", "动手", "干吧", "麻烦你了"
    ]

    /// 上一轮 AI 消息里出现这些，说明它在提议动手
    private static let proposalMarkers: [String] = [
        "要我去", "要我帮", "要我继续", "需要我", "是否需要我", "要不要我", "我可以帮", "我可以去",
        "我这就", "我来", "我去帮你", "让我去", "确认后我", "要我做吗", "要我去做吗"
    ]

    // MARK: 入口

    static func policy(for text: String, hasAttachments: Bool = false,
                       previousAssistant: String = "") -> RunPolicy {
        RunPolicy(intent: intent(for: text, hasAttachments: hasAttachments,
                                 previousAssistant: previousAssistant))
    }

    static func intent(for text: String, hasAttachments: Bool = false,
                       previousAssistant: String = "") -> RunIntent {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 带图/带附件：一定是让干活（看图、改图、分析截图）
        if hasAttachments { return .operate }
        // 空消息 = 不是新的用户输入（例如后台 worker 续跑已排队的这一轮）→ 交给调用方沿用旧档位
        if raw.isEmpty { return .chat }
        let t = raw.lowercased()

        // 1) 用户明确不让动手
        if containsAny(t, chatOverrideWords) { return .chat }

        // 2) 明确动手词
        if containsAny(t, operateWords) { return .operate }

        // 3) 像路径 / 协议地址 → 干活
        if looksLikePath(t) { return .operate }

        // 4) 上一轮 AI 在提议动手，用户这句是「好 / 去吧」→ 干活。
        //    上一轮是问句（"要我做吗？"）也算提议——中文里常省略主语的肯定回答最容易漏判。
        if isAgreement(t), isProposal(previousAssistant) { return .operate }

        // 5) 联网查证词
        if containsAny(t, lookupWords) { return .lookup }

        // 6) 兜底：当聊天。判错成本低——用户补一句「去做」就会升级到干活档，
        //    反过来（闲聊却开了工具）才是用户抱怨的那种体验。
        return .chat
    }

    // MARK: 内部

    /// 上一轮 AI 是不是在提议动手
    private static func isProposal(_ previousAssistant: String) -> Bool {
        guard !previousAssistant.isEmpty else { return false }
        let p = previousAssistant.lowercased()
        if containsAny(p, proposalMarkers) { return true }
        // 尾巴是问句（"要我做吗？" / "Shall I go ahead?"）也算
        let tail = String(p.suffix(200))
        return tail.contains("？") || tail.contains("?") || tail.hasSuffix("吗")
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        for n in needles where matches(haystack, n) { return true }
        return false
    }

    /// 命中判定：纯 ASCII 词走「词边界」，含空格/符号的词（"http://"、"别调工具"）走原样子串。
    /// 不加边界时 "ci" 会命中 "decision"、"app" 会命中 "appreciate"，
    /// 英文闲聊会被整片判成干活——那正是这次要消灭的故障。
    private static func matches(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        guard isASCIIWord(needle) else { return haystack.contains(needle) }
        var start = haystack.startIndex
        while let r = haystack.range(of: needle, range: start..<haystack.endIndex) {
            let beforeOK = r.lowerBound == haystack.startIndex
                || !isWordChar(haystack[haystack.index(before: r.lowerBound)])
            let afterOK = r.upperBound == haystack.endIndex
                || !isWordChar(haystack[r.upperBound])
            if beforeOK && afterOK { return true }
            start = haystack.index(after: r.lowerBound)
        }
        return false
    }

    private static func isASCIIWord(_ s: String) -> Bool {
        var has = false
        for c in s {
            guard c.isASCII else { return false }
            if c.isLetter || c.isNumber { has = true } else { return false }
        }
        return has
    }

    private static func isWordChar(_ c: Character) -> Bool {
        if !c.isASCII { return false }
        return c.isLetter || c.isNumber || c == "_"
    }

    /// 「好」「去吧」「可以，动手吧」这类短肯定句
    private static func isAgreement(_ t: String) -> Bool {
        let compact = t.replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard compact.count <= 8 else { return false }
        for w in agreementWords where compact == w || compact.hasPrefix(w) { return true }
        return false
    }

    private static func looksLikePath(_ t: String) -> Bool {
        let markers = ["/var/", "/private/", "/tmp/", "/usr/", "/applications/", "~/", "./", "../"]
        for m in markers where t.contains(m) { return true }
        return false
    }
}
