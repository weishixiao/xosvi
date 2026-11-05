import Foundation
import UIKit

// MARK: - v7.5.0 工作区（移植自 Kelivo 的 workspace 能力）
//
// Kelivo 的工作区 = 「给模型一个能真正干活的地方」：绑定后模型可以 shell / 读 / 写 / 改 / 列 / 匹配 / 搜索。
// 它的 iOS 端跑在 iSH Linux 沙盒里；本项目的 iSH 已经因为 arm64 段错误被移除，
// 所以这里改成**纯原生实现**——同样的八个工具，跑在 App 自己的沙盒里，不依赖任何 Linux 运行时。
//
// 八个工具（与 Kelivo 对齐）：
//   shell       执行命令（走内置原生 busybox / 内置工具链）
//   read_file   读文件（带行号，支持 offset/limit）
//   write_file  写文件（自动建目录）
//   edit_file   精确替换（old → new，必须唯一命中，防止改错地方）
//   list_dir    列目录
//   glob        按通配符找文件
//   grep        按正则搜内容
//   view_image  把图片返回给模型看
//
// 安全边界（Kelivo 也是这么做的）：
//   · 默认只允许在工作区目录内读写
//   · 越界访问需要「完全访问」开关（设置 → 工作区）
//   · shell 默认拒绝明显破坏性命令（rm -rf /、chmod -R 777 / 之类）

final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private let enabledKey = "workspace.enabled"
    private let fullAccessKey = "workspace.fullAccess"

    /// 当前会话绑定的工作区（nil = 用默认 Workspace 目录）
    var boundRoot: String? = UserDefaults.standard.string(forKey: "workspace.boundRoot")

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 「完全访问」——允许读写工作区之外的路径、执行桌面级命令
    /// v7.16.11：按用户要求默认开启（原来是 bool(forKey:) → 未设置时默认 false）。
    /// 用 object(forKey:) 区分「用户手动关过」和「从没设置过」，后者给 true。
    var fullAccess: Bool {
        get {
            if let v = UserDefaults.standard.object(forKey: fullAccessKey) as? Bool { return v }
            return true
        }
        set { UserDefaults.standard.set(newValue, forKey: fullAccessKey) }
    }

    var root: String {
        if let b = boundRoot, !b.isEmpty, FileManager.default.fileExists(atPath: b) { return b }
        return Workspace.root.path
    }

    func bind(_ path: String?) {
        boundRoot = path
        UserDefaults.standard.set(path ?? "", forKey: "workspace.boundRoot")
    }

    /// 路径归一化：相对路径按工作区解析，绝对路径按原样
    func resolve(_ raw: String) -> String {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return root }
        if p.hasPrefix("/") { return p }
        return (root as NSString).appendingPathComponent(p)
    }

    /// 是否在工作区内
    func isInsideRoot(_ path: String) -> Bool {
        let r = (root as NSString).standardizingPath
        let p = (path as NSString).standardizingPath
        return p == r || p.hasPrefix(r + "/")
    }

    /// 越界检查（fullAccess 打开时放行）
    func guardPath(_ path: String) throws -> String {
        let p = resolve(path)
        if !fullAccess && !isInsideRoot(p) {
            throw MCPError.failed("""
            路径在工作区之外：\(p)
            当前工作区：\(root)
            如需访问工作区外的文件，请在 设置 → 工作区 打开「完全访问」。
            """)
        }
        return p
    }
}

// MARK: - 工具实现

enum WorkspaceTools {

    // MARK: shell

    static func shell(_ params: [String: Any]) throws -> [String: Any] {
        guard let cmd = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cmd.isEmpty else {
            throw MCPError.invalidParams("command required")
        }
        if !WorkspaceStore.shared.fullAccess, isDestructive(cmd) {
            throw MCPError.failed("命令看起来会破坏系统（\(cmd.prefix(60))…）。当前未开启「完全访问」，已拒绝执行。")
        }
        let timeout = min(max(params["timeout"] as? Double ?? 30, 1), 300)
        // 复用现有 shell 执行器（原生 busybox / 内置工具链），不再走已移除的 Alpine
        let r = try ShellExecTool().invoke(["command": cmd, "timeout": timeout])
        var out = r
        out["cwd"] = WorkspaceStore.shared.root
        return out
    }

    private static func isDestructive(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        let bad = ["rm -rf /", "rm -fr /", "mkfs", "dd if=", ":(){", "chmod -r 777 /", "> /dev/disk"]
        return bad.contains { c.contains($0) }
    }

    // MARK: read_file

    static func readFile(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["path"] as? String else { throw MCPError.invalidParams("path required") }
        let p = try WorkspaceStore.shared.guardPath(raw)
        guard FileManager.default.fileExists(atPath: p) else {
            throw MCPError.failed("文件不存在：\(p)")
        }
        let offset = max(params["offset"] as? Int ?? 1, 1)
        let limit = min(max(params["limit"] as? Int ?? 2000, 1), 20000)

        // 二进制保护
        if let head = try? Data(contentsOf: URL(fileURLWithPath: p), options: .mappedIfSafe).prefix(512),
           head.contains(0) {
            let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? -1
            return ["path": p, "binary": true, "size": size,
                    "hint": "这是二进制文件，读文本没意义。要分析用 file / disasm / macho 工具，或 view_image 看图片。"]
        }
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else {
            throw MCPError.failed("无法按 UTF-8 读取：\(p)")
        }
        let lines = text.components(separatedBy: "\n")
        let start = min(offset - 1, max(lines.count - 1, 0))
        let end = min(start + limit, lines.count)
        let slice = lines[start..<end].enumerated()
            .map { "\(start + $0.offset + 1)\t\($0.element)" }
            .joined(separator: "\n")
        return ["path": p, "total_lines": lines.count,
                "from": start + 1, "to": end,
                "content": slice]
    }

    // MARK: write_file

    static func writeFile(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["path"] as? String else { throw MCPError.invalidParams("path required") }
        guard let content = params["content"] as? String else { throw MCPError.invalidParams("content required") }
        let p = try WorkspaceStore.shared.guardPath(raw)
        let dir = (p as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: p)
        do {
            try content.write(toFile: p, atomically: true, encoding: .utf8)
        } catch {
            throw MCPError.failed("写入失败：\(error.localizedDescription)")
        }
        return ["ok": true, "path": p, "bytes": content.utf8.count,
                "action": existed ? "overwritten" : "created"]
    }

    // MARK: edit_file

    static func editFile(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["path"] as? String else { throw MCPError.invalidParams("path required") }
        guard let old = params["old"] as? String, !old.isEmpty else { throw MCPError.invalidParams("old required") }
        guard let new = params["new"] as? String else { throw MCPError.invalidParams("new required") }
        let p = try WorkspaceStore.shared.guardPath(raw)
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else {
            throw MCPError.failed("读不到文件：\(p)")
        }
        let hits = text.components(separatedBy: old).count - 1
        if hits == 0 { throw MCPError.failed("old 内容没有出现在文件里，未做任何修改") }
        if hits > 1 {
            throw MCPError.failed("old 内容出现 \(hits) 次，不唯一。请带上更多上下文让它唯一，避免改错位置。")
        }
        let updated = text.replacingOccurrences(of: old, with: new)
        try updated.write(toFile: p, atomically: true, encoding: .utf8)
        // 返回改动摘要（Kelivo 用 diff 呈现，这里给行级摘要）
        let oldLines = text.components(separatedBy: "\n").count
        let newLines = updated.components(separatedBy: "\n").count
        return ["ok": true, "path": p,
                "removed_lines": max(oldLines - newLines, 0),
                "added_lines": max(newLines - oldLines, 0),
                "hint": "已精确替换 1 处"]
    }

    // MARK: list_dir

    static func listDir(_ params: [String: Any]) throws -> [String: Any] {
        let raw = params["path"] as? String ?? "."
        let p = try WorkspaceStore.shared.guardPath(raw)
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: p) else {
            throw MCPError.failed("不是目录或无法读取：\(p)")
        }
        var rows: [[String: Any]] = []
        for name in items.sorted() {
            let full = (p as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: full, isDirectory: &isDir)
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
            rows.append(["name": name, "dir": isDir.boolValue, "size": size])
        }
        return ["path": p, "count": rows.count, "items": rows]
    }

    // MARK: glob

    static func glob(_ params: [String: Any]) throws -> [String: Any] {
        guard let pattern = params["pattern"] as? String, !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern required（如 **/*.swift）")
        }
        let base = params["path"] as? String ?? "."
        let root = try WorkspaceStore.shared.guardPath(base)
        let limit = min(max(params["limit"] as? Int ?? 200, 1), 2000)
        let regex = try NSRegularExpression(pattern: Self.globToRegex(pattern))

        var out: [String] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else {
            throw MCPError.failed("无法遍历：\(root)")
        }
        for case let rel as String in en {
            if out.count >= limit { break }
            let full = (root as NSString).appendingPathComponent(rel)
            let range = NSRange(rel.startIndex..<rel.endIndex, in: rel)
            if regex.firstMatch(in: rel, range: range) != nil {
                out.append(full)
            }
        }
        return ["pattern": pattern, "root": root, "count": out.count, "files": out]
    }

    private static func globToRegex(_ glob: String) -> String {
        var r = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            if c == "*" {
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    r += ".*"
                    i = glob.index(after: next)
                    if i < glob.endIndex, glob[i] == "/" { i = glob.index(after: i) }
                    continue
                } else {
                    r += "[^/]*"
                }
            } else if c == "?" {
                r += "[^/]"
            } else if "\\.[]{}()+-^$|".contains(c) {
                r += "\\\(c)"
            } else {
                r += String(c)
            }
            i = glob.index(after: i)
        }
        return r + "$"
    }

    // MARK: grep

    static func grep(_ params: [String: Any]) throws -> [String: Any] {
        guard let pattern = params["pattern"] as? String, !pattern.isEmpty else {
            throw MCPError.invalidParams("pattern required（正则）")
        }
        let base = params["path"] as? String ?? "."
        let root = try WorkspaceStore.shared.guardPath(base)
        let limit = min(max(params["limit"] as? Int ?? 200, 1), 2000)
        let caseInsensitive = params["ignore_case"] as? Bool ?? false
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else {
            throw MCPError.invalidParams("正则语法有误：\(pattern)")
        }

        var results: [[String: Any]] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else {
            throw MCPError.failed("无法遍历：\(root)")
        }
        for case let rel as String in en {
            if results.count >= limit { break }
            let full = (root as NSString).appendingPathComponent(rel)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            let size = (try? fm.attributesOfItem(atPath: full)[.size] as? Int) ?? 0
            if size > 2_000_000 { continue }   // 跳过超大文件
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            for (idx, line) in text.components(separatedBy: "\n").enumerated() {
                if results.count >= limit { break }
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    results.append(["file": full, "line": idx + 1, "text": String(line.prefix(300))])
                }
            }
        }
        return ["pattern": pattern, "root": root, "count": results.count, "matches": results]
    }

    // MARK: view_image

    static func viewImage(_ params: [String: Any]) throws -> [String: Any] {
        guard let raw = params["path"] as? String else { throw MCPError.invalidParams("path required") }
        let p = try WorkspaceStore.shared.guardPath(raw)
        guard let data = FileManager.default.contents(atPath: p) else {
            throw MCPError.failed("读不到图片：\(p)")
        }
        if data.count > 8 * 1024 * 1024 {
            throw MCPError.failed("图片太大（\(data.count / 1024)KB），超过 8MB。先压缩再读。")
        }
        guard let img = UIImage(data: data) else {
            throw MCPError.failed("不是可识别的图片格式：\(p)")
        }
        let mime = p.lowercased().hasSuffix(".png") ? "image/png"
                 : p.lowercased().hasSuffix(".gif") ? "image/gif"
                 : p.lowercased().hasSuffix(".webp") ? "image/webp" : "image/jpeg"
        let b64 = data.base64EncodedString()
        return ["path": p,
                "width": Int(img.size.width),
                "height": Int(img.size.height),
                "bytes": data.count,
                "data_url": "data:\(mime);base64,\(b64)",
                "hint": "把 data_url 原样带给支持视觉的模型即可看图"]
    }
}

// MARK: - MCP 工具壳

final class WorkspaceExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "workspace",
        summary: """
        工作区：给模型一个能真正干活的地方（对应 Kelivo 的 workspace）。绑定的目录里可以执行命令、读写文件。
        子命令：shell / read_file / write_file / edit_file / list_dir / glob / grep / view_image
        Use for: 在项目目录里读代码、改文件、跑命令、批量找文件、搜内容。
        Don't use for: 读 App 沙盒外的系统文件（除非开「完全访问」）、联网检索（用 web.search）。
        Example: 用户说"把 README 里的端口改成 8080" → workspace {command:'read_file'} 看内容 → {command:'edit_file', old:'8000', new:'8080'}。
        """,
        parameters: [
            "command": "shell / read_file / write_file / edit_file / list_dir / glob / grep / view_image",
            "path": "文件或目录路径（相对工作区，或绝对路径）",
            "command_text": "For shell：要执行的命令",
            "content": "For write_file：文件内容",
            "old": "For edit_file：要被替换的原文（必须唯一）",
            "new": "For edit_file：替换成的内容",
            "pattern": "For glob/grep：通配符（**/*.swift）或正则",
            "offset": "For read_file：起始行（默认 1）",
            "limit": "For read_file/glob/grep：数量上限",
            "timeout": "For shell：超时秒数（默认 30）"
        ],
        returns: ["ok": "是否成功", "path": "实际路径", "content": "读到的内容", "count": "数量"],
        verified: true, category: "filesystem",
        uiSummary: "工作区：命令执行 + 文件读写查找"
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let cmd = (params["command"] as? String)?.lowercased(), !cmd.isEmpty else {
            throw MCPError.invalidParams("command required: shell / read_file / write_file / edit_file / list_dir / glob / grep / view_image")
        }
        AuditLog.shared.log("workspace", detail: "\(cmd) \(params["path"] as? String ?? "")")

        // shell 的参数名与其它工具冲突，单独映射
        var p = params
        if let t = params["command_text"] as? String, params["command"] as? String != nil {
            p["command"] = t
        }
        switch cmd {
        case "shell":      return try WorkspaceTools.shell(p)
        case "read_file":  return try WorkspaceTools.readFile(p)
        case "write_file": return try WorkspaceTools.writeFile(p)
        case "edit_file":  return try WorkspaceTools.editFile(p)
        case "list_dir":   return try WorkspaceTools.listDir(p)
        case "glob":       return try WorkspaceTools.glob(p)
        case "grep":
            return ExternalContent.flagRows(try WorkspaceTools.grep(p), key: "matches", fields: ["text"])
        case "view_image": return try WorkspaceTools.viewImage(p)
        default:
            throw MCPError.invalidParams("未知子命令：\(cmd)")
        }
    }
}
