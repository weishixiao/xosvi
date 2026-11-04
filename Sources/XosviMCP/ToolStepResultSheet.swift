import SwiftUI
import UIKit

// MARK: - v9：投影步骤结果面板
//
// 投影后的过程区里，工具结果住在 ToolCallPayload.result 上（不再有独立 tool 消息）。
// 点某一步时用这个面板展示完整参数与结果——与旧的 ToolResultSheet 布局对齐，
// 但数据源是 ToolStepRef / ToolCallPayload，不依赖 ChatMessage。

struct ToolStepResultSheet: View {
    var name: String
    var args: String
    var result: String?
    var isError: Bool
    var isRunning: Bool
    var durationMs: Int?

    @Environment(\.presentationMode) private var presentationMode
    @State private var copied = false

    private var statusText: String {
        if isRunning { return "执行中" }
        return isError ? "出错" : "完成"
    }

    /// v9.2：白底黑字——状态用明度表达（进行中黑 / 完成灰 / 出错暗红）
    private var statusColor: Color {
        if isRunning { return MonoChat.text }
        return isError ? Color(red: 0.80, green: 0.16, blue: 0.16) : MonoChat.subtext
    }

    private var durationText: String {
        guard let d = durationMs else { return "—" }
        return d >= 1000 ? String(format: "%.1fs", Double(d) / 1000) : "\(d)ms"
    }

    var body: some View {
        // iOS15 兼容：不能用 NavigationStack（iOS16+），统一走 CompatNav
        CompatNav {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: toolSymbol(name))
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                        Text(name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(statusColor)
                        Text(durationText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    section("参数", text: args, mono: true)

                    if let result, !result.isEmpty {
                        section(isError ? "错误" : "结果", text: result, mono: true,
                                tint: isError ? .red : .primary)
                    } else if isRunning {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("正在执行…").font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .background(MonoChat.bg.ignoresSafeArea())
            .navigationTitle("工具结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = [args, result ?? ""].joined(separator: "\n\n")
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func section(_ title: String, text: String, mono: Bool, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text(text)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .foregroundColor(tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(MonoChat.surfaceRaised)
                )
        }
    }
}
