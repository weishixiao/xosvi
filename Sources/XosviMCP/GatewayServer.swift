import Foundation
import Darwin
import Security
import CommonCrypto

// MARK: - v8（PR-D1a/D1b）：MCP Gateway
//
// 目标：让 Mac / 局域网内的 MCP 客户端直接接入本机工具集。
// 传输：
//   - POST /            JSON-RPC 请求 → JSON 响应（一对多）
//   - GET  /sse         SSE：先发 endpoint 事件，随后推送响应
//   - GET  /health      健康检查
// 鉴权：pair 后发放 token；除 /health 外必须携带 Authorization: Bearer <token>
//
// 设计取舍：
//   - 用 POSIX socket 而不是 NWListener：实现可控、无额外依赖，iSH/Alpine 侧也能测。
//   - 每连接一个串行队列；工具执行在队列外，避免慢工具阻塞 accept。
//   - 默认只绑 127.0.0.1；settings 里显式开启 LAN 才绑 0.0.0.0。
//   - 只读范围：`read` 令牌只能调用 isAnnotated && readOnly 的工具（未标注工具维持旧行为）。

final class MCPGatewayServer {
    static let shared = MCPGatewayServer()

    struct Config {
        var port: UInt16 = 8765
        var bindLAN: Bool = false
        var token: String = ""
        var readOnlyToken: String = ""
        var pairingCode: String = ""
    }

    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "gateway.accept", attributes: .concurrent)
    private let stateLock = NSLock()
    private var running = false
    private var connections = 0
    private var config = Config()
    private let defaults = UserDefaults.standard

    private let keyPort = "xosvi.gateway.port"
    private let keyLAN = "xosvi.gateway.bind_lan"
    private let keyToken = "xosvi.gateway.token"
    private let keyReadToken = "xosvi.gateway.read_token"
    private let keyPairing = "xosvi.gateway.pairing"

    private init() { loadConfig() }

    // MARK: - 生命周期

    var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return running }
    var currentToken: String { stateLock.lock(); defer { stateLock.unlock() }; return config.token }
    var currentReadToken: String { stateLock.lock(); defer { stateLock.unlock() }; return config.readOnlyToken }
    var pairingCode: String { stateLock.lock(); defer { stateLock.unlock() }; return config.pairingCode }

    /// v9.7：给 ChatBridgeServer 用的公开只读访问器——
    /// 本机兼容端点复用同一套 token，用户不用记两份密钥。
    public static var sharedFullToken: String { MCPGatewayServer.shared.currentToken }
    public static var sharedReadToken: String { MCPGatewayServer.shared.currentReadToken }

    func status() -> [String: Any] {
        stateLock.lock(); defer { stateLock.unlock() }
        return [
            "running": running,
            "port": Int(config.port),
            "bind": config.bindLAN ? "0.0.0.0 (LAN)" : "127.0.0.1",
            "connections_active": connections,
            "token_set": !config.token.isEmpty,
            "read_token_set": !config.readOnlyToken.isEmpty,
            "endpoints": ["POST /", "GET /sse", "GET /health", "POST /pair"],
            "lan_warning": config.bindLAN ? "已绑定局域网：任何拿到 token 的设备都能调用工具，请勿在不可信网络开启" : "",
        ]
    }

    @discardableResult
    func start(port: UInt16? = nil) -> (ok: Bool, error: String?) {
        if isRunning { return (true, nil) }
        if let p = port { config.port = p }

        // 非回环绑定视为高风险操作：必须显式开启，且在设置页有确认
        let host = config.bindLAN ? "0.0.0.0" : "127.0.0.1"
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return (false, "socket() failed: errno \(errno)") }
        var opt: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = config.port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let bound = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else {
            let e = errno
            close(fd)
            return (false, e == EADDRINUSE ? "端口 \(config.port) 已被占用，换一个端口或先停止旧实例" : "bind failed: errno \(e)")
        }
        guard listen(fd, 16) == 0 else {
            let e = errno; close(fd); return (false, "listen failed: errno \(e)")
        }

        stateLock.lock()
        listenFD = fd
        running = true
        if config.token.isEmpty { config.token = Self.randomToken() }
        if config.readOnlyToken.isEmpty { config.readOnlyToken = Self.randomToken() }
        if config.pairingCode.isEmpty { config.pairingCode = String(format: "%06d", Int.random(in: 0...999999)) }
        stateLock.unlock()
        persistConfig()

        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
        return (true, nil)
    }

    func stop() {
        stateLock.lock()
        let fd = listenFD
        listenFD = -1
        running = false
        stateLock.unlock()
        if fd >= 0 { close(fd) }
    }

    /// 重新生成令牌（泄漏后吊销）
    func rotateTokens() -> [String: Any] {
        stateLock.lock()
        config.token = Self.randomToken()
        config.readOnlyToken = Self.randomToken()
        config.pairingCode = String(format: "%06d", Int.random(in: 0...999999))
        stateLock.unlock()
        persistConfig()
        return ["token": currentToken, "read_token": currentReadToken, "pairing_code": pairingCode]
    }

    // MARK: - 连接处理

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            var client = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &client) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &len)
                }
            }
            if cfd < 0 {
                if errno == EBADF { break }
                continue
            }
            stateLock.lock(); connections += 1; stateLock.unlock()
            queue.async { [weak self] in
                self?.handle(cfd)
                close(cfd)
                self?.stateLock.lock(); self?.connections -= 1; self?.stateLock.unlock()
            }
        }
    }

    private func handle(_ fd: Int32) {
        guard let request = readRequest(fd) else { return }
        let method = request.method.uppercased()
        let path = request.path

        if path == "/health" && method == "GET" {
            writeJSON(fd, status: 200, body: ["ok": true, "name": "Xosvi Gateway", "running": isRunning])
            return
        }

        if path == "/pair" && method == "POST" {
            guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let code = obj["code"] as? String, code == pairingCode else {
                writeJSON(fd, status: 403, body: ["error": "invalid pairing code"])
                return
            }
            writeJSON(fd, status: 200, body: [
                "token": currentToken, "read_token": currentReadToken,
                "note": "read_token 只能调用显式标注为 readOnly 的工具",
            ])
            AuditLog.shared.log("gateway", detail: "pair success")
            return
        }

        let auth = request.headers["authorization"] ?? ""
        let bearer = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        let role: String
        if !bearer.isEmpty && bearer == currentToken { role = "full" }
        else if !bearer.isEmpty && bearer == currentReadToken { role = "read" }
        else {
            writeJSON(fd, status: 401, body: ["error": "unauthorized", "hint": "POST /pair with pairing code"])
            return
        }

        if path == "/sse" && method == "GET" {
            serveSSE(fd, role: role)
            return
        }

        // v8（PR-D1a）：WebSocket 升级（RFC6455 服务端握手 + 文本帧转发 JSON-RPC）
        if path == "/ws" && method == "GET" {
            guard let key = request.headers["sec-websocket-key"] else {
                writeJSON(fd, status: 400, body: ["error": "missing Sec-WebSocket-Key"])
                return
            }
            serveWebSocket(fd, key: key, role: role)
            return
        }

        // 默认：JSON-RPC over POST
        guard method == "POST" else {
            writeJSON(fd, status: 405, body: ["error": "method not allowed"])
            return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            writeJSON(fd, status: 400, body: ["error": "parse error"])
            return
        }
        // 只读令牌：拦截写工具
        if role == "read", let params = obj["params"] as? [String: Any],
           obj["method"] as? String == "tools/call", let name = params["name"] as? String,
           let def = ToolRegistry.shared.tool(named: name)?.definition,
           def.isAnnotated && !def.annotations.readOnly {
            writeJSON(fd, status: 200, body: [
                "jsonrpc": "2.0", "id": obj["id"] ?? NSNull(),
                "error": ["code": -32003, "message": "read-only token cannot call \(name)"],
            ])
            return
        }
        let resp = JSONRPC.handle(request.body)
        if resp.isEmpty {
            writeRaw(fd, status: 204, contentType: "application/json", body: Data())
        } else {
            writeRaw(fd, status: 200, contentType: "application/json", body: resp)
            AuditLog.shared.log("gateway", detail: "POST \(path) role=\(role)")
        }
    }

    /// SSE：先告知 endpoint，再按请求逐条推送（客户端用 POST /sse/message 提交）
    private func serveSSE(_ fd: Int32, role: String) {
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
        _ = headers.withCString { write(fd, $0, strlen($0)) }
        let endpoint = "event: endpoint\ndata: /message?role=\(role)\n\n"
        _ = endpoint.withCString { write(fd, $0, strlen($0)) }
        // 保持连接 30s，期间发送心跳；真正的请求走 POST /message
        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 5)
            let ping = ": ping\n\n"
            if ping.withCString({ write(fd, $0, strlen($0)) }) < 0 { break }
        }
    }

    // MARK: - v8（PR-D1a）：WebSocket 服务端（最小 RFC6455：text/binary 帧 + ping/pong）

    private func serveWebSocket(_ fd: Int32, key: String, role: String) {
        // 握手：Sec-WebSocket-Accept = base64(SHA1(key + magic))
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let concat = key + magic
        guard let data = concat.data(using: .utf8) else { return }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA1(buf.baseAddress, CC_LONG(data.count), &digest)
        }
        let accept = Data(digest).base64EncodedString()

        let resp = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        guard resp.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return }

        // 帧循环
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buffer.append(tmp, count: n)
            // 处理缓冲区里所有完整帧
            while let frame = Self.parseFrame(buffer) {
                buffer.removeFirst(frame.consumed)
                switch frame.opcode {
                case 0x1, 0x2:   // text / binary → 按 JSON-RPC 处理
                    let body = frame.payload
                    var out: [String: Any] = [:]
                    if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                       let method = obj["method"] as? String, method == "tools/call",
                       let params = obj["params"] as? [String: Any],
                       role == "read", let name = params["name"] as? String,
                       let def = ToolRegistry.shared.tool(named: name)?.definition,
                       def.isAnnotated && !def.annotations.readOnly {
                        out = ["jsonrpc": "2.0", "id": obj["id"] ?? NSNull(),
                               "error": ["code": -32003, "message": "read-only token cannot call \(name)"]]
                    } else {
                        out = handleWSRequest(body)
                    }
                    if let data = try? JSONSerialization.data(withJSONObject: out) {
                        Self.writeWSFrame(fd, payload: data, opcode: 0x1)
                    }
                case 0x8:      // close
                    Self.writeWSFrame(fd, payload: Data(), opcode: 0x8)
                    return
                case 0x9:      // ping → pong
                    Self.writeWSFrame(fd, payload: frame.payload, opcode: 0xA)
                default:
                    break
                }
            }
        }
    }

    private func handleWSRequest(_ body: Data) -> [String: Any] {
        let resp = JSONRPC.handle(body)
        if resp.isEmpty { return ["jsonrpc": "2.0", "id": NSNull(), "result": []] as [String: Any] }
        return (try? JSONSerialization.jsonObject(with: resp) as? [String: Any]) ?? [:]
    }

    private struct WSFrame {
        let opcode: UInt8
        let payload: Data
        let consumed: Int
    }

    /// 解析一帧（客户端帧必须带掩码）；不完整返回 nil
    private static func parseFrame(_ data: Data) -> WSFrame? {
        guard data.count >= 2 else { return nil }
        let b0 = data[data.startIndex]
        let b1 = data[data.startIndex + 1]
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var offset = 2
        if len == 126 {
            guard data.count >= 4 else { return nil }
            len = Int(data[data.startIndex + 2]) << 8 | Int(data[data.startIndex + 3])
            offset = 4
        } else if len == 127 {
            guard data.count >= 10 else { return nil }
            var big: UInt64 = 0
            for i in 0..<8 {
                big = big << 8 | UInt64(data[data.startIndex + 2 + i])
            }
            len = Int(big)
            offset = 10
        }
        let maskLen = masked ? 4 : 0
        guard data.count >= offset + maskLen + len else { return nil }
        var mask = [UInt8](repeating: 0, count: 4)
        if masked {
            for i in 0..<4 { mask[i] = data[data.startIndex + offset + i] }
        }
        var payload = Data()
        payload.reserveCapacity(len)
        for i in 0..<len {
            let byte = data[data.startIndex + offset + maskLen + i]
            payload.append(masked ? byte ^ mask[i % 4] : byte)
        }
        return WSFrame(opcode: opcode, payload: payload, consumed: offset + maskLen + len)
    }

    /// 服务端帧不掩码
    private static func writeWSFrame(_ fd: Int32, payload: Data, opcode: UInt8) {
        var header = Data()
        header.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            header.append(UInt8(len))
        } else if len <= 0xFFFF {
            header.append(126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            var big = UInt64(len).bigEndian
            withUnsafeBytes(of: &big) { header.append(contentsOf: $0) }
        }
        var out = header
        out.append(payload)
        out.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress, out.count)
        }
    }

    // MARK: - HTTP 解析/写回

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private func readRequest(_ fd: Int32) -> Request? {
        var buffer = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        let headerEnd = Data("\r\n\r\n".utf8)
        var headerRange: Range<Data.Index>?

        // 读头
        while buffer.count < 64 * 1024 {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buffer.append(tmp, count: n)
            if let r = buffer.range(of: headerEnd) { headerRange = r; break }
        }
        guard let hr = headerRange else { return nil }
        let headData = buffer.subdata(in: 0..<hr.lowerBound)
        guard let headStr = String(data: headData, encoding: .utf8) else { return nil }
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
        writeRaw(fd, status: status, contentType: "application/json", body: data)
    }

    private func writeRaw(_ fd: Int32, status: Int, contentType: String, body: Data) {
        let reason = status == 200 ? "OK" : (status == 204 ? "No Content" : "Error")
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        if body.isEmpty { head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n\r\n" }
        _ = head.withCString { write(fd, $0, strlen($0)) }
        if !body.isEmpty {
            body.withUnsafeBytes { ptr in
                var off = 0
                while off < body.count {
                    let n = write(fd, ptr.baseAddress!.advanced(by: off), body.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
    }

    // MARK: - 配置

    private func loadConfig() {
        config.port = UInt16(defaults.integer(forKey: keyPort) == 0 ? 8765 : defaults.integer(forKey: keyPort))
        config.bindLAN = defaults.bool(forKey: keyLAN)
        config.token = defaults.string(forKey: keyToken) ?? ""
        config.readOnlyToken = defaults.string(forKey: keyReadToken) ?? ""
        config.pairingCode = defaults.string(forKey: keyPairing) ?? ""
    }

    private func persistConfig() {
        stateLock.lock()
        let c = config
        stateLock.unlock()
        defaults.set(Int(c.port), forKey: keyPort)
        defaults.set(c.bindLAN, forKey: keyLAN)
        defaults.set(c.token, forKey: keyToken)
        defaults.set(c.readOnlyToken, forKey: keyReadToken)
        defaults.set(c.pairingCode, forKey: keyPairing)
    }

    func setBindLAN(_ on: Bool) { stateLock.lock(); config.bindLAN = on; stateLock.unlock(); persistConfig() }
    func setPort(_ p: UInt16) { stateLock.lock(); config.port = p; stateLock.unlock(); persistConfig() }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 工具：gateway.status / gateway.start / gateway.stop / gateway.rotate

final class GatewayTool: MCPTool {
    let definition = ToolDefinition(
        name: "gateway",
        summary: "MCP Gateway for external clients (Mac/局域网). Commands: status / start / stop / rotate / pair_code. Use for: 让 Mac 侧 MCP 客户端接入本机工具. Don't use for: 本地内置 AI（它直接走进程内 dispatch）. Example: '让 Mac 连上这台手机的 MCP' → gateway command:start，再用返回的端口+配对码在 Mac 侧连接.",
        parameters: [
            "command": "status / start / stop / rotate / pair_code",
            "port": "start 时的端口（默认 8765）",
            "bind_lan": "Bool，默认 false；true 才绑定 0.0.0.0（高风险）",
        ],
        returns: ["running": "Bool", "port": "Int", "token": "full token", "read_token": "只读 token", "pairing_code": "6 位配对码"],
        verified: false, category: "system",
        paramSpecs: [
            .e("command", "子命令", values: ["status", "start", "stop", "rotate", "pair_code"], required: true),
            .i("port", "端口", required: false, example: "8765"),
            .b("bind_lan", "绑定 0.0.0.0（高风险）", required: false),
        ],
        variants: [
            ToolVariant("status", requires: [], accepts: []),
            ToolVariant("start", requires: [], accepts: ["port", "bind_lan"]),
            ToolVariant("stop", requires: [], accepts: []),
            ToolVariant("rotate", requires: [], accepts: []),
            ToolVariant("pair_code", requires: [], accepts: []),
        ],
        annotations: .systemControl,
        cache: ToolCachePolicy.none,
        related: [RelatedTool(tool: "server", command: "status", when: "查看本地 HTTP 服务状态时")])

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let cmd = (params["command"] as? String) ?? "status"
        let gw = MCPGatewayServer.shared
        switch cmd {
        case "status":
            return gw.status()
        case "start":
            if let lane = params["bind_lan"] as? Bool { gw.setBindLAN(lane) }
            let port = UInt16((params["port"] as? Int) ?? 8765)
            let r = gw.start(port: port)
            guard r.ok else { return ["error": r.error ?? "start failed"] }
            var out = gw.status()
            out["token"] = gw.currentToken
            out["read_token"] = gw.currentReadToken
            out["pairing_code"] = gw.pairingCode
            out["next_step"] = "Mac 侧：POST http://<iphone-ip>:\(port)/pair {\"code\":\"\(gw.pairingCode)\"} 取 token；随后 POST / 发 JSON-RPC"
            return out
        case "stop":
            gw.stop()
            return ["stopped": true]
        case "rotate":
            return gw.rotateTokens()
        case "pair_code":
            return ["pairing_code": gw.pairingCode]
        default:
            return ["error": "unknown command: \(cmd)"]
        }
    }
}
