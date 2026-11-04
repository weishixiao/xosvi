// ChatBridgeServer.swift —— 「大模型即入口」：本机提供一个 OpenAI 兼容的 chat/completions 端点。
//
// 为什么不再逐家对接：
//   主流服务商（OpenAI / DeepSeek / 智谱 / Kimi / 通义 / MiniMax / 阶跃 / 豆包 / Anthropic）
//   都支持「OpenAI 兼容的 chat/completions + function calling」这一种协议。所以只要
//   本机开一个同协议的端点，把 Xosvi 的 MCP 工具翻译成 function 描述，任何一家模型
//   ——或者用户自己存的任何一条 API 配置——都能直接驱动本机能力，无需为每家写登录/授权。
//
// 与 MCPGatewayServer 的关系：
//   GatewayServer 暴露的是 JSON-RPC（/sse、/ws）和原始工具路由，给 MCP 客户端用。
//   ChatBridgeServer 暴露的是 /v1/chat/completions，给「聊天」用：它负责
//     ① GET  /v1/models          —— 告诉外部「我这有哪些本机能力档位」
//     ② POST /v1/chat/completions —— 非流式；把 tools 描述注入、跑工具、回 tool_calls 循环
//   鉴权复用 GatewayServer 的 token（同一套 Bearer，避免用户管理两份密钥）。
//
// 设计约束（照 docs/TROUBLESHOOTING.md）：
//   - 只监听 127.0.0.1，不提供 LAN 绑定：本机能力属于高危面。
//   - 工具的 annotations.readOnly 决定是否允许「只读 token」调用。
//   - 单轮工具调用上限 maxToolRounds，防止模型死循环烧钱。

import Foundation

public final class ChatBridgeServer {
    public static let shared = ChatBridgeServer()

    /// 默认端口：与 GatewayServer(8765) 错开，避免抢同一个端口
    public static let defaultPort: UInt16 = 8766
    /// 单次请求里最多串行跑几轮工具调用
    public static let maxToolRounds = 8

    private var serverFD: Int32 = -1
    private var acceptThread: Thread?
    private let lock = NSLock()
    private var running = false

    private init() {}

    // MARK: - 生命周期

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public var port: UInt16 {
        let d = UserDefaults.standard
        let v = d.integer(forKey: "xosvi.chatbridge.port")
        return v == 0 ? Self.defaultPort : UInt16(v)
    }

    public func setPort(_ p: UInt16) {
        UserDefaults.standard.set(Int(p), forKey: "xosvi.chatbridge.port")
    }

    /// 启动本机兼容端点。已启动时返回 false。
    @discardableResult
    public func start(port: UInt16? = nil) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        lock.unlock()

        if let p = port { setPort(p) }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // 只本机可达

        let bindOK = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK, listen(fd, 16) == 0 else {
            close(fd)
            return false
        }

        lock.lock()
        serverFD = fd
        running = true
        lock.unlock()

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "xosvi.chatbridge"
        t.stackSize = 512 * 1024
        t.start()
        acceptThread = t
        return true
    }

    public func stop() {
        lock.lock()
        let fd = serverFD
        running = false
        serverFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    public func status() -> [String: Any] {
        let host = "127.0.0.1:\(port)"
        return [
            "running": isRunning,
            "port": Int(port),
            "base_url": "http://\(host)/v1",
            "endpoint": "http://\(host)/v1/chat/completions",
            "auth": "Bearer <GatewayServer token>",
            "max_tool_rounds": Self.maxToolRounds,
            "hint": "任何 OpenAI 兼容的模型/客户端，把 Base URL 指到这里即可调用本机工具"
        ]
    }

    // MARK: - 连接循环

    private func acceptLoop() {
        while isRunning {
            let client = accept(serverFD, nil, nil)
            if client < 0 {
                if !isRunning { break }
                usleep(50_000)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
                close(client)
            }
        }
    }

    private func handle(_ fd: Int32) {
        guard let request = readRequest(fd) else { return }
        let method = request.method.uppercased()
        let path = request.path

        if path == "/health" && method == "GET" {
            writeJSON(fd, status: 200, body: ["ok": true, "running": isRunning, "service": "Xosvi Chat Bridge"])
            return
        }

        // 鉴权：与 GatewayServer 共享 token
        let auth = request.headers["authorization"] ?? ""
        let bearer = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        let fullToken = MCPGatewayServer.sharedFullToken
        let readToken = MCPGatewayServer.sharedReadToken
        let role: String
        if !bearer.isEmpty && bearer == fullToken { role = "full" }
        else if !bearer.isEmpty && bearer == readToken { role = "read" }
        else {
            writeJSON(fd, status: 401, body: [
                "error": ["message": "unauthorized", "type": "invalid_request_error",
                          "code": "unauthorized",
                          "hint": "在「MCP 服务」页拿 token，请求头帶 Authorization: Bearer <token>"]
            ])
            return
        }

        if path == "/v1/models" && method == "GET" {
            writeJSON(fd, status: 200, body: [
                "object": "list",
                "data": [
                    ["id": "xosvi-local", "object": "model", "owned_by": "xosvi",
                     "description": "本机工具直连：调用在本机执行，不消耗服务商配额"]
                ]
            ])
            return
        }

        if path == "/v1/chat/completions" && method == "POST" {
            handleChat(fd, role: role, body: request.body)
            return
        }

        writeJSON(fd, status: 404, body: ["error": ["message": "not found: \(path)", "type": "invalid_request_error"]])
    }

    // MARK: - chat/completions

    private func handleChat(_ fd: Int32, role: String, body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            writeJSON(fd, status: 400, body: ["error": ["message": "invalid JSON body", "type": "invalid_request_error"]])
            return
        }
        let messages = obj["messages"] as? [[String: Any]] ?? []
        let clientTools = obj["tools"] as? [[String: Any]] ?? []
        let model = obj["model"] as? String ?? "xosvi-local"

        // 客户端没带工具时，把本机工具清单全量塞给它，让它能直接规划调用。
        let tools = clientTools.isEmpty ? ChatBridge.publicTools(role: role) : clientTools
        let prompt = ChatBridge.injectedSystemPrompt(role: role)

        // 本端点不自己调外部模型（用户在哪家都用同一套代码，且这里没有密钥上下文）。
        // 它做的是「工具执行代理」：把消息按 OpenAI 语义拆解，跑完工具后回标准响应。
        let outcome = ChatBridge.runToolTurn(messages: messages, role: role)

        var message: [String: Any] = ["role": "assistant"]
        if !outcome.toolCalls.isEmpty {
            message["content"] = outcome.text.isEmpty ? NSNull() : outcome.text
            message["tool_calls"] = outcome.toolCalls
        } else {
            message["content"] = outcome.text
        }

        var body: [String: Any] = [
            "id": "chatcmpl-xosvi-\(UUID().uuidString.prefix(8))",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": outcome.toolCalls.isEmpty ? "stop" : "tool_calls"
            ]],
            "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0]
        ]
        // 便于调试：把注入给模型的系统提示与可用工具数量一并回传（非标准字段，客户端会忽略）
        body["xosvi"] = [
            "system_prompt_chars": prompt.count,
            "available_tools": tools.count,
            "tool_rounds": outcome.rounds,
            "note": "本端点是工具执行桥：模型侧请把 base_url 指到这里，并把 tools 定义转给原生模型"
        ]
        writeJSON(fd, status: 200, body: body)
    }

    // MARK: - HTTP 底层（与 GatewayServer 同风格，独立实现避免耦合）

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        let headerEnd = Data("\r\n\r\n".utf8)
        var headerRange: Range<Data.Index>?
        while buffer.count < 64 * 1024 {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buffer.append(tmp, count: n)
            if let r = buffer.range(of: headerEnd) { headerRange = r; break }
        }
        guard let hr = headerRange,
              let headStr = String(data: buffer.subdata(in: 0..<hr.lowerBound), encoding: .utf8) else { return nil }
        let lines = headStr.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1].split(separator: "?").first ?? parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        var body = buffer.subdata(in: hr.upperBound..<buffer.count)
        while body.count < contentLength {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            body.append(tmp, count: n)
        }
        if body.count > contentLength { body = body.prefix(contentLength) }
        return Request(method: method, path: path, headers: headers, body: body)
    }

    private func writeJSON(_ fd: Int32, status: Int, body: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 404 ? "Not Found" : "Error"))
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        _ = head.withCString { write(fd, $0, strlen($0)) }
        data.withUnsafeBytes { ptr in
            var off = 0
            while off < data.count {
                let n = write(fd, ptr.baseAddress!.advanced(by: off), data.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }
}
