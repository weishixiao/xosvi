import SwiftUI
import UIKit

// MARK: - v9.9 会话页模型快速切换（重新设计）
//
// 原来标题下面是一行极小的「● 模型名 ▾」（11pt 灰字），看不出当前用的是哪家、哪个模型，也点不准。
// 现在改成真胶囊：左侧状态点 + 模型名（主字）+ 服务商/模型名（次字）+ 展开箭头，
// 灰底细描边、圆角胶囊，点开是重新排版的选择面板（见 ChatModelPickerSheet）。
struct ModelQuickChip: View {
    var name: String
    var detail: String
    var onTap: () -> Void

    private var connected: Bool { !name.isEmpty && name != "未选择模型" }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connected ? Color.green : Color(UIColor.tertiaryLabel))
                    .frame(width: 6, height: 6)
                Text(connected ? name : "未选择模型")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MonoChat.text)
                    .lineLimit(1)
                if connected, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(MonoChat.subtext)
                        .lineLimit(1)
                        .frame(maxWidth: 132, alignment: .leading)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(MonoChat.subtext)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(MonoChat.surfaceRaised))
            .overlay(Capsule().stroke(MonoChat.stroke, lineWidth: 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("切换模型")
    }
}

/// v9.9：顶部栏里的模型胶囊——自己读 ModelStore，调用方只要给回调
struct ModelQuickChipLive: View {
    @ObservedObject private var modelStore = ModelStore.shared
    var onTap: () -> Void

    var body: some View {
        let cfg = modelStore.defaultConfig
        ModelQuickChip(
            name: cfg?.name ?? "",
            detail: cfg.map { $0.model.isEmpty ? $0.provider : $0.model } ?? "",
            onTap: onTap
        )
    }
}

// MARK: - v9.9 选择模型面板（重新设计）

struct ChatModelPickerSheet: View {
    @ObservedObject private var modelStore = ModelStore.shared
    @Environment(\.dismiss) private var dismissSheet
    let onSelect: (ModelConfig) -> Void

    @State private var search = ""
    @State private var mode: Mode = .saved

    enum Mode: String, CaseIterable {
        case saved = "已保存"
        case upstream = "上游模型"
    }

    private var filteredConfigs: [ModelConfig] {
        guard !search.isEmpty else { return modelStore.configs }
        return modelStore.configs.filter {
            ($0.name + " " + $0.model + " " + $0.provider).localizedCaseInsensitiveContains(search)
        }
    }

    private var current: ModelConfig? { modelStore.defaultConfig }

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                currentCard
                modeSwitch
                ScrollView {
                    VStack(spacing: 10) {
                        if modelStore.configs.isEmpty {
                            emptyCard
                        } else if mode == .saved {
                            savedList
                        } else {
                            upstreamList
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismissSheet() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // 当前模型卡
    private var currentCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 40, height: 40)
                Image(systemName: "cpu")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("当前模型").font(.caption2).foregroundColor(.secondary)
                Text(current?.name ?? "未选择")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if let c = current {
                    Text("\(c.provider) · \(c.model)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Circle().fill(current == nil ? Color(UIColor.tertiaryLabel) : Color.green)
                .frame(width: 8, height: 8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.systemBackground)))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var modeSwitch: some View {
        HStack(spacing: 6) {
            ForEach(Mode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { mode = m }
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(mode == m ? Color(.systemBackground) : Color.clear)
                        )
                        .foregroundColor(mode == m ? .primary : .secondary)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(.tertiarySystemFill)))
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundColor(.secondary)
            TextField("搜索模型 / 服务商", text: $search)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.systemBackground)))
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu").font(.system(size: 34)).foregroundColor(Color(UIColor.tertiaryLabel))
            Text("还没有已保存的模型").font(.subheadline).foregroundColor(.secondary)
            Text("去设置 → 模型 API 里连接服务商。")
                .font(.caption).foregroundColor(.secondary)
            Button {
                goToSettings()
            } label: {
                Label("去设置", systemImage: "gearshape.fill").font(.footnote)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.systemBackground)))
    }

    private var savedList: some View {
        VStack(spacing: 10) {
            searchBar
            ForEach(filteredConfigs) { cfg in
                NavigationLink {
                    UpstreamModelsView(config: cfg) { picked, model in
                        switchTo(picked, model: model)
                    }
                } label: {
                    configRow(cfg)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Button {
                goToSettings()
            } label: {
                Label("在设置中管理模型", systemImage: "gearshape.fill")
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemBackground)))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func configRow(_ cfg: ModelConfig) -> some View {
        let isCurrent = cfg.isDefault
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isCurrent ? Color.green.opacity(0.15) : Color(.tertiarySystemFill))
                    .frame(width: 36, height: 36)
                Image(systemName: isCurrent ? "checkmark" : "cpu")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isCurrent ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(cfg.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if isCurrent {
                        Text("当前")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundColor(.green)
                    }
                }
                Text("\(cfg.provider) · \(cfg.model)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                let tags = ModelTags.tags(for: cfg.model)
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { t in
                            Text(t)
                                .font(.system(size: 9.5, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color(.secondarySystemFill)))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(isCurrent ? Color.green.opacity(0.45) : Color.clear, lineWidth: 1))
    }

    private var upstreamList: some View {
        VStack(spacing: 10) {
            Text("选一个已保存的模型，进入后获取该站的上游模型列表，点选即切换。")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(modelStore.configs) { cfg in
                NavigationLink {
                    UpstreamModelsView(config: cfg) { picked, model in
                        switchTo(picked, model: model)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cfg.name).font(.subheadline).foregroundColor(.primary)
                            Text("\(cfg.provider) · \(cfg.model)")
                                .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.systemBackground)))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func goToSettings() {
        dismissSheet()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            AppUIState.shared.settingsJumpToModels = true
            AppUIState.shared.settingsPresented = true
        }
    }

    private func switchTo(_ cfg: ModelConfig, model: String?) {
        var c = cfg
        if let m = model { c.model = m }
        c.isDefault = true
        modelStore.update(c)
        onSelect(c)
        dismissSheet()
    }
}
