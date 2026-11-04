// ChatBridge.swift —— 把 Xosvi 的 MCP 工具翻译成 OpenAI function calling，并负责执行。
//
// 目的：让「用户存的任意一条 API 配置」或「任何 OpenAI 兼容的服务商」都能直接驱动本机能力，
// 而不需要为每家服务商单独做账号登录/授权对接。
//
// 两个入口：
//   1. publicTools(role:)        —— 把 ToolDefinition 转成 OpenAI tools 数组
//   2. injectedSystemPrompt(role:) —— 给模型看的系统提示（含用法约定与只读限制）
//   3. runToolTurn(messages:role:) —— 从 messages 里取出 tool_calls 并执行，返回标准结构
//
// 约束（照 docs/TROUBLESHOOTING.md 的纪律）：
//   - 只读 token 只能调用 annotations.readOnly 的工具，其余直接拒绝，不靠模型自觉。
//   - 所有工具在后台串行执行，不阻塞服务线程。
//   - 失败按 MCPError 分类回传，不吞异常。

import Foundation

public enum ChatBridge {

    // MARK: - 工具描述转换

    /// 可选工具名（按 token 权限过滤）。
    /// 注意返回的是 **apiName**（模型看到的、也是 dispatch 能解析的名字），不是内部注册名。
    public static func allowedToolNames(role: String) -> [String] {
        let defs = ToolRegistry.shared.definitions
        if role == "read" {
            return defs.filter { $0.isAnnotated && $0.annotations.readOnly }.map { $0.apiName }.sorted()
        }
        return defs.map { $0.apiName }.sorted()
    }

    /// 转成 OpenAI `tools` 数组。
    /// v9.7：复用 ToolRegistry 现成的 `enabledOpenAIToolSchema()`——它会把工具名映射成
    /// OpenAI 安全的 apiName 并登记反向映射，dispatch 才能把模型返回的名字转回真实工具名。
    /// 与其平行造一套契约（迟早对不上），不如直接用同一份。
    public static func publicTools(role: String) -> [[String: Any]] {
        let schema = ToolRegistry.shared.enabledOpenAIToolSchema()
        guard role == "read" else { return schema }
        // 只读 token：按 apiName → 真实名反查注解，过滤掉写操作
        let readOnlyNames = Set(
            ToolRegistry.shared.definitions
                .filter { $0.isAnnotated && $0.annotations.readOnly }
                .map { $0.apiName }
        )
        return schema.filter { item in
            guard let fn = item["function"] as? [String: Any],
                  let name = fn["name"] as? String else { return false }
            return readOnlyNames.contains(name)
        }
    }

    // MARK: - 系统提示

    /// 注入给模型的系统提示：说明「你现在跑在什么样的设备上、怎么用工具」。
    public static func injectedSystemPrompt(role: String) -> String {
        let names = allowedToolNames(role: role)
        let readOnly = role == "read"
        var lines: [String] = []
        lines.append("你正在通过 Xosvi 操作一台真实的 iOS 设备。\(names.count) 个本机工具已以 function 形式提供。")
        lines.append("")
        lines.append("【硬性规则】")
        lines.append("1. 只调用真实存在的工具名，不要加前缀或别名；子命令放 command 参数里（如 app 的 launch）。")
        lines.append("2. 一律使用绝对路径；iOS 原生 shell 不支持通配符展开、cd 后相对路径、二进制 grep。")
        lines.append("3. 失败先看返回的 code/reason/next_step 再决定是否重试；同一工具同一参数同一类错误连续 2 次即停。")
        lines.append("4. 注入、替换二进制、改数据库/plist、删除文件之前必须先备份，并在结果里给出备份绝对路径。")
        lines.append("5. 结论先给判断，再给证据（命令/路径/字节/哈希）。")
        if readOnly {
            lines.append("")
            lines.append("【本会话限制】当前使用只读 token：只能调用标注为只读的工具，任何写操作会被拒绝。")
        }
        lines.append("")
        lines.append("【可用工具】")
        lines.append(names.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    // MARK: - 执行一轮 tool_calls

    public struct Outcome {
        public let text: String
        public let toolCalls: [[String: Any]]
        public let rounds: Int
    }

    /// 从 messages 末尾取出 assistant 的 tool_calls（或客户端显式传入的工具调用），
    /// 依次执行，返回可回填给模型的结果。没有工具调用时返回纯文本说明。
    public static func runToolTurn(messages: [[String: Any]], role: String) -> Outcome {
        // 收集本轮要执行的工具调用
        var pending: [(id: String, name: String, args: [String: Any])] = []
        for m in messages {
            guard (m["role"] as? String) == "assistant" else { continue }
            for call in (m["tool_calls"] as? [[String: Any]] ?? []) {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                let id = call["id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                var args: [String: Any] = [:]
                if let s = fn["arguments"] as? String, let d = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    args = o
                } else if let o = fn["arguments"] as? [String: Any] {
                    args = o
                }
                pending.append((id, name, args))
            }
        }

        guard !pending.isEmpty else {
            return Outcome(text: "没有待执行的工具调用。把 base_url 指向 \(endpointHint())，"
                           + "你的模型会在需要时收到 \(allowedToolNames(role: role).count) 个 function 定义。",
                           toolCalls: [], rounds: 0)
        }

        let allowed = Set(allowedToolNames(role: role))
        // v9.7：内部注册名也算「存在的工具」——dispatch 同时接受 apiName 和原名，
        // 预先算一次，避免在循环里反复整表白拿开销。
        let internalNames = Set(ToolRegistry.shared.definitions.map { $0.name })
        var outputs: [[String: Any]] = []
        var rounds = 0
        for call in pending.prefix(ChatBridgeServer.maxToolRounds) {
            rounds += 1
            var content: String
            if !allowed.contains(call.name) && !internalNames.contains(call.name) {
                content = "{\"ok\":false,\"error\":{\"code\":\"FORBIDDEN\",\"reason\":\"当前 token 无权调用该工具\"}}"
            } else {
                let result = executeSynchronously(name: call.name, args: call.args)
                content = ChatBridge.jsonString(result)
            }
            outputs.append(["tool_call_id": call.id, "role": "tool", "name": call.name, "content": content])
        }
        return Outcome(text: "", toolCalls: outputs, rounds: rounds)
    }

    private static func endpointHint() -> String {
        "http://127.0.0.1:\(ChatBridgeServer.shared.port)/v1"
    }

    /// 同步执行（内部用信号量等后台任务），出错按 MCPError 分类落成 JSON。
    private static func executeSynchronously(name: String, args: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try ToolRegistry.shared.dispatch(name: name, params: args)
                out = ["ok": true, "tool": name, "result": r]
            } catch {
                let msg = (error as? MCPError)?.description ?? error.localizedDescription
                out = ["ok": false, "tool": name, "error": ["code": "TOOL_FAILED", "reason": msg]]
            }
            sem.signal()
        }
        // 单工具最长 60 秒，超时不拖死整个请求
        if sem.wait(timeout: .now() + 60) == .timedOut {
            return ["ok": false, "tool": name,
                    "error": ["code": "TOOL_TIMEOUT", "reason": "工具执行超过 60 秒"]]
        }
        return out
    }

    public static func jsonString(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
