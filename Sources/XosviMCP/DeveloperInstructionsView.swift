import SwiftUI
import UIKit

// MARK: - v9.9 模型破甲提示词（设置页重新设计）
//
// 版式：概览卡（启用了几份、默认是哪份、注入位置）→ 内置预设（一键导入/覆盖）→
// 指令列表（勾选即启用、行内编辑/复制/设为默认、长按菜单删除、右上角 + 新建）→ 说明（折叠）。
// 原来 List + PageHeader 两段式改成卡片 + 系统分组混排，开关改成明确的行内勾选。
struct DeveloperInstructionsView: View {
    @State private var items: [DeveloperInstructionStore.Item] = []
    @State private var editing: DevInstrEditorPayload?
    @State private var creating = false
    @State private var copiedName: String?
    @State private var showExplain = false
    @State private var toast: String?

    private let presetName = "1. 技术测试模式（内置）"

    private var hasPreset: Bool { items.contains(where: { $0.name == presetName }) }
    private var enabledCount: Int { items.filter { $0.enabled }.count }
    private var defaultName: String? { items.first(where: { $0.isDefault })?.name }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                overviewCard
                presetCard
                listCard
                explainCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .navigationTitle(L10n.t("page_dev_instr"))
        .navigationBarTitleDisplayMode(.inline)
        .deepseekPage()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    creating = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing, onDismiss: reload) { payload in
            DevInstructionEditorView(name: payload.name, initialContent: payload.content, mode: .edit)
        }
        .sheet(isPresented: $creating, onDismiss: reload) {
            DevInstructionEditorView(name: "", initialContent: "", mode: .create)
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
    }

    // MARK: 概览

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("page_dev_instr"))
                        .font(.headline)
                    Text(L10n.t("page_dev_instr_sub"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            HStack(spacing: 0) {
                metric("已启用", "\(enabledCount) / \(items.count)")
                Rectangle().fill(Color(UIColor.separator).opacity(0.5)).frame(width: 0.6, height: 26)
                metric("默认", defaultName ?? "未设")
                Rectangle().fill(Color(UIColor.separator).opacity(0.5)).frame(width: 0.6, height: 26)
                metric("注入位置", "系统指令之后")
            }
            Text(enabledCount == 0
                 ? "当前没有启用的指令：勾选一份后才会追加到 AI 请求。"
                 : "勾选的指令会追加在系统指令之后；「默认」只决定优先顺序，不勾选也不会注入。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: 内置预设

    private var presetCard: some View {
        Button {
            importPreset()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: hasPreset ? "checkmark.seal.fill" : "arrow.down.circle")
                    .font(.system(size: 18))
                    .foregroundColor(hasPreset ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasPreset ? "「技术测试模式」已导入" : "导入「技术测试模式」预设")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Text("扩充词库版破甲提示词（TECHNICAL 模式）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if hasPreset {
                    Text("覆盖")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(UIColor.separator).opacity(0.45), lineWidth: 0.6))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: 指令列表

    private var listCard: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 26))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                    Text(L10n.t("ui_136"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 {
                        Divider().padding(.leading, 52)
                    }
                    instructionRow(item)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color(UIColor.separator).opacity(0.45), lineWidth: 0.6))
    }

    private func instructionRow(_ item: DeveloperInstructionStore.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                DeveloperInstructionStore.shared.setEnabled(name: item.name, enabled: !item.enabled)
                reload()
            } label: {
                Image(systemName: item.enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(item.enabled ? .primary : Color(UIColor.tertiaryLabel))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(item.enabled ? .primary : .secondary)
                        .lineLimit(1)
                    if item.isDefault {
                        Text("默认")
                            .font(.system(size: 10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(UIColor.separator).opacity(0.8), lineWidth: 0.6))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                    Text("\(item.content.count) 字")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
                Text(preview(item.content))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                HStack(spacing: 14) {
                    Button {
                        editing = DevInstrEditorPayload(name: item.name, content: item.content)
                    } label: { Label("编辑", systemImage: "pencil").font(.caption) }
                        .buttonStyle(PlainButtonStyle())
                    Button {
                        copyItem(item)
                    } label: {
                        Label(copiedName == item.name ? "已复制" : "复制",
                              systemImage: copiedName == item.name ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(PlainButtonStyle())
                    if !item.isDefault {
                        Button {
                            DeveloperInstructionStore.shared.setDefault(name: item.name)
                            reload()
                            toast = "已设为默认"
                        } label: { Label("设为默认", systemImage: "star").font(.caption) }
                            .buttonStyle(PlainButtonStyle())
                    }
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contextMenu {
            Button { copyItem(item) } label: { Label("复制内容", systemImage: "doc.on.doc") }
            Button { editing = DevInstrEditorPayload(name: item.name, content: item.content) } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) { remove(item) } label: { Label("删除", systemImage: "trash") }
        }
    }

    // MARK: 说明

    private var explainCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showExplain.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("破甲提示词怎么用").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showExplain ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(PlainButtonStyle())

            if showExplain {
                Text(L10n.t("ui_145"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("用 <!--用户可见--> ... <!--/用户可见--> 包住的段落只显示给你，不会注入 AI 请求。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("作为补充提示词追加在系统指令之后，与「开发者模式」组合使用；只用于授权范围内的安全测试。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.tertiarySystemBackground)))
    }

    // MARK: 数据

    private func preview(_ c: String) -> String {
        let lines = c.split(separator: "\n").map(String.init)
        for ln in lines {
            let t = ln.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("#") { return String(t.prefix(60)) }
        }
        return c.isEmpty ? "（空指令）" : String(c.prefix(60))
    }

    private func reload() {
        items = DeveloperInstructionStore.shared.list()
    }

    private func importPreset() {
        let store = DeveloperInstructionStore.shared
        if hasPreset {
            store.update(name: presetName, content: DeveloperInstructionStore.technicalModeSeed)
            toast = "已用内置版本覆盖现有内容"
        } else {
            store.create(name: presetName, content: DeveloperInstructionStore.technicalModeSeed)
            toast = "已导入内置预设（勾选后生效）"
        }
        AuditLog.shared.log("dev_instructions", detail: "导入技术测试预设")
        reload()
    }

    private func copyItem(_ item: DeveloperInstructionStore.Item) {
        UIPasteboard.general.string = item.content
        withAnimation { copiedName = item.name }
        toast = "已复制「\(item.name)」"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedName == item.name {
                withAnimation { copiedName = nil }
            }
        }
    }

    private func remove(_ item: DeveloperInstructionStore.Item) {
        DeveloperInstructionStore.shared.delete(name: item.name)
        reload()
        toast = "已删除「\(item.name)」"
    }
}

struct DevInstrEditorPayload: Identifiable {
    var id: String { name }
    let name: String
    let content: String
}
