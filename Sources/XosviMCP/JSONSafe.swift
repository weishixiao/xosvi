//
//  JSONSafe.swift
//  Xosvi
//
//  v10.15 崩溃修复 —— 工具结果一定可以过 NSJSONSerialization。
//
//  背景（报告 Xosvi-2026-11-17-173625，SIGABRT）：
//  工具成功返回后 dispatchCore 会写审计（Self.resultBytes(result) → JSONSerialization.data），
//  而 NSJSONSerialization 遇到 Date / Data / NaN / ±Infinity / 自定义对象时是**抛 ObjC 异常**
//  （不是走 error 出参），`try?` 抓不住 → 未捕获异常穿过 dispatchCore 的
//  com.apple.root.default-qos 闭包 → std::terminate → _objc_terminate → abort()。
//  因为任何工具成功返回都要过这一行，表现为"用着用着就闪退"。
//
//  修法：在工具返回进入一切后续处理（审计、缓存、压缩、回模型）之前，
//  先把结果整棵树规整成 JSON 合法值。不认识的对象降级成它的描述字符串，
//  信息不丢，只是变成可读文本。
//

import Foundation
import CoreFoundation

enum JSONSafe {

    /// 递归深度上限：防止自引用 / 病态深树把栈打穿。
    private static let maxDepth = 16

    /// 结果字典入口。
    static func sanitize(_ result: [String: Any]) -> [String: Any] {
        return sanitizeValue(result, depth: 0) as? [String: Any] ?? [:]
    }

    /// 任意值 → JSON 合法值（NSNull / Bool / 数字 / String / [Any] / [String: Any]）。
    static func sanitizeValue(_ value: Any, depth: Int = 0) -> Any {
        if depth > maxDepth {
            return describe(value)
        }

        // Optional 先剥壳：拆完再判断，否则 Optional 会落进 default 变成 "Optional(...)"
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let inner = mirror.children.first?.value else { return NSNull() }
            return sanitizeValue(inner, depth: depth + 1)
        }

        switch value {
        case is NSNull:
            return NSNull()

        case let s as String:
            return s

        // NSNumber 必须排在 Bool/Int/Double 之前：Swift 这三者都能桥接到 NSNumber，
        // 顺序错了会把数字 1 变成 true（或反过来 true 变 1）。这里用 CFBoolean 精确分辨：
        // 真正的布尔走 boolValue，其余原样返回（换类型会掉精度，大 UInt64 走 Double 会失真）。
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue
            }
            let d = n.doubleValue
            if !d.isFinite {
                return String(describing: d)      // nan / inf / -inf → "nan" / "inf" / "-inf"
            }
            return n

        case let b as Bool:
            return b
        case let i as Int:
            return i
        case let d as Double:
            return d.isFinite ? d : String(describing: d)
        case let f as Float:
            return f.isFinite ? Double(f) : String(describing: f)

        case let date as Date:
            return isoFormatter.string(from: date)
        case let data as Data:
            return "data(\(data.count) bytes)"
        case let url as URL:
            return url.absoluteString
        case let err as Error:
            return err.localizedDescription

        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out[k] = sanitizeValue(v, depth: depth + 1)
            }
            return out

        case let dict as [AnyHashable: Any]:
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (k, v) in dict {
                out["\(k)"] = sanitizeValue(v, depth: depth + 1)
            }
            return out

        case let array as [Any]:
            return array.map { sanitizeValue($0, depth: depth + 1) }

        default:
            return describe(value)
        }
    }

    /// 兜底描述：类对象用 description（有 debugDescription 更好读），标量用 String(describing:)。
    private static func describe(_ value: Any) -> String {
        if let obj = value as? NSObject {
            let d = obj.description
            return d.isEmpty ? "<\(type(of: value))>" : d
        }
        return String(describing: value)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
