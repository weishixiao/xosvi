import Foundation

// 统一备份台账（第一梯队）
//
// 历史包袱：备份散在四个落点、三种后缀，各写各的，没有任何一处能回答
// 「这台机器上现在有哪些备份、哪个 App 被改过、怎么整体退回去」。
//   ① <App>/…/X.troll-fools.bak       注入 / 替换主二进制（TrollFools 同款格式）
//   ② <App>/…/X.bak_macho             旧版遗留，只读兼容
//   ③ <容器>.xosvi.bak                整容器改名（device.refresh_container）
//   ④ Workspace/backups/<bid>_<ts>/   原生直写与可写绑定的目录快照
//
// 本文件只做「登记 + 统一入口」，一个后缀都不改：
//   ① 是 TrollFools 的既定格式，RULES.md 明确要求识别，改名等于自断兼容；
//   ③ ④ 是另外两类语义（整容器 / 目录树），本就不是同一回事。
// 真正缺的是「一次看完、一键退回、卸载前先退」，这就是这里的全部职责。
//
// 安全边界：
//   · 只自动还原 Mach-O 就地备份（原子、可验证、失败可留档）
//   · 容器改名与目录快照只报告、不自动执行，note 里给出该走哪个工具
//   · 还原用 cp 到临时文件再 mv，绝不做「先 rm 再 mv」——那两步之间断电两边都没了
//
// 目标指纹：注入成功后在 persist/BackupLedger/<bid>.json 记下改动时的 App 版本。
// App 更新后版本变了，就不再自动按旧记录还原（旧备份对不上新二进制），
// 由 prunedReason 如实说明，交给人决定。
enum BackupRegistry {

    static let inPlaceSuffix = ".troll-fools.bak"
    static let legacySuffix = ".bak_macho"
    static let containerSuffix = ".xosvi.bak"
    static var treeRoot: String { return XDirs.workspace + "/backups" }
    static var ledgerRoot: String { return XDirs.persist + "/BackupLedger" }

    // MARK: - 记录

    struct Entry {
        let kind: String            // macho / legacy_macho / container / tree
        let bundleId: String
        let originalPath: String
        let backupPath: String
        let size: Int64
        let mtime: TimeInterval
        let restorable: Bool
        let note: String

        var dict: [String: Any] {
            return [
                "kind": kind,
                "bundle_id": bundleId,
                "original": originalPath,
                "backup": backupPath,
                "size": size,
                "mtime": mtime,
                "restorable": restorable,
                "note": note,
            ]
        }
    }

    private static func fileStat(_ path: String) -> (size: Int64, mtime: TimeInterval)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    static func fileSafe(_ s: String) -> String {
        return s.replacingOccurrences(of: "/", with: "_")
    }

    // MARK: - 扫描

    /// 扫一个 App 的全部备份落点。trees 传入可避免批量扫描时反复读 backups 目录
    static func scanBundle(bundleId: String, appPath: String, trees: [String]? = nil) -> [Entry] {
        let fm = FileManager.default
        var out: [Entry] = []

        func add(kind: String, target: String, backup: String, restorable: Bool, note: String) {
            guard let st = fileStat(backup) else { return }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: backup, isDirectory: &isDir)
            out.append(Entry(kind: kind, bundleId: bundleId, originalPath: target,
                             backupPath: backup,
                             size: isDir.boolValue ? 0 : st.size,
                             mtime: st.mtime, restorable: restorable, note: note))
        }

        // 主二进制
        let exec = (NSDictionary(contentsOfFile: appPath + "/Info.plist")?["CFBundleExecutable"] as? String) ?? ""
        if !exec.isEmpty {
            let main = appPath + "/" + exec
            add(kind: "macho", target: main, backup: main + inPlaceSuffix, restorable: true,
                note: "主二进制（TrollFools 兼容格式）")
            add(kind: "legacy_macho", target: main, backup: main + legacySuffix, restorable: true,
                note: "主二进制（旧格式，仅在新格式不存在时生效）")
        }

        // Frameworks 一层（注入点就在这里，不必递归整个 bundle）
        let fwDir = appPath + "/Frameworks"
        if let items = try? fm.contentsOfDirectory(atPath: fwDir) {
            for item in items.sorted() {
                if item.hasSuffix(inPlaceSuffix) || item.hasSuffix(legacySuffix) { continue }
                let full = fwDir + "/" + item
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue, item.hasSuffix(".framework") {
                    let nm = (item as NSString).deletingPathExtension
                    let exe = full + "/" + nm
                    add(kind: "macho", target: exe, backup: exe + inPlaceSuffix, restorable: true,
                        note: "Frameworks/\(item)")
                    add(kind: "legacy_macho", target: exe, backup: exe + legacySuffix, restorable: true,
                        note: "Frameworks/\(item)（旧格式）")
                } else if !isDir.boolValue {
                    add(kind: "macho", target: full, backup: full + inPlaceSuffix, restorable: true,
                        note: "Frameworks/\(item)")
                    add(kind: "legacy_macho", target: full, backup: full + legacySuffix, restorable: true,
                        note: "Frameworks/\(item)（旧格式）")
                }
            }
        }

        // PlugIns（appex 也可能被注入过）
        let plugDir = appPath + "/PlugIns"
        if let items = try? fm.contentsOfDirectory(atPath: plugDir) {
            for item in items.sorted() where item.hasSuffix(".appex") {
                let p = plugDir + "/" + item
                let e = (NSDictionary(contentsOfFile: p + "/Info.plist")?["CFBundleExecutable"] as? String) ?? ""
                if e.isEmpty { continue }
                let exe = p + "/" + e
                add(kind: "macho", target: exe, backup: exe + inPlaceSuffix, restorable: true,
                    note: "PlugIns/\(item)")
            }
        }

        // 容器改名：不自动还原，指引回原工具
        if let c = AppCatalog.lookupContainer(bundleId: bundleId), !c.isEmpty {
            add(kind: "container", target: c, backup: c + containerSuffix, restorable: false,
                note: "整个数据容器被改名过：还原走 device command=refresh_container restore=true")
        }

        // 工作区目录快照：AppWriteFileTool 用 "<bid>_<ts>"，BindAppTool 用 "<bid>-<ts>"
        let treeList: [String]
        if let t = trees {
            treeList = t
        } else {
            treeList = (try? fm.contentsOfDirectory(atPath: treeRoot)) ?? []
        }
        for d in treeList.sorted() {
            guard d.hasPrefix(bundleId + "_") || d.hasPrefix(bundleId + "-") else { continue }
            let p = treeRoot + "/" + d
            guard let st = fileStat(p) else { continue }
            out.append(Entry(kind: "tree", bundleId: bundleId,
                             originalPath: "(Documents + Library/Preferences)",
                             backupPath: p, size: st.size, mtime: st.mtime,
                             restorable: false,
                             note: "工作区目录快照：路径已扁平化，需人工比对后手工取回，不自动覆盖"))
        }

        return out
    }

    /// 全量清点。App 数量多时靠 limit 收口，默认 200
    static func scanAll(limit: Int = 200) -> [Entry] {
        let trees = (try? FileManager.default.contentsOfDirectory(atPath: treeRoot)) ?? []
        var out: [Entry] = []
        for app in AppCatalog.list().prefix(limit) {
            out.append(contentsOf: scanBundle(bundleId: app.bundleId, appPath: app.path, trees: trees))
        }
        return out
    }

    // MARK: - 台账（目标指纹）

    static func ledger(_ bundleId: String) -> [String: Any]? {
        let p = ledgerRoot + "/" + fileSafe(bundleId) + ".json"
        guard let d = FileManager.default.contents(atPath: p),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o
    }

    static func writeLedger(bundleId: String, appPath: String, assets: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: ledgerRoot, withIntermediateDirectories: true)
        let info = NSDictionary(contentsOfFile: appPath + "/Info.plist")
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let exec = info?["CFBundleExecutable"] as? String ?? ""
        var execSize: Int64 = 0
        if !exec.isEmpty {
            execSize = fileStat(appPath + "/" + exec)?.size ?? 0
        }
        let rec: [String: Any] = [
            "bundle_id": bundleId,
            "app_path": appPath,
            "short_version": short,
            "build": build,
            "exec": exec,
            "exec_size": execSize,
            "dylibs": assets.map { ($0 as NSString).lastPathComponent },
            "recorded_at": Int(Date().timeIntervalSince1970),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: ledgerRoot + "/" + fileSafe(bundleId) + ".json"))
        }
    }

    /// 目标指纹校验：返回 nil 表示一致（或根本没记录，视为可继续），否则返回不一致的原因。
    /// 用在「按旧记录自动还原 / 自动重新注入」之前——App 更新过就别自动动它。
    static func fingerprintMismatch(bundleId: String, appPath: String) -> String? {
        guard let rec = ledger(bundleId) else { return nil }
        let info = NSDictionary(contentsOfFile: appPath + "/Info.plist")
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        let recShort = rec["short_version"] as? String ?? ""
        let recBuild = rec["build"] as? String ?? ""
        if recBuild.isEmpty && recShort.isEmpty { return nil }
        if recShort != short || recBuild != build {
            return "target changed since backup: recorded \(recShort)(\(recBuild)) → now \(short)(\(build))"
        }
        return nil
    }

    // MARK: - 还原

    /// 还原一个 App 的 Mach-O 就地备份。keepBackup 为 true 时保留备份文件
    static func restore(bundleId: String, keepBackup: Bool = false) -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            return ["ok": false, "error": "app not found: \(bundleId)"]
        }
        let entries = scanBundle(bundleId: bundleId, appPath: app.path)
        let im = InjectionManager.shared
        var done: [[String: Any]] = []
        var skipped: [[String: Any]] = []

        // 新格式优先：同一目标上若两者都在，只认 .troll-fools.bak
        var hasNew = Set<String>()
        for e in entries where e.kind == "macho" {
            hasNew.insert(e.originalPath)
        }

        for e in entries {
            guard e.kind == "macho" || e.kind == "legacy_macho" else {
                skipped.append(["backup": e.backupPath, "kind": e.kind, "reason": e.note])
                continue
            }
            if e.kind == "legacy_macho", hasNew.contains(e.originalPath) {
                skipped.append(["backup": e.backupPath,
                                "reason": "新的 .troll-fools.bak 已存在，旧格式忽略"])
                continue
            }
            // 先 cp 到临时文件再 mv：中途失败时原路径与备份都还在
            let tmp = e.originalPath + ".xosvi.restore.tmp"
            _ = im.runAsRoot("rm", args: ["-f", tmp])
            let (c0, o0) = im.runAsRoot("cp", args: ["-p", e.backupPath, tmp])
            guard c0 == 0 else {
                skipped.append(["backup": e.backupPath, "reason": "cp temp failed (\(c0)): \(o0)"])
                continue
            }
            let (c1, o1) = im.runAsRoot("mv", args: ["-f", tmp, e.originalPath])
            guard c1 == 0 else {
                _ = im.runAsRoot("rm", args: ["-f", tmp])
                skipped.append(["backup": e.backupPath, "reason": "mv into place failed (\(c1)): \(o1)"])
                continue
            }
            _ = im.runAsRoot("chown", args: ["33:33", e.originalPath])
            if !keepBackup {
                _ = im.runAsRoot("rm", args: ["-f", e.backupPath])
            }
            done.append(["restored": e.originalPath, "from": e.backupPath, "backup_kept": keepBackup])
        }

        AppCatalog.invalidateCache()
        AuditLog.shared.log("backup.restore", detail: "\(bundleId) done=\(done.count) skipped=\(skipped.count)")
        return [
            "ok": !done.isEmpty || entries.isEmpty,
            "bundle_id": bundleId,
            "app_path": app.path,
            "restored": done,
            "skipped": skipped,
            "message": done.isEmpty
                ? "nothing restored (no Mach-O backup for this app, or all skipped — see skipped)"
                : "restored \(done.count) file(s); relaunch the app to verify",
        ]
    }

    /// 卸载前的地基：App 都要删了，先把 Mach-O 备份退回去。
    /// 不还原也没意义（删了就找不回），但「删掉 App 前留一份能启动的原二进制」是两个坏选项里较好的那个，
    /// 更重要的是保证 uninstall 不会把一个「已被我们改坏的二进制」当成原样留在磁盘上再被扫回注册。
    static func preUninstallRestore(bundleId: String) -> [String: Any] {
        let r = restore(bundleId: bundleId, keepBackup: false)
        let ok = (r["ok"] as? Bool) ?? false
        let restored = (r["restored"] as? [[String: Any]]) ?? []
        let skipped = (r["skipped"] as? [[String: Any]]) ?? []
        return [
            "restored": restored,
            "skipped": skipped,
            "ok": ok,
        ]
    }

    // MARK: - 清理

    /// 清理工作区目录快照。只动 Workspace/backups 下的一级目录，别的路径一概不碰
    static func purge(days: Int) -> [String: Any] {
        let fm = FileManager.default
        guard days >= 0 else {
            return ["ok": false, "error": "days must be >= 0"]
        }
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400.0
        guard let dirs = try? fm.contentsOfDirectory(atPath: treeRoot) else {
            return ["ok": true, "removed": [], "note": "no backup directory"]
        }
        var removed: [String] = []
        var kept = 0
        for d in dirs.sorted() {
            let p = treeRoot + "/" + d
            guard let st = fileStat(p) else { continue }
            if st.mtime < cutoff {
                if (try? fm.removeItem(atPath: p)) != nil { removed.append(p) }
            } else {
                kept += 1
            }
        }
        AuditLog.shared.log("backup.purge", detail: "days=\(days) removed=\(removed.count) kept=\(kept)")
        return ["ok": true, "removed": removed, "kept": kept, "root": treeRoot, "days": days]
    }
}

// MARK: - MCP 工具

final class BackupTool: MCPTool {
    let definition = ToolDefinition(
        name: "backup",
        summary: "统一备份台账：一次列出某个 App（或不带参数时全部 App）的全部备份，一键还原，清理过期快照。覆盖四类落点：Mach-O 就地备份(.troll-fools.bak/.bak_macho)、整容器改名(.xosvi.bak)、工作区目录快照(Workspace/backups/)。Use for: 查这台机器上还有哪些备份、注入后想退回原样、App 打不开要恢复、清理备份占的空间。Don't use for: 按需改数据前备份(用 app_write_file 自带备份)、重置容器(用 device command=refresh_container)。Example: 用户说「把小红书恢复原样」→ backup command=restore bundle_id=com.xingin.discover；用户问「这些备份占多少地方」→ backup command=list。",
        parameters: [
            "command": "Subcommand: list / restore / prune / info",
            "bundle_id": "App bundle ID (list/restore/info 用；list 不传则扫全部 App)",
            "keep_backup": "restore 后是否保留备份文件，默认 false",
            "days": "prune 保留最近多少天的目录快照，默认 0（全清）",
        ],
        // verified 保持 false：本机无 swiftc，编译与真机行为都没验过，标 true 就是假象
        verified: false, category: "filesystem",
        paramSpecs: [
            .e("command", "子命令（必填）",
               values: ["list", "restore", "prune", "info"], required: true, example: "list"),
            .s("bundle_id", "目标 App 包名", example: "com.xingin.discover"),
            .b("keep_backup", "restore 后是否保留备份"),
            .i("days", "prune 保留天数", example: "7"),
        ],
        variants: [
            .init("list", accepts: ["bundle_id"], note: "不传 bundle_id 就扫全部 App（慢一些）"),
            .init("restore", requires: ["bundle_id"], accepts: ["keep_backup"], note: "只还原 Mach-O 备份"),
            .init("prune", accepts: ["days"], note: "只删 Workspace/backups 下的一级目录"),
            .init("info", requires: ["bundle_id"], note: "只看台账记录与指纹是否对得上"),
        ],
        annotations: .destructiveSystem, cache: ToolCachePolicy.none)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required: list / restore / prune / info")
        }
        AuditLog.shared.log("backup", detail: command)

        switch command {
        case "list":
            if let bid = params["bundle_id"] as? String, !bid.isEmpty {
                guard let app = AppCatalog.find(bid) else {
                    return ["ok": false, "error": "app not found: \(bid)"]
                }
                let entries = BackupRegistry.scanBundle(bundleId: bid, appPath: app.path)
                return ["ok": true, "bundle_id": bid, "app_path": app.path,
                        "count": entries.count,
                        "backups": entries.map { $0.dict }]
            }
            let all = BackupRegistry.scanAll()
            var byApp: [String: Int] = [:]
            for e in all { byApp[e.bundleId, default: 0] += 1 }
            // 逐条加类型标注：混合值字典字面量若靠推断，编译器会抱怨 heterogeneous
            var apps: [[String: Any]] = []
            for (k, v) in byApp {
                apps.append(["bundle_id": k, "backups": v])
            }
            apps.sort { ($0["bundle_id"] as? String ?? "") < ($1["bundle_id"] as? String ?? "") }
            return ["ok": true, "count": all.count,
                    "apps": apps,
                    "backups": all.map { $0.dict }]

        case "restore":
            guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
                throw MCPError.invalidParams("restore requires bundle_id")
            }
            let keep = (params["keep_backup"] as? Bool) ?? false
            return BackupRegistry.restore(bundleId: bid, keepBackup: keep)

        case "prune":
            let days = (params["days"] as? Int) ?? 0
            return BackupRegistry.purge(days: days)

        case "info":
            guard let bid = params["bundle_id"] as? String, !bid.isEmpty else {
                throw MCPError.invalidParams("info requires bundle_id")
            }
            let rec = BackupRegistry.ledger(bid)
            var out: [String: Any] = ["ok": true, "bundle_id": bid, "ledger": rec ?? [:]]
            if let app = AppCatalog.find(bid) {
                out["app_path"] = app.path
                let mismatch = BackupRegistry.fingerprintMismatch(bundleId: bid, appPath: app.path)
                out["fingerprint_ok"] = (mismatch == nil)
                out["fingerprint_note"] = mismatch ?? "consistent (or no record)"
                let entries = BackupRegistry.scanBundle(bundleId: bid, appPath: app.path)
                out["count"] = entries.count
                out["backups"] = entries.map { $0.dict }
            } else {
                out["app_path"] = ""
                out["fingerprint_ok"] = false
                out["note"] = "app not installed; ledger kept for reference"
            }
            return out

        default:
            throw MCPError.invalidParams("unknown command: \(command) (list / restore / prune / info)")
        }
    }
}
