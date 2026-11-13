import SwiftUI
import UIKit

// MARK: - v7.7.0 深度思考渲染（对齐 Kelivo 的 reasoning 呈现）
//
// 之前：纯 Text + 固定高度内部滚动，长思考内容既不好读、也不像代码。
// 现在：
//   · 折叠态 = preview：最多 100pt，上下渐变遮罩，暗示"还有更多"
//   · 展开态 = 全量渲染，Markdown 风格：普通段落 + 黑底代码块 + 行内代码
//   · 流式时也走同一套渲染
//   · 点标题栏切换；展开后可复制全文

struct ReasoningBlock: View {
    let text: String
    let isStreaming: Bool
    @Binding var expanded: Bool
    /// v7.8.1：思考起止时间与 token（对齐 kelivo，用于显示"思考了 Xs · N tokens"）
    var startAt: Date? = nil
    var finishedAt: Date? = nil
    var tokens: Int? = nil

    /// 思考耗时（流式中随每次刷新递增）
    private var elapsedSeconds: Int? {
        guard let start = startAt else { return nil }
        let end = finishedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(start)))
    }

    private var headerText: String {
        if isStreaming {
            if let s = elapsedSeconds, s > 0 { return "思考中… \(s)s" }
            return "思考中…"
        }
        var parts: [String] = []
        if let s = elapsedSeconds, s > 0 { parts.append("\(s)s") }
        if let t = tokens, t > 0 { parts.append("\(t) tokens") }
        parts.append("\(text.count) 字")
        return "已深度思考 · " + parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            // v10.4：折叠态只有标题行（不再画 100pt 预览灰字）——「默认折叠」就是真的收起来
            if expanded { content }
        }
        .padding(.horizontal, 2)
    }

    /// 标题栏：点一下展开 / 收起
    private var header: some View {
        Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                    Text(headerText)
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    if expanded {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(isStreaming ? "…" : "（无思考内容）")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
        } else {
            ScrollView(.vertical, showsIndicators: true) {
                ReasoningRichText(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        }
    }
}

// MARK: - 富文本思考内容（段落 + 行内代码 + 黑底代码块）

struct ReasoningRichText: View {
    let text: String

    var body: some View {
        let blocks = MessageBlockParser.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                switch block.kind {
                case .text(let t):
                    Text(inline(t))
                        .font(.system(size: 12.5))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .code(let lang, let body):
                    CodeBlockView(lang: lang, code: body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                // v8.5：结构化块（列表/标题/引用）——思考内容里同样按层级渲染，
                // 字号统一 12.5 灰字（思考块视觉权重最轻）
                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(ordered ? "\(i + 1)." : "•")
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.secondary)
                                    .frame(minWidth: 14, alignment: .trailing)
                                Text(inline(item))
                                    .font(.system(size: 12.5))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .heading(_, let s):
                    Text(inline(s))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .quote(let t):
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.secondary.opacity(0.25))
                            .frame(width: 2)
                        Text(inline(t))
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                // v8.6：表格块（思考内容里同样横向可滚；字号 13 略大于思考正文，仍属次要信息）
                case .table(let rows):
                    MarkdownTable(rows: rows)
                }
            }
        }
    }

    /// 行内：`code` 等宽 + 灰底
    private func inline(_ s: String) -> AttributedString {
        var out = AttributedString()
        var rest = s[s.startIndex...]
        while let tick = rest.firstIndex(of: "`") {
            let after = rest.index(after: tick)
            guard let end = rest[after...].firstIndex(of: "`") else { break }
            if tick > rest.startIndex {
                out += AttributedString(String(rest[rest.startIndex..<tick]))
            }
            let code = String(rest[after..<end])
            var c = AttributedString(code)
            c.font = .system(size: 12, design: .monospaced)
            c.backgroundColor = Color(UIColor.tertiarySystemFill)
            out += c
            rest = rest[rest.index(after: end)...]
        }
        if !rest.isEmpty { out += AttributedString(String(rest)) }
        return out
    }
}
