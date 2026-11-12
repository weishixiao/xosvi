// ConsoleErrorDigest.swift — 控制台「抓报错」（v10.x）
//
// 控制台原来只留一行 error 字符串：注入失败 / 连不上时，用户手里没有能粘给人或模型的现场，
// 分不清「注入没写进去」「ControlAgent 没起」「目标进程崩了」这三种情况。
// 这里把三条线索拍平成一段可复制文本：
//   ① 状态行 + 最近一次失败的原文
//   ② 目标 App 最近的崩溃报告：crash.ips list 取清单，再对最近两份 parse，
//      折叠出异常 / 终止原因 / 崩溃线程前几帧
//   ③ 采集口径：过滤词、没找到的目录、以及「按名字没匹配到就退回全目录」这种降级要写明
//
// 只读：不注入、不改目标 App、不 respring。拿不到的字段就如实写空，不猜。

import Foundation

enum ConsoleErrorDigest {

    /// 采集一份失败现场。所有参数都在主线程取好再传进来，避免后台线程读 @State。
    /// `crashDirectory` 只在自检里给出（把 CrashReporter 目录指到夹具），运行时为 nil 即系统默认目录。
    static func build(bundleId: String,
                      appName: String,
                      statusLine: String,
                      lastAction: String,
                      lastFailureRaw: String?,
                      crashDirectory: String? = nil) -> String {
        var out: [String] = []
        out.append("== 控制台失败现场 ==")
        out.append("时间：" + stamp())
        let target: String
        if bundleId.isEmpty {
            target = "(未选择目标 App)"
        } else if appName.isEmpty {
            target = bundleId
        } else {
            target = "\(appName) · \(bundleId)"
        }
        out.append("目标：" + target)
        out.append("状态行：" + (statusLine.isEmpty ? "—" : statusLine))
        if !lastAction.isEmpty { out.append("最近一次动作：" + lastAction) }
        if let raw = lastFailureRaw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            out.append("最近一次失败：" + failureText(raw))
        }
        out.append("")

        let filter = filterWord(bundleId: bundleId, appName: appName)
        var listParams: [String: Any] = ["command": "list", "limit": 5]
        if let dir = crashDirectory, !dir.isEmpty { listParams["path"] = dir }
        if !filter.isEmpty { listParams["filter"] = filter }
        var list = call("crash.ips", listParams)
        var usedFilter = filter
        if let err = str(list["error"]) {
            out.append("崩溃报告：清单读不出来（\(err)）")
            return finish(out)
        }
        var total = intOf(list["total"]) ?? 0
        if total == 0 && !filter.isEmpty {
            // 报告文件名里通常是 App 显示名，按 bundle id 末段过滤常常一份都匹配不到；
            // 这时退回全目录最近几份，但必须说清「可能不属于目标 App」。
            var loose: [String: Any] = ["command": "list", "limit": 5]
            if let dir = crashDirectory, !dir.isEmpty { loose["path"] = dir }
            list = call("crash.ips", loose)
            usedFilter = ""
            total = intOf(list["total"]) ?? 0
            out.append("按「\(filter)」没匹配到报告，下面是全目录最近的报告（可能不属于目标 App）")
        }
        let rows = dictRows(list["reports"])
        let scope = usedFilter.isEmpty ? "（全目录）" : "（过滤词：\(usedFilter)）"
        out.append("崩溃报告：匹配 \(total) 份，取最近 \(rows.count) 份\(scope)")
        if rows.isEmpty {
            out.append("  · 没有 .ips / .crash：进程可能没崩过，或报告已被「设置 ▸ 隐私 ▸ 分析与改进」清理")
        }
        for (i, row) in rows.prefix(2).enumerated() {
            out.append("")
            out.append(contentsOf: describe(row, index: i + 1))
        }
        let missing = stringRows(list["missing_dirs"])
        if !missing.isEmpty {
            out.append("")
            out.append("没找到的目录：" + missing.joined(separator: "、"))
        }
        return finish(out)
    }

    // MARK: - 一份报告

    private static func describe(_ row: [String: Any], index: Int) -> [String] {
        var out: [String] = []
        let path = str(row["path"]) ?? ""
        let name = str(row["name"]) ?? (path as NSString).lastPathComponent
        var head = "报告 \(index)：\(name)"
        if let when = str(row["mtime"]) { head += "  " + when }
        if let bug = str(row["bug_type"]) { head += "  bug_type=" + bug }
        if let osv = str(row["os_version"]) { head += "  " + osv }
        out.append(head)
        guard !path.isEmpty else {
            out.append("  · 报告没有路径字段，跳过解析")
            return out
        }

        let parsed = call("crash.ips", ["command": "parse", "path": path, "limit": 12])
        if let err = str(parsed["error"]) {
            out.append("  · 解析失败：\(err)")
            return out
        }

        if let exc = dict(parsed["exception"]) {
            var parts: [String] = []
            if let t = str(exc["type"]) { parts.append(t) }
            if let st = str(exc["subtype"]) { parts.append(st) }
            if let codes = stringRows(exc["codes"]), !codes.isEmpty {
                parts.append(codes.joined(separator: ","))
            }
            if let sig = str(exc["signal"]) { parts.append("signal " + sig) }
            if !parts.isEmpty { out.append("  · 异常：" + parts.joined(separator: " · ")) }
        }
        if let term = dict(parsed["termination"]) {
            var parts: [String] = []
            if let ns = str(term["namespace"]) { parts.append(ns) }
            if let code = str(term["code"]) { parts.append("code " + code) }
            if let ind = str(term["indicator"]) { parts.append(ind) }
            if let reasons = stringRows(term["reasons"]), !reasons.isEmpty {
                parts.append(reasons.joined(separator: " / "))
            }
            if !parts.isEmpty { out.append("  · 终止：" + parts.joined(separator: " · ")) }
        }
        if let ft = intOf(parsed["faulting_thread"]), ft >= 0 {
            out.append("  · 崩溃线程 #\(ft)")
        }
        let frames = dictRows(parsed["faulting_frames"])
        if frames.isEmpty {
            out.append("      （这份报告没给出崩溃线程的帧）")
        }
        for (i, f) in frames.prefix(8).enumerated() {
            var line = "      #\(i) " + (str(f["image"]) ?? "??")
            if let off = str(f["offset"]) { line += " + " + off }
            if let addr = str(f["address"]) { line += " @ " + addr }
            if let sym = str(f["symbol"]) { line += "  " + sym }
            out.append(line)
        }
        return out
    }

    // MARK: - 口径

    private static func finish(_ lines: [String]) -> String {
        var out = lines
        out.append("")
        out.append("口径：只读 crash.ips（list / parse），不注入、不 respring、不改目标 App；")
        out.append("      帧上的符号只在 App 自带符号表时才有，系统库要配 dSYM 才还原得出函数名。")
        return out.joined(separator: "\n")
    }

    /// 报告文件名里一般是 App 显示名，其次才可能带 bundle id，所以两者都试。
    private static func filterWord(bundleId: String, appName: String) -> String {
        if !appName.isEmpty { return appName }
        let bits = bundleId.split(separator: ".").map(String.init)
        return bits.last ?? bundleId
    }

    /// 控制台记的是上一次调用的整份 JSON；失败原因可能藏在 error 键里，也可能是整份信封。
    private static func failureText(_ raw: String) -> String {
        if let d = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d),
           let dd = obj as? [String: Any],
           let e = str(dd["error"]) {
            return e
        }
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 300 ? String(oneLine.prefix(300)) + "…" : oneLine
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - 调用

    private static func call(_ tool: String, _ params: [String: Any]) -> [String: Any] {
        let raw: [String: Any]
        do {
            raw = try ToolRegistry.shared.dispatch(name: tool, params: params)
        } catch {
            if let e = error as? MCPError { return ["error": e.description] }
            return ["error": "\(error)"]
        }
        var out: [String: Any] = (raw["data"] as? [String: Any]) ?? raw
        if (raw["ok"] as? Bool) == false, out["error"] == nil {
            out["error"] = (raw["message"] as? String) ?? (raw["code"] as? String) ?? "调用失败"
        }
        if let e = out["error"] as? [String: Any] {
            out["error"] = (e["reason"] as? String) ?? (e["message"] as? String) ?? (e["code"] as? String) ?? "调用失败"
        } else if out["error"] != nil, !(out["error"] is String) {
            out["error"] = String(describing: out["error"]!)
        }
        if let s = out["error"] as? String, s.isEmpty { out.removeValue(forKey: "error") }
        return out
    }

    // MARK: - 取值

    private static func str(_ v: Any?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        if let i = v as? Int { return String(i) }
        return nil
    }

    private static func intOf(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func dict(_ v: Any?) -> [String: Any]? {
        v as? [String: Any]
    }

    private static func dictRows(_ v: Any?) -> [[String: Any]] {
        (v as? [[String: Any]]) ?? []
    }

    private static func stringRows(_ v: Any?) -> [String]? {
        guard let a = v as? [Any] else { return nil }
        return a.compactMap { str($0) }
    }
}
