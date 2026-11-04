import SwiftUI
import UIKit

// MARK: - v7.4.1 AI Agent 调试会话风格：消息区组件
//
// 设计目标（用户要求）：干净、简约、不要多余装饰。
//   · 普通文本 → 纯文本块，无彩色气泡
//   · 代码 → **黑色代码预览块**（浅色模式也是黑底），带语言标签 + 复制
//   · 工具调用 → 圆角卡片：图标 + 名称 + 运行耗时，状态用极简符号表达
//
// 所有颜色走中性灰阶 + 语义色（红=出错），不再用蓝/青色做装饰。

// MARK: - 文本分块（普通文本 / 代码块）

// MARK: - v8.5：排版体系（一次定死，全局复用）
//
// 「乱」的三个根因：块内/段落/消息三级间距全用同一个值、中文没有行距、列表/标题/
// 引用全被压进 text 块。这里把三级间距显式区分开，并把结构块从 text 里拆出来。

enum ChatType {
    // 字号：正文 16（中文阅读舒适区）、次要 13、元信息 11.5
    static let body      = Font.system(size: 16, weight: .regular)
    static let bodyEm    = Font.system(size: 16, weight: .semibold)
    static let code      = Font.system(size: 13.5, design: .monospaced)
    static let secondary = Font.system(size: 13)
    static let meta      = Font.system(size: 11.5)

    // 行距：中文正文 6.5 最舒服；代码 3
    static let bodyLineSpacing: CGFloat = 6.5
    static let codeLineSpacing: CGFloat = 3
}

enum ChatMetrics {
    static let bubbleMaxWidth: CGFloat = 0.86     // 屏宽占比
    static let blockGap: CGFloat = 10             // 气泡内各块之间的间距
    static let messageGap: CGFloat = 18           // 消息之间的间距
    static let paragraphGap: CGFloat = 9          // 正文段落间距
    static let bubbleRadius: CGFloat = 18         // 气泡圆角
    static let bubblePaddingH: CGFloat = 14       // 气泡左右内边距
    static let bubblePaddingV: CGFloat = 10       // 气泡上下内边距
}

// MARK: - v9.1：聊天页黑白主题
//
// 用户要求：对话界面只要黑白色，不要现在的「白底浅灰气泡」。
// 设计：整页纯黑；AI 气泡近黑 + 白字；用户气泡纯白 + 黑字（唯一留白，反衬层次）；
//       工具卡/输入框抬一档灰；所有装饰色（蓝/绿）收敛成白/灰。
// 注意：本主题只作用于聊天页，设置页等其他页面维持系统语义色。

enum MonoChat {
    // v9.2：白底黑字（用户指定）——纯白页面 + 黑色文字，唯一的反色块是用户气泡与发送键。
    static let bg            = Color.white
    static let surface       = Color.white            // AI 气泡：白底 + 黑细描边
    static let surfaceRaised = Color(white: 0.95)     // 工具卡 / 输入框 / 抬升面
    static let stroke        = Color.black.opacity(0.12)
    static let strokeStrong  = Color.black.opacity(0.30)
    static let text          = Color.black
    static let subtext       = Color.black.opacity(0.55)
    /// 用户气泡：纯黑底 + 白字（黑白设计里唯一的实心反色块）
    static let userBubble    = Color.black
    static let userStroke    = Color.clear
    static let userText      = Color.white
    /// 反色令牌（发送键 / toast / 开关开启态 / 引用角标）
    static let invertBg      = Color.black
    static let invertText    = Color.white
}

struct MessageBlock: Identifiable {
    enum Kind {
        case text(String)
        case code(lang: String, body: String)
        // v8.5：结构块——列表/标题/引用从 text 里拆出来，才有层级
        case list(items: [String], ordered: Bool)
        case heading(level: Int, text: String)
        case quote(String)
        // v8.6：表格块——| a | b | + | --- | --- |，横向可滚不撑爆气泡
        case table(rows: [[String]])
    }
    let id = UUID()
    var kind: Kind
}

enum MessageBlockParser {
    /// 按 ``` 围栏切分。未闭合的围栏（流式输出中途）按普通文本处理，避免闪烁。
    // v7.9.12：按原文缓存——同一段文本在多次 body 重算里会被反复解析（列表越大越明显）
    private static var parseCache: [String: [MessageBlock]] = [:]
    private static let parseLock = NSLock()

    static func parse(_ raw: String) -> [MessageBlock] {
        parseLock.lock()
        if let hit = parseCache[raw] {
            parseLock.unlock()
            return hit
        }
        parseLock.unlock()
        let result = parseUncached(raw)
        parseLock.lock()
        if parseCache.count > 200 { parseCache.removeAll(keepingCapacity: true) }
        parseCache[raw] = result
        parseLock.unlock()
        return result
    }

    private static func parseUncached(_ raw: String) -> [MessageBlock] {
        guard raw.contains("```") else { return classify(raw.components(separatedBy: "\n")) }
        var blocks: [MessageBlock] = []
        var buffer: [String] = []
        var inCode = false
        var lang = ""

        func flushText() {
            // v8.5：文本缓冲交给行级分类器（拆出列表/标题/引用），不再整坨当 text
            let classified = classify(buffer)
            if !classified.isEmpty { blocks.append(contentsOf: classified) }
            buffer.removeAll()
        }

        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(MessageBlock(kind: .code(lang: lang, body: buffer.joined(separator: "\n"))))
                    buffer.removeAll()
                    inCode = false
                    lang = ""
                } else {
                    flushText()
                    inCode = true
                    lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            } else {
                buffer.append(line)
            }
        }
        // 收尾：未闭合的代码块按普通文本处理（流式中途）
        if inCode {
            blocks.append(contentsOf: classify(buffer))
        } else {
            flushText()
        }
        return blocks
    }

    // MARK: - v8.5 行级分类（列表 / 标题 / 引用 / 段落）

    private static func classify(_ lines: [String]) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var para: [String] = []
        var items: [String] = []
        var ordered = false

        func flushPara() {
            let t = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(MessageBlock(kind: .text(t))) }
            para.removeAll()
        }
        func flushItems() {
            if !items.isEmpty { blocks.append(MessageBlock(kind: .list(items: items, ordered: ordered))) }
            items.removeAll()
        }

        // v8.6：表格探测——本行含 | 且下一行是分隔行（|---|:--:|）。
        // 不强制首列前有 |：模型常输出 "A | B" / "--- | ---" 这种无前导竖线的表，
        // 分隔行（每格只由 - 和 : 组成）已经把误判概率压得很低。
        func isTableRow(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.contains("|")
                && !t.hasPrefix("```")
        }
        func isTableSeparator(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.contains("|") else { return false }
            let cells = MessageBlockParser.splitTableRow(t)
            guard cells.count > 1 else { return false }
            return cells.allSatisfy { c in
                let d = c.filter { !$0.isWhitespace }
                return !d.isEmpty && d.allSatisfy { $0 == "-" || $0 == ":" } && d.contains("-")
            }
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let l = line.trimmingCharacters(in: .whitespaces)

            // 表格：本行是表格行 + 下一行是分隔行（Markdown 表格必须分隔行才算）
            if isTableRow(l), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushItems(); flushPara()
                var rows: [[String]] = [MessageBlockParser.splitTableRow(l)]
                var j = i + 2
                while j < lines.count {
                    let next = lines[j].trimmingCharacters(in: .whitespaces)
                    // 表格在空行 / 非表格行处结束（分隔行之后的行按表体处理）
                    guard !next.isEmpty, next.contains("|"), !next.hasPrefix("```") else { break }
                    rows.append(MessageBlockParser.splitTableRow(next))
                    j += 1
                }
                blocks.append(MessageBlock(kind: .table(rows: rows)))
                i = j
                continue
            }

            if l.isEmpty { flushItems(); flushPara(); i += 1; continue }

            // 标题（# / ## / ###）
            if let m = l.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
                flushItems(); flushPara()
                let level = l.prefix(while: { $0 == "#" }).count
                blocks.append(MessageBlock(kind: .heading(level: level,
                                                          text: String(l[m.upperBound...]))))
                i += 1
                continue
            }
            // 无序列表
            if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") {
                if !items.isEmpty && ordered { flushItems() }
                ordered = false
                items.append(String(l.dropFirst(2)))
                i += 1
                continue
            }
            // 有序列表
            if l.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil {
                if !items.isEmpty && !ordered { flushItems() }
                ordered = true
                items.append(l.replacingOccurrences(of: #"^\d+[.)]\s+"#, with: "",
                                                     options: .regularExpression))
                i += 1
                continue
            }
            // 引用
            if l.hasPrefix("> ") {
                flushItems(); flushPara()
                blocks.append(MessageBlock(kind: .quote(String(l.dropFirst(2)))))
                i += 1
                continue
            }
            flushItems()
            para.append(line)
            i += 1
        }
        flushItems(); flushPara()
        return blocks
    }

    /// v8.6：表格行切分——去掉首尾竖线，按未转义的 | 切，trim 每个单元格
    static func splitTableRow(_ s: String) -> [String] {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var escaped = false
        for ch in t {
            if escaped {
                cur.append(ch == "|" ? "|" : ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }
}

// MARK: - 代码预览块（黑底）

// MARK: - v8：[cite:sN] 引用角标（web.search 结果引用）

/// web.search 结果带稳定 id（s1, s2, ...），模型在句末写 [cite:sN]；
/// 这里把标记替换成彩色角标：命中本轮结果的蓝标，未命中的灰标。
/// 走 NSAttributedString（与 v4.5.0 富文本路径一致，SwiftUI AttributedString 桥接会丢样式）。
enum CitationRenderer {
    private static let pattern = #"\[cite:(s\d+)\]"#

    /// 在粗体/代码解析结果之上替换 [cite:sN]；urls 来自本轮 web.search 工具消息的 citedURLs
    static func apply(to attributed: NSAttributedString, urls: [String: String]) -> NSAttributedString {
        guard attributed.string.contains("[cite:") else { return attributed }
        let ns = attributed.string as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return attributed }
        let matches = regex.matches(in: attributed.string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return attributed }
        let out = NSMutableAttributedString(attributedString: attributed)
        for m in matches.reversed() {
            let id = ns.substring(with: m.range(at: 1))
            let target = urls[id].flatMap { URL(string: $0) }
            let hit = target != nil
            let marker = NSMutableAttributedString(string: " \(id) ")
            marker.addAttributes([
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                // v9.2：白底黑字——命中=黑底白字，未命中=浅灰底灰字
                .foregroundColor: hit ? UIColor.white : UIColor.secondaryLabel,
                .backgroundColor: hit ? UIColor.black : UIColor(white: 0, alpha: 0.07)
            ], range: NSRange(location: 0, length: marker.length))
            // v8.6：命中条目带上跳转 URL——SelectableText 点击命中测试用（未命中的灰标不可点）
            if let target {
                marker.addAttribute(.citationURL, value: target,
                                    range: NSRange(location: 0, length: marker.length))
            }
            out.replaceCharacters(in: m.range, with: marker)
        }
        return out
    }

    /// 从消息流收集本轮可引用的 id→url：从当前 assistant 消息向前扫到上一条 user 消息为止，
    /// 合并所有 tool 消息的 citedURLs（按会话轮次累积——第 2 轮仍可引用第 1 轮搜到的 sN）
    static func collectURLs(around message: ChatMessage, in messages: [ChatMessage]) -> [String: String] {
        guard let idx = messages.firstIndex(where: { $0.id == message.id }) else { return [:] }
        var urls: [String: String] = [:]
        for m in messages[...idx].reversed() {
            if m.role == "user" { break }
            if let c = m.citedURLs { urls.merge(c) { _, new in new } }
        }
        return urls
    }
}

// MARK: - v8：NSAttributedString 自定义属性键（引用角标跳转）

extension NSAttributedString.Key {
    /// v8.6：[cite:sN] 角标携带的目标 URL（点击时由 SelectableText 弹出确认后打开）
    static let citationURL = NSAttributedString.Key("xosvi.citationURL")
}

/// v8.6：可点引用（`Identifiable` 供 SwiftUI `.alert(item:)` 使用）
struct CitationLink: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - v8.5：正文渲染器（按块类型渲染 + 中文行距 + 段落间距）
//
// 三条中文排版铁律：
//   1) .lineSpacing(6.5)——默认行距对中文太挤，这是"读起来乱"第一元凶
//   2) .fixedSize(horizontal: false, vertical: true)——否则多行 Text 在某些容器里被压缩/截断
//   3) 段落之间用 VStack(spacing: 9) 显式给间距，不靠 \n\n 空行（空行高度随字号浮动）

struct MessageBodyView: View {
    let blocks: [MessageBlock]
    let isUser: Bool
    let citedURLs: [String: String]
    let textColor: Color
    /// v8.5：正文文本块的渲染闭包——由 MessageBubble 注入现有富文本路径
    /// （attributedBody + SelectableText，保住加粗/行内代码/[cite:sN] 角标）。
    /// 默认退回纯 Text（无富文本样式）。
    var renderText: ((String) -> AnyView)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.paragraphGap) {
            ForEach(blocks) { block in
                switch block.kind {
                case .text(let s):
                    if let renderText = renderText {
                        renderText(s)
                    } else if s.count > 20000 {
                        // v9：超长单块 → 分块渲染（对应 Kelivo bounded_large_text_view）
                        BoundedLargeText(text: s, textColor: textColor)
                    } else {
                        Text(s)
                            .font(ChatType.body)
                            .lineSpacing(ChatType.bodyLineSpacing)
                            .foregroundColor(textColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                case .code(let lang, let body):
                    CodeBlockView(lang: lang, code: body)   // 现有黑底块，不动

                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(ordered ? "\(i + 1)." : "•")
                                    .font(ChatType.body)
                                    .foregroundColor(isUser ? textColor.opacity(0.8) : .secondary)
                                    .frame(minWidth: 16, alignment: .trailing)
                                if let renderText = renderText {
                                    renderText(item)
                                } else {
                                    Text(item)
                                        .font(ChatType.body)
                                        .lineSpacing(ChatType.bodyLineSpacing)
                                        .foregroundColor(textColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                case .heading(let level, let s):
                    Text(s)
                        .font(.system(size: level == 1 ? 18 : level == 2 ? 17 : 16, weight: .semibold))
                        .foregroundColor(textColor)
                        .padding(.top, 3)

                case .quote(let t):
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(isUser ? textColor.opacity(0.45) : DoubaoTheme.hairline)
                            .frame(width: 3)
                        Text(t)
                            .font(ChatType.secondary)
                            .lineSpacing(4)
                            .foregroundColor(isUser ? textColor.opacity(0.85) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .table(let rows):
                    MarkdownTable(rows: rows, textColor: textColor)
                }
            }
        }
        // v8.6：不再强制撑满——短内容贴合自身宽度（气泡才不会变成一条长卡片），
        // 长内容由父级给的 width 上限（86% 屏宽）自然换行。
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - v8.6：Markdown 表格（横向可滚，不撑爆气泡）

struct MarkdownTable: View {
    let rows: [[String]]
    /// v8.6：文字色——用户气泡（accent 底）传白字，AI 气泡传主色
    var textColor: Color = .primary

    private var columnCount: Int { rows.map(\.count).max() ?? 0 }

    var body: some View {
        if columnCount == 0 {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<columnCount, id: \.self) { c in
                                Text(c < row.count ? row[c] : "")
                                    .font(rowIndex == 0
                                          ? .system(size: 13, weight: .semibold)
                                          : .system(size: 13))
                                    .foregroundColor(textColor.opacity(rowIndex == 0 ? 1 : 0.9))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                    // v8.6：单列限宽——超长单元格在列内换行，不再把表格拉成一条长龙
                                    .frame(minWidth: 64, maxWidth: 200, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .overlay(alignment: .trailing) {
                                        if c < columnCount - 1 {
                                            Rectangle()
                                                .fill(textColor.opacity(0.12))
                                                .frame(width: 0.6)
                                        }
                                    }
                            }
                        }
                        .background(rowIndex == 0
                                    ? MonoChat.surfaceRaised.opacity(0.7)
                                    : Color.clear)
                        .overlay(alignment: .bottom) {
                            if rowIndex < rows.count - 1 {
                                Rectangle()
                                    .fill(textColor.opacity(0.12))
                                    .frame(height: 0.6)
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(textColor.opacity(0.15), lineWidth: 0.6)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CodeBlockView: View {
    var lang: String
    var code: String
    @State private var copied = false

    private var displayLang: String {
        let l = lang.trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? "code" : l
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：语言标签 + 复制
            HStack(spacing: 6) {
                Text(displayLang.lowercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.62))
                Spacer(minLength: 0)
                Button {
                    UIPasteboard.general.string = code
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(copied ? "已复制" : "复制")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(Color(white: 0.62))
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 6)

            // 代码正文：黑底、等宽、横向可滚
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(Color(white: 0.90))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(white: 0.14))     // v9.1：黑白主题——比 AI 气泡抬一档，纯黑页面上能看出块边界
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        )
    }
}

// MARK: - 工具调用卡片（圆角 + 图标 + 名称 + 耗时）

/// 工具名 → SF Symbol（中性线条图标，不用彩色）
func toolSymbol(_ name: String) -> String {
    let n = name.lowercased()
    if n.hasPrefix("shell") { return "terminal" }
    if n.hasPrefix("web") { return "globe" }
    if n.hasPrefix("workspace") { return "folder" }
    if n.hasPrefix("subagent") { return "person.2" }
    if n.hasPrefix("file") || n.hasPrefix("artifact") { return "doc" }
    if n.hasPrefix("db") { return "cylinder.split.1x2" }
    if n.hasPrefix("app") { return "square.grid.2x2" }
    if n.hasPrefix("inject") { return "syringe" }
    if n.hasPrefix("control") { return "cursorarrow.click" }
    if n.hasPrefix("memory") { return "memorychip" }
    if n.hasPrefix("network") || n.hasPrefix("vpn") { return "antenna.radiowaves.left.and.right" }
    if n.hasPrefix("device") { return "iphone" }
    if n.hasPrefix("package") { return "shippingbox" }
    if n.hasPrefix("macho") || n.hasPrefix("disasm") { return "cpu" }
    if n.hasPrefix("skills") || n.hasPrefix("knowledge") { return "book" }
    if n.hasPrefix("diagnose") || n.hasPrefix("verify") { return "stethoscope" }
    return "wrench.and.screwdriver"
}

struct ToolCallCard: View {
    var name: String
    var args: String?
    var duration: Double?
    var isRunning: Bool
    var isError: Bool
    /// 展开后的结果区（由调用方传入，可为空）
    var expanded: Bool = false
    var onTap: (() -> Void)? = nil

    private var subtitle: String? {
        guard let a = args, !a.isEmpty else { return nil }
        // 单行化，太长截断（完整内容展开后可看）
        let one = a.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count > 120 ? String(one.prefix(120)) + "…" : one
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: toolSymbol(name))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let s = subtitle {
                        Text(s)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                // 状态 + 耗时（极简：只有转圈 / ✓ / ✗ 加时间）
                HStack(spacing: 5) {
                    if isRunning {
                        ProgressView().scaleEffect(0.62)
                    } else if isError {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.red)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    if let d = duration {
                        Text(String(format: "%.1fs", d))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MonoChat.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MonoChat.stroke, lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }
}
