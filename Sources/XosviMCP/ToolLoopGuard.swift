// ToolLoopGuard.swift — 工具循环守卫（v9.2）
//
// 背景：会话会「卡在工具执行阶段不动」——进程活着（wakeups 飙升、EXC_GUARD/LIBXPC），
// 但会话不推进、请求没到 xosvid。旧实现只有「同参数 + 同错误文本」的失败熔断，
// 对下面两类完全无感：
//   1. 工具不返回（阻塞在 XPC / 子进程 / 网络）—— 一次都不返回，失败计数永远不涨；
//   2. 工具反复成功但返回同一份结果（原地踏步）—— 成功路径刻意不熔断（v6.9.0）。
//
// 本文件补的是「能不能走出来」这一层，按 OpenMinis ToolLoopDetector 的思路实现：
//   - argsHash  ：工具名 + 稳定序列化参数（递归排序键、剔除 UI 噪声字段）
//   - resultHash：结果稳定序列化后 **先 stripVolatile**（抹掉时间戳/耗时/调用计数/缓存年龄），
//                 让真正相同的产出坍缩成同一个 hash —— 这是 no-progress 判据成立的前提。
//                 若不清 `_call_count`（每次递增），hash 永远变化，检测形同虚设。
//   - 四级策略：unknown_tool 连击 / no-progress 连击 / 轮询工具双阈值 / generic_repeat
//   - 阻断方式是**注入结果**（返回 [LOOP BLOCKED] 给模型），不是抛异常 ——
//     抛异常会走失败熔断，而失败熔断只对「同参数同错误」生效，且会让会话停在这里。
//   - 告警按桶节流：同一档位只提示一次，避免把每次重试都灌进上下文。

import Foundation
import CryptoKit

// MARK: - 工具结果闩（v9.2）
//
// 一个工具调用只有一次「定局」机会：要么工具自己返回（settle），要么看门狗到点（expire）。
// 卡住的线程无法被 Swift 强行终止，但只要 run 不再等它，会话就能往下走——
// 这就是「工具永不返回也不会把整轮卡死」的实现要点。

final class ToolResultLatch {
    static let shared = ToolResultLatch()
    private init() {}

    private enum State { case pending, settled, expired }
    private let lock = NSLock()
    private var states: [String: State] = [:]

    /// 工具自己返回时调用。已经超时过的调用直接丢弃（避免同一调用收尾两次）。
    func settle(callId: String, _ body: () -> Void) {
        lock.lock()
        let s = states[callId]
        if s == .expired {
            states.removeValue(forKey: callId)
            lock.unlock()
            return
        }
        states[callId] = .settled
        lock.unlock()
        body()
        lock.lock(); states.removeValue(forKey: callId); lock.unlock()
    }

    /// 看门狗到点时调用。返回 true 表示这次超时由它定局，调用方可以按超时收尾。
    func expire(callId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch states[callId] {
        case .none, .expired:
            return false
        case .settled:
            states.removeValue(forKey: callId)
            return false
        case .pending:
            states[callId] = .expired
            return true
        }
    }

    /// 注册一个待定局调用（缺省即为 pending，这里留显式接口便于阅读）
    func begin(callId: String) {
        lock.lock(); states[callId] = .pending; lock.unlock()
    }

    /// run 结束时清空残留
    func reset() {
        lock.lock(); states.removeAll(keepingCapacity: true); lock.unlock()
    }
}

final class ToolLoopGuard {
    static let shared = ToolLoopGuard()
    private init() {}

    // MARK: - 阈值（集中定义，便于真机调参）

    /// 历史窗口条数
    private let historyLimit = 40
    /// 同参同结果连续多少次 → 警告
    private let noProgressWarn = 2
    /// 同参同结果连续多少次 → 阻断
    private let noProgressBlock = 4
    /// 同参（结果不同）连续多少次 → 警告
    private let repeatWarn = 4
    /// 同参（结果不同）连续多少次 → 阻断
    private let repeatBlock = 8
    /// 不存在的工具连续多少次 → 阻断
    private let unknownToolBlock = 3
    /// 轮询类工具：同参同结果连续多少次 → 警告 / 阻断
    private let pollWarn = 6
    private let pollBlock = 12
    /// 全局熔断：历史窗口内同参记录总数
    private let globalCircuit = 24

    // MARK: - 记录

    private struct Record {
        let tool: String
        let argsHash: String
        let resultHash: String?
        let isError: Bool
        let unknownTool: Bool
        let poll: Bool
        let ts: Date
    }

    /// 判定结果
    enum Level: Equatable {
        case allow
        case warn
        case block
        case circuit
    }

    struct Outcome {
        let level: Level
        let policy: String
        let message: String
        var blocked: Bool { level == .block || level == .circuit }
    }

    private let lock = NSLock()
    private var history: [Record] = []
    /// 告警节流：key = "policy@tool"，value = 已提示到的档位
    private var warnedAt: [String: Int] = [:]

    // MARK: - 执行前检查

    /// 在真正执行工具之前调用。返回 .block / .circuit 时调用方应**短路执行**，
    /// 把 message 当作该工具的结果喂回模型。
    func check(tool: String, params: [String: Any]) -> Outcome {
        let ah = Self.argsHash(tool: tool, params: params)
        let poll = Self.isPollTool(tool: tool, params: params)
        lock.lock()
        let (noProgress, sameArgs) = Self.streaks(history, tool: tool, argsHash: ah)
        let unknownRun = Self.unknownStreak(history: history, tool: tool)
        let globalSameArgs = history.filter { $0.argsHash == ah }.count
        lock.unlock()

        // 策略 1：反复调用不存在的工具（模型拼错名，或照抄了未启用的历史工具）
        if unknownRun >= unknownToolBlock {
            return Outcome(level: .block, policy: "unknown_tool_repeat", message: Self.blockMessage(
                tool: tool, policy: "unknown_tool_repeat", count: unknownRun,
                detail: "连续 \(unknownRun) 次调用了不存在的工具。该工具名不在当前注册表内，重试同一个名字必然得到同样的 unknownTool；"
                    + "先 system.overview 或 tools/list 确认真实工具名（子命令是 command:/action: 参数，不是工具名）。"))
        }

        // 策略 3：轮询类工具（状态/进度查询）本来就该重复调用，用更高的双阈值
        if poll {
            if noProgress >= pollBlock {
                return Outcome(level: .block, policy: "known_poll_no_progress", message: Self.blockMessage(
                    tool: tool, policy: "known_poll_no_progress", count: noProgress,
                    detail: "轮询类工具连续 \(noProgress) 次拿到完全相同的结果，目标状态没有变化。继续轮询不会改变结论："
                        + "要么先执行推动状态的动作，要么按当前状态给出结论。"))
            }
            if noProgress >= pollWarn {
                return Outcome(level: .warn, policy: "known_poll_no_progress", message: Self.warnMessage(
                    tool: tool, count: noProgress,
                    detail: "轮询结果一直没有变化（连续 \(noProgress) 次）。如果是在等某个状态就绪，先确认推动它的那一步真的成功了。"))
            }
            return Outcome(level: .allow, policy: "known_poll", message: "")
        }

        // 策略 2：同参同结果原地踏步（最典型的「卡住」形态）
        if noProgress >= noProgressBlock {
            return Outcome(level: .block, policy: "no_progress", message: Self.blockMessage(
                tool: tool, policy: "no_progress", count: noProgress,
                detail: "同样参数已连续 \(noProgress) 次拿到完全相同的结果，这一步没有产生任何新信息。"
                    + "不要再用同样参数调用它：换参数、换工具，或基于已有结果直接给出结论。"))
        }
        if noProgress >= noProgressWarn, throttle(key: "no_progress@\(tool)", level: noProgress) {
            return Outcome(level: .warn, policy: "no_progress", message: Self.warnMessage(
                tool: tool, count: noProgress,
                detail: "这次的结果和上一次完全相同。如果再一次还是同样的结果，就别再重复这一步。"))
        }

        // 策略 4：同参但结果在变（说明在推进，只轻提示）
        if sameArgs >= repeatBlock {
            return Outcome(level: .block, policy: "generic_repeat", message: Self.blockMessage(
                tool: tool, policy: "generic_repeat", count: sameArgs,
                detail: "同样参数已累计调用 \(sameArgs) 次。参数没变说明你的假设没变，结果也不会变："
                    + "停下来，把已经拿到的信息整理成结论，或换一个真正能推进的动作。"))
        }
        if sameArgs >= repeatWarn,
           throttle(key: "generic_repeat@\(tool)", level: sameArgs / repeatWarn) {
            return Outcome(level: .warn, policy: "generic_repeat", message: Self.warnMessage(
                tool: tool, count: sameArgs,
                detail: "同一调用已重复 \(sameArgs) 次。确认这几次之间确实有区别，否则换一步。"))
        }

        // 策略 5：窗口内同参总量上限（兜底全局熔断）
        if globalSameArgs >= globalCircuit {
            return Outcome(level: .circuit, policy: "global_circuit_breaker", message: Self.blockMessage(
                tool: tool, policy: "global_circuit_breaker", count: globalSameArgs,
                detail: "这条调用在本轮已经执行了 \(globalSameArgs) 次，触发全局熔断。本轮到此为止："
                    + "向用户汇报已经查到什么、卡在哪里。"))
        }

        return Outcome(level: .allow, policy: "allow", message: "")
    }

    // MARK: - 执行后记录

    /// 在工具返回（或抛出）之后调用，回填 resultHash。
    func record(tool: String, params: [String: Any], result: [String: Any]?, error: String?) {
        let ah = Self.argsHash(tool: tool, params: params)
        let rh: String?
        if let result = result {
            rh = Self.resultHash(result)
        } else if let error = error {
            rh = "err:" + Self.hash(Self.stripVolatileText(error))
        } else {
            rh = nil
        }
        push(Record(tool: tool, argsHash: ah, resultHash: rh, isError: error != nil,
                    unknownTool: false, poll: Self.isPollTool(tool: tool, params: params), ts: Date()))
    }

    /// 记录一次「工具名不存在」——它不会进入 dispatchCore，但必须参与连击判定。
    func recordUnknownTool(tool: String, params: [String: Any]) {
        let ah = Self.argsHash(tool: tool, params: params)
        push(Record(tool: tool, argsHash: ah, resultHash: "err:unknownTool", isError: true,
                    unknownTool: true, poll: false, ts: Date()))
    }

    /// 一次 run 结束（或用户点停止）时清空，避免跨 run 误判
    func reset() {
        lock.lock(); history.removeAll(keepingCapacity: true); warnedAt.removeAll(); lock.unlock()
    }

    // MARK: - 内部

    private func push(_ r: Record) {
        lock.lock()
        history.append(r)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        lock.unlock()
    }

    /// 告警节流：同一档位只提示一次。返回 false 表示这一档已经提示过。
    private func throttle(key: String, level: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let prev = warnedAt[key] ?? 0
        if level <= prev { return false }
        warnedAt[key] = level
        return true
    }

    /// 尾部倒着数：同 tool + 同 argsHash 的连续记录里，resultHash 是否恒等。
    /// 返回 (no-progress 连击数, 同参总连击数)。resultHash 一变就停 —— 这是「是否真的原地踏步」的判据。
    private static func streaks(_ history: [Record], tool: String, argsHash: String) -> (Int, Int) {
        var sameArgs = 0
        var noProgress = 0
        var firstResultHash: String? = nil
        for rec in history.reversed() {
            guard rec.tool == tool, rec.argsHash == argsHash else { break }
            sameArgs += 1
            // 没有 resultHash 的记录（例如超时未定局）无法参与「结果是否相同」的判定，
            // 它本身也要中断 no-progress 连击——否则会跨过一条未知结果继续数，误判为原地踏步。
            guard let rh = rec.resultHash else { break }
            if let f = firstResultHash {
                guard rh == f else { break }
            } else {
                firstResultHash = rh
            }
            noProgress += 1
        }
        return (noProgress, sameArgs)
    }

    /// 尾部倒着数：连续多少次 unknownTool
    private static func unknownStreak(history: [Record], tool: String) -> Int {
        var n = 0
        for rec in history.reversed() {
            guard rec.tool == tool, rec.unknownTool else { break }
            n += 1
        }
        return n
    }

    /// 轮询类工具：状态查询 / 进度查询 / 日志轮询。这类重复调用是合理的，阈值要放宽。
    private static func isPollTool(tool: String, params: [String: Any]) -> Bool {
        let cmd = ((params["command"] as? String) ?? (params["action"] as? String) ?? "").lowercased()
        if cmd == "status" || cmd == "poll" || cmd == "log" || cmd == "logs" || cmd == "tail" {
            return true
        }
        let n = tool.lowercased()
        return n.hasSuffix(".status") || n.hasSuffix(".info") || n.hasSuffix(".probe")
            || n == "system.overview" || n == "tools.audit"
    }

    private static func blockMessage(tool: String, policy: String, count: Int, detail: String) -> String {
        "[LOOP BLOCKED] \(tool) 已被循环守卫阻断（策略 \(policy)，计数 \(count)）。\n"
            + detail + "\n"
            + "这一步没有被执行，也不会计入失败次数。请直接基于已有结果推进，或换一种做法。"
    }

    private static func warnMessage(tool: String, count: Int, detail: String) -> String {
        "[LOOP WARNING] \(tool)：\(detail)（计数 \(count)）"
    }

    // MARK: - 稳定 hash

    /// argsHash：工具名 + 稳定序列化参数。剔除模型会随手加后缀的 UI 噪声字段
    /// （如 tool_title 的 "#1/#2"），否则同一次逻辑调用会被当成不同调用。
    static func argsHash(tool: String, params: [String: Any]) -> String {
        let noise: Set<String> = ["tool_title", "title", "_comment", "_note", "note", "reason", "thought", "narration"]
        var clean: [String: Any] = [:]
        for (k, v) in params where !noise.contains(k) {
            clean[k] = v
        }
        return hash(tool + "|" + stableJSON(clean))
    }

    /// resultHash：先 stripVolatile，再稳定序列化，再 hash。
    /// 剔字段的理由：这些每次都会变，留着会让「相同产出」永远 hash 不同，
    /// no-progress 检测就完全失效。
    static func resultHash(_ result: [String: Any]) -> String {
        let cleaned = stripVolatileDict(result)
        return "res:" + hash(stableJSON(cleaned))
    }

    /// 只剔「纯计量/元数据」字段。**绝不能剔 id / pid / name / path / status 这类内容字段**——
    /// 进程列表、查询结果的主体就是它们，剔掉会让「不同结果」坍缩成同一个 hash，
    /// no-progress 判定立刻退化成误杀。
    private static let volatileKeys: Set<String> = [
        "ts", "timestamp", "time", "now", "epoch", "date", "started_at", "finished_at",
        "elapsed", "elapsed_ms", "elapsedMs", "duration", "durationMs", "duration_ms", "took", "cost",
        "request_id", "call_id", "trace_id", "uptime", "rss", "wakeups",
        "_call_count", "_cache_hits", "_cached_age_seconds", "_cached", "_cached_note",
        "_run_tool_calls", "_slow", "_slow_note", "_call",
    ]

    private static func stripVolatileDict(_ d: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in d where !volatileKeys.contains(k) {
            out[k] = stripVolatile(v)
        }
        return out
    }

    private static func stripVolatile(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return stripVolatileDict(d) }
        if let a = v as? [[String: Any]] { return a.map { stripVolatileDict($0) } }
        if let a = v as? [Any] { return a.map { stripVolatile($0) } }
        if let s = v as? String { return stripVolatileText(s) }
        return v
    }

    /// 抹掉文本里的易变片段：ISO 时间、形如 1234ms 的耗时、纯数字 id 串
    static func stripVolatileText(_ s: String) -> String {
        var t = s
        let patterns: [(String, String)] = [
            ("\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?Z?", "<ts>"),
            ("\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}", "<ts>"),
            ("\\b\\d+(\\.\\d+)?\\s?(ms|us|s|秒|毫秒)\\b", "<dur>"),
            ("\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b", "<uuid>"),
        ]
        for (p, r) in patterns {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return t
    }

    /// 稳定序列化：字典递归按键排序，数组保持顺序。避免 Dictionary 无序导致同内容不同 hash。
    static func stableJSON(_ v: Any) -> String {
        switch v {
        case let d as [String: Any]:
            let inner = d.keys.sorted().map { "\(quote($0)):\(stableJSON(d[$0]!))" }
            return "{" + inner.joined(separator: ",") + "}"
        case let a as [Any]:
            return "[" + a.map { stableJSON($0) }.joined(separator: ",") + "]"
        case let s as String:
            return quote(s)
        case let b as Bool:
            return b ? "true" : "false"
        case let n as NSNumber:
            return n.stringValue
        case let n as Int:
            return String(n)
        case let n as Double:
            return String(n)
        case is NSNull:
            return "null"
        case let o as Optional<Any> where o == nil:
            return "null"
        case let other:
            return quote("\(other)")
        }
    }

    private static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"" + escaped + "\""
    }

    private static func hash(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        // 12 字节足够区分，短一些便于日志阅读
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
