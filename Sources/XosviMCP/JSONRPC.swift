import Foundation

/// 最小 JSON-RPC 2.0 处理器（tools/list + tools/call）。
/// M1 阶段直接进程内调用；M4 接 Gateway 时同一套分发逻辑套上 WebSocket 传输。
///
/// PR-B1（安全子集）改动：
///   - initialize：serverInfo.version 动态读取 Bundle（不再写死 2.0.0-m1）
///   - 新增 notifications/*（无响应）与 ping
///   - tools/list：暴露已有元数据（returns / prerequisites / environment /
///     param_specs / variants）+ 可选分页（cursor/nextCursor）
///   - 错误响应：MCPError.classified 的结构化字段写入 error.data
///
/// 说明：ToolDefinition v2（annotations / cache / related / examples / aliases）
/// 属于高风险批次，本文件暂不投影这些字段；字段只增不改，后续补上不影响客户端。
///
/// ⚠️ 调用方注意：notifications/* 返回**空 Data**，HTTP/WS 层必须跳过写回。
public enum JSONRPC {

    /// 协议版本：客户端能力协商用。保持向后兼容（只增不改）。
    public static let protocolVersion = "2024-11-05"

    /// 单页工具数量上限（超出返回 nextCursor 分页）
    public static let toolsPageSize = 200

    public static func handle(_ data: Data, registry: ToolRegistry = .shared) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            return encode(errorResponse(id: nil, code: -32700, message: "parse error"))
        }
        let id = obj["id"]
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
            return encode(response(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]] as [String: Any],
                "serverInfo": ["name": "Xosvi", "version": appVersion],
            ]))

        case "ping":
            return encode(response(id: id, result: [:]))

        case let m where m.hasPrefix("notifications/"):
            // 通知无响应；调用方拿到空 Data 时跳过写回
            return Data()

        case "tools/list":
            let defs = registry.definitions
            let startIndex: Int
            if let cursor = params["cursor"] as? String, let n = Int(cursor) {
                startIndex = max(0, min(n, defs.count))
            } else {
                startIndex = 0
            }
            let endIndex = min(startIndex + toolsPageSize, defs.count)
            let page: [[String: Any]] = defs[startIndex..<endIndex].map { toolListItem($0) }
            var result: [String: Any] = ["tools": page]
            if endIndex < defs.count { result["nextCursor"] = String(endIndex) }
            return encode(response(id: id, result: result))

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return encode(errorResponse(id: id, code: -32602, message: "params.name required"))
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try registry.dispatch(name: toolName, params: args)
                return encode(response(id: id, result: [
                    "content": [["type": "text", "text": jsonString(from: result)]],
                    "isError": (result["ok"] as? Bool) == false,
                ]))
            } catch let e as MCPError {
                return encode(errorResponse(id: id, code: -32000, message: e.description, data: mcpErrorData(e)))
            } catch {
                return encode(errorResponse(id: id, code: -32000, message: String(describing: error)))
            }

        default:
            return encode(errorResponse(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: - 工具元数据投影

    /// 单个工具的协议投影。字段只增不改；未知字段由客户端忽略。
    public static func toolListItem(_ def: ToolDefinition) -> [String: Any] {
        var item: [String: Any] = [
            "name": def.name,
            "description": def.summary,
            "parameters": def.parameters,
            "verified": def.verified,
            "category": def.category,
        ]

        // 结构化返回值说明（AI 知道工具会返回什么字段）
        if !def.returns.isEmpty { item["returns"] = def.returns }
        // 前置条件（AI 规划顺序时使用）
        if !def.prerequisites.isEmpty { item["prerequisites"] = def.prerequisites }

        // 环境约束（静态声明；设备实测可用性由 system.overview / device 工具给出）
        var env: [String: Any] = [:]
        if let v = def.minIOSMajor { env["min_ios_major"] = v }
        if let v = def.maxIOSMajor { env["max_ios_major"] = v }
        if def.requiresJailbreak { env["requires_jailbreak"] = true }
        if def.requiresTrollStore { env["requires_trollstore"] = true }
        if def.remoteOnly { env["remote_only"] = true }

        // v8（PR-B2）：注解 / 缓存 / 交叉引用 / 示例 / 旧名 / 设备可用性
        item["annotations"] = def.annotationsJSON
        if def.isAnnotated { item["annotated"] = true }
        if !def.related.isEmpty { item["related"] = def.related.map { $0.jsonObject } }
        if !def.examples.isEmpty { item["examples"] = def.examples.map { $0.jsonObject } }
        if let cache = def.cache { item["cache"] = cache.jsonObject }
        if !def.deprecatedAliases.isEmpty { item["deprecated_aliases"] = def.deprecatedAliases }
        let availability = ToolRegistry.shared.availability(of: def)
        env["available"] = availability.available
        if let reason = availability.reason { env["unavailable_reason"] = reason }
        if !env.isEmpty { item["environment"] = env }

        // 结构化参数 + 子命令要求（已有字段，直接投影）
        if !def.paramSpecs.isEmpty {
            item["param_specs"] = def.paramSpecs.map { spec -> [String: Any] in
                var d = spec.schemaFragment()
                d["name"] = spec.name
                d["required"] = spec.required
                return d
            }
        }
        if !def.variants.isEmpty {
            item["variants"] = def.variants.map { v -> [String: Any] in
                var d: [String: Any] = ["command": v.command,
                                        "required_params": v.requires,
                                        "optional_params": v.accepts]
                if let note = v.note { d["note"] = note }
                return d
            }
        }

        return item
    }

    // MARK: - 错误数据（结构化失败信息进 error.data）

    private static func mcpErrorData(_ e: MCPError) -> [String: Any]? {
        if case let .classified(_, code, reason, nextStep) = e {
            return ["mcp_code": code, "reason": reason, "next_step": nextStep]
        }
        // v10.3：classifiedData 是 classified 的结构化版本（带 kb_fix / unmet_prerequisites），
        // 之前这里只认 classified，带数据的分类错误在 MCP 协议层丢掉 mcp_code。
        if case let .classifiedData(_, code, reason, nextStep, _) = e {
            return ["mcp_code": code, "reason": reason, "next_step": nextStep]
        }
        if case let .unknownTool(name) = e {
            return ["mcp_code": "UNKNOWN_TOOL", "tool": name]
        }
        if case let .invalidParams(msg) = e {
            return ["mcp_code": "PARAM_INVALID", "reason": msg]
        }
        if case let .failed(msg) = e {
            return ["mcp_code": "TOOL_FAILED", "reason": msg]
        }
        return nil
    }

    // MARK: - 私有

    private static func response(id: Any?, result: [String: Any]) -> [String: Any] {
        var dict: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { dict["id"] = id }
        return dict
    }

    private static func errorResponse(id: Any?, code: Int, message: String,
                                      data: [String: Any]? = nil) -> [String: Any] {
        var err: [String: Any] = ["code": code, "message": message]
        if let data = data { err["data"] = data }
        var dict: [String: Any] = ["jsonrpc": "2.0", "error": err]
        if let id = id { dict["id"] = id }
        return dict
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    private static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
