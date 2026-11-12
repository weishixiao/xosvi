// Stubs.swift — 静态解析自检用的「最小 MCPCore 形状」（v7.18 系列）
//
// 目的：让 StaticAnalysisSupport / BinaryForensicsTool / CrashIPSTool / BundleAnatomy
// 这四个**纯 Foundation** 的文件能在 macOS runner 上单独编译运行，从而真正执行
// 自己写的 Mach-O / .ips / .app 解析代码（而不是只在 CI 里 -parse 一遍）。
//
// 约束：
//   · 这里只提供这四个文件实际用到的成员，**不是** MCPCore 的复制品；
//   · 语义（尤其是 ToolDefinition 的默认值、annotations 归一化）以
//     Sources/XosviMCP/MCPCore.swift 为准；那边签名变了，这里要跟着改，
//     否则编译会失败——失败是**可见**的，不会变成假绿。
//   · 自检只断言解析结果，不断言工具元数据。

import Foundation

// MARK: - 错误

public enum MCPError: Error, CustomStringConvertible {
    case unknownTool(String)
    case invalidParams(String)
    case failed(String)
    case classified(String, code: String, reason: String, nextStep: String)
    case classifiedData(String, code: String, reason: String, nextStep: String, data: [String: Any])

    public var description: String {
        switch self {
        case .unknownTool(let n): return "unknown tool: \(n)"
        case .invalidParams(let m): return "invalid params: \(m)"
        case .failed(let m): return "tool failed: \(m)"
        case .classified(let m, let code, let reason, let nextStep):
            return "tool failed: [\(code)] \(m) (category: \(reason)) next: \(nextStep)"
        case .classifiedData(let m, let code, let reason, let nextStep, _):
            return "tool failed: [\(code)] \(m) (category: \(reason)) next: \(nextStep)"
        }
    }
}

// MARK: - 工具元数据

public struct ToolAnnotations {
    public let readOnly: Bool
    public let destructive: Bool
    public let idempotent: Bool
    public let openWorld: Bool

    public init(readOnly: Bool = false,
                destructive: Bool = true,
                idempotent: Bool = false,
                openWorld: Bool = true) {
        self.readOnly = readOnly
        self.destructive = readOnly ? false : destructive
        self.idempotent = readOnly ? true : idempotent
        self.openWorld = openWorld
    }

    public static let readOnlyLocal = ToolAnnotations(
        readOnly: true, destructive: false, idempotent: true, openWorld: false)
    public static let readOnlyNetwork = ToolAnnotations(
        readOnly: true, destructive: false, idempotent: true, openWorld: true)
    public static let writeLocal = ToolAnnotations(
        readOnly: false, destructive: false, idempotent: false, openWorld: false)
    public static let destructiveLocal = ToolAnnotations(
        readOnly: false, destructive: true, idempotent: false, openWorld: false)
}

public struct ToolCachePolicy {
    public let ttl: TimeInterval?
    public let invalidatedBy: [String]

    public init(ttl: TimeInterval?, invalidatedBy: [String] = []) {
        self.ttl = ttl
        self.invalidatedBy = invalidatedBy
    }

    public static let none = ToolCachePolicy(ttl: nil)
    public static let short = ToolCachePolicy(ttl: 300)
    public static let long = ToolCachePolicy(ttl: 1800)
}

public struct ToolDefinition {
    public let name: String
    public let summary: String
    public let parameters: [String: String]
    public let returns: [String: String]
    public let verified: Bool
    public let category: String
    public let prerequisites: [String]
    public let annotations: ToolAnnotations?
    public let cache: ToolCachePolicy?

    public init(name: String,
                summary: String,
                parameters: [String: String] = [:],
                returns: [String: String] = [:],
                verified: Bool = false,
                category: String = "misc",
                prerequisites: [String] = [],
                annotations: ToolAnnotations? = nil,
                cache: ToolCachePolicy? = nil) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returns = returns
        self.verified = verified
        self.category = category
        self.prerequisites = prerequisites
        self.annotations = annotations
        self.cache = cache
    }
}

public protocol MCPTool {
    var definition: ToolDefinition { get }
    func invoke(_ params: [String: Any]) throws -> [String: Any]
}

// MARK: - 工具注册表（只给 ConsoleErrorDigest 用）

/// ConsoleErrorDigest 需要 `ToolRegistry.shared.dispatch(name:params:)` 这一小块：
/// 按名字找到工具并调用。真实的注册表还有 envelope / 缓存 / 审计，自检不需要。
final class ToolRegistry {
    static let shared = ToolRegistry()

    private var tools: [String: MCPTool] = [:]

    func register(_ tool: MCPTool) {
        tools[tool.definition.name] = tool
    }

    func dispatch(name: String, params: [String: Any]) throws -> [String: Any] {
        guard let tool = tools[name] else {
            throw MCPError.unknownTool(name)
        }
        return try tool.invoke(params)
    }
}
