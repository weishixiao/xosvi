import SwiftUI
import UIKit

// MARK: - XDesign（底座设计层 / v10.2）
//
// 参照 OpenMinis 的底座把「视觉」抽成一层，页面里不再写死颜色与圆角：
//   · OpenMinis `ChatColors.swift`      → 本文件 `XColor`（只用系统语义色，深/浅色自适应）
//   · OpenMinis `ComposerSurface.swift` → 本文件 `xComposerSurface()` / `xFloatCircle()`
//   · OpenMinis `SidebarSurfaces.swift` → 本文件 `xSurface(radius:...)` 卡片面 + 列表行面
//   · OpenMinis `SessionRow.swift`      → 本文件 `XAvatar` + `XType.rowTitle / rowSubtitle / rowMeta`
//
// 照搬的三条原则（Minis 原样）：
//   1. 颜色只用 UIKit 语义色包一层（systemBackground / secondarySystemBackground /
//      tertiarySystemFill / separator / label…），不写死 RGB —— 深色模式免费拿到。
//   2. 强调色收敛成单色 `label`（ChatColors.accent 同款）；彩色只留给状态（成功 / 失败）。
//   3. 「面」统一由修饰器产出：填充画在形状**里面**、0.5~0.8pt 细描边、极轻阴影；
//      不用 `.blur`（离屏渲染，列表滚动会掉帧 —— Minis 在 SidebarSurfaces 里有同款结论）。
//
// 关于 iOS 26 的 Liquid Glass：Minis 在 iOS 26+ 用 `.glassEffect(in:)`，低版本降级成
// 填充 + 细描边 + 阴影。本项目当前绑定的 SDK 是 iPhoneOS 18.5，没有 `glassEffect`
// 这个符号（写了会直接编译失败，`#available` 挡不住），因此这里先只实现降级分支；
// 将来 SDK 升到 26+ 再在下面的修饰器里加一条 `if #available(iOS 26.0, *)`。

// MARK: - 颜色令牌

enum XColor {
    /// 页面底（侧栏 / 抽屉 / 设置二级页统一）
    static var page: Color { Color(uiColor: .systemGroupedBackground) }
    /// 卡片 / 列表行默认底
    static var card: Color { Color(uiColor: .systemBackground) }
    /// 抬升面（搜索框、输入工具行、次级卡片）
    static var raised: Color { Color(uiColor: .secondarySystemBackground) }
    /// 弱填充：头像底、选中态（Minis ChatColors.userBubble 同语义）
    static var fill: Color { Color(uiColor: .tertiarySystemFill) }
    /// 稍强填充：长按 / 按下态
    static var fillStrong: Color { Color(uiColor: .secondarySystemFill) }
    /// 输入卡底（浅色近白、深色近黑，Minis ChatColors.inputBg 同款）
    static var inputBg: Color { Color(uiColor: .systemBackground) }
    /// 细描边 / 分隔线
    static var hairline: Color { Color(uiColor: .separator).opacity(0.6) }
    static var text: Color { Color(uiColor: .label) }
    static var subtext: Color { Color(uiColor: .secondaryLabel) }
    static var tertiaryText: Color { Color(uiColor: .tertiaryLabel) }
    static var quaternaryText: Color { Color(uiColor: .quaternaryLabel) }
    /// 单色强调（= label）：选中描边、悬停、说明性图标
    static var accent: Color { Color(uiColor: .label) }
    /// 反色块（可点的实心键 / 头像底）
    static var invertBg: Color { Color(uiColor: .label) }
    static var invertText: Color { Color(uiColor: .systemBackground) }
}

// MARK: - 尺寸令牌

enum XRadius {
    /// 列表选中块 / 搜索框
    static let row: CGFloat = 12
    /// 卡片
    static let card: CGFloat = 16
    /// 输入卡（Minis ComposerSurface 的 20pt continuous）
    static let composer: CGFloat = 20
    /// 整页容器 / 浮层
    static let sheet: CGFloat = 24
}

enum XMetric {
    /// 页面左右距（Minis 全程 16）
    static let gutter: CGFloat = 16
    /// 行内上下内距
    static let rowPadV: CGFloat = 12
    /// 会话行头像直径
    static let avatar: CGFloat = 44
    /// 会话行高（头像 44 + 上下各 11）
    static let rowHeight: CGFloat = 66
    /// 搜索框高
    static let searchHeight: CGFloat = 36
    /// 浮钮直径
    static let fab: CGFloat = 52
}

// MARK: - 行排版令牌（Minis SessionRow 的 16/14/13）

extension XType {
    /// 会话行标题：16 semibold
    static let rowTitle = Font.system(size: 16, weight: .semibold)
    /// 会话行预览：14 regular
    static let rowSubtitle = Font.system(size: 14)
    /// 会话行时间 / 元信息：13 tertiary
    static let rowMeta = Font.system(size: 13)
    /// 列表分组标题：13 medium
    static let groupHeader = Font.system(size: 13, weight: .medium)
}

// MARK: - 面：卡片 / 输入卡 / 浮钮（Minis 的 surface 三件套）

/// 圆角卡面：填充画在形状内 + 细描边 + 轻阴影。
private struct XSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let strokeColor: Color
    let strokeWidth: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background(shape.fill(fill))
            .clipShape(shape)
            .overlay(shape.stroke(strokeColor, lineWidth: strokeWidth))
            .shadow(color: Color.black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
    }
}

/// 圆形浮钮面（滚动键 / 新建会话键）。
private struct XFloatCircleModifier: ViewModifier {
    let fill: Color
    let strokeWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Circle().fill(fill))
            .clipShape(Circle())
            .overlay(Circle().stroke(XColor.hairline, lineWidth: strokeWidth))
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
    }
}

extension View {
    /// 统一卡面。`shadow: false` 用于列表内行（滚动区里避免叠阴影）。
    func xSurface(radius: CGFloat = XRadius.card,
                  fill: Color = XColor.card,
                  stroke: Color = XColor.hairline,
                  strokeWidth: CGFloat = 0.8,
                  shadow: Bool = true) -> some View {
        modifier(XSurfaceModifier(radius: radius,
                                  fill: fill,
                                  strokeColor: stroke,
                                  strokeWidth: strokeWidth,
                                  shadowOpacity: shadow ? 0.06 : 0,
                                  shadowRadius: shadow ? 8 : 0,
                                  shadowY: shadow ? 2 : 0))
    }

    /// 输入卡面（Minis ComposerSurface 的降级分支：20pt 圆角 + 0.12 阴影 + 深色上浮阴影）。
    func xComposerSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: XRadius.composer, style: .continuous)
        return self
            .background(shape.fill(XColor.inputBg))
            .clipShape(shape)
            .overlay(shape.stroke(XColor.hairline, lineWidth: 0.8))
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
            .shadow(color: Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.5) : UIColor(white: 0, alpha: 0) }),
                    radius: 8, x: 0, y: -4)
    }

    /// 圆形浮钮面。
    func xFloatCircle(fill: Color = XColor.card, strokeWidth: CGFloat = 0.5) -> some View {
        modifier(XFloatCircleModifier(fill: fill, strokeWidth: strokeWidth))
    }
}

// MARK: - 首字母头像（Minis SessionRow 的 44pt 圆形头像位）

struct XAvatar: View {
    let text: String
    var size: CGFloat = XMetric.avatar
    /// 运行中的会话在头像右下角加一个小跳动点
    var busy: Bool = false

    private var initial: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = String(trimmed.prefix(1))
        return first.isEmpty ? "·" : first.uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(XColor.fill)
            Text(initial)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(XColor.text)
            if busy {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: size, height: size, alignment: .bottomTrailing)
                    .offset(x: -2, y: -2)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 搜索框（Minis 侧栏搜索：36pt 高、12pt 圆角、次级填充）

struct XSearchField: View {
    @Binding var text: String
    var placeholder: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(XColor.subtext)
            TextField(placeholder, text: $text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 15))
                .foregroundColor(XColor.text)
                .autocorrectionDisabled(true)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(XColor.tertiaryText)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 10)
        .frame(height: XMetric.searchHeight)
        .background(
            RoundedRectangle(cornerRadius: XRadius.row, style: .continuous)
                .fill(XColor.raised)
        )
    }
}

// MARK: - 浮钮（Minis DraggableFAB 的静态版：列表右下角新建会话）

struct XFloatingActionButton: View {
    let icon: String
    var size: CGFloat = XMetric.fab
    var accessibilityText: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(XColor.text)
                .frame(width: size, height: size)
                .xFloatCircle()
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(accessibilityText.isEmpty ? icon : accessibilityText)
    }
}
