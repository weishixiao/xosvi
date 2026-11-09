import Foundation

// MARK: - v8（P2-6）：受限壳（shim）识别
//
// 有些内置二进制「同名但能力被裁剪」——例如 sqlite3 只支持读查询、
// `--version` 打印的是 Usage 而不是版本号。自检不能把它当「坏了」，
// 但也不能当「完整能力」；这里给出统一判定，供 diagnose toolchain / 自检脚本使用。

enum ShimDetector {
    struct Verdict {
        let name: String
        let isShim: Bool
        let note: String
        let versionOutput: String
    }

    /// 判定规则：--version 输出里出现 Usage/<占位符> → 壳；空输出 → 未响应（不等于壳）
    /// v9.15：先判「进程内实现」——这类工具磁盘上没有同名文件（sqlite3/plutil/otool/class-dump…），
    /// 旧逻辑按 binDir 查不到就报「未内置」，自检于是绕路去找不存在的 Alpine 版本。
    static func inspect(_ name: String, binDir: String = Bundle.main.bundlePath + "/bin") -> Verdict {
        if ShellExecTool.inProcessNativeCommands.contains(name) {
            let out = ShellExecTool.inProcessVersionProbe(name)
            return Verdict(name: name, isShim: false,
                           note: "\(name) 是 App 进程内实现（无 bin/ 同名文件），能力以内置实现为准",
                           versionOutput: out)
        }
        let path = binDir + "/" + name
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Verdict(name: name, isShim: false, note: "\(name) 未内置", versionOutput: "")
        }
        let out = run(path, ["--version"])
        let lower = out.lowercased()
        let looksUsage = lower.contains("usage:") || lower.contains("<db_file>")
            || lower.contains("<file>") || lower.contains("<hexstring>")
            || lower.contains("<hexstring>")
        let empty = out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if looksUsage {
            return Verdict(name: name, isShim: true,
                           note: "\(name) 是受限壳：--version 返回用法说明，能力小于同名标准工具",
                           versionOutput: out)
        }
        if empty {
            return Verdict(name: name, isShim: false,
                           note: "\(name) 未响应 --version（可能不支持该旗标，不等于是壳）",
                           versionOutput: "")
        }
        return Verdict(name: name, isShim: false, note: "\(name) 响应正常", versionOutput: out)
    }

    static func scan(names: [String]) -> [[String: Any]] {
        names.map { n in
            let v = inspect(n)
            return ["name": v.name, "is_shim": v.isShim, "note": v.note,
                    "version_output": String(v.versionOutput.prefix(200))]
        }
    }

    /// 用 BuildRunner（iOS 可用的 posix_spawn 封装）跑一次，2s 超时
    private static func run(_ path: String, _ args: [String]) -> String {
        let res = BuildRunner.shared.run(executable: path, args: args,
                                         env: ["PATH": ShellExecTool.effectivePATH],
                                         timeout: 2)
        var out = res.stdout
        if !res.stderr.isEmpty { out += (out.isEmpty ? "" : "\n") + res.stderr }
        return out
    }
}
