import SwiftUI
import UIKit

// MARK: - v9.15 抽屉会话行（v10.2 按 Minis SessionRow 重排）
//
// 为什么单独成视图：旧实现把「哪一行滑开 + 滑动位移」放在父视图（ConversationDrawerView）的
// @State 里，于是拖动过程中每一帧都会触发整张会话列表重算；列表还是 LazyVStack（按可见范围
// 回收格子），叠加就出现滚动时行与行重叠、折叠的「重影」。
// 现在：
//   · 位移是行自己的 @State（只有这一行重绘），固定行高，手势不会再撑高整行；
//   · 父视图只保留一个 swipedId，手势结束时才写一次，用来保证同一时间只有一行滑开；
//   · 列表侧改用非延迟容器（见 RootView.conversationList），格子不再回收复用。
//
// v10.2（仿 OpenMinis 底座，见 docs/plan/08-base-ui-minis.md）：
//   行的排版照 Minis `SessionRow` —— 44pt 头像 + 标题 16 semibold + 预览 14 + 尾部时间 13，
//   上下各 11pt 内距（行高 66）。视觉令牌全部走 XDesign（XColor / XMetric / XType.row*），
//   行内不再出现写死字号与写死颜色。
//
//   行底用 XColor.page（= 抽屉底色）而不是白卡：Minis 的侧栏行本身就是「透明行」，
//   层级靠头像的浅色圆和分组标题建立，只有文件夹才有卡片面。这里之所以仍画一层
//   **不透明**的底，是因为滑开时下层是红色删除键——底必须能盖住它；底色与抽屉背景
//   同色，所以看起来仍然是透明行。选中态在其上叠一层 XColor.fill（tertiarySystemFill）。

struct DrawerConversationRow: View {
    let title: String
    /// 最后一条消息预览（Minis SessionRow 的 subtitle 位）
    var subtitle: String = ""
    /// 尾部相对时间（Minis SessionRow 的 13pt tertiaryLabel 位）
    var meta: String = ""
    let selected: Bool
    let deleteTitle: String
    /// 删除按钮露出宽度
    let reveal: CGFloat
    /// 超过这个位移直接删除
    let commit: CGFloat
    /// 父视图记录的「这一行是不是滑开状态」
    let isSwiped: Bool
    /// 滑开 / 收回报给父视图（只做全局唯一标记，不参与布局）
    let onSwipeChange: (Bool) -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    /// v10.5：导出这段会话（Markdown 落盘 + 自建分享菜单）
    let onExport: () -> Void
    /// v10.5：导出键标题（与 deleteTitle 一样由调用方给本地化文案）
    var exportTitle: String = "导出"

    /// 行内位移：手势过程只改这里
    @State private var offset: CGFloat = 0
    /// 手指拖动中：此时不让外部状态把 offset 拽回去
    @State private var dragging = false

    /// 行高固定，拖动手势永远不会把行撑高或压扁（44 头像 + 上下各 11）
    static let rowHeight: CGFloat = XMetric.rowHeight

    var body: some View {
        ZStack(alignment: .trailing) {
            // 底层：删除按钮（露出来才可点）
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    offset = 0
                    onSwipeChange(false)
                }
                onDelete()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15, weight: .semibold))
                    Text(deleteTitle)
                        .font(.system(size: 10))
                }
                .foregroundColor(.white)
                .frame(width: reveal)
                .frame(maxHeight: .infinity)
                .background(Color.red)
                .clipShape(RoundedRectangle(cornerRadius: XRadius.row, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(offset < -8 ? 1 : 0)
            .allowsHitTesting(offset < -8)

            // 上层：会话行
            rowCard
                .frame(height: Self.rowHeight)
                .background(rowBackground)
                .contentShape(Rectangle())
                .offset(x: offset)
                .onTapGesture {
                    if offset < 0 {
                        close()
                    } else {
                        onOpen()
                    }
                }
                .highPriorityGesture(dragGesture)
                .contextMenu {
                    // v10.5：导出放在删除上面——长按是「留下这份对话」的入口，破坏性操作压到最后
                    Button(action: onExport) {
                        Label(exportTitle, systemImage: "square.and.arrow.up")
                    }
                    Button(action: onDelete) {
                        Label(deleteTitle, systemImage: "trash")
                    }
                }
        }
        .frame(height: Self.rowHeight)
        .clipped()
        .onChange(of: isSwiped) { open in
            // 别的行被滑开时，这一行收回（拖动中的那行不受影响）
            guard !dragging else { return }
            let target: CGFloat = open ? -reveal : 0
            if abs(offset - target) > 0.5 {
                withAnimation(.easeOut(duration: 0.18)) { offset = target }
            }
        }
    }

    // MARK: 行底

    /// 不透明行底（盖住滑开的红键）+ 选中叠色。填充一律画在形状里，
    /// 不用 .background(color).clipShape() 那种组合（见 XDesign 注释）。
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: XRadius.row, style: .continuous)
        return shape
            .fill(XColor.page)
            .overlay(shape.fill(selected ? XColor.fill : Color.clear))
    }

    // MARK: 行内容

    private var rowCard: some View {
        HStack(alignment: .center, spacing: 10) {
            XAvatar(text: title, size: XMetric.avatar)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(XType.rowTitle)
                    .foregroundColor(XColor.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(XType.rowSubtitle)
                        .foregroundColor(XColor.subtext)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                if !meta.isEmpty {
                    Text(meta)
                        .font(XType.rowMeta)
                        .foregroundColor(XColor.tertiaryText)
                        .lineLimit(1)
                }
                if selected {
                    Menu {
                        Button(action: onExport) {
                            Label(exportTitle, systemImage: "square.and.arrow.up")
                        }
                        Button(action: onDelete) {
                            Label(deleteTitle, systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(XColor.subtext)
                            .frame(width: 26, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    // MARK: 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                // 只处理水平拖；竖直手势留给列表滚动
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if !dragging {
                    dragging = true
                    onSwipeChange(true)
                }
                let base: CGFloat = isSwiped ? -reveal : 0
                var t = base + value.translation.width
                // 越界阻尼：最多滑到 commit 的 1.2 倍，右滑最多回到 0
                t = min(0, max(t, -commit * 1.2))
                offset = t
            }
            .onEnded { _ in
                dragging = false
                if offset < -commit {
                    withAnimation(.easeOut(duration: 0.18)) { offset = 0 }
                    onSwipeChange(false)
                    onDelete()
                } else if offset < -reveal * 0.5 {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        offset = -reveal
                    }
                    onSwipeChange(true)
                } else {
                    close()
                }
            }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
        onSwipeChange(false)
    }
}
