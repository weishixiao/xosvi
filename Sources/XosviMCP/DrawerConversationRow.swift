import SwiftUI
import UIKit

// MARK: - v9.15 抽屉会话行
//
// 为什么单独成视图：旧实现把「哪一行滑开 + 滑动位移」放在父视图（ConversationDrawerView）的
// @State 里，于是拖动过程中每一帧都会触发整张会话列表重算；列表还是 LazyVStack（按可见范围
// 回收格子），叠加就出现滚动时行与行重叠、折叠的「重影」。
// 现在：
//   · 位移是行自己的 @State（只有这一行重绘），固定行高 50pt，手势不会再撑高整行；
//   · 父视图只保留一个 swipedId，手势结束时才写一次，用来保证同一时间只有一行滑开；
//   · 列表侧改用非延迟容器（见 RootView.conversationList），格子不再回收复用。

struct DrawerConversationRow: View {
    let title: String
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

    /// 行内位移：手势过程只改这里
    @State private var offset: CGFloat = 0
    /// 手指拖动中：此时不让外部状态把 offset 拽回去
    @State private var dragging = false

    /// 行高固定，拖动手势永远不会把行撑高或压扁
    static let rowHeight: CGFloat = 50

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
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(offset < -8 ? 1 : 0)
            .allowsHitTesting(offset < -8)

            // 上层：会话行卡片
            rowCard
                .frame(height: Self.rowHeight)
                .background(
                    Group {
                        if selected {
                            Color(uiColor: .systemBackground)
                                .overlay(Color.primary.opacity(0.07))
                        } else {
                            Color(uiColor: .systemBackground)
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(selected
                                    ? Color.primary.opacity(0.22)
                                    : Color(uiColor: .separator).opacity(0.6),
                                lineWidth: 0.8)
                )
                .cornerRadius(16)
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

    // MARK: 行内容

    private var rowCard: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(XType.body)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if selected {
                Menu {
                    Button(action: onDelete) {
                        Label(deleteTitle, systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 14)
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
