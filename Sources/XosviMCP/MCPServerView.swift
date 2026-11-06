import SwiftUI

// MARK: - v9.4：MCP 服务页（用户要求"本机没有 MCP 功能，实现此功能添加到设置中"）
//
// 之前 MCPGatewayServer（Sources/XosviMCP/GatewayServer.swift）已经在跑一套完整的
// JSON-RPC 2.0 服务端（POST /、GET /sse、GET /health、POST /pair，内含 tools/list 与
// tools/call），但**设置里没有任何入口**，用户看不到、也开不起来，所以表现成"本机没有 MCP"。
//
// 这一页把已有的服务端接到界面上：
//   · 开关启停，端口可改，是否绑定局域网（默认仅 127.0.0.1）
//   · 显示两个令牌（完整令牌 / 只读令牌）与配对码，可一键轮换、复制
//   · 直接给出可粘贴到客户端（Claude Desktop / Cursor / 各类 MCP 客户端）的配置片段
//   · 连通性自检：在本机对 /health 发一次请求，失败时把原因说清楚

struct MCPServerView: View {
    @ObservedObject private var gateway = MCPGatewayState.shared

    @State private var portText = ""
    @State private var bindLAN = false
    @State private var showToken = false
    @State private var toast = ""
    @State private var health = ""
    @State private var busy = false

    var body: some View {
        List {
            // v10：页首大标题卡（与「环境」页同一套排版）
            Section {
                XHeroHeader(icon: "server.rack",
                            title: "本地网关",
                            subtitle: gateway.running ? "运行中 · \(gateway.address)" : "已停止")
            }

            // MARK: 状态
            Section(header: Text("服务状态"),
                    footer: Text(gateway.running
                                 ? "本机 AI 与外部 MCP 客户端共用同一套工具注册表，调用都会写入审计日志。"
                                 : "关闭时外部客户端无法连接；App 内的 AI 助手不受影响。")) {
                HStack {
                    Circle()
                        .fill(gateway.running ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(gateway.running ? "运行中" : "已停止")
                        .foregroundColor(gateway.running ? Color.primary : Color.secondary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { gateway.running },
                        set: { on in setRunning(on) }
                    ))
                    .labelsHidden()
                    .accentColor(Color.primary)
                }
                HStack {
                    Text("监听地址")
                    Spacer()
                    Text(gateway.running ? gateway.address : "—")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(Color.secondary)
                }
                if !health.isEmpty {
                    Text(health).font(XType.note).foregroundColor(Color.secondary)
                }
                Button {
                    healthCheck()
                } label: {
                    rowLabel("waveform.path.ecg", "连通性自检")
                }
                .disabled(busy || !gateway.running)
            }

            // MARK: 配置
            Section(header: Text("配置"),
                    footer: Text("局域网模式会让同网段任何持有令牌的设备调用本机工具，仅在可信网络开启。改端口后需重新启停服务。")) {
                HStack {
                    Text("端口")
                    Spacer()
                    TextField("8765", text: $portText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .onChange(of: portText) { v in
                            if let p = UInt16(v), p >= 1024 {
                                MCPGatewayServer.shared.setPort(p)
                            }
                        }
                }
                Toggle(isOn: Binding(
                    get: { bindLAN },
                    set: { on in
                        bindLAN = on
                        MCPGatewayServer.shared.setBindLAN(on)
                        // 绑定地址改了必须重启监听才生效
                        if gateway.running { restart() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("允许局域网访问")
                        Text(bindLAN ? "0.0.0.0（同网段可连）" : "127.0.0.1（仅本机）")
                            .font(XType.note).foregroundColor(Color.secondary)
                    }
                }
                .accentColor(Color.primary)
            }

            // MARK: 令牌
            Section(header: Text("访问令牌"),
                    footer: Text("客户端请求需带 Authorization: Bearer <令牌>。只读令牌只能调用只读工具（不含 shell / 注入 / 文件写入）。")) {
                tokenRow("完整令牌", gateway.token, isReadOnly: false)
                tokenRow("只读令牌", gateway.readToken, isReadOnly: true)
                HStack {
                    Text("配对码")
                    Spacer()
                    Text(gateway.pairingCode)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(Color.secondary)
                }
                Button {
                    let r = MCPGatewayServer.shared.rotateTokens()
                    gateway.refresh()
                    toast = "已轮换：旧令牌立即失效，请更新客户端配置"
                    _ = r
                } label: {
                    rowLabel("arrow.triangle.2.circlepath", "轮换令牌")
                }
            }

            // MARK: 客户端配置
            Section(header: Text("客户端配置"),
                    footer: Text("把下面这段粘进客户端的 MCP 配置（url 换成设备 IP，需先开局域网模式）。tools/list 会返回本机当前启用的全部工具。")) {
                Text(configSnippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.secondary)
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = configSnippet
                    toast = "配置已复制"
                } label: {
                    rowLabel("doc.on.doc", "复制配置")
                }
            }

            // MARK: 说明
            Section(header: Text("说明")) {
                Text("端点：POST / 发 JSON-RPC（initialize / tools/list / tools/call）；GET /sse 为流式通道；GET /health 免令牌探活；POST /pair 用配对码换令牌。")
                    .font(XType.note).foregroundColor(Color.secondary)
                if !toast.isEmpty {
                    Text(toast).font(XType.note).foregroundColor(Color.secondary)
                }
            }
        }
        .xGroupedPage()
        .navigationTitle("MCP 服务")
        .onAppear {
            gateway.refresh()
            portText = "\(gateway.port)"
            bindLAN = gateway.bindLAN
        }
    }

    // MARK: - 行样式

    private func rowLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(XType.rowIcon).foregroundColor(Color.primary)
                .frame(width: 24, alignment: .center)
            Text(title).font(XType.body).foregroundColor(Color.primary)
            Spacer()
        }
    }

    private func tokenRow(_ title: String, _ value: String, isReadOnly: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button(showToken ? "隐藏" : "显示") { showToken.toggle() }
                    .font(XType.note)
                    .foregroundColor(Color.secondary)
                Button {
                    UIPasteboard.general.string = value
                    toast = "\(title)已复制"
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            Text(showToken ? (value.isEmpty ? "（未生成，点下方轮换）" : value)
                           : String(repeating: "•", count: min(max(value.count, 8), 32)))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - 动作

    private func setRunning(_ on: Bool) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            if on {
                let r = MCPGatewayServer.shared.start(port: UInt16(portText))
                DispatchQueue.main.async {
                    busy = false
                    gateway.refresh()
                    if !r.ok { toast = "启动失败：\(r.error ?? "未知错误")" }
                }
            } else {
                MCPGatewayServer.shared.stop()
                DispatchQueue.main.async {
                    busy = false
                    gateway.refresh()
                    toast = "服务已停止"
                }
            }
        }
    }

    private func restart() {
        MCPGatewayServer.shared.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            _ = MCPGatewayServer.shared.start(port: UInt16(portText))
            gateway.refresh()
        }
    }

    /// 在本机对 /health 发一次请求，确认真的能连（不只是"状态说运行中"）
    private func healthCheck() {
        busy = true
        health = "正在检查…"
        let url = URL(string: "http://127.0.0.1:\(gateway.port)/health")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                busy = false
                if let err = err {
                    health = "自检失败：\(err.localizedDescription)"
                    return
                }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                health = code == 200
                    ? "自检通过（HTTP 200）· \(body.prefix(120))"
                    : "自检异常：HTTP \(code) \(body.prefix(80))"
            }
        }.resume()
    }

    private var configSnippet: String {
        let host = bindLAN ? "<设备局域网 IP>" : "127.0.0.1"
        return """
        {
          "mcpServers": {
            "xosvi": {
              "url": "http://\(host):\(gateway.port)/",
              "headers": {
                "Authorization": "Bearer <完整令牌>"
              }
            }
          }
        }
        """
    }
}

// MARK: - 网关状态镜像（服务端不是 ObservableObject，这里做一层可观察代理）

final class MCPGatewayState: ObservableObject {
    static let shared = MCPGatewayState()
    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = 8765
    @Published private(set) var bindLAN = false
    @Published private(set) var token = ""
    @Published private(set) var readToken = ""
    @Published private(set) var pairingCode = ""

    var address: String {
        let host = bindLAN ? "0.0.0.0" : "127.0.0.1"
        return "http://\(host):\(port)/"
    }

    func refresh() {
        let s = MCPGatewayServer.shared.status()
        running = (s["running"] as? Bool) ?? false
        if let p = s["port"] as? Int { port = UInt16(clamping: p) }
        bindLAN = ((s["bind"] as? String) ?? "").contains("0.0.0.0")
        token = MCPGatewayServer.shared.currentToken
        readToken = MCPGatewayServer.shared.currentReadToken
        pairingCode = MCPGatewayServer.shared.pairingCode
    }
}
