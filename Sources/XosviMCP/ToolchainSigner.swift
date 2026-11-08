// ToolchainSigner.swift — 内置工具链启动自检 + 自签
//
// 目标：进 App 后先自己把 bin/ 里的工具查清楚（存在 / 执行位 / Mach-O / 签名 /
// ad-hoc / TeamID / entitlements），能签就用自带的 ldid 补签，不能签就给出
// 明确结论（是签名问题、权限问题还是被 rootHide 拦），不用再靠猜。
//
// 全部进程内完成；只有真正调用 ldid 那一步需要 spawn。

import Darwin
import Foundation

enum ToolchainSigner {
    /// 自动修复记录版本号（升级后重跑一次）
    private static let autoKey = "xosvi.toolchain_selfsign_version"

    /// 与 Support/bin-entitlements.plist 保持一致
    static let entitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>platform-application</key><true/>
      <key>com.apple.private.security.no-container</key><true/>
      <key>com.apple.private.cs.debugger</key><true/>
      <key>get-task-allow</key><true/>
      <key>task_for_pid-allow</key><true/>
      <key>com.apple.private.skip-library-validation</key><true/>
    </dict>
    </plist>
    """

    static func binDir() -> String {
        (Bundle.main.bundlePath as NSString).appendingPathComponent("bin")
    }

    static func entries() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: binDir()) else {
            return []
        }
        return names
            .filter { !$0.hasSuffix(".dylib") && !$0.hasPrefix(".") }
            .sorted()
    }

    // MARK: - 检查

    static func inspect(_ path: String) -> [String: Any] {
        let fm = FileManager.default
        var out: [String: Any] = [
            "name": (path as NSString).lastPathComponent,
            "path": path,
            "exists": fm.fileExists(atPath: path),
            "executable": fm.isExecutableFile(atPath: path),
        ]
        let mo = SpawnDiag.readMachO(path)
        out["macho"] = mo.isMachO
        out["magic"] = mo.magic
        out["cryptid"] = Int(mo.cryptid)
        out["code_signature"] = mo.hasCodeSignature
        let si = SpawnDiag.signatureInfo(path)
        out["adhoc"] = si.adhoc
        out["team_id"] = si.teamID
        out["has_cms"] = si.hasCMS
        out["has_entitlements"] = entitlementsBlob(path) != nil
        out["platform_application"] = (entitlementsBlob(path) ?? "").contains("platform-application")
        return out
    }

    /// 从 LC_CODE_SIGNATURE 的 SuperBlob 里取 entitlements（CSSLOT_ENTITLEMENTS）。
    static func entitlementsBlob(_ path: String) -> String? {
        let mo = SpawnDiag.readMachO(path)
        guard mo.hasCodeSignature, mo.codeSigSize > 12,
            let fh = FileHandle(forReadingAtPath: path)
        else { return nil }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: UInt64(mo.codeSigOffset))) != nil,
            let blob = try? fh.read(upToCount: mo.codeSigSize), blob.count >= 12
        else { return nil }
        // 签名 blob 一律大端（Apple cs_blobs），按小端读会让 magic 永远不匹配
        let magic = UInt32(bigEndian: blob.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard magic == 0xfade0cc0 else { return nil }
        let count = UInt32(bigEndian: blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        for index in 0..<Int(min(count, 32)) {
            let base = 12 + index * 8
            guard base + 8 <= blob.count else { break }
            let type = UInt32(bigEndian: blob.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: base, as: UInt32.self)
            })
            let offset = UInt32(bigEndian: blob.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self)
            })
            guard type == 5 else { continue }  // CSSLOT_ENTITLEMENTS
            let start = Int(offset)
            guard start + 8 <= blob.count else { return nil }
            let emagic = UInt32(bigEndian: blob.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: start, as: UInt32.self)
            })
            guard emagic == 0xfade7171 else { return nil }
            let length = UInt32(bigEndian: blob.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: start + 4, as: UInt32.self)
            })
            let dataStart = start + 8
            let dataEnd = min(start + Int(length), blob.count)
            guard dataStart < dataEnd else { return nil }
            return String(data: blob.subdata(in: dataStart..<dataEnd), encoding: .utf8)
        }
        return nil
    }


    // MARK: - 对照实验：到底是谁在拦

    static func errnoName(_ code: Int32) -> String {
        switch code {
        case 0: return "OK"
        case 1: return "EPERM"
        case 2: return "ENOENT"
        case 13: return "EACCES"
        case 78: return "ENOSYS"
        case 85: return "EBADEXEC"
        case 86: return "EBADARCH"
        default: return "errno\(code)"
        }
    }

    /// 分别尝试 spawn：Apple 自带二进制 / 自带二进制 / 越狱路径。
    /// 用来区分「整个 spawn 被拦」和「只是自带二进制签名不被接受」。
    static func spawnProbe() -> [[String: Any]] {
        let dir = binDir()
        let targets: [(String, String)] = [
            ("system_true", "/usr/bin/true"),
            ("system_ls", "/bin/ls"),
            ("bundled_ldid", (dir as NSString).appendingPathComponent("ldid")),
            ("jailbreak_true", "/var/jb/usr/bin/true"),
        ]
        var out: [[String: Any]] = []
        for (label, path) in targets {
            var row: [String: Any] = ["target": label, "path": path]
            guard FileManager.default.fileExists(atPath: path) else {
                row["exists"] = false
                out.append(row)
                continue
            }
            row["exists"] = true
            var pid: pid_t = 0
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
            let rc = posix_spawn(&pid, path, nil, nil, &argv, environ)
            for pointer in argv where pointer != nil { free(pointer) }
            var status: Int32 = 0
            if rc == 0 { waitpid(pid, &status, 0) }
            let code = rc == 0 ? Int32(0) : errno
            row["spawn_ok"] = rc == 0
            row["errno"] = Int(code)
            row["errno_name"] = errnoName(code)
            row["exit"] = rc == 0 ? Int((status >> 8) & 0xff) : -1
            out.append(row)
        }
        return out
    }

    /// 根据对照实验结果给出结论。
    /// v8（P0-3）：verdict 只看内置二进制；系统路径缺失（/usr/bin/true 在 iOS 本来就不存在）
    /// 不能作为「spawn 被拦截」的证据。旧实现据此断言"整个 spawn 被拦截"，把模型带偏。
    static func probeVerdict(_ probe: [[String: Any]]) -> String {
        let bundled = probe.filter { (($0["target"] as? String) ?? "").hasPrefix("bundled_") }
        guard !bundled.isEmpty else { return "未找到内置二进制探针结果" }
        let ok = bundled.filter { ($0["spawn_ok"] as? Bool) == true }.count
        if ok == bundled.count {
            return "内置二进制可执行 \(ok)/\(bundled.count)；系统路径缺失属 iOS 常态，不影响功能"
        }
        if ok > 0 {
            return "内置二进制部分可执行 \(ok)/\(bundled.count)；失败项见 spawn_probe（多为签名/架构）"
        }
        return "内置二进制全部无法执行（\(bundled.count) 个）"
    }

    // MARK: - 自签

    static func spawn(_ exe: String, _ args: [String]) -> Int32 {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) }
        argv.append(nil)
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
        }
        let spawned = posix_spawn(&pid, exe, nil, nil, &argv, environ)
        guard spawned == 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
    }

    static func writeEntitlements() -> String? {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("xosvi-bin-entitlements.plist")
        do {
            try entitlementsXML.write(toFile: path, atomically: true, encoding: .utf8)
            return path
        } catch {
            return nil
        }
    }

    // MARK: - 主流程

    /// - Parameter repair: true 时对缺失签名/无 entitlements 的工具尝试补签
    static func run(repair: Bool) -> [String: Any] {
        let dir = binDir()
        let ldid = (dir as NSString).appendingPathComponent("ldid")
        let fm = FileManager.default

        var items: [[String: Any]] = []
        var broken: [String] = []
        var repaired: [String] = []
        var signerRunnable = false

        if fm.isExecutableFile(atPath: ldid) {
            // ldid -h 能跑通才认为签名器可用（EBADEXEC 时返回 -1）
            let probe = spawn(ldid, ["-h"])
            signerRunnable = probe >= 0
        }


        for name in entries() {
            let path = (dir as NSString).appendingPathComponent(name)
            var info = inspect(path)
            let needSign =
                info["macho"] as? Bool == true
                && info["code_signature"] as? Bool != true
            if needSign { broken.append(name) }

            if repair, needSign, signerRunnable {
                // 按 CI 的策略：普通 ad-hoc 补签（不带特权 entitlements）。
                // 带 platform-application 反而会与 TrollStore 的重签身份不匹配 → AMFI 拒绝。
                let code = spawn(ldid, ["-S", path])
                if code == 0 {
                    info = inspect(path)
                    repaired.append(name)
                } else {
                    info["sign_error"] = "ldid exit \(code)"
                }
            }
            items.append(info)
        }

        let probe = spawnProbe()
        let verdict = probeVerdict(probe)
        // v8（P0-3）：advice 只在有确证时输出（签名器不可用 / 真的补签过），
        // 不再出现「repaired 为空却断言补签失败」这种自相矛盾。
        var advice: String? = nil
        if !signerRunnable {
            advice = "自带 ldid 跑不起来。" + verdict
        } else if !repaired.isEmpty {
            advice = "已补签 \(repaired.count) 个工具，重启 App 后重新跑 diagnose spawn 验证。"
        } else if broken.isEmpty {
            advice = nil
        }

        let report: [String: Any] = [
            "bin_dir": dir,
            "spawn_probe": probe,
            "spawn_verdict": probeVerdict(probe),
            "signer": ldid,
            "signer_runnable": signerRunnable,
            "count": items.count,
            "broken": broken,
            "repaired": repaired,
            "advice": advice as Any,
            // v8（P2-6）：识别同名但能力被裁剪的壳二进制（如只读 sqlite3）
            "shims": ShimDetector.scan(names: ["sqlite3", "plutil", "jq", "cstool"]),
            "items": items,
        ]

        if let data = try? JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]
        ) {
            let out = Workspace.root.appendingPathComponent("toolchain-report.json")
            try? data.write(to: out)
        }
        return report
    }

    /// 启动时跑一次（每个版本一次），异步、失败静默。
    static func autoRepairIfNeeded() {
        let version =
            (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: autoKey) == version { return }
        let report = run(repair: true)
        if report["signer_runnable"] as? Bool == true {
            defaults.set(version, forKey: autoKey)
        }
        let broken = (report["broken"] as? [String]) ?? []
        AuditLog.shared.log(
            "toolchain.selfsign",
            detail: "broken=\(broken.count) repaired=\((report["repaired"] as? [String])?.count ?? 0)"
        )
    }
}
