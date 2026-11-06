import SwiftUI

// MARK: - XTheme（v10 统一设计规范）
//
// 按用户给的设计稿实测建立（390pt 宽、3 倍图）：
//   卡片大标题  21pt semibold（拉丁大写字母墨迹 15pt ≈ 21pt 字号）
//   大标题副行  13pt secondary（"未启动" 三字墨迹 11.3pt）
//   分组标题    13pt secondary
//   行标题/行值 17pt（"状态" 二字墨迹 15.7pt；"8.13 MB" 大写高 12.7pt）
//   行高        44pt（实测 132px）
//   卡片左右距  16pt；卡片圆角 12pt；卡片白色 #FFFFFF，页面底 #F2F2F7
//
// 所有设置二级页统一用这里的组件，别再在页面里写 15/11.5/14/12 这类花色字号。

enum XType {
    /// 卡片大标题（页首 hero）
    static let hero = Font.system(size: 21, weight: .semibold)
    /// 大标题下的副标题
    static let heroSub = Font.system(size: 13)
    /// 分组标题 / 底部说明 / 行内次要状态
    static let section = Font.system(size: 13)
    /// 行标题与右侧值
    static let body = Font.system(size: 17)
    /// 行内次要说明（比 body 小一号，用于两行式行）
    static let note = Font.system(size: 13)
    /// 等宽（版本号、路径）
    static let mono = Font.system(size: 13, design: .monospaced)
    /// 行内图标
    static let rowIcon = Font.system(size: 17)
    /// hero 图标
    static let heroIcon = Font.system(size: 20)
    /// 行内状态勾
    static let check = Font.system(size: 12, weight: .bold)
}

// MARK: - 页首大标题卡（图标 + 大标题 + 副标题）

struct XHeroHeader: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var tint: Color = .primary

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(XType.heroIcon)
                .foregroundColor(tint)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(XType.hero)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(XType.heroSub)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - 两列信息行（左标签 17pt / 右值 17pt 灰 / 可选绿勾）

struct XInfoRow: View {
    let label: String
    let value: String
    var check: Bool = false
    var checkColor: Color = .green

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(XType.body)
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(XType.body)
                .foregroundColor(.secondary)
            if check {
                Image(systemName: "checkmark")
                    .font(XType.check)
                    .foregroundColor(checkColor)
            }
        }
        .frame(minHeight: 25)
    }
}

// MARK: - 入口行（图标 + 标题 + 副标题 + 右侧状态）

struct XNavRow: View {
    let icon: String
    let title: String
    var subtitle: String = ""
    var status: String = ""
    var busy: Bool = false
    var checked: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(XType.rowIcon)
                .foregroundColor(.primary)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(XType.body)
                    .foregroundColor(.primary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(XType.note)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView().scaleEffect(0.7)
            } else if checked {
                Image(systemName: "checkmark")
                    .font(XType.check)
                    .foregroundColor(.green)
            } else if !status.isEmpty {
                Text(status)
                    .font(XType.section)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minHeight: 25)
        .contentShape(Rectangle())
    }
}

// MARK: - 单行动作（图标 + 17pt 文案 + 可选进度）

struct XActionRow: View {
    let icon: String
    let title: String
    var busy: Bool = false
    var accent: Color = .blue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(XType.rowIcon)
                .frame(width: 24, alignment: .center)
            Text(title)
                .font(XType.body)
            Spacer(minLength: 0)
            if busy { ProgressView().scaleEffect(0.7) }
        }
        .foregroundColor(accent)
        .frame(minHeight: 25)
        .contentShape(Rectangle())
    }
}

// MARK: - 分组标题 / 分组说明

struct XSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(XType.section)
            .fontWeight(.regular)
            .foregroundColor(.secondary)
            .textCase(nil)
    }
}

struct XFooterNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(XType.section)
            .foregroundColor(.secondary)
    }
}

// MARK: - 页面壳：原生分组列表（白卡 + #F2F2F7 底 + 16pt 边距）

struct XGroupedPage: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemGroupedBackground))
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}

extension View {
    /// 所有设置二级页统一走这个壳，保证底色/边距/卡片观感一致
    func xGroupedPage() -> some View { modifier(XGroupedPage()) }
}
