import SwiftUI
import UIKit   // v9.9：UIPasteboard 复制地址/令牌

// MARK: - v9.9 远程终端（被远程访问的细节页，重新设计）
//
// 版式：状态卡（运行/停止 + 开关 + 一键地址复制）→ 连接信息（端口、令牌、局域网地址、请求示例）
// → 安全（危险工具授权，红字）→ 公网映射说明 → 可用接口清单 → 最近一次操作结果。
// 关闭时保存、按键即生效；端口改动需重启服务，页内会提示「重启」。
struct RemoteTerminalView: View {
    @State private var token: String = RemoteTerminalServer.shared.token
    @State private var portText: String = "\(RemoteTerminalServer.shared.port)"
    @State private var allowDangerous = RemoteTerminalServer.shared.allowDangerous
    @State private var running = RemoteTerminalServer.shared.isRunning
    @State private var showToken = false
    @State private var toast: String? = nil
    // v9.9：属性初始化里不能用 Self（Swift 报 "cannot use instance member ... stored property initializer"），
    // 改成只在 onAppear 里取，避免编译期报错。
    @State private var lanIP = ""
    @Environment(\.presentationMode) private var presentationMode

    private var port: Int { Int(portText) ?? RemoteTerminalServer.shared.port }
    private var baseURL: String { "http://\(lanIP.isEmpty ? "—" : lanIP):\(port)" }
    private var tokenState: String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "未设置（远程请求一律拒绝）" }
        return "已设置 · \(t.count) 位"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statusCard
                connCard
                tokenCard
                securityCard
                publicCard
                endpointsCard
                if let t = toast { toastCard(t) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .navigationTitle("远程终端")
        .navigationBarTitleDisplayMode(.inline)
        .deepseekPage()
        .onAppear {
            running = RemoteTerminalServer.shared.isRunning
            if token.isEmpty { token = RemoteTerminalServer.shared.token }
            if lanIP.isEmpty { lanIP = RemoteTerminalView.localIPAddress() }
        }
        .onDisappear { save() }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Circle()
                    .fill(running ? Color.green : Color(UIColor.tertiaryLabel))
                    .frame(width: 9, height: 9)
                Text(running ? "服务运行中" : "服务已停止")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { running },
                    set: { setRunning($0) }
                ))
                .labelsHidden()
                .tint(.primary)
            }
            HStack(spacing: 8) {
                Text(baseURL)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(running ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button {
                    UIPasteboard.general.string = baseURL
                    toast = "已复制 \(baseURL)"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.primary)
                .disabled(lanIP.isEmpty)
            }
            HStack(spacing: 6) {
                Text("后台保活")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(BackgroundKeepAlive.shared.running ? "已开启" : "未开启（随服务自动开启）")
                    .font(.caption2)
                    .foregroundColor(BackgroundKeepAlive.shared.running ? .green : .secondary)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    // MARK: 连接信息

    private var connCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("连接信息", "network")
            fieldRow(title: "端口") {
                TextField("8790", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 14, design: .monospaced))
                    .frame(maxWidth: 90)
            }
            Divider()
            HStack {
                Text("局域网 IP").font(.subheadline)
                Spacer()
                Text(lanIP.isEmpty ? "获取失败" : lanIP)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                Button {
                    lanIP = Self.localIPAddress()
                    toast = "已刷新网络地址"
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                }
                .buttonStyle(PlainButtonStyle())
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("请求示例（curl）")
                    .font(.caption2).foregroundColor(.secondary)
                Text("curl -H \"Authorization: Bearer <令牌>\" \(baseURL)/api/status")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
                HStack(spacing: 8) {
                    Button("复制示例") {
                        UIPasteboard.general.string = "curl -H \"Authorization: Bearer <令牌>\" \(baseURL)/api/status"
                        toast = "已复制请求示例"
                    }
                    .font(.caption)
                    if running && port != RemoteTerminalServer.shared.port {
                        Button("端口已改 · 点此重启服务") { restart() }
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: 令牌

    private var tokenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardTitle("访问令牌", "key")
            HStack(spacing: 8) {
                if showToken {
                    TextField("令牌", text: $token)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    Text(maskedToken)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                Button {
                    showToken.toggle()
                } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye").font(.system(size: 13))
                }
                .buttonStyle(PlainButtonStyle())
            }
            HStack(spacing: 14) {
                Button("生成新令牌") {
                    token = RemoteTerminalServer.makeToken()
                    RemoteTerminalServer.shared.token = token
                    showToken = true
                    toast = "已生成新令牌并保存"
                }
                .font(.caption)
                Button("复制") {
                    UIPasteboard.general.string = token
                    toast = "已复制令牌"
                }
                .font(.caption)
                .disabled(token.isEmpty)
                Spacer()
                Text(tokenState).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var maskedToken: String {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "（空）" }
        guard t.count > 8 else { return String(repeating: "•", count: t.count) }
        return String(t.prefix(4)) + String(repeating: "•", count: 8) + String(t.suffix(4))
    }

    // MARK: 安全

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("危险工具授权", "exclamationmark.shield")
            Toggle(isOn: Binding(
                get: { allowDangerous },
                set: { v in
                    allowDangerous = v
                    RemoteTerminalServer.shared.allowDangerous = v
                    toast = v ? "已允许远程执行危险工具" : "已恢复只读模式"
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许远程执行危险工具").font(.subheadline)
                    Text(allowDangerous ? "注入 / 写入 / 点按 / 抓包 / shell 均可被远程调用" : "仅只读诊断工具（状态 / 文件 / 日志 / 审计）")
                        .font(.caption2)
                        .foregroundColor(allowDangerous ? .red : .secondary)
                }
            }
            .tint(.red)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: 公网映射

    private var publicCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardTitle("公网映射", "globe")
            stepRow("1", "子域名 A 记录指向网关（N1 / 路由器）的公网 IPv4")
            stepRow("2", "网关把公网端口 TCP 转发到 \(lanIP.isEmpty ? "手机局域网 IP" : lanIP):\(port)")
            stepRow("3", "云端访问 http://你的域名:公网端口，带 Authorization: Bearer <令牌>")
            Text("N1 只做端口转发，无需在网关上装任何服务。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    // MARK: 接口清单

    private var endpointsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            cardTitle("可用接口", "list.bullet.rectangle")
            endpoint("GET  /health", "是否在线（无需令牌）")
            endpoint("GET  /api/status", "设备 / 版本 / 工具数 / 服务状态")
            endpoint("GET  /api/tools", "工具清单")
            endpoint("POST /api/tool", "调用工具 {name, params}")
            endpoint("GET  /api/audit", "工具审计链路")
            endpoint("GET  /api/crash", "崩溃日志列表 / 全文")
            endpoint("GET  /api/file", "下载 Documents / Workspace 内文件")
            endpoint("GET  /api/conversations", "会话列表")
            endpoint("GET  /api/conversation", "单会话完整导出")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func endpoint(_ path: String, _ note: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 168, alignment: .leading)
            Text(note)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func toastCard(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    if toast == text { toast = nil }
                }
            }
    }

    private func cardTitle(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
        }
        .foregroundColor(.primary)
    }

    private func fieldRow<T: View>(title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            trailing()
        }
    }

    private func stepRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color(.tertiarySystemFill)))
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: 动作

    private func save() {
        let s = RemoteTerminalServer.shared
        s.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        s.port = port
        s.allowDangerous = allowDangerous
    }

    private func setRunning(_ on: Bool) {
        save()
        if on {
            if RemoteTerminalServer.shared.token.isEmpty {
                token = RemoteTerminalServer.makeToken()
                RemoteTerminalServer.shared.token = token
            }
            let ok = RemoteTerminalServer.shared.start()
            running = RemoteTerminalServer.shared.isRunning
            toast = ok ? "已启动 \(baseURL)" : "启动失败：端口 \(port) 被占用？换个端口再试"
        } else {
            RemoteTerminalServer.shared.stop()
            running = false
            toast = "已停止"
        }
    }

    private func restart() {
        RemoteTerminalServer.shared.stop()
        save()
        let ok = RemoteTerminalServer.shared.start()
        running = RemoteTerminalServer.shared.isRunning
        toast = ok ? "已在新端口 \(port) 重启" : "重启失败：端口被占用？"
    }

    static func localIPAddress() -> String {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "" }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 { continue }
            if addr.sa_family != UInt8(AF_INET) { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            if name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                    break
                }
            }
        }
        freeifaddrs(ifaddr)
        return address ?? ""
    }
}

private extension View {
    func cardBackground() -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(UIColor.separator).opacity(0.45), lineWidth: 0.6)
        )
    }
}
