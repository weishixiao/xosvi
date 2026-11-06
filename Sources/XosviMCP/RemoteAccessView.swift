import SwiftUI
import UIKit   // v9.9：UIPasteboard / UIColor.tertiaryLabel 等

// MARK: - v9.9 远程访问（重新设计）
//
// 一页说清两件事：
//   ① 主动连接：本机 SSH 出去连远程服务器（SSHSettingsView 配主机/端口/认证）
//   ② 被远程访问：本机开 HTTP API，云端/电脑/远程 AI 调工具、读审计、拉崩溃日志
// 顶部一张状态卡（哪扇门开着、地址是什么、后台保活），下面两张门卡各自带开关与地址速览，
// 点进去才是细节页；细节页里统一排版：地址行可点复制、令牌可生成/隐藏、危险工具单独一段红字。
struct RemoteAccessView: View {
    // v9.9：SSHSettingsView 存的是 ssh_host（与 SSHTools 读取的键一致），
    // 旧版这里读成 ssh.host，导致「已配置」永远显示未配置。
    @AppStorage("ssh_host") private var sshHost: String = ""
    @State private var terminalRunning = RemoteTerminalServer.shared.isRunning
    @State private var toast: String?

    private var lanIP: String {
        let ip = RemoteTerminalView.localIPAddress()
        return ip.isEmpty ? "—" : ip
    }

    private var baseURL: String {
        "http://\(lanIP):\(RemoteTerminalServer.shared.port)"
    }

    private var tokenState: String {
        let t = RemoteTerminalServer.shared.token
        if t.isEmpty { return "未设置令牌（服务不会接受任何请求）" }
        return "已设置 \(t.count) 位令牌"
    }

    private var anyDoorOpen: Bool {
        terminalRunning || !sshHost.isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    outboundCard
                    inboundCard
                    securityCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }

            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
        .navigationTitle("远程访问")
        .navigationBarTitleDisplayMode(.inline)
        .deepseekPage()
        .onAppear { terminalRunning = RemoteTerminalServer.shared.isRunning }
    }

    // MARK: 顶部状态

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatusDot(on: anyDoorOpen)
                Text(anyDoorOpen ? (terminalRunning ? "本机服务在线" : "已配置远程主机") : "两扇门都关着")
                    .font(.headline)
                Spacer()
                Text(anyDoorOpen ? "运行中" : "未启用")
                    .font(.caption2)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.06)))
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 0) {
                statusMetric(title: "入站", value: terminalRunning ? ":\(RemoteTerminalServer.shared.port)" : "关")
                divider
                statusMetric(title: "出站", value: sshHost.isEmpty ? "未配置" : sshHost)
                divider
                statusMetric(title: "局域网", value: lanIP)
            }
            Text(tokenState)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private var divider: some View {
        Rectangle().fill(Color(UIColor.separator).opacity(0.5))
            .frame(width: 0.6, height: 26)
    }

    private func statusMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: 出站

    private var outboundCard: some View {
        DoorCard(
            icon: "arrow.up.forward",
            title: "主动连接",
            subtitle: sshHost.isEmpty ? "通过 SSH 连接远程 Linux 服务器执行命令" : "当前主机 \(sshHost)",
            badge: sshHost.isEmpty ? "未配置" : "已配置",
            badgeOn: !sshHost.isEmpty,
            destination: AnyView(SSHSettingsView())
        )
    }

    // MARK: 入站

    private var inboundCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink(destination: RemoteTerminalView()) {
                DoorRow(
                    icon: "arrow.down.left",
                    title: "被远程访问",
                    subtitle: terminalRunning
                        ? "HTTP API 运行中 · \(baseURL)"
                        : "开启后本机 HTTP API 供云端 / 电脑调用工具",
                    badge: terminalRunning ? "在线" : "离线",
                    badgeOn: terminalRunning
                )
            }
            .buttonStyle(PlainButtonStyle())

            Divider().padding(.leading, 56)

            // 开关放在门卡里，一眼能开/关，不必先进细节页
            HStack(spacing: 10) {
                Text("HTTP API 服务")
                    .font(.subheadline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { terminalRunning },
                    set: { on in setService(on) }
                ))
                .labelsHidden()
                .tint(.primary)
            }
            .padding(.vertical, 10)

            if terminalRunning {
                Divider().padding(.leading, 56)
                HStack(spacing: 8) {
                    Text(baseURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = baseURL
                        toast = "已复制地址"
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 13))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.primary)
                }
                .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DoubaoTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.6)
        )
    }

    private func setService(_ on: Bool) {
        let s = RemoteTerminalServer.shared
        if on {
            if s.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 没有令牌服务等于敞开：先替用户生成一个，再去细节页可以改
                s.token = RemoteTerminalServer.makeToken()
            }
            let ok = s.start()
            terminalRunning = s.isRunning
            toast = ok ? "服务已启动 :\(s.port)" : "启动失败（端口 \(s.port) 被占用？）"
        } else {
            s.stop()
            terminalRunning = false
            toast = "服务已停止"
        }
    }

    // MARK: 安全说明

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("安全提醒", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text("• 服务默认只放行只读诊断工具；注入、写入、点按、抓包等危险工具要在细节页单独开启。")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("• 令牌必填：远程请求需带 Authorization: Bearer <令牌>。公网映射（N1 / 路由器端口转发）只在你完全信任的网络里使用。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.tertiarySystemBackground))
        )
    }
}

// MARK: - 小组件

private struct StatusDot: View {
    let on: Bool
    var body: some View {
        Circle()
            .fill(on ? Color.green : Color(UIColor.tertiaryLabel))
            .frame(width: 9, height: 9)
            .overlay(
                Circle().stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
    }
}

private struct DoorRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String
    let badgeOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(UIColor.secondarySystemFill))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium)).foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(badge)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(badgeOn ? Color.black.opacity(0.08) : Color(UIColor.tertiarySystemFill)))
                .foregroundColor(badgeOn ? .primary : .secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(UIColor.tertiaryLabel))
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct DoorCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String
    let badgeOn: Bool
    let destination: AnyView

    var body: some View {
        NavigationLink(destination: destination) {
            DoorRow(icon: icon, title: title, subtitle: subtitle, badge: badge, badgeOn: badgeOn)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(DoubaoTheme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.6)
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
