import Foundation

// MARK: - v10.1：批执行规划器（对齐 Minis / Codex 的「同一轮批量跑独立调用」）
//
// 背景：旧实现在 .toolCalls 源头把批次硬裁成 `prefix(1)`，一次模型往返只跑一个工具。
// 后果是模型明明一次看得很清楚（ls + cat + grep 三个独立的读），却要被拆成三轮往返：
// 每轮一次网络请求、一次完整上下文重发、一次解说。用户看到的就是「跑得慢、来回绕」。
//
// 这里不靠提示词，靠机制决定能跑几个：
//   · 读类（annotations.readOnly 且非破坏性）→ 按顺序全部纳入，最多 maxBatch 个；
//   · 改状态的调用 → 只纳入**第一个**，且纳入后立即截断——它后面那些调用可能是
//     依赖它的结果才决定的，合批执行等于让模型猜结果（旧注释里的违规点）；
//   · 同参重复的调用 → 去重（同一批里发两遍通常只是模型手滑）；
//   · 未知工具 → 当作改状态处理（拿不到注解就别猜，保险丝）。
//
// shell.exec / root 这类 shell 工具即使注解写着 readOnly，也要再看命令本身：
// 用保守白名单判定「整条命令都由只读命令组成」，含重定向或任何写命令一律按改状态算。

/// 一批调用的执行计划
struct ToolBatchPlan {
    /// 按原顺序真正要执行的调用（≥1，除非输入为空）
    let calls: [ToolCall]
    /// 本次没有执行、也不自动补执行的调用（要告诉模型它的个数）
    let dropped: [ToolCall]

    var isEmpty: Bool { calls.isEmpty }

    static func passThrough(_ calls: [ToolCall]) -> ToolBatchPlan {
        ToolBatchPlan(calls: calls, dropped: [])
    }
}

enum ToolBatchPlanner {

    /// 一轮最多执行的独立调用数。再多人也看不过来，且单批耗时线性叠加会顶到工具超时。
    static let maxBatch = 4

    /// 入口：把模型给的一批调用压成「本轮真正执行的序列」
    static func plan(_ calls: [ToolCall]) -> ToolBatchPlan {
        guard calls.count > 1 else { return .passThrough(calls) }

        var keep: [ToolCall] = []
        var seen = Set<String>()
        var reachedMutation = false

        for call in calls {
            if reachedMutation { break }
            if keep.count >= maxBatch { break }

            // 去重：同工具同参（忽略 reason/note 之类的噪声字段）
            let key = ToolLoopGuard.argsHash(tool: call.name, params: parseArgs(call.arguments))
            if seen.contains(key) { continue }
            seen.insert(key)

            keep.append(call)
            if isMutating(name: call.name, params: parseArgs(call.arguments)) {
                reachedMutation = true
            }
        }

        if keep.isEmpty { keep = [calls[0]] }

        let keepIds = Set(keep.map { $0.id })
        let dropped = calls.filter { !keepIds.contains($0.id) }
        return ToolBatchPlan(calls: keep, dropped: dropped)
    }

    // MARK: - 分类

    /// 这个调用会不会改变设备/文件/进程状态（true → 它是本批的最后一棒）
    static func isMutating(name: String, params: [String: Any]) -> Bool {
        let def = resolveDefinition(name)
        let command = (params["command"] as? String) ?? (params["action"] as? String)

        // shell 类工具：注解不可信（多数写成 readOnly:false 或干脆没声明），看命令本身
        if isShellTool(name), let cmd = command, !cmd.isEmpty {
            return !shellCommandIsReadOnly(cmd)
        }

        guard let d = def else {
            // 未注册的工具名：拿不到注解，按「可能改状态」处理，让它单独成批
            return true
        }
        let a = d.effectiveAnnotations(for: command)
        if a.destructive { return true }
        return !a.readOnly
    }

    private static func isShellTool(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == "shell.exec" || n == "shell_exec" || n == "root"
    }

    /// 按工具真实名或 api 安全名解析定义（模型返回的是 shell_exec，注册表里叫 shell.exec）
    private static func resolveDefinition(_ name: String) -> ToolDefinition? {
        if let t = ToolRegistry.shared.tool(named: name) { return t.definition }
        return ToolRegistry.shared.definitions.first { $0.apiName == name }
    }

    // MARK: - shell 命令的只读判定

    /// 段首命令必须全在表内才算只读。故意保守：漏判只是退化成串行，误判会真的改坏东西。
    private static let readOnlyCommands: Set<String> = [
        "ls", "cat", "head", "tail", "grep", "egrep", "fgrep", "rg",
        "find", "wc", "awk", "gawk", "uniq", "cut", "tr", "sort", "comm", "diff",
        "sed",          // 下面单独挡 -i
        "echo", "printf", "pwd", "id", "whoami", "uname", "hostname",
        "stat", "du", "df", "readlink", "realpath", "basename", "dirname", "file",
        "md5", "md5sum", "shasum", "sha256sum", "sha1sum", "cksum",
        "otool", "objdump", "nm", "class-dump", "class_dump", "strings", "hexdump",
        "plutil",       // 下面单独挡写操作参数
        "which", "type", "env", "printenv", "date", "uptime", "sw_vers",
        "base64", "xxd", "od", "less", "more", "jq", "otool64",
        "sqlite3",      // 下面单独挡非 SELECT
    ]

    /// 出现任何一个即视为写操作（宁可串行）
    private static let writeCommands: Set<String> = [
        "rm", "rmdir", "mv", "cp", "ln", "mkdir", "touch", "tee", "dd",
        "chmod", "chown", "chgrp", "chflags", "xattr",
        "kill", "killall", "launchctl", "systemctl", "respring", "sbreload",
        "ldid", "insert_dylib", "dpkg", "dpkg-deb", "apt", "apt-get", "apk", "pip", "pip3",
        "git", "curl", "wget", "ssh", "scp", "nc", "ncat",
        "install", "sync", "reboot", "shutdown", "sudo", "su", "nohup",
        "defaults", "plistbuddy", "plutil-write",
    ]

    /// 整条 shell 命令是否全部由只读命令组成
    static func shellCommandIsReadOnly(_ command: String) -> Bool {
        guard !command.isEmpty else { return false }

        // 先把常见的「无害重定向」去掉，避免 2>/dev/null 这类把只读命令误判成写
        var normalized = command
        for pat in ["2>&1", "1>&2", "2>/dev/null", "2> /dev/null", "&>/dev/null", "&> /dev/null",
                    ">/dev/null", "> /dev/null"] {
            normalized = normalized.replacingOccurrences(of: pat, with: " ")
        }
        // 剩下的任何重定向都算写（> >> <）
        if normalized.contains(">") || normalized.contains("<") { return false }

        let segments = normalized
            .replacingOccurrences(of: "\n", with: ";")
            .components(separatedBy: CharacterSet(charactersIn: ";&|"))

        var sawCommand = false
        for segment in segments {
            var tokens = segment
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }
            // 去掉 FOO=bar 这类前置环境变量赋值
            while let first = tokens.first, first.contains("="), !first.hasPrefix("-"),
                  !first.hasPrefix("/") {
                tokens.removeFirst()
            }
            guard let head = tokens.first else { continue }

            let base = (head as NSString).lastPathComponent.lowercased()
            if writeCommands.contains(base) { return false }
            if base == "sh" || base == "bash" || base == "zsh" || base == "sh-c" { return false }

            if base == "sed" {
                // sed -i / -i.bak / --in-place 都会改文件
                if tokens.contains(where: { $0 == "-i" || $0.hasPrefix("-i") || $0 == "--in-place" }) {
                    return false
                }
            }
            if base == "plutil" {
                let writing = ["-replace", "-insert", "-remove", "-convert", "-set", "-add"]
                if tokens.contains(where: { writing.contains($0) }) { return false }
            }
            if base == "sqlite3" {
                // 只放行明显是查询的语句
                let lower = tokens.joined(separator: " ").lowercased()
                let isQuery = lower.contains(" select ") || lower.hasSuffix(" select")
                    || lower.contains("\"select") || lower.contains("'select")
                    || lower.contains("pragma") || lower.contains(".tables")
                    || lower.contains("insert") || lower.contains("update") || lower.contains("delete")
                if lower.contains("insert") || lower.contains("update")
                    || lower.contains("delete") || lower.contains("drop") || lower.contains("create") {
                    return false
                }
                if !isQuery { return false }
            }

            if !readOnlyCommands.contains(base) { return false }
            sawCommand = true
        }
        return sawCommand
    }

    // MARK: - 参数

    private static func parseArgs(_ raw: String) -> [String: Any] {
        guard let d = raw.data(using: .utf8), !d.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
}
