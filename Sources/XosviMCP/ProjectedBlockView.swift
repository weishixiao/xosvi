import SwiftUI
import UIKit

// MARK: - v9：投影块渲染层（移植 Kelivo chat_message_widget 的块分派）
//
// 一个 block → 一个视图。这是渲染层唯一入口：上面是投影器（纯数据），
// 下面不再关心 MessagePart / content / toolCalls 这些存储细节。

/// 单个块的分派
struct ProjectedBlockView: View {
    let block: ProjectedBlock
    let isUser: Bool
    let citedURLs: [String: String]
    /// 正文文本块的渲染闭包——由外层注入现有富文本路径
    /// （attributedBody + SelectableText，保住加粗/行内代码/[cite:sN] 角标）
    var renderText: ((String) -> AnyView)? = nil
    /// 点工具步骤（打开结果面板）
    var onTapTool: ((ToolStepRef) -> Void)? = nil

    var body: some View {
        switch block.kind {
        case .text(let s):
            if let renderText {
                renderText(s)
            } else {
                MessageBodyView(
                    blocks: MessageBlockParser.parse(s),   // 已有的 text/code/list/table 切分
                    isUser: isUser,
                    citedURLs: citedURLs,
                    textColor: isUser ? MonoChat.userText : MonoChat.text
                )
            }

        case .image(let img):
            MessageImageView(payload: img)

        case .file(let f):
            MessageFileView(payload: f)

        case .steps(let steps):
            ProcessStepsView(steps: steps, isUser: isUser, onTapTool: onTapTool)
        }
    }
}

/// 整条消息 = 一串 block，块间统一间距
struct ProjectedMessageView: View {
    let msg: ChatMessage
    let citedURLs: [String: String]
    /// 投影设置（气泡内会关掉 reasoning/image，避免与独立思考块/图片条重复）
    var settings: TimelineSettings = .default
    /// 外部传入投影结果（流式时由 StreamingProjection 提供；nil 时内部惰性投影 + 缓存）
    var precomputed: [ProjectedBlock]? = nil
    var renderText: ((String) -> AnyView)? = nil
    var onTapTool: ((ToolStepRef) -> Void)? = nil

    private var blocks: [ProjectedBlock] {
        precomputed ?? ProjectedBlockCache.shared.blocks(for: msg, settings: settings)
    }

    var body: some View {
        VStack(alignment: msg.role == "user" ? .trailing : .leading,
               spacing: ChatMetrics.blockGap) {
            ForEach(blocks) { block in
                ProjectedBlockView(block: block,
                                   isUser: msg.role == "user",
                                   citedURLs: citedURLs,
                                   renderText: renderText,
                                   onTapTool: onTapTool)
            }
        }
    }
}

// MARK: - 过程区（思考 + 工具）—— 层次的核心

struct ProcessStepsView: View {
    let steps: [ProjectedStep]
    let isUser: Bool
    var onTapTool: ((ToolStepRef) -> Void)? = nil

    @State private var expanded = false

    private var allTools: Bool { steps.allSatisfy { $0.isTool } }

    private var toolCount: Int {
        steps.reduce(0) { (acc: Int, s: ProjectedStep) -> Int in
            if case .tool = s { return acc + 1 }
            if case .toolGroup(_, let refs, let h, _) = s { return acc + refs.count + h }
            return acc
        }
    }

    private var hasError: Bool {
        steps.contains { (s: ProjectedStep) -> Bool in
            if case .tool(_, let r) = s { return r.isError }
            if case .toolGroup(_, let refs, _, _) = s { return refs.contains(where: \.isError) }
            return false
        }
    }

    private var anyRunning: Bool {
        steps.contains { (s: ProjectedStep) -> Bool in
            if case .tool(_, let r) = s { return r.isRunning }
            if case .toolGroup(_, let refs, _, _) = s { return refs.contains(where: \.isRunning) }
            return false
        }
    }

    /// 纯工具过程 → 折叠成一行摘要（最轻的视觉权重）
    private var collapsedSummary: String {
        if hasError { return "工具调用失败 · \(toolCount) 步" }
        if anyRunning { return "正在执行 · \(toolCount) 步" }
        return "已完成 \(toolCount) 个工具调用"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(steps) { step in
                        stepView(step)
                    }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isUser ? MonoChat.userText.opacity(0.25) : MonoChat.stroke)
                        .frame(width: 2)
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                if anyRunning {
                    ProgressView().scaleEffect(0.55)
                } else if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundColor(.red)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundColor(isUser ? MonoChat.userText.opacity(0.8) : MonoChat.subtext)
                }
                Text(allTools ? collapsedSummary : "过程 \(steps.count) 步")
                    .font(ChatType.meta)
                    .foregroundColor(hasError
                                     ? .red.opacity(0.9)
                                     : (isUser ? MonoChat.userText.opacity(0.9) : MonoChat.subtext))
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(isUser ? MonoChat.userText.opacity(0.7) : MonoChat.subtext)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func stepView(_ step: ProjectedStep) -> some View {
        switch step {
        case .reasoning(_, let text, let after):
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                        .foregroundColor(isUser ? MonoChat.userText.opacity(0.7) : MonoChat.subtext)
                    Text(after > 0 ? "思考（之后还有 \(after) 个工具）" : "思考")
                        .font(ChatType.meta)
                        .foregroundColor(isUser ? MonoChat.userText.opacity(0.75) : MonoChat.subtext)
                }
                Text(text)
                    .font(ChatType.secondary)
                    .lineSpacing(4.5)
                    .foregroundColor(isUser ? MonoChat.userText.opacity(0.9) : MonoChat.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .tool(_, let ref):
            ToolCallCard(name: ref.name,
                         args: ref.argumentsPreview,
                         duration: ref.durationMs.map { Double($0) / 1000 },
                         isRunning: ref.isRunning,
                         isError: ref.isError,
                         expanded: false,
                         onTap: { onTapTool?(ref) })

        case .toolGroup(_, let refs, let hidden, _):
            VStack(alignment: .leading, spacing: 5) {
                if hidden > 0 {
                    Text("另有 \(hidden) 步已折叠")
                        .font(ChatType.meta)
                        .foregroundColor(isUser ? MonoChat.userText.opacity(0.7) : MonoChat.subtext)
                        .padding(.leading, 2)
                }
                ForEach(refs) { ref in
                    ToolCallCard(name: ref.name,
                                 args: ref.argumentsPreview,
                                 duration: ref.durationMs.map { Double($0) / 1000 },
                                 isRunning: ref.isRunning,
                                 isError: ref.isError,
                                 expanded: false,
                                 onTap: { onTapTool?(ref) })
                }
            }
        }
    }
}

// MARK: - 图片

struct MessageImageView: View {
    let payload: ImagePayload
    @State private var showFull = false
    /// v9：解码前先按固定占位高度布局，避免 LazyVStack 里高度抖动导致滚动跳
    private var placeholderHeight: CGFloat {
        TimelineHeightEstimator.imageHeight(width: 240,
                                            aspectRatio: TimelineHeightEstimator.aspectRatio(for: payload))
    }

    private var uiImage: UIImage? {
        if payload.uri.hasPrefix("data:") {
            guard let comma = payload.uri.firstIndex(of: ",") else { return nil }
            let b64 = String(payload.uri[payload.uri.index(after: comma)...])
            guard let data = Data(base64Encoded: b64) else { return nil }
            return UIImage(data: data)
        }
        return UIImage(contentsOfFile: payload.uri)
    }

    var body: some View {
        Group {
            if payload.unavailable || uiImage == nil {
                HStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 12))
                    Text("图片不可用").font(ChatType.meta)
                }
                .foregroundColor(.secondary)
                .frame(height: min(placeholderHeight, 120))
            } else if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    // v9：占位与最终高度一致（按 4:3 预估、上限 240）——解码完成不跳
                    // 注意 frame 的参数顺序是 minWidth/idealWidth/maxWidth/minHeight/idealHeight/maxHeight，
                    // 混写会报参数顺序错，所以宽度、高度分开两次给。
                    .frame(maxWidth: 240)
                    .frame(minHeight: min(placeholderHeight, 240), maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { showFull = true }
            }
        }
        .fullScreenCover(isPresented: $showFull) {
            if let img = uiImage {
                ZoomableImageView(image: img)
            }
        }
    }
}

/// 全屏看图：双指缩放 + 拖动 + 双击复位 + 下滑关闭
struct ZoomableImageView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = min(max(lastScale * v, 1), 6) }
                        .onEnded { _ in lastScale = scale; if scale <= 1 { offset = .zero; lastOffset = .zero } }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { v in
                            if scale <= 1.01, abs(v.translation.height) > 120 {
                                dismiss()          // 未放大时下滑关闭
                            } else {
                                lastOffset = offset
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero }
                        else { scale = 2.5 }
                        lastScale = scale
                    }
                }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
            }
        }
        .statusBarHidden(true)
    }
}

// MARK: - 文件

struct MessageFileView: View {
    let payload: FilePayload

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.fill")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.name)
                    .font(ChatType.secondary)
                    .foregroundColor(MonoChat.text)
                    .lineLimit(1)
                if let m = payload.mime {
                    Text(m)
                        .font(ChatType.meta)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MonoChat.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MonoChat.stroke, lineWidth: 0.6)
        )
    }
}
