//
//  InstallTools.swift
//  v4.3.65：统一工具安装入口 —— AI 自动搜索并安装工具/依赖的闭环
//
//  tool.install：AI 想要某个工具时一键安装：
//    1. 已就绪？—— 内置原生 iOS bin（Resources/bin）/ Alpine 已有
//    2. Alpine 包（apk add，即装即用，可 bind 直读 iOS 文件）
//    3. 原生 iOS 二进制 → 触发 CI 交叉编译（build-tool.yml）→ github.download_artifact 取产物
//  env.setup_re：一键逆向工具链（逆向 iOS/App/IPA 常用 Alpine 工具批装）
//

import Foundation

final class ToolInstallTool: MCPTool {
    let definition = ToolDefinition(
        name: "tool.install",
        summary: "统一工具安装入口. Params: name(工具名) / profile(re逆向/dev开发/network网络 批量) / source(原生iOS二进制GitHub repo URL, 触发CI build-tool.yml). 安装链: 内置原生bin → Alpine apk(即装即用,auto-bind直读iOS文件) → pip → CI. Use for: AI 缺工具时一键装. 注dylib走inject.",
        parameters: [
            "name": "Tool name to install (e.g. jq / jtool2 / class-dump)",
            "profile": "Optional curated batch: re(逆向工具链) / dev(开发环境) / network(网络工具)",
            "source": "Optional GitHub repo URL for native iOS CI build (e.g. https://github.com/Neurotycho/jtool2)"
        ],
        verified: true, category: "build", annotations: .destructiveSystem, cache: ToolCachePolicy.none)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        // 1. profile 批量安装
        if let profile = params["profile"] as? String {
            let p = profile.lowercased().trimmingCharacters(in: .whitespaces)
            if let batch = Self.profiles[p] {
                return installBatch(batch, profile: p)
            }
            // 未知 profile：不直接报错——AI 可能把 pandas 这类包名误传成 profile，
            // 把它当作普通工具名继续走 name 安装流程。
            var sub = params
            sub["profile"] = nil
            sub["name"] = p
            return installByName(p, params: sub)
        }
        guard let rawName = params["name"] as? String else {
            throw MCPError.invalidParams("name or profile required")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw MCPError.invalidParams("name required") }
        return installByName(name, params: params)
    }

    // MARK: - 按名单个安装（内置 → Alpine apk → pip → CI）

    private func installByName(_ name: String, params: [String: Any]) -> [String: Any] {
        // v9.15：先认「进程内实现」——otool/class-dump/nm/strings/objdump/sqlite3/plutil 等没有
        // 磁盘文件，旧逻辑只 stat bin/ 于是报「未内置」，AI 转而去装不存在的 Alpine 包。
        if ShellExecTool.inProcessNativeCommands.contains(name) {
            return ["ok": true, "tool": name, "status": "ready", "source": "in_process",
                    "path": "\(name)（App 进程内）",
                    "hint": "App 内置进程内实现，直接调命令名即可；`\(name) --version` 返回内置版本说明。"]
        }
        // 1. 已就绪？——内置原生 bin / Alpine 已有
        // v4.4.9-fix3bv: 就绪≠可用——二进制存在/apk exit 0 都可能是"装了但调不动/输出不可见"
        // (pandas 误报、python3/r2 空输出、BusyBox tree 缺参数)。统一冒烟：命令名调 --version/-v/--help/-h，
        // 验证 exit 0 且输出可见；异常则在 hint 里明确提示（不静默报 ready）。
        if let bundled = bundledBinPath(name) {
            let (ok, note) = smokeTest(name)
            return ["ok": true, "tool": name, "status": "ready", "source": "builtin_native", "path": bundled,
                    "hint": "App 内置原生 iOS 二进制；" + note]
        }
        // v7.3.0：Alpine/apk 已随引擎移除——tool.install 只认 App 内置的原生二进制。
        // 原来这里会用 `which` 查 Alpine、再 apk add / pip install，现在这些路径全部不存在了。
        return ["ok": false, "tool": name, "status": "unavailable", "source": "none",
                "error": "该工具没有内置版本，且 Alpine/apk 已从本版本移除",
                "hint": "可用的是 App 内置原生工具（lua/node/r2/cstool/jq/bsdtar/llvm-*/jtool2 等）与内置 python3。\n需要额外命令行工具请先在设置里确认是否内置；apk add / pip install 已无可用路径。"]
    }

    /// v7.3.0：冒烟验证（原实现依赖 Alpine python，已简化为内置二进制的版本检验）
    private func smokeTest(_ name: String, importMode: Bool = false) -> (ok: Bool, note: String) {
        if importMode {
            // 内置 python3 是原生 ARM64，import 直接跑原生即可
            do {
                let safe = name.replacingOccurrences(of: "[^A-Za-z0-9_.-]", with: "_", options: .regularExpression)
                let r = try ShellExecTool().invoke(["command": "python3 -c 'import \(safe); print(\"IMPORT_OK\")'", "timeout": 30])
                let out = (r["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if (r["exit_code"] as? Int ?? 1) == 0, out.contains("IMPORT_OK") {
                    return (true, "内置 python3 冒烟 import \(safe) OK")
                }
                return (false, "内置 python3 里 import \(safe) 失败——该包未随 App 内置")
            } catch {
                return (false, "冒烟异常：\(error)")
            }
        }
        for flag in ["--version", "-v", "--help", "-h"] {
            do {
                let r = try ShellExecTool().invoke(["command": "\(name) \(flag)", "timeout": 20])
                let out = (r["stdout"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = r["exit_code"] as? Int ?? 1
                if exit == 0 && !out.isEmpty {
                    let first = out.split(separator: "\n").first.map(String.init) ?? ""
                    return (true, "冒烟 `\(name) \(flag)` OK（" + String(first.prefix(90)) + "）")
                }
            } catch { }
        }
        return (false, "冒烟 `\(name)` 全部失败——工具可能已内置但不可调用，或它没有版本/帮助参数")
    }

    // MARK: - 批量安装（profile）

    private func installBatch(_ pkgs: [String], profile: String) -> [String: Any] {
        // v7.3.0：批量安装（apk add 一批）已随引擎移除，只看内置情况
        var results: [[String: Any]] = []
        var okCount = 0
        for pkg in pkgs {
            if ConversationStore.shared.stopRequested { break }
            // v9.15：进程内实现没有 bin/ 文件，别报「未内置」
            if ShellExecTool.inProcessNativeCommands.contains(pkg) {
                okCount += 1
                results.append(["package": pkg, "ok": true,
                                "detail": "进程内实现（无需 bin/ 文件）：\(pkg) --version"])
                continue
            }
            let bundled = bundledBinPath(pkg)
            let ok = bundled != nil
            if ok { okCount += 1 }
            results.append(["package": pkg, "ok": ok,
                            "detail": bundled.map { "内置：\($0)" } ?? "未内置"])
        }
        return ["ok": okCount == pkgs.count, "profile": profile,
                "installed": okCount, "total": pkgs.count, "results": results,
                "hint": "Alpine/apk 已移除，这里只报告哪些工具是 App 内置的。逆向常用：内置 python3 / bsdtar / strings / nm / objdump / lua / node / r2 / cstool / jtool2。"]
    }

    // MARK: - 查找内置原生 bin

    /// v4.3.69：修复 pandas 等包被误判"内置已就绪"的 bug——实测 isExecutableFile 对【目录】
    /// 也返回 true，会把 bin 目录误当内置二进制而短路安装流程。修复：①必须存在且非目录才命中；
    /// ②Python 包（pythonHints / py3- 映射）根本不走内置检查（内置 bin 只有 iOS 原生工具，无 Python 包）。
    private func bundledBinPath(_ name: String) -> String? {
        if Self.pythonHints.contains(name)
            || Self.alpineNameMap[name]?.hasPrefix("py3-") == true {
            return nil
        }
        let roots = [
            Bundle.main.bundlePath + "/Resources/bin",
            Bundle.main.bundlePath + "/bin"
        ]
        for root in roots {
            let candidates = [
                root + "/" + name,
                root + "/" + name + "_ios",
                root + "/" + name + "-ios"
            ]
            for c in candidates {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: c, isDirectory: &isDir),
                      !isDir.boolValue,
                      FileManager.default.isExecutableFile(atPath: c) else { continue }
                return c
            }
        }
        return nil
    }

    // MARK: - 静态数据

    /// 常用工具名 → Alpine 包名映射（nm/strings 等常见名在 Alpine 里归属 binutils）
    private static let alpineNameMap: [String: String] = [
        "nm": "binutils", "strings": "binutils", "objdump": "binutils", "readelf": "binutils",
        "python": "python3", "sqlite3": "sqlite", "7z": "7zip",  // v4.3.77: Alpine 包名 7zip
        "node": "nodejs", "make": "make", "cmake": "cmake",
        "nc": "netcat-openbsd", "dig": "bind-tools", "nslookup": "bind-tools",
        "tcpdump": "tcpdump", "nmap": "nmap", "wget": "wget",
        "xxd": "xxd", "tree": "tree", "vim": "vim", "gawk": "gawk",
        "zip": "zip", "unzip": "unzip", "xz": "xz", "file": "file",
        "curl": "curl", "git": "git", "jq": "jq", "openssl": "openssl",
        "gcc": "gcc", "clang": "clang", "gdb": "gdb",
        // 常见 Python 包（Alpine 预编译，py3- 前缀）
        "pandas": "py3-pandas", "numpy": "py3-numpy", "scipy": "py3-scipy",
        "requests": "py3-requests", "matplotlib": "py3-matplotlib", "pillow": "py3-pillow",
        "flask": "py3-flask", "django": "py3-django", "pip": "py3-pip",
        "bs4": "py3-beautifulsoup4", "beautifulsoup4": "py3-beautifulsoup4",
        "openpyxl": "py3-openpyxl", "pytest": "py3-pytest", "yaml": "py3-yaml",
        "sqlalchemy": "py3-sqlalchemy", "cryptography": "py3-cryptography"
    ]

    /// 常见 Python 包名：apk 无对应 py3- 包时，回退到 pip install
    private static let pythonHints: Set<String> = [
        "pandas", "numpy", "scipy", "requests", "matplotlib", "pillow", "flask",
        "django", "bs4", "beautifulsoup4", "openpyxl", "pytest", "sqlalchemy",
        "cryptography", "pyyaml", "aiohttp", "tornado", "click", "six"
    ]

    /// 逆向/开发/网络 三档 curated 批量（Alpine 包）
    /// v8（P0-2）：供 env.setup_re action:list 使用
    static var profileNames: [String] { profiles.keys.sorted() }
    static func profileTools(_ name: String) -> [String] { profiles[name.lowercased()] ?? [] }

    private static let profiles: [String: [String]] = [
        "re": ["binutils", "file", "python3", "sqlite", "openssl", "curl", "git", "jq",
               "zip", "unzip", "xz", "7zip", "tree", "gawk", "coreutils", "findutils", "vim",
               "tcpdump", "netcat-openbsd"],
        "dev": ["build-base", "git", "python3", "vim", "curl", "jq", "cmake", "nodejs"],
        "network": ["curl", "wget", "jq", "openssl", "ca-certificates", "bind-tools", "tcpdump"]
    ]

    /// 原生 iOS 二进制注册表（Alpine 没有，走 CI 交叉编译；note 说明真实可行性）
    private static let nativeRegistry: [String: (source: String, note: String)] = [
        "jtool2": ("https://github.com/Neurotycho/jtool2",
                   "Makefile 工程，best-effort 交叉编译；输出 jtool（Mach-O 深度分析），iOS 逆向标配"),
        "class-dump": ("https://github.com/stevemacarthur/class-dump",
                       "macOS Makefile，iOS 交叉编译需改 SDK 目标；若 artifact 为空请 PC 编译后自写 dylib 包装"),
        "frida-server": ("https://github.com/frida/frida",
                         "需要越狱/内核信任，TrollStore 下通常不可用；不建议，仅列出说明边界")
    ]
}

/// v4.3.65：一键逆向工具链（env.setup_re）
/// v8（P0-2）：补必填校验与 action:list——无参调用不再进入执行后吐 ok=false（AI 会原样重试）。
final class EnvSetupRETool: MCPTool {
    let definition = ToolDefinition(
        name: "env.setup_re",
        summary: "Prepare/inspect the reverse-engineering toolchain. Actions: list (profiles) / report (bundled tools, default) / setup (install a profile). Use for: AI needs RE tools or wants to know what is bundled. Don't use for: single tool install (use tool.install name:...). Example: '看看逆向环境' → action:report; '装逆向工具链' → action:setup profile:re.",
        parameters: [
            "action": "list / report (default) / setup",
            "profile": "setup 时的批次名（re / dev / network），先用 action:list 查",
        ],
        verified: true, category: "build",
        paramSpecs: [
            .e("action", "动作", values: ["list", "report", "setup"], required: false),
            .s("profile", "批次名（setup 必填）", required: false, example: "re"),
        ],
        variants: [
            ToolVariant("list", requires: [], accepts: []),
            ToolVariant("report", requires: [], accepts: []),
            ToolVariant("setup", requires: ["profile"], accepts: []),
        ],
        annotations: .destructiveSystem, cache: ToolCachePolicy.none
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let action = ((params["action"] as? String) ?? "report").lowercased()

        switch action {
        case "list":
            return [
                "ok": true,
                "profiles": ToolInstallTool.profileNames.map { name in
                    ["name": name, "tools": ToolInstallTool.profileTools(name)]
                },
                "next_step": "env.setup_re action:setup profile:<name>",
            ]

        case "report":
            // 只读盘点：App 内置 bin 下的工具 + 版本自检（不安装任何东西）
            let dir = Bundle.main.bundlePath + "/bin"
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?.sorted() ?? []
            let tools = files.compactMap { name -> [String: Any]? in
                let path = dir + "/" + name
                var row: [String: Any] = ["name": name, "path": path]
                // v8.3（P2）：库文件不参与 exec 自检——旧版把 .dylib/.a 拿去跑，
                // 得到 ENOEXEC(8) 后被误判成「被越狱拦截」，面板一片假 blocked。
                if name.hasSuffix(".a") {
                    row["status"] = "n/a (static lib)"
                    return row
                }
                guard SpawnClassifier.isExecutableMachO(path) else {
                    row["status"] = "n/a (not executable)"
                    return row
                }
                let ver = Self.versionOutput(path)
                row["status"] = ver.isEmpty ? "no-output" : "ok"
                if !ver.isEmpty { row["version"] = String(ver.prefix(120)) }
                return row
            }
            return [
                "ok": true,
                "bin_dir": dir,
                "count": tools.count,
                "tools": tools,
                "profiles": ToolInstallTool.profileNames,
                "next_step": "需要安装批次用 action:setup profile:<name>；单工具用 tool.install name:<tool>",
            ]

        case "setup", "install":
            guard let profile = params["profile"] as? String,
                  !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.classified(
                    "env.setup_re 缺少 profile 参数",
                    code: "PARAM_INVALID",
                    reason: "未提供 profile，且 setup 不支持无参调用",
                    nextStep: "先用 env.setup_re action:list 取可用名称，再 action:setup profile:<名称> 重试")
            }
            return try ToolInstallTool().invoke(["profile": profile])

        default:
            throw MCPError.classified(
                "env.setup_re 未知 action: \(action)",
                code: "PARAM_INVALID",
                reason: "action 只支持 list / report / setup",
                nextStep: "用 env.setup_re action:list 查看批次名")
        }
    }

    /// 轻量版本探测（只读，2s 超时）——用 BuildRunner（iOS 可用），不用 macOS-only 的 Process
    private static func versionOutput(_ path: String) -> String {
        let res = BuildRunner.shared.run(executable: path, args: ["--version"],
                                         env: ["PATH": ShellExecTool.effectivePATH],
                                         timeout: 2)
        var out = res.stdout
        if !res.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + res.stderr }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
