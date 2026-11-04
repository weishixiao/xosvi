import SwiftUI
import UIKit

// MARK: - v9：用户消息超长折叠（对应 Kelivo collapsible_user_text）
//
// 用户粘贴一大段日志/代码时，气泡会占满整屏把对话推走。规则：
//  · 超过 12 行 或 600 字 → 默认折叠到 8 行，底部渐变 + "展开全文"按钮
//  · 折叠只影响用户消息；AI 正文不折叠（它本身有过程区折叠）
//  · 展开状态存在 @State，不写库（每次进入会话重新折叠，符合"默认干净"的取向）

struct CollapsibleUserText: View {
    let text: String
    var lineLimitCollapsed: Int = 8
    var charThreshold: Int = 600
    var lineThreshold: Int = 12

    @State private var expanded = false

    private var needsCollapse: Bool {
        text.count > charThreshold || text.components(separatedBy: "\n").count > lineThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(ChatType.body)
                .lineSpacing(ChatType.bodyLineSpacing)
                // v9.1：用户气泡深灰底 → 白字
                .foregroundColor(MonoChat.userText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .lineLimit(expanded || !needsCollapse ? nil : lineLimitCollapsed)

            if needsCollapse {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "收起" : "展开全文")
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundColor(MonoChat.userText.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(MonoChat.userText.opacity(0.08)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

// MARK: - v9：视口高度预估（对应 Kelivo estimateTimelineImageHeight）
//
// LazyVStack 里图片块在解码完成前高度为 0，解码完突然撑开 → 滚动位置跳。
// 这里给出确定性的占位高度（按 4:3 + 上限 240），解码完成前后高度一致。
// 只对图片做预估：文本高度由 Text 自身排版决定，强行给估值反而会截断。

enum TimelineHeightEstimator {
    /// 图片块占位高度（与 MessageImageView 的 maxHeight 240 对齐）
    static func imageHeight(width: CGFloat, aspectRatio: CGFloat?) -> CGFloat {
        let maxW = min(width, 240)
        let ratio = (aspectRatio ?? 4.0 / 3.0)
        guard ratio > 0 else { return 160 }
        return min(maxW / ratio, 240)
    }

    /// 从 ImagePayload 读宽高比（有 assetId 时可用于后续扩展；目前返回 nil 走默认 4:3）
    static func aspectRatio(for payload: ImagePayload) -> CGFloat? { nil }

    /// 文本块预估高度（只用于滚动定位的粗估，不用于布局）
    static func roughTextHeight(_ text: String, width: CGFloat, fontSize: CGFloat = 16) -> CGFloat {
        guard width > 0 else { return 0 }
        // 中文按 1 字宽 ≈ fontSize，英文按 0.55；行高 ≈ fontSize * 1.45 + 行距
        var lines: CGFloat = 0
        for line in text.components(separatedBy: "\n") {
            let visual = line.reduce(CGFloat(0)) { (acc: CGFloat, ch: Character) -> CGFloat in
                let wide = (ch.unicodeScalars.first?.value ?? 0) > 0x2E80
                return acc + (wide ? 1.0 : 0.55)
            }
            lines += max(1, ceil(visual * fontSize / max(width, 1)))
        }
        return lines * (fontSize * 1.45 + 6.5)
    }
}

// MARK: - v9：超长文本分块渲染（对应 Kelivo bounded_large_text_view）
//
// 单条 Text 渲染 5 万字时，SwiftUI 的布局与命中测试都会明显变慢。
// 这里把超长正文按空行/段落切成若干块，每块独立 Text，块间给段落间距。
// 好处：单块文本量小，排版与选择都更稳；坏处：跨块不能一次划选（可接受，
// 完整文本仍可从长按菜单"复制全文"拿到）。

struct BoundedLargeText: View {
    let text: String
    var textColor: Color = .primary
    var fontSize: CGFloat = 16
    var lineSpacing: CGFloat = 6.5
    /// 单块字符上限（超过就切）
    var chunkLimit: Int = 4000

    private var chunks: [String] {
        guard text.count > chunkLimit else { return [text] }
        var out: [String] = []
        var cur = ""
        for para in text.components(separatedBy: "\n\n") {
            if cur.count + para.count + 2 > chunkLimit, !cur.isEmpty {
                out.append(cur)
                cur = para
            } else {
                cur += (cur.isEmpty ? "" : "\n\n") + para
            }
            // 单段本身超长：按字符硬切
            while cur.count > chunkLimit * 2 {
                let idx = cur.index(cur.startIndex, offsetBy: chunkLimit)
                out.append(String(cur[..<idx]))
                cur = String(cur[idx...])
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ChatMetrics.paragraphGap) {
            ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                Text(chunk)
                    .font(.system(size: fontSize))
                    .lineSpacing(lineSpacing)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
