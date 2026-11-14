import Foundation

/// v10.5：导出会话——把对话按 Markdown 落到工作区 `exports/`，再交给 ShareCenter 的自建分享菜单
/// （拷贝 / 存储到文件 / 分享到其他 App）。
///
/// 为什么不直接弹系统分享面板：侧载环境下 ShareSheet 枚举文档类型 → MobileIcons → CoreImage
/// 必崩（见 ShareCenter 顶部注释，两次真机崩溃栈逐字节相同）。所以这里只产文件 URL，
/// 呈现一律走 ShareCenter，不在本文件里碰 UIActivityViewController。
///
/// 导出是只读操作：不写会话数据、不动会话文件，只在工作区多一份 .md。
enum ConversationExport {

    /// 单条正文的空行拼接：md 里段落之间留一空行才算新段落
    private static let gap = "\n\n"

    // MARK: - 生成

    /// 把一段对话拼成 Markdown。role 与 ChatMessage 的取值一致（user / assistant / system / tool）。
    static func markdown(_ conv: ChatConversation) -> String {
        var out = "# \(titleText(conv.title))\n\n"
        out += "- 创建：\(stamp(conv.createdAt))\n"
        out += "- 更新：\(stamp(conv.updatedAt))\n"
        out += "- 消息：\(conv.messages.count) 条\n"
        out += "\n---\n"

        for m in conv.messages {
            guard let piece = block(m) else { continue }
            out += "\n" + piece + "\n"
        }
        return out
    }

    /// 全部会话按 updatedAt 倒序拼成一份，顶部加一段总览。
    static func allMarkdown(_ convs: [ChatConversation]) -> String {
        let sorted = convs.sorted { $0.updatedAt > $1.updatedAt }
        let messageCount = sorted.reduce(0) { $0 + $1.messages.count }
        var out = "# Xosvi 会话导出\n\n"
        out += "- 导出时间：\(stamp(Date()))\n"
        out += "- 会话：\(sorted.count) 个\n"
        out += "- 消息：\(messageCount) 条\n"
        for conv in sorted {
            out += "\n---\n\n" + markdown(conv)
        }
        return out
    }

    /// 单条消息 → Markdown 片段；没有可导出内容（空占位、纯 running 卡）时返回 nil。
    private static func block(_ m: ChatMessage) -> String? {
        let body = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let thinking = (m.thinking ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch m.role {
        case "user":
            guard !body.isEmpty else { return nil }
            return "## 我\(gap)\(body)"

        case "assistant":
            guard !body.isEmpty || !thinking.isEmpty else { return nil }
            var out = "## Xosvi"
            if !thinking.isEmpty {
                // 思考过程折叠起来：存档里要留，但默认别把正文压到几屏之后
                out += "\n\n<details>\n<summary>思考过程</summary>\n\n" + thinking + "\n\n</details>"
            }
            if !body.isEmpty { out += gap + body }
            return out

        case "tool":
            let rawName = m.toolName ?? ""
            let name = rawName.isEmpty ? "工具" : rawName
            guard !body.isEmpty else {
                // 结果还没回来 / 结果为空的工具卡：只留一行说明，不占版面
                return m.isRunning ? "### 工具 · \(name)（未完成）" : nil
            }
            var out = "### 工具 · \(name)"
            if let args = m.toolArgs, !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += "\n\n参数：`" + args.replacingOccurrences(of: "\n", with: " ") + "`"
            }
            let mark = fence(body)
            out += "\n\n" + mark + "text\n" + body + "\n" + mark
            if m.isError { out += "\n\n> 该工具返回错误" }
            return out

        case "system":
            guard !body.isEmpty else { return nil }
            return "### 系统\(gap)> " + body.replacingOccurrences(of: "\n", with: "\n> ")

        default:
            guard !body.isEmpty else { return nil }
            return "## \(m.role.isEmpty ? "消息" : m.role)\(gap)\(body)"
        }
    }

    /// 代码围栏长度：工具输出里可能自带 ``` 或 `````，围栏必须比内容里最长的一串反引号更长，
    /// 否则导出文件从此处开始整段错乱。
    private static func fence(_ text: String) -> String {
        var longest = 0
        var run = 0
        for ch in text {
            if ch == "`" {
                run += 1
                if run > longest { longest = run }
            } else {
                run = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    private static func titleText(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "会话" : t
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: - 落盘

    /// 文件名去掉路径分隔符与 md 里有歧义的字符：标题是用户/模型写的，可能带 / 与换行。
    static func fileNameBase(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let pieces = raw.components(separatedBy: bad).filter { !$0.isEmpty }
        var s = pieces.joined(separator: "-")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "会话" }
        if s.count > 40 { s = String(s.prefix(40)) }
        return s
    }

    /// 写到工作区 `exports/`，返回文件 URL（失败 nil）。
    /// 放在工作区里而不是 tmp：用户在「数据管理」能看到、能删，重装 App 前也能自己拷走。
    @discardableResult
    static func write(_ text: String, base: String) -> URL? {
        let dir = Workspace.root.appendingPathComponent("exports", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let url = dir.appendingPathComponent("\(base)-\(f.string(from: Date())).md")
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 入口（UI 只调这两个）

    static func present(_ conv: ChatConversation) {
        present(text: markdown(conv), base: fileNameBase(conv.title))
    }

    static func presentAll() {
        let convs = ConversationStore.shared.conversations
        guard !convs.isEmpty else {
            ShareCenter.shared.showNotice("还没有会话可导出")
            return
        }
        present(text: allMarkdown(convs), base: "全部会话")
    }

    private static func present(text: String, base: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ShareCenter.shared.showNotice("没有可导出的内容")
            return
        }
        guard let url = write(text, base: base) else {
            ShareCenter.shared.showNotice("导出失败：写不进工作区")
            return
        }
        AuditLog.shared.log("conversation.export", detail: "\(url.lastPathComponent) chars=\(text.count)")
        ShareCenter.shared.presentShareMenuFile(url)
    }
}
