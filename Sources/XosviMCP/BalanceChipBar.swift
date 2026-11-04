import SwiftUI
import UIKit
import Combine

// MARK: - v9：输入框顶部状态条（余额胶囊 + 模型胶囊）
//
// 文档第三节：金额显示在输入框上方那条「工具条」区域，点一下刷新，长按看详情。
// 三种展示形态（文档第六节）都实现了，用 @AppStorage 切换：
//   0 胶囊（形态 A，默认，最省空间）
//   1 仅低额时显示（形态 B，最克制）
//   2 输入框右下角小字（形态 C，最轻）
//
// 行为约束（文档第七节）：
//   · 不在 body 里查余额（网络请求会每帧触发）→ onAppear / onChange / 请求完成通知
//   · 失败静默：只显示「余额 ?」灰胶囊，长按才看原因
//   · 缓存 5 分钟（BalanceChecker 内），切模型 / 请求完成时 force 刷新
//   · 只在请求「结束」时刷新，流式 delta 期间不刷（中转站普遍限流）

enum BalanceDisplayMode: Int, CaseIterable, Identifiable {
    case capsule = 0     // 形态 A
    case lowOnly = 1     // 形态 B
    case corner = 2      // 形态 C

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .capsule: return "胶囊（推荐）"
        case .lowOnly: return "仅低额时显示"
        case .corner: return "输入框右下角小字"
        }
    }
}

struct BalanceChipBar: View {
    /// 当前生效的模型配置
    let config: ModelConfig?
    /// 展示形态（默认胶囊）
    @AppStorage("xosvi.balance_display") private var modeRaw: Int = 0

    @State private var balance: BalanceInfo?
    @State private var errorText: String?
    @State private var querying = false
    @State private var hidden = false
    @State private var copied = false

    private var mode: BalanceDisplayMode { BalanceDisplayMode(rawValue: modeRaw) ?? .capsule }

    var body: some View {
        // 形态 C 的显示处是输入卡内右下角（BalanceCornerOverlay），这一行整条不渲染
        if mode == .corner {
            EmptyView()
        } else if let cfg = config, !hidden {
            Group {
                if mode == .lowOnly {
                    lowOnlyRow(cfg)
                } else {
                    capsuleRow(cfg)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .onAppear { refresh() }
            .onChange(of: cfg.id) { _ in refresh(force: true) }
            .onReceive(NotificationCenter.default.publisher(for: .xosviRequestFinished)) { note in
                // 只刷新「刚刚真正发过请求」的那个配置，别被别的会话的请求带跑
                let id = (note.userInfo?["configID"] as? String) ?? ""
                if id.isEmpty || id == cfg.id.uuidString { refresh(force: true) }
            }
        }
    }

    // MARK: 形态 A：模型胶囊 + 余额胶囊

    private func capsuleRow(_ cfg: ModelConfig) -> some View {
        HStack(spacing: 8) {
            modelChip(cfg)
            balanceChip
            Spacer(minLength: 4)
        }
    }

    // MARK: 形态 B：余额充足时不显示余额（模型胶囊仍在，菜单里可查看/刷新）

    private func lowOnlyRow(_ cfg: ModelConfig) -> some View {
        HStack(spacing: 8) {
            modelChip(cfg)
            if let b = balance, b.isLow {
                balanceChip
            } else if errorText != nil {
                balanceChip
            }
            Spacer(minLength: 4)
        }
    }

    // MARK: 模型胶囊

    private func modelChip(_ cfg: ModelConfig) -> some View {
        Menu {
            ForEach(ModelStore.shared.configs) { m in
                Button {
                    var c = m
                    c.isDefault = true
                    ModelStore.shared.update(c)
                    ModelStore.shared.markUsed(m.id.uuidString)
                } label: {
                    if m.id == cfg.id {
                        Label(m.name, systemImage: "checkmark")
                    } else {
                        Text(m.name)
                    }
                }
            }
            Divider()
            Button { refresh(force: true) } label: {
                Label(balance == nil ? "查询余额" : "刷新余额", systemImage: "creditcard")
            }
            if let b = balance {
                Text(b.detail ?? b.text)
            }
            Button { hidden = true } label: { Label("隐藏余额", systemImage: "eye.slash") }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(cfg.isDefault ? MonoChat.text : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(cfg.name)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(MonoChat.surfaceRaised))
            .overlay(Capsule().strokeBorder(MonoChat.stroke, lineWidth: 0.6))
        }
    }

    // MARK: 余额胶囊

    @ViewBuilder
    private var balanceChip: some View {
        if let b = balance {
            Button { refresh(force: true) } label: {
                HStack(spacing: 4) {
                    if querying {
                        ProgressView().scaleEffect(0.45).frame(width: 9, height: 9)
                    } else {
                        Image(systemName: "creditcard")
                            .font(.system(size: 9, weight: .medium))
                    }
                    Text(copied ? "已复制" : b.text)
                        .font(.system(size: 11.5, design: .monospaced))
                    if b.isLow {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                    }
                }
                // v9.1：黑白主题——低余额用白色高对比 + 三角提示，不用橙色
                .foregroundColor(b.isLow ? MonoChat.text : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(MonoChat.surfaceRaised))
                .overlay(Capsule().strokeBorder(
                    b.isLow ? MonoChat.strokeStrong : MonoChat.stroke,
                    lineWidth: 0.6))
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                if let d = b.detail { Text(d) }
                Button { refresh(force: true) } label: {
                    Label("刷新余额", systemImage: "arrow.clockwise")
                }
                Button { copy(b) } label: { Label("复制", systemImage: "doc.on.doc") }
                Button { hidden = true } label: { Label("隐藏", systemImage: "eye.slash") }
            }
        } else if errorText != nil {
            Button { refresh(force: true) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard").font(.system(size: 9))
                    Text(querying ? "查询中…" : "余额 ?").font(.system(size: 11.5))
                }
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(MonoChat.surfaceRaised))
                .overlay(Capsule().strokeBorder(MonoChat.stroke, lineWidth: 0.6))
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                if let e = errorText { Text(e) }
                Button { refresh(force: true) } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                Button { hidden = true } label: { Label("隐藏", systemImage: "eye.slash") }
            }
        } else if querying {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.45).frame(width: 9, height: 9)
                Text("查询中").font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(MonoChat.surfaceRaised))
        }
    }

    // MARK: 动作

    private func refresh(force: Bool = false) {
        guard let cfg = config else { return }
        if !force, let c = BalanceChecker.shared.cached(cfg.id) {
            balance = c
            errorText = nil
            return
        }
        querying = true
        BalanceChecker.shared.check(config: cfg, force: force) { result in
            querying = false
            switch result {
            case .success(let info):
                balance = info
                errorText = nil
            case .failure(let e):
                // 失败静默：有旧值就留着旧值，没有才显示「余额 ?」
                if balance == nil { errorText = e.description }
            }
        }
    }

    private func copy(_ b: BalanceInfo) {
        UIPasteboard.general.string = b.text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}


// MARK: - 形态 C：输入框右下角小字（独立视图，挂在输入框内 overlay）

struct BalanceCornerOverlay: View {
    let config: ModelConfig?
    @AppStorage("xosvi.balance_display") private var modeRaw: Int = 0

    @State private var balance: BalanceInfo?
    @State private var errorText: String?
    @State private var querying = false

    var body: some View {
        if modeRaw == BalanceDisplayMode.corner.rawValue, let cfg = config {
            Group {
                if querying {
                    Text("余额 …")
                } else if let b = balance {
                    Text(b.text)
                        .foregroundColor(b.isLow ? MonoChat.text : MonoChat.subtext)
                        .onTapGesture { refresh(cfg, force: true) }
                } else if errorText != nil {
                    Text("余额 ?")
                        .onTapGesture { refresh(cfg, force: true) }
                }
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundColor(MonoChat.subtext)
            .padding(.trailing, 12)
            .padding(.bottom, 6)
            .onAppear { refresh(cfg) }
            .onChange(of: cfg.id) { _ in refresh(cfg, force: true) }
            .onReceive(NotificationCenter.default.publisher(for: .xosviRequestFinished)) { note in
                let id = (note.userInfo?["configID"] as? String) ?? ""
                if id.isEmpty || id == cfg.id.uuidString { refresh(cfg, force: true) }
            }
        }
    }

    private func refresh(_ cfg: ModelConfig, force: Bool = false) {
        if !force, let c = BalanceChecker.shared.cached(cfg.id) { balance = c; return }
        querying = true
        BalanceChecker.shared.check(config: cfg, force: force) { result in
            querying = false
            switch result {
            case .success(let info): balance = info; errorText = nil
            case .failure(let e): if balance == nil { errorText = e.description }
            }
        }
    }
}
