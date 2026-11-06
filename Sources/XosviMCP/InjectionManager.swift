import Foundation
import Darwin
import UIKit

// v2.9.52：对照 TrollStore 官方 TSUtil.m，用 @_silgen_name 编译时链接 persona 函数。
// 之前用 dlsym(nil, ...) 运行时查找，但这些符号在 iOS 上是隐藏符号，dlsym 全返回 nil，
// 导致 persona 99+uid0+gid0 根本没设置上，euid 恒为 501，cp 写 root 目录 EPERM。
// 编译时链接后，只要 App 有 com.apple.private.persona-mgmt entitlement，就能以 root spawn。
@_silgen_name("posix_spawnattr_set_persona_np")
private func posix_spawnattr_set_persona_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ persona: UInt32, _ flags: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_uid_np")
private func posix_spawnattr_set_persona_uid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ uid: UInt32) -> Int32
@_silgen_name("posix_spawnattr_set_persona_gid_np")
private func posix_spawnattr_set_persona_gid_np(_ attr: UnsafeMutablePointer<posix_spawnattr_t?>, _ gid: UInt32) -> Int32
private let POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE: UInt32 = 1

// MARK: - v2.9.89 Mach-O 分析器 (对齐 TrollFools 注入策略：选未加密可注入目标 + 备份 diff）

/// 轻量 Mach-O 解析：magic / 架构 / 加密状态 (LC_ENCRYPTION_INFO cryptid）/ 加载的 dylib 列表。
/// 支持 thin (32/64）与 fat (大端，自动定位 arm64 slice）。
enum MachOAnalyzer {
    struct Info {
        var arch: String
        var cryptID: UInt32
        var dylibs: [String]
        var valid: Bool
        var fileType: UInt32 = 0
        var hasCodeSignature: Bool = false
    }

    static let lcLoadDylib: UInt32 = 0x0C
    static let lcLoadWeakDylib: UInt32 = 0x80000018
    static let lcLoadUpwardDylib: UInt32 = 0x23
    static let lcEncryptionInfo: UInt32 = 0x21
    static let lcEncryptionInfo64: UInt32 = 0x2C

    /// 解析 Mach-O 信息；非 Mach-O 或读取failed返回 nil
    /// v2.9.265：大文件只读头 8MB (fat header + load commands 区足够解析 cryptID/dylibs）——
    /// 全量 mmap 394MB 主二进制 + 6 个 framework 会压垮 Xosvi (实测多次断连/被杀）。
    static func analyze(_ path: String) -> Info? {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        let total = size?.int64Value ?? 0
        let readLen = Int(min(total, 8 * 1024 * 1024))
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: readLen), data.count >= 8 else { return nil }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }

        var offset = 0
        var effectiveMagic = magic

        if magic == 0xCAFEBABE || magic == 0xBEBAFECA {
            // fat：按大端读 nfat_arch，找 arm64 (cputype=0x0100000C）slice
            let countRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let count = magic == 0xCAFEBABE ? countRaw.byteSwapped : countRaw
            var foundSlice: (off: UInt32, size: UInt32)?
            for i in 0..<min(count, 16) {
                let off = 8 + Int(i) * 20
                guard data.count >= off + 16 else { break }
                let cpuRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
                let cpu = magic == 0xCAFEBABE ? cpuRaw.byteSwapped : cpuRaw
                let sliceOffRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self) }
                let sliceOff = magic == 0xCAFEBABE ? sliceOffRaw.byteSwapped : sliceOffRaw
                if cpu == 0x0100000C {   // arm64
                    foundSlice = (sliceOff, 0)
                    break
                }
            }
            guard let f = foundSlice else {
                return Info(arch: "fat(no-arm64)", cryptID: 0, dylibs: [], valid: false)
            }
            offset = Int(f.off)
            guard data.count >= offset + 8 else { return nil }
            effectiveMagic = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }

        let is64 = effectiveMagic == 0xFEEDFACF
        let is32 = effectiveMagic == 0xFEEDFACE
        guard is64 || is32 else {
            return Info(arch: "not-macho", cryptID: 0, dylibs: [], valid: false)
        }
        let headerSize = is64 ? 32 : 28
        guard data.count >= offset + headerSize else { return nil }

        let fileType = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self) }
        var hasCodeSignature = false
        let ncmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 16, as: UInt32.self) }
        let sizeofcmds = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 20, as: UInt32.self) }

        var cryptID: UInt32 = 0
        var dylibs: [String] = []
        var cursor = offset + headerSize
        let cmdEnd = offset + headerSize + Int(sizeofcmds)
        var remain = Int(ncmds)
        while cursor + 8 <= cmdEnd, remain > 0, data.count >= cursor + 8 {
            let cmd = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) }
            let cmdsizeRaw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self) }
            let cmdsize = Int(cmdsizeRaw)
            guard cmdsize >= 8, cursor + cmdsize <= cmdEnd, data.count >= cursor + cmdsize else { break }
            switch cmd {
            case lcLoadDylib, lcLoadWeakDylib, lcLoadUpwardDylib:
                if cursor + 12 <= data.count {
                    let nameOff = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 8, as: UInt32.self) })
                    let nameStart = cursor + nameOff
                    if nameStart < data.count {
                        var name = ""
                        var i = nameStart
                        while i < data.count, i < nameStart + 512 {
                            let b = data[i]
                            if b == 0 { break }
                            name.append(Character(UnicodeScalar(b)))
                            i += 1
                        }
                        if !name.isEmpty { dylibs.append(name) }
                    }
                }
            case lcEncryptionInfo, lcEncryptionInfo64:
                if cursor + 20 <= data.count {
                    cryptID = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 16, as: UInt32.self) }
                }
            case 0x1D:   // LC_CODE_SIGNATURE
                hasCodeSignature = true
            default:
                break
            }
            cursor += cmdsize
            remain -= 1
        }
        return Info(arch: is64 ? "arm64" : "arm32", cryptID: cryptID, dylibs: dylibs, valid: true,
                    fileType: fileType, hasCodeSignature: hasCodeSignature)
    }

    /// 是否已加密 (App Store 加密二进制 cryptid=1，注入会破坏它 → 必须跳过）
    static func isProtected(_ path: String) -> Bool {
        guard let info = analyze(path) else { return true }
        return info.cryptID != 0
    }

    /// 是否合法可注入的 Mach-O
    static func isInjectiveMachO(_ path: String) -> Bool {
        guard let info = analyze(path) else { return false }
        return info.valid && (info.arch == "arm64" || info.arch == "arm32" || info.arch.hasPrefix("fat")) && info.cryptID == 0
    }

    /// v2.9.305：只要是合法 Mach-O 就列进候选 (不查 cryptid）——小红书自家 framework
    /// (Sheim/DisGuard) 可能加密，TrollFools 靠 ct_bypass 强注，枚举阶段不应过滤。
    static func isValidMachO(_ path: String) -> Bool {
        guard let info = analyze(path) else { return false }
        return info.valid && (info.arch == "arm64" || info.arch == "arm32" || info.arch.hasPrefix("fat"))
    }

    /// v2.9.308：是否加密 (对齐 TrollFools isProtectedMachO）——选目标时优先未加密
    static func isEncryptedMachO(_ path: String) -> Bool {
        return (analyze(path)?.cryptID ?? 0) != 0
    }
}

/// 注入管理器：使用内置 ldid / optool / insert_dylib / ct_bypass 二进制，通过 posix_spawn
/// 真实地把 ControlAgent.dylib 注入到目标 App 主可执行文件 (TrollStore 无越狱注入）。
/// v2.9.32：写 bundle 的文件操作全部改 **root 身份**执行 (TrollStore TSRootBinaries +
/// persona-mgmt），修复无越狱下 mobile 用户无权写 root 拥有的 app bundle (POSIX 13）。
final class InjectionManager {
    static let shared = InjectionManager()

    private var binDir: URL {
        Bundle.main.bundleURL.appendingPathComponent("bin")
    }

    func binaryPath(_ name: String) -> String? {
        let p = binDir.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func availableBinaries() -> [String] {
        let names = ["ldid", "optool", "insert_dylib", "ct_bypass", "install_name_tool",
                     "chown", "cp", "cp-15", "mkdir", "mv", "mv-15", "rm"]
        return names.filter { binaryPath($0) != nil }
    }

    /// iOS 大版本 (用于选择 cp / cp-15 等工具变体）
    private var majorVersion: Int {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.majorVersion
    }

    /// 选择可用的 coreutils 复制工具：iOS 15 用 cp-15，iOS 16+ 用 cp
    private func cpBinary() -> String? {
        if majorVersion <= 15 { return binaryPath("cp-15") ?? binaryPath("cp") }
        return binaryPath("cp") ?? binaryPath("cp-15")
    }

    private func mvBinary() -> String? {
        if majorVersion <= 15 { return binaryPath("mv-15") ?? binaryPath("mv") }
        return binaryPath("mv") ?? binaryPath("mv-15")
    }

    // MARK: - posix_spawn 执行包内二进制

    /// v2.9.126：结构化 spawn 结果——stdout/stderr 分离 (根治"ldid 错误混进 entitlements"）、
    /// 超时标记、signal/exit 区分。code：>=0 exit code；-1 spawn failed；-2 超时被 SIGKILL。
    struct SpawnResult {
        var code: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool
        var signaled: Bool
        var signal: Int32
        var diagPrefix: String
        /// v3.0.42：stdout 原始字节 (二进制安全，如 ldid -e 输出的 bplist）。解析用 rawStdout，展示用 stdout。
        var rawStdout: Data = Data()
        var output: String { diagPrefix + stdout + stderr }
        var isTimeout: Bool { code == -2 || timedOut }
        var isSpawnFailed: Bool { code == -1 }
    }

    /// 执行包内二进制，captured stdout/stderr，返回 (exitCode, combinedOutput)
    @discardableResult
    func runBundled(_ name: String, args: [String], timeout: Double = 60) -> (Int32, String) {
        guard let bin = binaryPath(name) else { return (-1, "binary not bundled: \(name)") }
        let result = spawn(bin, args: [name] + args, timeout: timeout)
        // 权限/签名问题：ldid 重签后重试一次
        if result.0 != 0, name != "ldid", let ldid = binaryPath("ldid") {
            _ = spawn(ldid, args: ["-S", bin], timeout: 30)
            let retry = spawn(bin, args: [name] + args, timeout: timeout)
            if retry.0 == 0 { return retry }
        }
        return result
    }

    /// v2.9.32：以 **root 身份**执行包内二进制 (写 app bundle 必需，mobile 无 POSIX 写权限）。
    /// 依赖 TrollStore 安装时保留的 persona-mgmt entitlement + Info.plist TSRootBinaries 声明。
    /// v2.9.126：内部走 spawnRootDetailed (stdout/stderr 分离 + 超时），对外签名不变；
    /// 进程本身已是 root (越狱环境 geteuid()==0）时，cp/rm/mv/mkdir/chown 直接用 FileManager
    /// 原生 API (对齐 TrollFools isPrivileged），省一次进程创建。
    @discardableResult
    func runAsRoot(_ name: String, args: [String], timeout: Double = 60) -> (Int32, String) {
        guard let bin = binaryPath(name) else { return (-1, "binary not bundled: \(name)") }
        if geteuid() == 0, let native = nativeFileOp(name, args) {
            return native
        }
        // v6.9.4：只读命令直接执行，不经过提权。
        //
        // `ldid -e <bin>` 只是读签名里的 entitlements blob——普通用户就能读，
        // 不需要 root。但它此前被塞进 runAsRoot，spawnRoot 在 rootHide 下返回 85
        // → app entitlements 永远失败（用户实测连续 26 次报 ldid -e failed (85)）。
        //
        // 判定：ldid 的 -e / -e 组合属于纯读；写操作（-S 签名）才需要提权。
        if name == "ldid", args.contains("-e"), !args.contains("-S") {
            let direct = spawn(bin, args: args, timeout: timeout)
            if direct.0 == 0 { return direct }
            // 直跑失败再走提权（某些环境 ldid 需要签名权限才能读加密段）
        }
        // v6.9.3：文件操作类**优先直写**（对齐 TrollFools）。
        //
        // TrollFools 全程用 FileManager 直接写 App Bundle，没有任何提权逻辑——
        // 它能写只是因为 entitlements 里的 com.apple.private.security.storage.AppBundles
        // 生效了。Xosvi 配了同样的 entitlement，那么这类操作根本不需要 root。
        //
        // 旧顺序「先 spawnRoot 失败再兜底」有两个问题：
        //   1. 每次多起一个进程，慢
        //   2. spawnRoot 在 rootHide 下可能返回超时/非典型错误码，
        //      兜底判据 result.code != 0 未必触发 → 明明能写的操作报失败
        // 改成先直写：成功就直接返回，失败才去提权。
        var nativeError: String? = nil
        if let native = nativeFileOp(name, args) {
            if native.0 == 0 { return (0, native.1) }
            // 直写失败：记下来，若后面提权也失败，至少把两边的真实原因都给出去
            nativeError = native.1
        }
        // v0.2.3：越狱环境下**优先**走守护的 root XPC 通道。
        // 现场实测：rootHide 上 /var/containers/Bundle/Application 对 root 完全可写
        // （root 下 mkdir 探针成功），但 App 自己的 spawnRoot / setuid / jb-launcher 三条路
        // 全部失败（85 / 13），诊断于是误报「Bundle 目录不可写」。xosvid 是 uid=0 的常驻守护，
        // `xosvi-build --exec` 就是一条可用的 root 通道，直接借它执行这几个内置工具。
        if JBEnvironment.isJailbroken,
           let viaXPC = runViaRootChannel(bin, args: args, timeout: timeout) {
            if viaXPC.0 == 0 { return (0, viaXPC.1) }
            if nativeError == nil { nativeError = "[xpc-root] " + viaXPC.1 }
        }
        // v0.2.5：守护的 root helper **xosvi-bin** 代跑包内工具（白名单 + 绝对路径校验）。
        //
        // 上面那条 runViaRootChannel 走的是 `xosvi-build --exec <裸命令>`，转一趟 dash：
        // 命令串里的引号被吃一层、非 0 退出码被 [exit N] 包住还要二次解析，任何一环
        // 不对劲就表现为「spawnRoot failed」而看不到真实原因。这里改成把**工具绝对
        // 路径 + 参数数组**原样交给 helper，不经过 shell，拿到的就是工程真正的退出码。
        // 守护没装（< 0.2.5）时 helper 不在白名单，返回 nil，自动退回老路径。
        if JBEnvironment.isJailbroken,
           let viaBin = runViaBinHelper(name, bin: bin, args: args, timeout: timeout) {
            if viaBin.0 == 0 { return (0, viaBin.1) }
            if nativeError == nil { nativeError = "[xosvi-bin] " + viaBin.1 }
        }
        // v6.6.10：越狱环境专用提权路径。
        // rootHide/Relaxin 会拦截 persona spawn → 恒返回 85 (ENOSYS)，那条路注定失败。
        // 越狱的 amfid 已绕过签名校验，只要 helper 有 setuid + root 属主，
        // **普通 posix_spawn（不带 persona）** 就能拿到 euid=0。
        if JBEnvironment.isJailbroken {
            let jb = spawnRootDetailed(bin, args: args, timeout: timeout, usePersona: false)
            if jb.code == 0 {
                return (0, jb.output)
            }
            // helper 自身没权限时，借越狱自带的 root 工具代跑（sudo -n / jbctl）
            if jb.code == 13 || jb.code == 1 || jb.code == 126 {
                if let launcher = JBEnvironment.rootLaunchPath() {
                    let viaLauncher = spawn(launcher, args: ["-n", bin] + args, timeout: timeout)
                    if viaLauncher.0 == 0 {
                        return (0, "[jb-launcher \(launcher)] " + viaLauncher.1)
                    }
                }
            }
            // v6.6.15：**关键修复**——越狱分支此前直接 return，跳过了文件末尾的 native 直写兜底。
            // 结果：目标 App 属主是 mobile(501) 时，本可无需 root 直接写，却被 early return 挡住，
            // 表现为「root 写入 failed(85)」而注入失败（用户实测 ControlAgent 注入失败的真因）。
            if let native = nativeFileOp(name, args) {
                return (native.0, native.1.isEmpty ? "[native fallback OK，无需 root]" : native.1)
            }
            let hint: String
            switch jb.code {
            case 13:  hint = "（helper 无 root 权限：越狱终端执行 chown root:wheel + chmod u+s 修复）"
            case 2:   hint = "（helper 不存在）"
            case 85:  hint = "（persona 被拒 ENOSYS，且该操作不能走 native 直写）"
            default:  hint = "（越狱 spawn 失败 errno=\(jb.code)）"
            }
            let nativeNote = nativeError.map { " | 直写也失败: \($0)" } ?? ""
            return (jb.code, "[越狱环境] " + hint + " " + jb.diagPrefix + jb.output + nativeNote)
        }

        // v2.9.284：去掉 [name] 前缀——argv[0]=bin 已是可执行路径 (v2.9.281 修复），
        // argv[1:] 应为纯参数。之前多塞 name 导致 argv[1]="cp"/"chown"/"install_name_tool" 等
        // 被工具当作第一个参数/第一个源文件：cp 报 "target ... No such file" (把 "cp" 当源）、
        // install_name_tool 把 "install_name_tool" 当命令等，大量注入步骤静默failed (_ = 忽略返回）。
        //
        // v8（R⑥）：iOS 17+ 上 persona 恒 85（AMFI 拒绝 persona-mgmt），先查策略层跳过这一跳，
        // 直接走 setuid/无 persona 路径，避免每次都多一次注定失败的 spawn（R⑰ 提速）。
        let personaExpectedBlocked = ExecutionStrategy.DeviceFacts.personaExpectedBlocked
            || !ExecutionStrategy.canUsePersona
        let result = spawnRootDetailed(bin, args: args, timeout: timeout,
                                       usePersona: !personaExpectedBlocked)
        // v6.6.7: ENOSYS fallback——persona spawn 被内核拒时（iOS 17+ AMFI 拒绝 persona-mgmt entitlement），
        // 降级到不带 persona attr 的 posix_spawn，依赖 helper 二进制的 setuid 位由 TrollStore 装上。
        // 这样即使 persona 链路挂了，只要 TrollStore 版本 ≥ 1.1.1 且 helper 有 setuid 位，仍能提权。
        if result.code == 85 {
            let setuidFallback = spawnRootDetailed(bin, args: args, timeout: timeout, usePersona: false)
            if setuidFallback.code == 0 {
                return (0, "[setuid fallback OK] " + setuidFallback.output)
            }
            // fallback 也失败：返回原 85 + fallback 详细错误，便于用户和 AI 诊断
            let fbHint: String
            if setuidFallback.code == 85 {
                fbHint = " (setuid 位也没被 TrollStore 打上)"
            } else if setuidFallback.code == 13 {
                fbHint = " (helper 可执行但无 root 权限——setuid 位缺失或 sandbox 拒绝)"
            } else {
                fbHint = " (fallback errno=\(setuidFallback.code))"
            }
            return (85, "[spawnRoot 85 ENOSYS] " + fbHint + " " + setuidFallback.diagPrefix + setuidFallback.output)
        }
        if result.code != 0, name != "ldid", let ldid = binaryPath("ldid") {
            _ = spawnRootDetailed(ldid, args: ["-S", bin], timeout: 30)
            let retry = spawnRootDetailed(bin, args: args, timeout: timeout)
            if retry.code == 0 { return (0, retry.output) }
        }
        // v6.6.13：**最后兜底**——提权全线失败时，直接试 FileManager 原生写。
        // 目标 App 若由 TrollStore/越狱安装，bundle 属主常是 mobile(501)，
        // 此时 Xosvi（同样 EUID=501）根本不需要 root 就能读写/删除。
        // 之前只有在 geteuid()==0 时才走 nativeFileOp，白白浪费了这条可用路径。
        if result.code != 0, let native = nativeFileOp(name, args) {
            return (native.0, native.1.isEmpty ? "[native fallback OK，无需 root]" : native.1)
        }
        let nativeNote = nativeError.map { " | 直写也失败: \($0)" } ?? ""
        return (result.code, result.output + nativeNote)
    }

    /// v0.2.3：借 xosvid（uid=0 常驻守护）执行包内工具，绕开 rootHide 上必然失败的
    /// persona / setuid spawn。走 `xosvi-build --exec <cwd> <命令>`，等价于 `sh -c`。
    /// 返回 nil = 通道不可用（守护没起 / 没装 / 无 entitlement），调用方退回原路径。
    private func runViaRootChannel(_ bin: String, args: [String], timeout: Double) -> (Int32, String)? {
        let cmd = ([bin] + args).map(shellQuote).joined(separator: " ")
        let res = XosviXPC.helper("xosvi-build",
                                  args: ["--exec", "/private/var/mobile", cmd],
                                  timeout: Int(min(max(timeout, 1), 120)))
        guard (res["ok"] as? Bool) == true else { return nil }
        let code = Int32((res["exit_code"] as? Int) ?? 0)
        var out = (res["stdout"] as? String) ?? ""
        if let err = res["error"] as? String, !err.isEmpty { out += (out.isEmpty ? "" : " ") + err }
        return (code, out)
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - root helper xosvi-bin

    /// xosvi-bin 能代跑的工具（与 Support/xosvi/xosvi-bin.c 的 allowed_tools 一致）。
    private static let rootBinTools: Set<String> = [
        "ldid", "cp", "cp-15", "rm", "mv", "mv-15", "mkdir", "chown",
        "insert_dylib", "optool", "install_name_tool", "ct_bypass", "teamid", "opainject"
    ]

    /// 借守护的 root helper 执行一个包内工具，返回（退出码, 输出）；守护不可用时返回 nil。
    ///
    /// 不经过 shell：请求体是 `[<工具名>, <工具绝对路径>, "--", 参数...]`，
    /// 守护 fork 出 xosvi-bin 后直接 execv，stdout/stderr 原样回传。
    private func runViaBinHelper(_ name: String, bin: String, args: [String], timeout: Double) -> (Int32, String)? {
        guard Self.rootBinTools.contains(name) else { return nil }
        let trusted = prepareTrustedToolForRoot(name, path: bin)
        let res = XosviXPC.helper("xosvi-bin",
                                  args: [name, trusted, "--"] + args,
                                  timeout: Int(min(max(timeout, 1), 120)))
        guard (res["ok"] as? Bool) == true else { return nil }
        // helper 不在白名单 = 守护版本太旧（< 0.2.5），让调用方退回老路径
        if let err = res["error"] as? String, err.contains("not allowed") { return nil }
        let code = Int32((res["exit_code"] as? Int) ?? -1)
        var out = (res["stdout"] as? String) ?? ""
        if let err = res["error"] as? String, !err.isEmpty { out += (out.isEmpty ? "" : " ") + err }
        if code == 127, out.contains("Unable to find") {
            out += "（副本缺 bootstrap 依赖库：\(trusted)）"
        }
        return (code, out)
    }

    /// 为包内工具找一份「跑得起来」的副本。
    ///
    /// 本机实测（iOS 17.1 / roothide）：守护启动的**第一个** helper 会在自己的 bootstrap
    /// 视图（/.jbroot-*/usr/...）里被内核按该视图补齐 rootfs 沙箱扩展；之后 fork 出来的
    /// 子进程再 exec 真根视图路径（/var/containers/.../Xosvi.app/bin/cp）会因为镜像
    /// 不在视图映射里，拿不到同样的扩展 → 被禁写 App 容器，复制 App 只有 EPERM。
    /// 但同一个 App 自带的**原版** cp 从 dash 视图启动却是正常的。
    ///
    /// 所以优先用 bootstrap 里的 cp（`<bootstrap>` 由调用方作为首参传入时解析）；
    /// 没有才退回包内副本，并把失败原因带回去，而不是笼统报「spawnRoot failed」。
    private func prepareTrustedToolForRoot(_ name: String, path: String) -> String {
        // 工具名 → bootstrap 里的名字：coreutils 的 cp 变体都叫 cp
        let wanted = name.hasPrefix("cp") ? "cp" : (name.hasPrefix("mv") ? "mv" : name)
        for root in Self.bootstrapRoots() {
            let cand = root + "/usr/bin/" + wanted
            if FileManager.default.isExecutableFile(atPath: cand) { return cand }
        }
        return path
    }

    /// 本机上 bootstrap 的候选根：共享视图里的 .jbroot-* 目录。
    private static func bootstrapRoots() -> [String] {
        let bases = ["/private/var/containers/Bundle/Application",
                     "/var/containers/Bundle/Application"]
        var out: [String] = []
        let fm = FileManager.default
        for base in bases {
            guard let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
            for e in entries where e.hasPrefix(".jbroot-") {
                let p = base + "/" + e
                if fm.isExecutableFile(atPath: p + "/usr/bin/cp") { out.append(p) }
            }
        }
        return out
    }

    /// v2.9.126：root 环境下 FileManager 原生映射 (对齐 TrollFools isPrivileged 快路径）。
    /// 只处理参数形态明确的简单操作，无法安全映射返回 nil 走 spawn。
    private func nativeFileOp(_ name: String, _ args: [String]) -> (Int32, String)? {
        let fm = FileManager.default
        // v7.15.1：runAsRoot("cp", args: [纯参数]) 传的是 2 个参数（不像 argv 带 argv[0]），
        // 旧的 >= 3 让这条快路径恒不命中 → 注入时的 cp 永远退回 spawnRoot，
        // rootHide 下 spawnRoot 返回 85，于是"明明能写"的操作报失败。
        if name == "cp", args.count >= 2 {
            let src = args[args.count - 2], dst = args[args.count - 1]
            do {
                if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                try fm.copyItem(atPath: src, toPath: dst)
                return (0, "")
            } catch { return (1, "cp failed: \(error.localizedDescription)") }
        }
        if name == "rm" {
            var failed = false
            var errMsg = ""
            for a in args where !a.hasPrefix("-") {
                do {
                    if fm.fileExists(atPath: a) { try fm.removeItem(atPath: a) }
                } catch { failed = true; errMsg = error.localizedDescription }
            }
            return (failed ? 1 : 0, failed ? "rm: \(errMsg)" : "")
        }
        // v7.15.1：同 cp —— 去掉 argv[0] 后正常 mv 是 2 个参数
        if name == "mv", args.count >= 2 {
            let src = args[args.count - 2], dst = args[args.count - 1]
            do {
                if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
                try fm.moveItem(atPath: src, toPath: dst)
                return (0, "")
            } catch { return (1, "mv failed: \(error.localizedDescription)") }
        }
        if name == "mkdir", let path = args.last {
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
                return (0, "")
            } catch { return (1, "mkdir failed: \(error.localizedDescription)") }
        }
        if name == "chown", args.count >= 2 {
            let parts = args[0].split(separator: ":").map { Int($0) }
            let path = args.last ?? ""
            guard parts.count >= 2, let uid = parts[0], let gid = parts[1] else { return nil }
            do {
                try fm.setAttributes([.ownerAccountID: uid, .groupOwnerAccountID: gid], ofItemAtPath: path)
                return (0, "")
            } catch { return (1, "chown failed: \(error.localizedDescription)") }
        }
        return nil
    }

    /// 需要纯净 stdout 的命令 (如 ldid -e 提取 entitlements）：stderr 噪音不混入。
    /// v2.9.126：根治"工具结果混杂"——解析类命令只读 stdout。
    @discardableResult
    func runAsRootStdout(_ name: String, args: [String], timeout: Double = 30) -> (Int32, String) {
        guard let bin = binaryPath(name) else { return (-1, "") }
        // v2.9.284：同 runAsRoot，去掉 [name] 前缀 (argv[0]=bin，argv[1:] 纯参数）
        let r = spawnRootDetailed(bin, args: args, timeout: timeout)
        return (r.code, r.stdout)
    }

    /// v3.0.42：root 执行返回原始 stdout 字节 (二进制安全）——ldid -e 输出 bplist 时用。
    func runAsRootData(_ name: String, args: [String], timeout: Double = 60) -> (Int32, Data) {
        guard let bin = binaryPath(name) else { return (-1, Data()) }
        let r = spawnRootDetailed(bin, args: args, timeout: timeout)
        return (r.code, r.rawStdout)
    }

    /// v3.0.50：设备端注入——多策略签名链依次尝试，哪个能让 opainject dlopen OK用哪个。
    /// 背景 (真机实测链）：TrollStore 安装签名带 Team ID → dyld 报 "different Team IDs"；
    /// 设备端 ldid -S 空签 → iOS16 dyld 报 "code signature invalid (errno=1)"。
    /// 依次试：①ldid -S (空 entitlements adhoc）②ldid -S+platform/no-sandbox entitlements
    /// ③系统 /usr/bin/codesign adhoc ④不重签直接injected (对照）。返回最优结果 + 全链路诊断。
    @discardableResult
    func injectDylib(pid: Int, dylib: String, timeout: Double = 25) -> (Int32, String) {
        let workDir = "/var/mobile/Documents/Workspace"
        let entPath = workDir + "/inject-ent.plist"
        let entXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>platform-application</key><true/>
            <key>com.apple.private.security.no-sandbox</key><true/>
            <key>get-task-allow</key><true/>
        </dict>
        </plist>
        """
        _ = try? entXML.data(using: .utf8)?.write(to: URL(fileURLWithPath: entPath))

        // (签名工具, 参数, 描述)。v3.0.58: ctchain 排第一 (真机验证OK路径），failed依次降级。
        // OK路径 = teamid 提目标 App Team ID + ldid -S 伪签 + ct_bypass CoreTrust (CVE-2023-41991 多签名者）。
        let signSteps: [(String, [String], String)] = [
            ("ctchain", [dylib], "ldid -S + ct_bypass CoreTrust"),
            ("ldid", ["-S", dylib], "ldid -S 空签"),
            ("ldid", ["-S" + entPath, dylib], "ldid -S platform+no-sandbox"),
            ("codesign", ["-f", "-s", "-", dylib], "/usr/bin/codesign adhoc"),
        ]
        var diag = ""
        // 先试各种签名方案
        for (tool, args, desc) in signSteps {
            var rc: Int32 = -1
            var ro = ""
            if tool == "codesign" {
                let r = spawnRootDetailed("/usr/bin/codesign", args: args, timeout: 20)
                rc = r.code; ro = r.output
            } else if tool == "ctchain" {
                // v3.0.53: 先提目标进程真实 Team ID (teamid 解析其 CodeDirectory TeamID 字段），
                // 再 ldid -S 伪签 → ct_bypass -r -i -t <teamID> (CoreTrust 多签名者漏洞，CVE-2023-41991）
                let (tc, to) = runAsRoot("teamid", args: ["\(pid)", "-v"], timeout: 15)
                var teamID = ""
                if tc == 0 {
                    for line in to.components(separatedBy: "\n") where line.hasPrefix("team_id: ") {
                        teamID = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                diag += "[\(desc)] teamid(\(tc)) team=\(teamID.isEmpty ? "(empty)" : teamID)\n"
                diag += to.prefix(900) + "\n"
                (rc, ro) = runAsRoot("ldid", args: ["-S", dylib], timeout: 20)
                if rc != 0 {
                    diag += "[\(desc)] ldid fake-sign failed (\(rc)) \(ro.prefix(150))\n"
                    continue
                }
                (rc, ro) = runAsRoot("ct_bypass", args: ["-r", "-i", dylib, "-t", teamID], timeout: 30)
                if rc != 0 {
                    diag += "【\(desc)】ct_bypass failed(\(rc)) \(ro.prefix(200))\n"
                    continue
                }
            } else {
                (rc, ro) = runAsRoot(tool, args: args, timeout: 20)
            }
            if rc != 0 {
                diag += "[\(desc)] signing failed (\(rc)) \(ro.prefix(150))\n"
                continue
            }
            let (ic, io) = runAsRoot("opainject", args: ["\(pid)", dylib], timeout: timeout)
            let ok = io.contains("dlopen succeeded") || io.contains("Injected") || io.contains("injected successfully")
            diag += "【\(desc)】opainject \(ok ? "OK" : "failed"): " + io.replacingOccurrences(of: "\n", with: " ").suffix(180) + "\n"
            if ok { return (ic, io) }
            // v3.0.62：ctchain (OK路径）opainject failed且是"读内存/__LINKEDIT/task port"类环境问题，
            // 说明 opainject 本身读不到目标进程内存，后续签名变体也救不了——直接停，避免 5 个 opainject 堆在手机上发烫
            if desc.contains("CoreTrust") {
                let envIssue = io.contains("Failed to read process memory") || io.contains("__LINKEDIT not found") || io.contains("Failed to find main thread") || io.contains("task port") || io.contains("EBADARCH") || io.contains("spawnRoot failed")
                if envIssue {
                    diag += "[v3.0.62] ctchain opainject env-class failed, skipping further signing strategy (avoid opainject pileup)\n"
                    break
                }
            }
        }
        // 最后：不重签直接injected (对照 TrollStore 安装签名）
        let (ic2, io2) = runAsRoot("opainject", args: ["\(pid)", dylib], timeout: timeout)
        let ok2 = io2.contains("dlopen succeeded") || io2.contains("Injected") || io2.contains("injected successfully")
        diag += "[no-resign direct inject] opainject \(ok2 ? "OK" : "failed"): " + io2.replacingOccurrences(of: "\n", with: " ").suffix(180) + "\n"
        if ok2 { return (ic2, io2) }
        // v3.0.62：智能failed归因——不是干巴巴的错误，告诉用户为什么failed+怎么办
        var reason = "未知"
        var advice = ""
        if diag.contains("team=(空)") {
            reason = "目标 App 无 Team ID (Apple 系统 App 常见)"
            advice = "系统 App 签名里没有 Team ID 字段，ct_bypass 无法匹配。这类 App 暂不支持内存注入。"
        } else if diag.contains("Failed to read process memory") || diag.contains("__LINKEDIT not found") {
            reason = "opainject 读不到目标进程内存"
            advice = "目标 App 有安全 SDK 防护 (字节/腾讯/阿里系常见)，或进程处于冻结/挂起态。试试：先手动打开目标 App 到前台，再注入。"
        } else if diag.contains("Failed to find main thread") || diag.contains("task port") {
            reason = "opainject 获取 task port failed"
            advice = "目标 App 有反调试/反注入保护 (如聚安全/安全 SDK)，或进程已崩溃。换无防护 App 测试。"
        } else if diag.contains("EBADARCH") {
            reason = "opainject 架构不兼容"
            advice = "opainject 二进制与 Xosvi 主二进制架构不匹配。检查 Resources/bin/opainject 架构。"
        } else if diag.contains("spawnRoot failed (85") || diag.contains("ENOSYS") {
            // v6.6.7: 85 = ENOSYS = persona spawn 被内核拒（不是架构问题）
            reason = "persona spawn 被内核拒绝 (ENOSYS)"
            advice = "posix_spawn 返回 85 (ENOSYS)：persona-mgmt entitlement 未生效或被 iOS AMFI 拒绝。用 inject diagnose 看完整链路：① Xosvi 主二进制是否含 com.apple.private.persona-mgmt；② TSRootBinaries helper 的 setuid 位是否被 TrollStore 打上；③ TrollStore 版本是否 ≥ 1.1.1。iOS 17+ 该问题高发——Xosvi 需双架构原生运行 (arm64+arm64e)。已自动尝试 setuid fallback。"
        } else if diag.contains("spawnRoot failed (2)") {
            reason = "/usr/bin/codesign 不存在 (预期)"
            advice = "TrollStore 环境没有 codesign，正常。ct_bypass 应该能替代。"
        } else if diag.contains("ldid") || diag.contains("ct_bypass") {
            reason = "签名工具failed"
            advice = "ldid 或 ct_bypass 执行failed，检查 bin/ 目录下二进制完整性。"
        }
        diag += "\n【智能归因】failed原因：\(reason)\n【建议】\(advice)\n"
        return (1, diag)
    }

    /// 非 root 版 posix_spawn (部分场景需要 mobile 身份执行）。
    /// v2.9.126：加 timeout (默认 60s，超时 SIGKILL 返回 code=-2），防命令挂起卡死。
    /// v2.9.281：argv[0] 必须放可执行路径——posix_spawn 的 argv[0] 是程序名惯例，
    /// trollstorehelper 等从 argv[1] 开始解析命令；之前直接放 args 导致 cmd 错位
    ///  (收到 "installd"/"custom" 而非 "install"/"uninstall"），helper 静默返回 0 假OK。
    func spawn(_ path: String, args: [String], timeout: Double = 60) -> (Int32, String) {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)] + args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var pid: pid_t = 0
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        pipe(&outPipe)
        pipe(&errPipe)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], 2)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])

        var env: [UnsafeMutablePointer<CChar>?] = [
            strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"),
            strdup("HOME=/var/mobile"),
            nil
        ]
        defer { for p in env where p != nil { free(p) } }

        let status = posix_spawn(&pid, path, &fileActions, nil, &argv, &env)
        posix_spawn_file_actions_destroy(&fileActions)
        close(outPipe[1]); close(errPipe[1])

        var out = Data()
        if status == 0 {
            // v2.9.126：超时控制 (timer 到点 SIGKILL，防挂起永久卡死）
            var timedOut = false
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { timedOut = true; kill(pid, SIGKILL) }
            timer.resume()

            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(outPipe[0], &buf, buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            var buf2 = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(errPipe[0], &buf2, buf2.count)
                if n <= 0 { break }
                out.append(buf2, count: n)
            }
            var st: Int32 = 0
            waitpid(pid, &st, 0)
            timer.cancel()
            close(outPipe[0]); close(errPipe[0])
            if timedOut { return (-2, "timeout after \(Int(timeout))s (SIGKILL)") }
            let code = Int32((UInt32(st) >> 8) & 0xff)  // WEXITSTATUS
            return (code, String(data: out, encoding: .utf8) ?? "")
        }
        close(outPipe[0]); close(errPipe[0])
        return (status, "posix_spawn failed (\(status))")
    }

    /// v2.9.52：root 版 spawn (真正修复版）。
    /// 对照 TrollStore 官方 TSUtil.m spawnRoot：persona 99 + uid=0 + gid=0，编译时链接 (@_silgen_name）。
    /// 之前用 dlsym 运行时查找，iOS 上这些是隐藏符号，dlsym 全返回 nil → persona 没设置 → euid=501 → EPERM。
    /// 编译时链接后直接调用，有 persona-mgmt entitlement 即可 root spawn，不依赖 TSRootBinaries setuid 位。
    /// v2.9.57：完全重写，对齐 TrollFools AuxiliaryExecute+Spawn.swift。
    /// v2.9.126：薄封装，真实实现走 spawnRootDetailed (stdout/stderr 分离 + 超时 + signal 区分）。
    @discardableResult
    func spawnRoot(_ path: String, args: [String], timeout: Double = 60) -> (Int32, String) {
        let r = spawnRootDetailed(path, args: args, timeout: timeout)
        return (r.code, r.output)
    }

    /// v2.9.126：root spawn 结构化版。
    /// - stdout/stderr 分离：解析类命令 (ldid -e 等）可只取 stdout，根治"stderr 噪音混进结果"
    /// - 超时：默认 60s，超时 SIGKILL → code=-2，调用方可报 [TOOL_TIMEOUT]
    /// - signal/exit 区分：被信号杀死的命令 → signaled=true + signal 号，而非误报 exit code
    /// 保持 v2.9.57 的非阻塞 pipe + DispatchSource 异步读取 + waitpid 同步等待。
    /// v6.6.7: 新增 usePersona 参数——false 时不设置 persona 属性，依赖目标二进制的 setuid 位提权。
    ///         用于 posix_spawn 返回 85 (ENOSYS) 时的 fallback：iOS 17+ 上 persona spawn 被 AMFI 拒绝时，
    ///         若 helper 二进制被 TrollStore 打上 setuid 位，走这条路径仍能提权。
    // MARK: - v8（R②/R⑥）：spawn 探针（ExecutionStrategy 用）
    //
    // 与 spawnRootDetailed 共享同一条 spawn 链，但只关心「能不能起来」，不读输出。
    // usePersona=false → 依赖 setuid 位；true → persona 链路（iOS 17+ 恒 85）。
    /// v8.1：真·提权探针——`launchctl print system` 只有 uid 0 能成功。
    /// 旧探针只看「spawn 成功」，persona 明明没拿到 root（proc-euid=501）也报 ok，误导模型。
    func spawnPrivilegeProbe(usePersona: Bool) -> SpawnProbe.SpawnResult {
        let r = spawnRootDetailed("/bin/launchctl", args: ["print", "system"],
                                  timeout: 8, usePersona: usePersona)
        if r.code == 0 { return .ok }
        let code = Int32(r.code)
        let detail: String
        switch code {
        case 85: detail = usePersona ? "persona ENOSYS(85)" : "setuid spawn ENOSYS(85)"
        case 13: detail = "EACCES(13)：没有 root 权限"
        case 1:  detail = "launchctl 退出 1：uid 不是 0（persona 未生效）"
        case 2:  detail = "launchctl 不存在"
        default: detail = "exit/errno=\(code)"
        }
        return .failed(code: code, detail: detail)
    }

    func spawnRootProbe(usePersona: Bool) -> SpawnProbe.SpawnResult {
        guard let bin = binaryPath("ldid") else {
            return .failed(code: 2, detail: "helper not bundled")
        }
        let r = spawnRootDetailed(bin, args: ["-h"], timeout: 6, usePersona: usePersona)
        if r.code == 0 { return .ok }
        // 把真实 errno 归位（spawnRootDetailed 里 code 即 errno/exit）
        let code = Int32(r.code)
        let detail: String
        switch code {
        case 85: detail = usePersona ? "persona spawn ENOSYS(85)——iOS 17+ AMFI 拒绝 persona-mgmt" : "setuid spawn ENOSYS(85)——容器内第三方二进制被拦"
        case 86: detail = "EBADEXEC(86)：二进制格式不被认可"
        case 13: detail = "EACCES(13)：helper 无执行/root 权限"
        case 2:  detail = "helper 不存在"
        default: detail = r.diagPrefix + String(r.output.prefix(120))
        }
        return .failed(code: code, detail: detail)
    }

    func spawnRootDetailed(_ path: String, args: [String], timeout: Double = 60, usePersona: Bool = true) -> SpawnResult {
        // v2.9.281：argv[0] 放可执行路径 (posix_spawn 程序名惯例）。之前 argv[0]=args[0]
        // 导致 trollstorehelper 的 main (从 argv[1] 解析 cmd）把命令参数当成命令：
        // install/uninstall/refresh-all 全部假OK返回 0，实际从未执行 (小红书装不上根因）。
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)] + args.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        var binSetuid = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let mode = attrs[.posixPermissions] as? Int {
            binSetuid = (mode & 0o4000) != 0 ? 1 : 0
        }

        // 非阻塞 pipe
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        pipe(&outPipe)
        pipe(&errPipe)
        _ = fcntl(outPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(errPipe[0], F_SETFL, O_NONBLOCK)

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[0])
        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // v6.6.7: usePersona=false 时不设置 persona 属性（依赖 helper 二进制的 setuid 位提权）
        let rPersona: Int32
        let rUid: Int32
        let rGid: Int32
        if usePersona {
            rPersona = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE)
            rUid = posix_spawnattr_set_persona_uid_np(&attr, 0)
            rGid = posix_spawnattr_set_persona_gid_np(&attr, 0)
        } else {
            rPersona = -999; rUid = -999; rGid = -999
        }
        defer { posix_spawnattr_destroy(&attr) }

        let personaFlag = usePersona ? "on" : "off"
        let diagPrefix = "[bin-setuid=\(binSetuid) proc-euid=\(geteuid()) persona_flag=\(personaFlag) persona_r=\(rPersona) uid_r=\(rUid) gid_r=\(rGid)] "

        // 环境变量：继承当前环境 + DISABLE_TWEAKS=1 + PATH
        var envBuilder = [String: String]()
        var currentEnv = environ
        while let rawStr = currentEnv.pointee {
            defer { currentEnv += 1 }
            let str = String(cString: rawStr)
            if let eq = str.firstIndex(of: "=") {
                envBuilder[String(str[..<eq])] = String(str[str.index(after: eq)...])
            }
        }
        envBuilder["DISABLE_TWEAKS"] = "1"
        envBuilder["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        var env: [UnsafeMutablePointer<CChar>?] = envBuilder.map { strdup("\($0.key)=\($0.value)") }
        env.append(nil)
        defer { for p in env where p != nil { free(p) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, path, &fileActions, &attr, argv, env)
        guard spawnStatus == 0 else {
            close(outPipe[0]); close(outPipe[1])
            close(errPipe[0]); close(errPipe[1])
            // v6.6.7: 加 errno 名字，避免用户看到裸数字 85/13/8 猜谜
            let errnoName: String
            switch spawnStatus {
            case 2:  errnoName = "ENOENT"    // file not found
            case 8:  errnoName = "ENOEXEC"   // exec format error
            case 12: errnoName = "ENOMEM"    // out of memory
            case 13: errnoName = "EACCES"    // permission denied
            case 14: errnoName = "FAULT"
            case 22: errnoName = "EINVAL"    // invalid argument
            case 85: errnoName = "ENOSYS"    // function not implemented (persona spawn rejected by kernel)
            case 86: errnoName = "ENOTDIR"   // not a directory
            default: errnoName = "errno=\(spawnStatus)"
            }
            let hint: String
            switch spawnStatus {
            case 85: hint = " [persona-mgmt 未生效或 AMFI 拒绝；见 inject diagnose]"
            case 13: hint = " [权限被拒，检查 entitlements 或 setuid 位]"
            case 2:  hint = " [二进制路径不存在]"
            case 8:  hint = " [二进制格式不可执行]"
            default: hint = ""
            }
            return SpawnResult(code: spawnStatus, stdout: "", stderr: "", timedOut: false,
                               signaled: false, signal: 0,
                               diagPrefix: diagPrefix + "spawnRoot failed (\(spawnStatus) \(errnoName))\(hint) ")
        }

        close(outPipe[1]); close(errPipe[1])

        var stdoutStr = ""
        var stderrStr = ""
        var stdoutData = Data()   // v3.0.42：原始字节 (二进制安全，bplist 等）
        let outputLock = NSLock()
        let bufsiz = 65536

        let outSource = DispatchSource.makeReadSource(fileDescriptor: outPipe[0], queue: .global())
        let errSource = DispatchSource.makeReadSource(fileDescriptor: errPipe[0], queue: .global())
        let outSem = DispatchSemaphore(value: 0)
        let errSem = DispatchSemaphore(value: 0)

        outSource.setCancelHandler { close(outPipe[0]); outSem.signal() }
        errSource.setCancelHandler { close(errPipe[0]); errSem.signal() }

        outSource.setEventHandler {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buf.deallocate() }
            let n = read(outPipe[0], buf, bufsiz)
            guard n > 0 else {
                if n == -1 && errno == EAGAIN { return }
                outSource.cancel()
                return
            }
            let arr = Array(UnsafeBufferPointer(start: buf, count: n))
            outputLock.lock()
            stdoutData.append(contentsOf: arr)
            stdoutStr += String(decoding: arr, as: UTF8.self)
            outputLock.unlock()
        }
        errSource.setEventHandler {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufsiz)
            defer { buf.deallocate() }
            let n = read(errPipe[0], buf, bufsiz)
            guard n > 0 else {
                if n == -1 && errno == EAGAIN { return }
                errSource.cancel()
                return
            }
            let arr = Array(UnsafeBufferPointer(start: buf, count: n)) + [UInt8(0)]
            arr.withUnsafeBufferPointer { ptr in
                let s = String(cString: unsafeBitCast(ptr.baseAddress, to: UnsafePointer<CChar>.self))
                outputLock.lock(); stderrStr += s; outputLock.unlock()
            }
        }
        outSource.resume()
        errSource.resume()

        // v2.9.126：超时控制——timer 到点 SIGKILL，防命令挂起永久卡死
        var timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { timedOut = true; kill(pid, SIGKILL) }
        timer.resume()

        // v2.9.63：用 waitpid 同步等待进程结束，替代 DispatchSource.makeProcessSource。
        // 原实现有竞态：/usr/bin/id 等快速命令在 procSource.resume() 前就退出，.exit 事件丢失，
        // exitCode 停在初始值 -1，导致 Entitlements 检测误报"未生效"。
        var st: Int32 = 0
        var wr: Int32 = 0
        repeat { wr = waitpid(pid, &st, 0) } while wr == -1 && errno == EINTR
        timer.cancel()
        // 进程已退出，等待 pipe 数据全部读完
        // v2.9.280：waitpid 返回后 DispatchSource 可能仍有余量未读 (大输出被 64KB pipe
        // 缓冲截断、进程已退出导致 event 不再触发），先同步 drain 两个 pipe 到 EOF，
        // 再等 sem，避免 install/sign 等大输出日志丢失 (曾导致 install 中间日志全丢、
        // 无法诊断"返回 0 却没装上"）。
        func drain(_ fd: Int32) {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n > 0 {
                    let chunk = Array(buf.prefix(n))
                    outputLock.lock()
                    if fd == outPipe[0] {
                        stdoutData.append(contentsOf: chunk)
                        stdoutStr += String(decoding: chunk, as: UTF8.self)
                    } else {
                        stderrStr += String(decoding: chunk, as: UTF8.self)
                    }
                    outputLock.unlock()
                } else { break }
            }
        }
        drain(outPipe[0])
        drain(errPipe[0])
        outSource.cancel(); errSource.cancel()
        outSem.wait()
        errSem.wait()

        // v2.9.126：signal/exit 区分 (对齐 TrollFools WIFSIGNALED/WTERMSIG）
        var signaled = false
        var signal = Int32(0)
        if timedOut {
            return SpawnResult(code: -2, stdout: stdoutStr, stderr: stderrStr, timedOut: true,
                               signaled: false, signal: 0,
                               diagPrefix: diagPrefix + "timeout after \(Int(timeout))s (SIGKILL) ")
        }
        if (st & 0x7F) != 0 && (st & 0x7F) != 0x7F {
            signaled = true
            signal = st & 0x7F   // WTERMSIG
        }
        let exitCode = signaled ? -100 - signal : Int32((UInt32(st) >> 8) & 0xff)

        return SpawnResult(code: exitCode, stdout: stdoutStr, stderr: stderrStr, timedOut: false,
                           signaled: signaled, signal: signal, diagPrefix: diagPrefix,
                           rawStdout: stdoutData)
    }

    // MARK: - 路径解析

    func executablePath(_ app: AppCatalog.AppEntry) -> String {
        let plist = (app.path as NSString).appendingPathComponent("Info.plist")
        if let dict = NSDictionary(contentsOfFile: plist),
           let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty {
            return (app.path as NSString).appendingPathComponent(exe)
        }
        let fallback = app.bundleId.split(separator: ".").last.map(String.init) ?? app.bundleId
        return (app.path as NSString).appendingPathComponent(fallback)
    }

    /// 通过扫描二进制内是否含 "ControlAgent" 字符串判断注入状态 (LC_LOAD_DYLIB 名字会被写入）
    /// v2.9.265：只读前 1MB——load commands 区在文件头 64KB 内，全量读 394MB 主二进制的
    /// Data(contentsOf:) 会压垮 Xosvi (实测多次内存被杀/断连）。
    func isInjected(_ mainBinary: String) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: mainBinary)) else { return false }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 1024 * 1024)) ?? Data()
        return head.range(of: "ControlAgent".data(using: .utf8)!) != nil
    }

    // MARK: - 公total API

    /// 高危 App 前缀 (v2.9.89 高危护栏）：支付/银行/系统等注入风险高，注入前强制提醒
    static let sensitiveBundleHints = [
        "com.tencent.mm", "com.tencent.xin", "com.alipay", "com.apple",
        "com.unionpay", "com.ccb", "com.icbc", "com.cmbchina", "com.bank",
        "com.paypal", "com.apple.mobilesafari", "com.tencent.wework",
    ]

    static func isSensitive(_ bundleId: String) -> Bool {
        sensitiveBundleHints.contains { bundleId.lowercased().hasPrefix($0) }
    }

    /// 是否为系统/越狱基础库 (清理残留时不能删这些）
    static func isSensitiveSystemLibrary(_ itemName: String) -> Bool {
        let lower = itemName.lowercased()
        if lower.hasPrefix("libswift") { return true }
        let names = ["cydiasubstrate", "ellekit", "libsubstrate", "libsubstitute",
                     "libellekit", "substitute", "libhooker", "libjailbreak"]
        return names.contains { lower.contains($0) }
    }

    /// 注入资产忽略名单 (对齐 TrollFools ignoredDylibAndFrameworkNames）
    private static let ignoredDylibNames: Set<String> = [
        "cydiasubstrate", "cydiasubstrate.framework", "ellekit", "ellekit.framework",
        "libsubstrate.dylib", "libsubstitute.dylib", "libellekit.dylib",
    ]

    // MARK: 备份辅助 (对齐 TrollFools：备份后缀 .troll-fools.bak）

    private func alternateURL(for target: String) -> String {
        target + ".troll-fools.bak"
    }

    private func hasAlternate(_ target: String) -> Bool {
        FileManager.default.fileExists(atPath: alternateURL(for: target)) ||
        FileManager.default.fileExists(atPath: target + ".bak_macho")   // 旧格式兼容
    }

    /// 持久化注入资产到 /var/mobile/Library/TrollFools/PersistentPlugins/<bid>/ (对齐 TrollFools persist：
    /// App 覆盖重装/更新后可从持久区恢复注入）
    private static let persistentPluginsRoot = "/var/mobile/Library/TrollFools/PersistentPlugins"
    private func persistAsset(name: String, src: String, bid: String) {
        let base = Self.persistentPluginsRoot + "/" + bid
        let dst = (base as NSString).appendingPathComponent(name)
        let (mc, _) = runAsRoot("mkdir", args: ["-p", base])
        guard mc == 0 else { return }
        _ = runAsRoot("rm", args: ["-rf", dst])
        let (cc, _) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", src, dst])
        if cc == 0 {
            _ = runAsRoot("chown", args: ["-R", "501:501", dst])
        }
    }

    /// 从持久化区启用插件 (对齐 TrollFools：启用 = 从 PersistentPlugins 副本重新注入）
    func restore(bundleId: String) throws -> [String: Any] {
        let base = Self.persistentPluginsRoot + "/" + bundleId
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            throw MCPError.failed("this App has no persisted plugin to enable (inject first to persist)")
        }
        var restored: [String: String] = [:]
        for item in items.sorted() where item.hasSuffix(".dylib") || item.hasSuffix(".framework") || item.hasSuffix(".bundle") {
            let src = (base as NSString).appendingPathComponent(item)
            let r = try enable(bundleId: bundleId, dylibName: "@rpath/" + item, dylibSourcePath: src)
            restored[item] = (r["injected"] as? Bool == true) ? "enabled" : "skipped"
        }
        return ["action": "restore", "bundleId": bundleId, "restored": restored]
    }

    // MARK: - CydiaSubstrate (对齐 TrollFools prepareSubstrate / standardizeLoadCommandDylibToSubstrate）
    // v2.9.121：根治 substrate 插件闪退——不再拒绝，而是内置 CydiaSubstrate.framework.zip，
    // 注入用户插件时自动准备并拷入目标 App，插件对 substrate 的引用重定向到内置路径。

    private static let substrateFwkName = "CydiaSubstrate.framework"
    private static let substrateName = "CydiaSubstrate"
    static let ignoredRuntimeNames: Set<String> = [
        "cydiasubstrate", "cydiasubstrate.framework", "ellekit", "ellekit.framework",
        "libsubstrate.dylib", "libsubstitute.dylib", "libellekit.dylib",
    ]

    /// 解压内置 CydiaSubstrate.framework.zip → 临时目录，标记 .troll-fools + ct_bypass + chown 33:33 (对齐 prepareSubstrate）
    private func prepareSubstrate() throws -> String {
        let tmpRoot = NSTemporaryDirectory() + "XosviSubstrate-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: tmpRoot, withIntermediateDirectories: true)
        let zipPath = Bundle.main.path(forResource: "CydiaSubstrate.framework", ofType: "zip")
            ?? (binDir.deletingLastPathComponent().appendingPathComponent("CydiaSubstrate.framework.zip").path)
        guard FileManager.default.fileExists(atPath: zipPath) else {
            throw MCPError.failed("CydiaSubstrate.framework.zip not bundled")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: zipPath))
        let entries = try ZIPReader.extractEntries(from: data)
        for e in entries {
            let dest = tmpRoot + "/" + e.name
            try? FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try e.data.write(to: URL(fileURLWithPath: dest))
        }
        let fwk = tmpRoot + "/" + Self.substrateFwkName
        guard FileManager.default.fileExists(atPath: fwk) else { throw MCPError.failed("substrate extraction failed") }
        _ = runAsRoot("touch", args: [fwk + "/.troll-fools"])
        let machO = fwk + "/" + Self.substrateName
        let (pc, po) = runAsRoot("ct_bypass", args: ["-r", "-i", machO, "-t", "TROLLTROLL"])
        if pc != 0 { AuditLog.shared.log("injection.substrate.ct", detail: "exit=\(pc) \(po)") }
        _ = runAsRoot("chown", args: ["33:33", fwk])
        return fwk
    }

    /// 插件内 substrate 系 load command → 内置 substrate 路径 (对齐 standardizeLoadCommandDylibToSubstrate）
    private func standardizeLoadCommandDylibToSubstrate(_ asset: String) {
        let machO: String
        if asset.hasSuffix(".framework") {
            machO = (asset as NSString).appendingPathComponent((asset as NSString).deletingPathExtension)
        } else {
            machO = asset
        }
        guard let info = MachOAnalyzer.analyze(machO) else { return }
        for dylib in info.dylibs {
            let lower = dylib.lowercased()
            if Self.ignoredRuntimeNames.contains(where: { lower.hasSuffix("/" + $0) || lower == $0 }) {
                _ = runAsRoot("install_name_tool", args: ["-change", dylib,
                    "@executable_path/Frameworks/" + Self.substrateFwkName + "/" + Self.substrateName, machO])
            }
        }
    }

    // MARK: - iTunesMetadata 分离 (对齐 TrollFools setMetadataDetached：注入期间移开 metadata，
    // 避免 App Store 更新/校验把注入痕迹当异常）

    private func metadataURLs(bundleId: String) -> (meta: String, bak: String) {
        guard let appPath = AppCatalog.find(bundleId)?.path else { return ("", "") }
        let containerURL = URL(fileURLWithPath: appPath).deletingLastPathComponent()
        let metaURL = containerURL.appendingPathComponent("iTunesMetadata.plist")
        let bakURL = containerURL.appendingPathComponent("iTunesMetadata.plist.bak")
        return (metaURL.path, bakURL.path)
    }

    func detachMetadata(bundleId: String) {
        let m = metadataURLs(bundleId: bundleId)
        guard !m.meta.isEmpty else { return }
        if FileManager.default.fileExists(atPath: m.meta), !FileManager.default.fileExists(atPath: m.bak) {
            _ = runAsRoot("mv", args: ["-f", m.meta, m.bak])
        }
    }

    func attachMetadata(bundleId: String) {
        let m = metadataURLs(bundleId: bundleId)
        guard !m.bak.isEmpty else { return }
        if FileManager.default.fileExists(atPath: m.bak), !FileManager.default.fileExists(atPath: m.meta) {
            _ = runAsRoot("mv", args: ["-f", m.bak, m.meta])
        }
    }

    /// 启动自检：open -b 兜底直接执行主二进制；两次探测进程均不在 → 判定闪退
    // v2.9.190：TrollStore 无 shell (/bin/sh、/usr/bin/open、/bin/ps、spawnRoot 全部不可用，
    // 真机实测）——原实现启动与探测全走 spawnRoot，恒failed → 误判"注入后必闪退"并Auto rollback，
    // 导致 201 个工具里 injection.enable/control.inject 注入任意 App 都被判"闪退"。
    // 修复：启动改用 LSWorkspace 私有 API (与 app.start 同款，185 起真机实测可拉起），
    //       探测改用 libproc (proc_listallpids + proc_pidpath，排除 .appex，与 app.status 同款）。
    private func launchAndProbe(bundleId: String, execName: String, executable: String) -> Bool {
        // v2.9.301：大厂App (豆包/小红书/微信）冷启动需8-15秒，旧版仅7秒窗口会误判闪退→回滚好注入。
        // 改为25秒窗口、每1.5秒探测一次；拉起pid=0时也继续探测 (LSWorkspace可能异步拉起）。
        _ = DecryptEngine.launchApp(bundleId: bundleId, waitSeconds: 2)
        for _ in 0..<16 {
            Thread.sleep(forTimeInterval: 1.5)
            if appProcessAlive(executable) { return true }
        }
        return false
    }

    private func appProcessAlive(_ executable: String) -> Bool {
        // executable = xxx.app/xxx；bundlePath = xxx.app (findPidByExecutable 排除 .appex 后命中主进程）
        let bundlePath = (executable as NSString).deletingLastPathComponent
        return findPidByExecutable(bundlePath: bundlePath) > 0
    }

    @discardableResult
    private func makeAlternate(_ target: String) throws -> String {
        let alt = alternateURL(for: target)
        if !FileManager.default.fileExists(atPath: alt) {
            let (c, o) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", target, alt])
            if c != 0 { throw MCPError.failed("root cp backup failed (\(c)): \(o)") }
        }
        return alt
    }

    /// 从备份restored (优先新格式 .troll-fools.bak，兼容旧 .bak_macho），OK后删备份
    @discardableResult
    func restoreAlternate(_ target: String) throws -> Bool {
        let alt = alternateURL(for: target)
        let legacy = target + ".bak_macho"
        let backupPath: String
        if FileManager.default.fileExists(atPath: alt) {
            backupPath = alt
        } else if FileManager.default.fileExists(atPath: legacy) {
            backupPath = legacy
        } else {
            return false
        }
        _ = runAsRoot("rm", args: ["-f", target])
        let (c, o) = runAsRoot("mv", args: ["-f", backupPath, target])
        if c != 0 { throw MCPError.failed("root mv restore failed (\(c)): \(o)") }
        _ = runAsRoot("rm", args: ["-f", backupPath])
        return true
    }

    // MARK: Mach-O collected (对齐 TrollFools frameworkMachOsInBundle + locateAvailableMachO）

    /// 收集可injected Mach-O：Frameworks/ 下未加密 dylib (字典序），主二进制垫底。
    /// 跳过：非 Mach-O、加密段 (cryptid!=0）、忽略名单、备份文件、已注入资产文件。
    func collectInjectableMachOs(_ app: AppCatalog.AppEntry, strategy: String = "lexicographic") -> [String] {
        var candidates: [String] = []
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworksDir),
           let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            for item in items.sorted() {
                let full = (frameworksDir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                let lower = item.lowercased()
                // 跳过备份文件、忽略名单、非 dylib 目录
                if item.hasSuffix(".troll-fools.bak") || item.hasSuffix(".bak_macho") { continue }
                if Self.ignoredDylibNames.contains(lower) { continue }
                if lower.hasPrefix("libswift") { continue }
                if isDir.boolValue {
                    // .framework 目录：解析内部可执行文件
                    if lower.hasSuffix(".framework") {
                        let exeName = (item as NSString).deletingPathExtension
                        let exe = (full as NSString).appendingPathComponent(exeName)
                        // v2.9.305：不再用 isInjectiveMachO(要求cryptid==0)过滤——小红书自家
                        // framework(Sheim/DisGuard/Dis) 可能加密，TrollFools 靠 ct_bypass 强注。
                        // 只要是合法 Mach-O 就列进候选，注入时统一 ct_bypass。
                        if MachOAnalyzer.isValidMachO(exe) { candidates.append(exe) }
                    }
                    continue
                }
                if lower.hasSuffix(".dylib"), MachOAnalyzer.isValidMachO(full) {
                    candidates.append(full)
                }
            }
        }
        // 主二进制垫底 (TrollFools 默认 preferMainExecutable=false）
        let main = executablePath(app)
        if MachOAnalyzer.isInjectiveMachO(main) { candidates.append(main) }

        // 备份差分 (对齐 TrollFools Build 246 三层防御第三层）：当前 load commands 与
        // .troll-fools.bak 备份的差集 = 注入添加的 → 排除已injected Mach-O，防止二次注入误选
        var injectedNames = Set<String>()
        for m in (candidates + [main]) {
            let alt = alternateURL(for: m)
            if FileManager.default.fileExists(atPath: alt),
               let cur = MachOAnalyzer.analyze(m)?.dylibs,
               let orig = MachOAnalyzer.analyze(alt)?.dylibs {
                for n in cur where !orig.contains(n) {
                    injectedNames.insert((n as NSString).lastPathComponent)
                }
            }
        }
        if !injectedNames.isEmpty {
            let before = candidates.count
            candidates = candidates.filter { !injectedNames.contains(($0 as NSString).lastPathComponent) }
            AuditLog.shared.log("injection.backupdiff", detail: "excluded=\(before - candidates.count) \(injectedNames.sorted())")
        }

        // v2.9.310：对齐 TrollFools intersection——主二进制直接链接的 ∩ 枚举到的
        // 优先选真链接的 (启动必加载）；空了才 fallback 全部 (懒加载 App）
        let mainDylibNames = Set((MachOAnalyzer.analyze(executablePath(app))?.dylibs ?? [])
            .map { ($0 as NSString).lastPathComponent })
        let intersected = candidates.filter { mainDylibNames.contains(($0 as NSString).lastPathComponent) }
        if !intersected.isEmpty {
            AuditLog.shared.log("injection.intersection", detail: "\(intersected.count)/\(candidates.count) 主二进制直接链接")
            candidates = intersected
        } else {
            AuditLog.shared.log("injection.intersection_empty", detail: "主二进制无直接链接framework,fallback全部\(candidates.count)")
        }

        // 注入策略排序 (对齐 TrollFools Strategy：lexicographic 默认 / fast 大小升序 / preorder / postorder）
        switch strategy {
        case "fast":
            candidates = candidates.sorted { a, b in
                let s1 = (try? (FileManager.default.attributesOfItem(atPath: a)[.size] as? Int)) ?? 0
                let s2 = (try? (FileManager.default.attributesOfItem(atPath: b)[.size] as? Int)) ?? 0
                return s1 == s2 ? (a as NSString).lastPathComponent < (b as NSString).lastPathComponent : s1 < s2
            }
        case "postorder":
            candidates = candidates.reversed()
        case "preorder":
            break
        default:
            candidates = candidates.sorted { ($0 as NSString).lastPathComponent < ($1 as NSString).lastPathComponent }
        }
        return candidates
    }

    /// 注入资产列表 (对齐 TrollFools injectedDylibAndFrameworkURLsInBundle）：
    /// Frameworks/ 下非系统 dylib + 带 .troll-fools 标记的 framework/bundle
    func injectedAssets(in app: AppCatalog.AppEntry) -> [String] {
        var assets: [String] = []
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworksDir),
           let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            for item in items {
                let full = (frameworksDir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                let lower = item.lowercased()
                if lower.hasPrefix("libswift") || Self.ignoredDylibNames.contains(lower) { continue }
                if item.hasSuffix(".troll-fools.bak") || item.hasSuffix(".bak_macho") { continue }
                if lower.hasSuffix(".dylib"), !isDir.boolValue {
                    assets.append(full)
                } else if lower.hasSuffix(".framework") || lower.hasSuffix(".bundle") {
                    // 只有带注入标记的才算 (.troll-fools 文件）
                    let marker = (full as NSString).appendingPathComponent(".troll-fools")
                    if FileManager.default.fileExists(atPath: marker) { assets.append(full) }
                }
            }
        }
        return assets.sorted()
    }

    /// 收集被修改过的 Mach-O (有备份的）：主二进制 + Frameworks 下所有 dylib
    func collectModifiedMachOs(_ app: AppCatalog.AppEntry) -> [String] {
        var modified: [String] = []
        let main = executablePath(app)
        if hasAlternate(main) { modified.append(main) }
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        if FileManager.default.fileExists(atPath: frameworksDir),
           let items = try? FileManager.default.contentsOfDirectory(atPath: frameworksDir) {
            for item in items {
                let full = (frameworksDir as NSString).appendingPathComponent(item)
                if item.hasSuffix(".troll-fools.bak") || item.hasSuffix(".bak_macho") { continue }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue, item.lowercased().hasSuffix(".framework") {
                    let exeName = (item as NSString).deletingPathExtension
                    let exe = (full as NSString).appendingPathComponent(exeName)
                    if hasAlternate(exe) { modified.append(exe) }
                    continue
                }
                if hasAlternate(full) { modified.append(full) }
            }
        }
        return modified
    }

    /// 移除指定资产的加载命令 (对齐 TrollFools optool uninstall）
    private func removeLoadCommand(assetName: String, from target: String) -> (Int32, String) {
        runAsRoot("optool", args: ["uninstall", "-p", assetName, "-t", target])
    }

    /// 伪签 (对齐 TrollFools cmdPseudoSign）：
    /// - 已有代码签名且非 force → 跳过，避免二次签名破坏原签名 (v2.9.104 修复：此前无条件 ldid -S
    ///   会把主二进制的 entitlements 抹掉 → App 启动被 amfid 拒 → 注入后闪退）
    /// - 主二进制 (MH_EXECUTE=0x2）→ 保留 entitlements：ldid -e 提取 → -S<xml> 重签
    /// - 无签名 → ldid -S
    @discardableResult
    private func pseudoSign(_ target: String, force: Bool = false) -> (Int32, String) {
        guard let info = MachOAnalyzer.analyze(target), info.valid else {
            return runAsRoot("ldid", args: ["-S", target])
        }
        guard force || !info.hasCodeSignature else {
            return (0, "skip: already signed")
        }
        if info.fileType == 0x2 {
            // v2.9.126：走 runAsRootStdout——只读纯净 stdout，根治"ldid 错误混进 entitlements"
            let (c1, o1) = runAsRootStdout("ldid", args: ["-e", target], timeout: 30)
            if c1 == 0 {
                let trimmed = o1.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let xmlPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("ent_\(UUID().uuidString).xml")
                    do {
                        try trimmed.write(toFile: xmlPath, atomically: true, encoding: .utf8)
                        return runAsRoot("ldid", args: ["-S\(xmlPath)", target])
                    } catch {}
                }
            }
            return (c1, o1)
        }
        return runAsRoot("ldid", args: ["-S", target])
    }

    /// CoreTrust 重签 + 属主 (对齐 TrollFools cmdCoreTrustBypass + cmdChangeOwnerToInstalld）
    /// v2.9.104：teamID 用目标 App 真实 TeamID (TrollFools 用 LSApplicationProxy.teamID()），
    /// fallback TROLLTROLL——部分 App 对签名 TeamID 有校验，固定 TROLLTROLL 会被拒启动
    @discardableResult
    func coreTrustBypass(_ target: String, teamID: String = "TROLLTROLL") -> (Int32, String) {
        _ = pseudoSign(target)
        let (c, o) = runAsRoot("ct_bypass", args: ["-r", "-i", target, "-t", teamID])
        _ = runAsRoot("chown", args: ["33:33", target])
        return (c, o)
    }

    /// 目标 App 真实 TeamID。
    /// v3.0.59：优先用 teamid 工具直接解析主二进制 CodeDirectory teamOffset 字段 (与内存注入链路统一，
    /// 不依赖 ldid -e entitlements 解析）；failed才回退 ldid -e application-identifier 前缀；再failed TROLLTROLL。
    func realTeamID(for bundleId: String, appPath: String?) -> String {
        guard let main = appPath else { return "TROLLTROLL" }
        if let tid = teamIDFromBinary(main) {
            return tid
        }
        // 旧通道兜底：ldid -e 解析 entitlements application-identifier = TEAMID.bundleId
        let (c, o) = runAsRootStdout("ldid", args: ["-e", main], timeout: 30)
        guard c == 0, let r = o.range(of: "application-identifier"), o.contains(bundleId) else {
            return "TROLLTROLL"
        }
        let tail = o[r.upperBound...]
        if let open = tail.range(of: "<string>"), let close = tail.range(of: "</string>") {
            let val = String(tail[open.upperBound..<close.lowerBound])
            if val.hasSuffix(bundleId) {
                let team = String(val.dropLast(bundleId.count))
                if !team.isEmpty { return team }
            }
        }
        return "TROLLTROLL"
    }

    /// 用 teamid 工具解析 Mach-O 的 CodeDirectory TeamID (接受 pid 或路径）。
    func teamIDFromBinary(_ path: String) -> String? {
        let (c, o) = runAsRoot("teamid", args: [path], timeout: 15)
        guard c == 0 else { return nil }
        for line in o.components(separatedBy: "\n") where line.hasPrefix("team_id: ") {
            let t = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    /// injected dylib 到指定 App
    /// v2.9.89：完全对齐 TrollFools InjectorV3 策略——
    /// 目标默认选 Frameworks/ 内未加密可injected Mach-O (不直接改主二进制），
    /// 备份 .troll-fools.bak (TrollFools 可识别），每步改前 ldid 伪签，任一步failedAuto rollback。
    func enable(bundleId: String, dylibName: String = "@executable_path/ControlAgent.dylib",
                dylibSourcePath: String? = nil, weakReference: Bool = false,
                injectStrategy: String = "lexicographic", preferredTarget: String? = nil,
                skipProbe: Bool = false, allowMain: Bool = false,
                smartFallback: Bool = true) throws -> [String: Any] {
        _ = dylibName
        // v3.0.89：iOS 17+ 自动切换到静态injected (ct_bypass 已失效）
        let majorVer = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let builtinDylib = dylibSourcePath ?? Bundle.main.path(forResource: "ControlAgent", ofType: "dylib") ?? ""

        if majorVer >= 17 {
            // v9.10：iOS 17+ 上 ct_bypass 失效，仍按原路先走「静态重打包 IPA + 重装 App」。
            // 但那条链在越狱环境里常拿不到安装器（appinst 在、trollstorehelper 不一定），
            // 失败时 injectStatic 返回 false —— 而调用方 doInject 以前无条件写 injected=true，
            // 于是控制台显示"注入成功"，App 其实一点没改，完全用不了。
            // 现在：静态重打包失败且处于越狱环境时，再用原地写入（直接改目标 Mach-O，不重装）
            // 兜一次；两条都不成如实返回 injected=false，把两边的原因都带出来。
            guard !builtinDylib.isEmpty else {
                throw MCPError.failed("iOS 17+ requires dylib_path parameter (no built-in dylib found)")
            }
            let (ok, msg) = injectStatic(bundleId: bundleId, dylibPath: builtinDylib)
            if ok {
                return ["injected": true, "method": "static", "message": msg, "ios_version": majorVer]
            }
            var out: [String: Any] = ["injected": false, "method": "static",
                                      "message": msg, "ios_version": majorVer]
            if JBEnvironment.isJailbroken {
                do {
                    let r = try inPlaceEnable(bundleId: bundleId, dylibSourcePath: builtinDylib,
                                              weakReference: weakReference, injectStrategy: injectStrategy,
                                              preferredTarget: preferredTarget, skipProbe: skipProbe,
                                              smartFallback: smartFallback)
                    if r["injected"] as? Bool == true {
                        var okResult = r
                        okResult["method"] = "inplace"
                        okResult["ios_version"] = majorVer
                        okResult["static_error"] = msg
                        return okResult
                    }
                    out["inplace_attempt"] = r
                } catch {
                    out["inplace_error"] = "\(error)"
                }
            }
            return out
        }

        return try inPlaceEnable(bundleId: bundleId, dylibSourcePath: dylibSourcePath,
                                 weakReference: weakReference, injectStrategy: injectStrategy,
                                 preferredTarget: preferredTarget, skipProbe: skipProbe,
                                 smartFallback: smartFallback)
    }

    /// 原地注入：直接改目标 App 的 Mach-O 加 LC_LOAD_DYLIB，不重打 IPA、不重装 App。
    /// iOS 16 及以下一直是这条路；v9.10 起 iOS 17+ 越狱环境也先用它。
    private func inPlaceEnable(bundleId: String, dylibSourcePath: String?,
                               weakReference: Bool, injectStrategy: String,
                               preferredTarget: String?, skipProbe: Bool,
                               smartFallback: Bool) throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }

        guard binaryPath("insert_dylib") != nil,
              binaryPath("ldid") != nil,
              binaryPath("install_name_tool") != nil,
              binaryPath("optool") != nil,
              binaryPath("ct_bypass") != nil,
              cpBinary() != nil else {
            throw MCPError.failed("insert_dylib / ldid / install_name_tool / optool / ct_bypass / cp not bundled")
        }

        // 0. 高危护栏：敏感 App 注入前强制提醒 (不阻断，AI 需看到风险并先 diagnose）
        let sensitive = Self.isSensitive(bundleId)

        // 1. 决定注入源资产列表 (对齐 TrollFools preprocessAssets：支持 .zip/.deb 解压提取 dylib/framework/bundle）
        let agentSrc: String
        let sourceFileName: String
        var preparedAssets: [String] = []
        let assetTmpRoot = NSTemporaryDirectory() + "XosviAssets-" + UUID().uuidString
        if let src = dylibSourcePath, !src.isEmpty {
            guard FileManager.default.fileExists(atPath: src) else {
                throw MCPError.failed("specified plugin file not found: \(src)")
            }
            let ext = (src as NSString).pathExtension.lowercased()
            if ext == "zip" || ext == "deb" {
                try? FileManager.default.createDirectory(atPath: assetTmpRoot, withIntermediateDirectories: true)
                let tmpURL = URL(fileURLWithPath: assetTmpRoot)
                if ext == "zip" {
                    let entries = try ZIPReader.extractEntries(from: Data(contentsOf: URL(fileURLWithPath: src)))
                    for e in entries {
                        let lower = e.name.lowercased()
                        guard lower.hasSuffix(".dylib") || lower.hasSuffix(".framework") || lower.hasSuffix(".bundle") else { continue }
                        let dest = tmpURL.appendingPathComponent(e.name)
                        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try e.data.write(to: dest)
                        preparedAssets.append(dest.path)
                    }
                } else {
                    try DebReader.extractDylibAndBundles(at: URL(fileURLWithPath: src), to: tmpURL)
                    if let items = try? FileManager.default.contentsOfDirectory(atPath: assetTmpRoot) {
                        preparedAssets = items.map { (assetTmpRoot as NSString).appendingPathComponent($0) }
                    }
                }
                preparedAssets = preparedAssets.filter { !Self.ignoredRuntimeNames.contains(($0 as NSString).lastPathComponent.lowercased()) }
                guard !preparedAssets.isEmpty else {
                    throw MCPError.failed("no valid plugin (dylib/framework/bundle) in zip/deb, system runtimes filtered out")
                }
                sourceFileName = (preparedAssets[0] as NSString).lastPathComponent
                agentSrc = preparedAssets[0]
            } else {
                agentSrc = src
                sourceFileName = (src as NSString).lastPathComponent
                preparedAssets = [src]
            }
        } else {
            agentSrc = binDir.appendingPathComponent("ControlAgent.dylib").path
            guard FileManager.default.fileExists(atPath: agentSrc) else {
                throw MCPError.failed("ControlAgent.dylib not bundled (\(agentSrc))")
            }
            sourceFileName = "ControlAgent.dylib"
            preparedAssets = [agentSrc]
        }

        // 2. 选注入目标 Mach-O：对齐 TrollFools——有 Frameworks 时只injected Frameworks/ 内的 Mach-O
        // (TrollFools 的 modified 判定 = Frameworks/ 内带 .troll-fools.bak 的 Mach-O；
        //  注入主二进制 TrollFools 无法识别也无法关闭，用户会被卡死，故有 Frameworks 时强制拒绝主二进制）
        // v2.9.260：control.inject 传 allowMain=true 时强制选主二进制——懒加载 framework(AppsFlyerLib/BGM)
        // 实测导致 ControlAgent constructor 永不执行、4789 永不监听；主二进制 LC_LOAD_DYLIB 启动必加载
        // (加密 App 的 load commands 区不加密，insert_dylib + 伪签 + ct_bypass 可改；TrollStore fake sign 绕过校验）
        let frameworksDirPath = (app.path as NSString).appendingPathComponent("Frameworks")
        let hasFrameworks = FileManager.default.fileExists(atPath: frameworksDirPath)
        let allCandidates = collectInjectableMachOs(app, strategy: injectStrategy)
        let fwCandidates = hasFrameworks ? allCandidates.filter { $0.hasPrefix(frameworksDirPath + "/") } : []
        let mainName = (executablePath(app) as NSString).lastPathComponent.lowercased()
        // v2.9.315：AI 打分制选目标——每个候选打分后选最高分
        // 主二进制直接链接(+50) > 自家framework(+30) > 大文件(+10) > 懒加载SDK(-50) > 加密(-1000排除)
        let mainDeps = MachOAnalyzer.analyze(executablePath(app))?.dylibs ?? []
        let depNames = Set(mainDeps.map { ($0 as NSString).lastPathComponent })
        let lazySDK: Set<String> = ["appsflyer", "bgm", "bugly", "umeng", "firebase",
            "googleutilities", "googlesignin", "googletagmanager", "firebasemessaging",
            "firanalytics", "flurry", "adjust", "kochava", "branch", "tenjin", "appsflyerlib",
            "alivc", "aliyun", "artc", "queen", "nuisdk", "opencv", "yoga", "quickjs", "kun_bridge", "worker_bridge"]
        let ownPrefixes: [String] = [mainName, "dis", mainName.prefix(3).description, "app"]

        func scoreCandidate(_ path: String) -> (score: Int, reasons: [String]) {
            var score = 0
            var reasons: [String] = []
            let name = (path as NSString).lastPathComponent
            let lower = name.lowercased()
            if MachOAnalyzer.isEncryptedMachO(path) {
                return (-1000, ["encrypted (cryptid!=0)"])
            }
            if depNames.contains(where: { $0 == name || $0.hasPrefix(name) || name.hasPrefix($0) }) {
                score += 50; reasons.append("主二进制直接链接")
            }
            if ownPrefixes.contains(where: { lower.hasPrefix($0) }) {
                score += 30; reasons.append("自家framework")
            }
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 10_000_000 {
                score += 10; reasons.append("大文件(\(size/1024/1024)MB)")
            }
            if lazySDK.contains(where: { lower.contains($0) }) {
                score -= 50; reasons.append("第三方SDK(懒加载)")
            }
            return (score, reasons)
        }

        let scored = fwCandidates.map { ($0, scoreCandidate($0)) }
            .filter { $0.1.0 > -1000 }
            .sorted { $0.1.0 > $1.1.0 }
        // v2.9.316：保存排序列表，selfcheck failed时返回 retry 建议 (第二层自动重试）
        let scoredNames = scored.map { ($0.0 as NSString).lastPathComponent }
        AuditLog.shared.log("injection.score", detail: "\(bundleId) 打分: \(scored.map { "\(($0.0 as NSString).lastPathComponent)=\($0.1.0)" }.joined(separator: ","))")

        var targetMachO: String?
        if let pref = preferredTarget, !pref.isEmpty,
           let hit = scored.first(where: { $0.0.localizedCaseInsensitiveContains(pref) }) {
            targetMachO = hit.0
            AuditLog.shared.log("injection.pick_pref", detail: "\(bundleId) 指定: \((hit.0 as NSString).lastPathComponent)")
        } else if let best = scored.first {
            targetMachO = best.0
            AuditLog.shared.log("injection.pick_best", detail: "\(bundleId) 最高分: \((best.0 as NSString).lastPathComponent) score=\(best.1.score) reasons=\(best.1.reasons)")
        }
        if targetMachO == nil {
            let mainInfo = MachOAnalyzer.analyze(executablePath(app))
            if (mainInfo?.cryptID ?? 1) == 0 {
                targetMachO = executablePath(app)
                AuditLog.shared.log("injection.fallback_main", detail: "\(bundleId) 无framework候选，用主二进制 cryptid=0")
            }
        }
        guard let targetMachO else {
            // v3.0.59：智能降级——无静态可注入目标 (全加密/无 framework）时自动转内存注入，
            // 免砸壳免改文件 (用户点名"以内存注入方式实现 trollfools 注入"）
            if smartFallback {
                let memDylib = preparedAssets.first ?? ProcessHelper.tweakPath("ControlAgent.dylib") ?? ""
                if !memDylib.isEmpty {
                    var pid = findPidByExecutable(bundlePath: app.path)
                    if pid <= 0 {
                        _ = ProcessHelper.launchApp(bundleId: bundleId)
                        for _ in 0..<10 {
                            usleep(500_000)
                            pid = findPidByExecutable(bundlePath: app.path)
                            if pid > 0 { break }
                        }
                    }
                    guard pid > 0 else {
                        throw MCPError.failed("static injection has no candidate and App not running, memory fallback unavailable (open the App manually first)")
                    }
                    let (mc, mo) = injectDylib(pid: Int(pid), dylib: memDylib)
                    let ok = mo.contains("dlopen succeeded")
                    let alive = findPidByExecutable(bundlePath: app.path) > 0
                    AuditLog.shared.log("injection.mem_fallback", detail: "\(bundleId) ok=\(ok) alive=\(alive)")
                    return [
                        "status": ok ? "injected" : "failed",
                        "mode": "memory_fallback",
                        "reason": "no statically injectable target (all candidates encrypted/no framework), auto-switched to memory injection",
                        "bundle_id": bundleId,
                        "app": app.name,
                        "pid": pid,
                        "dylib": memDylib,
                        "app_alive": alive,
                        "exit": mc,
                        "output": mo,
                        "note": ok ? "memory injection OK: no decrypt, zero residue, instant; re-inject after App restart" : "memory injection failed, see output"
                    ]
                }
            }
            throw MCPError.failed("no injectable Mach-O: all candidates encrypted. Decrypt first (app.decrypt).")
        }
        let targetIsMain = targetMachO == executablePath(app)

        // 2.5 dylib 架构预检 (防注入后闪退）：源 dylib 与目标 Mach-O 均须可解析
        let dylibInfo2 = MachOAnalyzer.analyze(agentSrc)
        let targetInfo2 = MachOAnalyzer.analyze(targetMachO)
        if let d2 = dylibInfo2, let t2 = targetInfo2 {
            let dArchOk = d2.valid && (d2.arch == "arm64" || d2.arch == "arm32" || d2.arch.hasPrefix("fat"))
            if !dArchOk || !t2.valid {
                throw MCPError.failed("arch precheck failed, injection rejected (crash prevention): dylib=\(d2.arch) valid=\(d2.valid) target=\(t2.arch) valid=\(t2.valid)")
            }
        } else {
            throw MCPError.failed("cannot parse dylib or target Mach-O arch, injection rejected (crash prevention)")
        }

        // 3. 杀目标进程 (v2.9.193：TrollStore 无 /usr/bin/killall，spawnRoot 恒failed → 旧进程不杀
        // → 注入后 App 未真正重启 → dylib 永不加载 → 4789 不起 (B站 pid 恒定 1697 实测实锤）。
        // 改用 libproc 找主进程 pid + kill syscall）
        let executableName = (executablePath(app) as NSString).lastPathComponent
        let targetPid = findPidByExecutable(bundlePath: app.path)
        if targetPid > 0 {
            kill(targetPid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.6)
        }

        // 5. 拷贝 dylib 到 Frameworks/ (无 Frameworks 才放 app 根）
        // A3 资产预处理 (对齐 TrollFools injectDylibsAndFrameworks 前置）：
        // 用户插件 → standardizeLoadCommandDylibToSubstrate (substrate 引用重定向内置）+ ct_bypass + chown；
        // 内置 agent → ct_bypass + chown (agent 无 substrate 依赖）
        let frameworksDir = (app.path as NSString).appendingPathComponent("Frameworks")
        // v2.9.303：useFramework 由 targetMachO 实际位置决定，不再看 allowMain。
        // 注入目标在 Frameworks/ 下 → dylib 也放 Frameworks + @rpath；
        // 兜底注入主二进制 → dylib 放 App 根 + @executable_path。
        let useFramework = targetMachO.hasPrefix(frameworksDirPath + "/")
        let isUserPlugin = !(dylibSourcePath?.isEmpty ?? true)
        var injectNameMap: [String: String] = [:]
        for asset in preparedAssets {
            let name = (asset as NSString).lastPathComponent
            var iname = useFramework ? "@rpath/\(name)" : "@executable_path/\(name)"
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: asset, isDirectory: &isDir)
            if isDir.boolValue, name.hasSuffix(".framework") {
                let fwExe = (name as NSString).deletingPathExtension
                iname = "@rpath/\(name)/\(fwExe)"
            }
            injectNameMap[asset] = iname
            if isUserPlugin {
                standardizeLoadCommandDylibToSubstrate(asset)
            }
            let (pc2, po2) = runAsRoot("ct_bypass", args: ["-r", "-i", asset, "-t", realTeamID(for: bundleId, appPath: executablePath(app))])
            if pc2 != 0 { AuditLog.shared.log("injection.ct_bypass.asset", detail: "exit=\(pc2) \(po2)") }
            _ = runAsRoot("chown", args: ["33:33", asset])
        }
        let firstInjectName = injectNameMap[preparedAssets[0]] ?? "@rpath/\(sourceFileName)"

        // A4 拷贝资产到 Frameworks/ + substrate 自动injected (对齐 TrollFools copyfiles + prepareSubstrate）
        var copiedAssets: [String] = []
        if isUserPlugin {
            let sf = try prepareSubstrate()
            let subName = Self.substrateFwkName
            let subDst = useFramework
                ? (frameworksDir as NSString).appendingPathComponent(subName)
                : (app.path as NSString).appendingPathComponent(subName)
            if FileManager.default.fileExists(atPath: subDst) {
                _ = runAsRoot("rm", args: ["-rf", subDst])
            }
            let (c3, o3) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", sf, subDst])
            if c3 != 0 { throw MCPError.failed("root cp substrate failed(\(c3)): \(o3)") }
            _ = runAsRoot("chown", args: ["33:33", subDst])
            copiedAssets.append(subDst)
            AuditLog.shared.log("injection.substrate", detail: "\(bundleId) substrate=ready")
        }
        for asset in preparedAssets {
            let name = (asset as NSString).lastPathComponent
            let dst = useFramework
                ? (frameworksDir as NSString).appendingPathComponent(name)
                : (app.path as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst) {
                _ = runAsRoot("rm", args: ["-rf", dst])
            }
            let (c0, o0) = runAsRoot("cp", args: ["--reflink=auto", "-rfp", asset, dst])
            if c0 != 0 { throw MCPError.failed("root cp assets failed (\(c0)): \(o0)") }
            _ = runAsRoot("chown", args: ["33:33", dst])
            var isDir2: ObjCBool = false
            FileManager.default.fileExists(atPath: asset, isDirectory: &isDir2)
            if isDir2.boolValue, name.hasSuffix(".framework") || name.hasSuffix(".bundle") {
                _ = runAsRoot("touch", args: [(dst as NSString).appendingPathComponent(".troll-fools")])
            }
            copiedAssets.append(dst)
        }

        // 6. 备份目标 Mach-O (对齐 TrollFools makeAlternate：.troll-fools.bak）
        let backup = try makeAlternate(targetMachO)

        // 7. 注入链：改前伪签 → rpath → insert_dylib → 重签 → 验证；任一步failedAuto rollback
        var rpathExit: Int32 = -1
        var rpathOutput = ""
        var insertExit: Int32 = -1
        var insertOutput = ""
        do {
            // 7a. 改前伪签 (对齐 TrollFools cmdPseudoSign force）——修掉 install_name_tool LINKEDIT 报错
            let (ps, pso) = pseudoSign(targetMachO, force: true)
            if ps != 0 { AuditLog.shared.log("injection.presign", detail: "exit=\(ps) \(pso)") }

            // 7b. LC_RPATH：对齐 TrollFools cmdInsertLoadCommandRuntimePath——
            // 目标 Mach-O 统一加 @executable_path/Frameworks (@executable_path 始终指向 App 根目录）
            if useFramework {
                let (r, o) = runAsRoot("install_name_tool", args: ["-add_rpath", "@executable_path/Frameworks", targetMachO])
                // v4.3.5: install_name_tool 对【已存在】的 rpath 返回 error
                //   "would duplicate path, file already has LC_RPATH for: ..."
                //   这是"已存在=已正确"的正常情况(业界共识: already set = correct), 应视为成功而非 error。
                //   避免每次注入都污染 audit 日志为 exit=1 error。
                let alreadySet = o.localizedCaseInsensitiveContains("already has LC_RPATH")
                    || o.contains("would duplicate path")
                if r == 0 || alreadySet {
                    rpathExit = 0; rpathOutput = o
                    if alreadySet {
                        AuditLog.shared.log("injection.rpath", detail: "rpath already present (idempotent ok) \(targetMachO)")
                    }
                } else {
                    // 真错误(App Store 加密段未重签等)：伪签已做, 继续不阻断, 但如实记录
                    rpathExit = r; rpathOutput = o
                    AuditLog.shared.log("injection.rpath", detail: "exit=\(r) \(o)")
                }
            }

            // 7c. insert_dylib (对齐 TrollFools 参数 + 幂等：目标已含同名 load command 则跳过）—— 多资产逐个注入
            var insertedNames: [String] = []
            for asset in preparedAssets {
                let iname = injectNameMap[asset] ?? firstInjectName
                let preLoads = MachOAnalyzer.analyze(targetMachO)?.dylibs ?? []
                if preLoads.contains(iname) {
                    insertExit = 0; insertOutput = "already present, idempotent skip"
                } else {
                    var insArgs = [iname, targetMachO, "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes"]
                    if weakReference { insArgs.append("--weak") }
                    let (c1, o1) = runAsRoot("insert_dylib", args: insArgs)
                    insertExit = c1; insertOutput = o1
                    guard c1 == 0 else {
                        throw MCPError.failed("insert_dylib failed(\(c1)): \(o1)")
                    }
                }
                insertedNames.append(iname)

                // 7c2. standardizeLoadCommandDylib (对齐 TrollFools）：目标里指向同资产的其他路径统一为 @rpath/name
                let itemName = iname.hasPrefix("@rpath/") ? String(iname.dropFirst(7)) : (iname as NSString).lastPathComponent
                let postLoads = MachOAnalyzer.analyze(targetMachO)?.dylibs ?? []
                for d in postLoads where d != iname && d.hasSuffix("/" + itemName) {
                    _ = runAsRoot("install_name_tool", args: ["-change", d, iname, targetMachO])
                }
            }

            // 7d. 重签：条件伪签 (保留 entitlements）+ ct_bypass (真实 teamID）+ chown
            _ = coreTrustBypass(targetMachO, teamID: realTeamID(for: bundleId, appPath: executablePath(app)))

            // 7e. 验证：每个资产加载命令已写入 + Mach-O 结构有效
            let verifyInfo = MachOAnalyzer.analyze(targetMachO)
            let structOK = verifyInfo?.valid ?? false
            var loadOK = !insertedNames.isEmpty
            if let vd = verifyInfo?.dylibs {
                for n in insertedNames where !vd.contains(n) { loadOK = false }
            }
            if !loadOK || !structOK {
                throw MCPError.failed("post-injection verification failed: loadCommand=\(loadOK) macho=\(structOK) names=\(insertedNames)")
            }
        } catch {
            // failedAuto rollback：恢复目标 Mach-O + 删掉已拷贝 dylib (对齐 TrollFools restoreAlternate + batchRemove）
            var rollbackLog: [String: Any] = ["triggered": true]
            do {
                rollbackLog["restored"] = try restoreAlternate(targetMachO)
            } catch {
                rollbackLog["restore_error"] = "\(error)"
            }
            for dst in copiedAssets where FileManager.default.fileExists(atPath: dst) {
                _ = runAsRoot("rm", args: ["-rf", dst])
                rollbackLog["asset_removed"] = (dst as NSString).lastPathComponent
            }
            let wrapped = NSError(domain: "InjectionManager", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription) (已Auto rollback)"])
            AuditLog.shared.log("injection.enable.rollback", detail: "\(bundleId) \(wrapped.localizedDescription)")
            throw wrapped
        }

        let injected = MachOAnalyzer.analyze(targetMachO)?.dylibs.contains(firstInjectName) ?? false
        AuditLog.shared.log("injection.enable", detail: "\(bundleId) → \(targetMachO) injected=\(injected)")

        // 8. 启动自检 (v2.9.301 改策略）：旧版探测failed就Auto rollback，但大厂App冷启动8-15秒，
        // 7秒窗口误判率高。现在：探测不到不回滚 (注入已写入磁盘），只告警——用户手动开App验证，
        // 真闪退用"注入与自动化→手动恢复"回退。避免误杀好注入。
        var selfcheckAlive = false
        var selfcheckNote = "skipped"
        if injected && !skipProbe {
            selfcheckAlive = launchAndProbe(bundleId: bundleId, execName: executableName, executable: executablePath(app))
            if selfcheckAlive {
                selfcheckNote = "app launched and alive"
            } else {
                // v2.9.316：第二层自动重试建议——返回排序后的候选列表，AI 看到failed后自动换目标
                let nextTargets = scoredNames.filter { $0 != (targetMachO as NSString).lastPathComponent }.prefix(3)
                // v3.0.65：闪退Auto rollback——selfcheck failed (App 启动后 25s 内进程消失）= dylib 导致崩溃，自动 disable 回滚
                do {
                    _ = try self.disable(bundleId: bundleId, desist: true)
                    selfcheckNote = "selfcheck: 25s内未探测到进程 (疑似闪退)→ 已Auto rollback注入。建议：换 target=\(nextTargets.joined(separator: "/"))；若全failed，app.decrypt 砸壳主二进制"
                    AuditLog.shared.log("injection.auto_rollback", detail: "\(bundleId) → \(targetMachO): \(selfcheckNote)")
                } catch {
                    selfcheckNote = "selfcheck: 25s内未探测到进程 (疑似闪退)，Auto rollbackfailed：\(error.localizedDescription)。建议：手动 injection.disable"
                    AuditLog.shared.log("injection.selfcheck_warn", detail: "\(bundleId) → \(targetMachO): \(selfcheckNote)")
                }
            }
        }
        var persisted = false
        if injected {
            for asset in preparedAssets {
                persistAsset(name: (asset as NSString).lastPathComponent, src: asset, bid: bundleId)
            }
            persisted = true
            detachMetadata(bundleId: bundleId)
        }
        let trollfoolsCompatible = hasFrameworks
        return [
            "action": "inject",
            "app": app.name,
            "bundleId": bundleId,
            "target_macho": targetMachO,
            "target_is_main": targetIsMain,
            "candidates": allCandidates.map { ($0 as NSString).lastPathComponent },
            "framework_candidates": fwCandidates.map { ($0 as NSString).lastPathComponent },
            // v2.9.316：打分排序后的候选 (AI 自动重试用）
            "scored_candidates": scoredNames,
            // v2.9.309：对齐 TrollFools 诊断——每个候选的加密状态/大小/是否被选
            "candidates_detail": fwCandidates.map { p -> [String: Any] in
                let name = (p as NSString).lastPathComponent
                let enc = MachOAnalyzer.isEncryptedMachO(p)
                let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
                let selected = (p == targetMachO)
                return [
                    "name": name,
                    "encrypted": enc,
                    "size_kb": size / 1024,
                    "selected": selected,
                    "reason": enc ? "SKIP:encrypted" : (selected ? "SELECTED" : "candidate")
                ]
            },
            "main_deps": mainDeps.map { ($0 as NSString).lastPathComponent },
            "mainBinary": executablePath(app),
            "dylib": firstInjectName,
            "dylibSource": agentSrc,
            "dylibDst": copiedAssets.first ?? "",
            "assets": preparedAssets.map { ($0 as NSString).lastPathComponent },
            "substrate": isUserPlugin ? Self.substrateFwkName : nil,
            "backup": backup,
            "root": true,
            "killed_process": executableName,
            "rpath_exit": Int(rpathExit),
            "rpath_output": rpathOutput,
            "insert_dylib_exit": Int(insertExit),
            "insert_output": insertOutput,
            "verified": true,
            "injected": injected,
            "trollfools_compatible": trollfoolsCompatible,
            "persisted": persisted,
            "weak_reference": weakReference,
            "selfcheck": ["app_alive": selfcheckAlive, "note": selfcheckNote],
            "risk_warning": sensitive ? "⚠️ 目标 App 为敏感应用 (支付/银行/系统类)。已自动选择 Frameworks 内未加密 Mach-O 注入，未修改主二进制；如有异常立即调用 injection.restore 或 rescue.recover_all 恢复。" : nil,
            "hint": "Injection target: unencrypted Mach-O in Frameworks/ (TrollFools-style, no main binary mod). Backup at \(backup). Restore anytime via injection.restore.",
            "status": injected ? "injected" : "injection_failed"
        ]
    }

    /// 还原injected (v2.9.89：对齐 TrollFools eject 流程）
    /// 1) 收集有备份的 Mach-O (modified）；2) 移除每个注入资产的加载命令并删文件；
    /// 3) 重签；4) 全部清空后从备份还原并删备份。兼容 TrollFools 注入的 App。
    func disable(bundleId: String, desist: Bool = true) throws -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            throw MCPError.failed("app not found: \(bundleId)")
        }
        guard binaryPath("optool") != nil, binaryPath("ct_bypass") != nil, cpBinary() != nil else {
            throw MCPError.failed("optool / ct_bypass / cp not bundled")
        }

        var modified = collectModifiedMachOs(app)
        var assets = injectedAssets(in: app)

        // 旧格式兼容：有 .bak_macho 但无 .troll-fools.bak 时，主二进制即 modified
        let mainBinary = executablePath(app)
        if FileManager.default.fileExists(atPath: mainBinary + ".bak_macho"),
           !FileManager.default.fileExists(atPath: alternateURL(for: mainBinary)),
           !modified.contains(mainBinary) {
            modified.append(mainBinary)
        }

        guard !modified.isEmpty || !assets.isEmpty else {
            throw MCPError.failed("no injection trace found (no backup, no injected assets)")
        }

        // 杀目标进程
        let executableName = (mainBinary as NSString).lastPathComponent
        let dp = findPidByExecutable(bundlePath: (executablePath(app) as NSString).deletingLastPathComponent)
        if dp > 0 { kill(dp, SIGKILL); Thread.sleep(forTimeInterval: 0.5) }

        var removedLoads: [String: [String]] = [:]
        var removedAssets: [String] = []

        // 1. 先删除注入资产文件 (对齐 TrollFools eject：cmdRemove asset）
        for asset in assets {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: asset, isDirectory: &isDir)
            let (cD, _) = runAsRoot("rm", args: [isDir.boolValue ? "-rf" : "-f", asset])
            if cD == 0 { removedAssets.append(asset) }
        }

        // 2. 有备份的 Mach-O 直接 restore (备份 = 注入前原二进制，还原后无需 optool/重签；
        //    v2.9.105 修复：此前先 coreTrustBypass(TROLLTROLL) 再 restore，重签本身会破坏签名 → 删除也闪退）
        var restored: [String] = []
        var remaining: [String] = []
        for target in modified {
            if hasAlternate(target) {
                if (try? restoreAlternate(target)) == true {
                    restored.append(target)
                    continue
                }
            }
            remaining.append(target)
        }

        // 3. 无备份的 target 才手工清理：optool uninstall + 重签 (真实 teamID，对齐 TrollFools eject）
        for target in remaining {
            for asset in assets {
                let assetName: String
                if (asset as NSString).pathExtension == "framework" {
                    let fwName = (asset as NSString).lastPathComponent
                    let exeName = (fwName as NSString).deletingPathExtension
                    assetName = "@rpath/\(fwName)/\(exeName)"
                } else {
                    assetName = "@rpath/\((asset as NSString).lastPathComponent)"
                }
                let (c, o) = removeLoadCommand(assetName: assetName, from: target)
                if c == 0 { removedLoads[assetName] = (removedLoads[assetName] ?? []) + [target] }
                else { AuditLog.shared.log("injection.disable.optool", detail: "\(assetName) @ \(target): exit=\(c) \(o)") }
            }
            _ = coreTrustBypass(target, teamID: realTeamID(for: bundleId, appPath: executablePath(app)))
        }

        // 2.5 desist：desist=false 时保留持久化资产 (对齐 TrollFools 关闭插件语义，可再启用）
        if desist {
        for asset in assets {
            let pName = (asset as NSString).lastPathComponent
            let pDst = Self.persistentPluginsRoot + "/" + bundleId + "/" + pName
            if FileManager.default.fileExists(atPath: pDst) {
                _ = runAsRoot("rm", args: ["-rf", pDst])
            }
        }
        }

        // 2.6 清理注入的 CydiaSubstrate.framework (对齐 TrollFools eject：注入的 substrate 一并移除，防残留）
        let subDst = (app.path as NSString).appendingPathComponent("Frameworks/" + Self.substrateFwkName)
        if FileManager.default.fileExists(atPath: subDst) {
            _ = runAsRoot("rm", args: ["-rf", subDst])
            AuditLog.shared.log("injection.disable.substrate", detail: "\(bundleId) removed \(Self.substrateFwkName)")
        }

        attachMetadata(bundleId: bundleId)

        let injected = MachOAnalyzer.analyze(mainBinary)?.dylibs.contains(where: { $0.contains("ControlAgent") }) ?? false
        AuditLog.shared.log("injection.disable", detail: "\(bundleId) removed=\(removedAssets.count) restored=\(restored.count)")
        return [
            "action": "remove",
            "bundleId": bundleId,
            "root": true,
            "modified_machos": modified,
            "assets_found": assets,
            "assets_removed": removedAssets,
            "load_commands_removed": removedLoads,
            "restored_from_backup": restored,
            "desisted": desist,
            "injected": injected,
            "status": injected ? "still_injected" : "reverted",
            "hint": restored.isEmpty ? "no restorable backup found; if App still cannot launch, use rescue.cleanup to clear residue" : "restored original binary from backup"
        ]
    }

    /// 完全移除：还原 + 删除 dylib 文件 + 清理备份
    func remove(bundleId: String) throws -> [String: Any] {
        var r = (try? disable(bundleId: bundleId)) ?? ["action": "remove"]
        if let app = AppCatalog.find(bundleId) {
            // 清理遗留：新格式备份 + 旧格式备份 + 标记文件
            let mainBinary = executablePath(app)
            for backup in [alternateURL(for: mainBinary), mainBinary + ".bak_macho"] {
                if FileManager.default.fileExists(atPath: backup) {
                    let (cD, _) = runAsRoot("rm", args: ["-f", backup])
                    r["backup_removed_\((backup as NSString).lastPathComponent)"] = cD == 0
                }
            }
            // v2.9.45：dylib 可能在 Frameworks/ 或 app 根目录，两处都检查
            let candidates = [
                (app.path as NSString).appendingPathComponent("ControlAgent.dylib"),
                (app.path as NSString).appendingPathComponent("Frameworks/ControlAgent.dylib")
            ]
            for p in candidates where FileManager.default.fileExists(atPath: p) {
                let (cD, oD) = runAsRoot("rm", args: ["-f", p])
                r["dylib_removed"] = cD == 0
                r["rm_output"] = oD
            }
        }
        AuditLog.shared.log("injection.remove", detail: bundleId)
        return r
    }

    /// 检查指定 App 是否已injected (全 Mach-O 扫描：主二进制 + Frameworks 内全部可injected Mach-O）
    func inspect(_ bundleId: String) -> [String: Any] {
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        let mainBinary = executablePath(app)
        let machos = collectInjectableMachOs(app)
        var injected = false
        var targetInfo: [[String: Any]] = []
        for m in machos {
            let dylibs = MachOAnalyzer.analyze(m)?.dylibs ?? []
            let hit = hasAlternate(m) || isInjected(m) ||
                dylibs.contains(where: { $0.contains("ControlAgent") })
            if hit {
                injected = true
                targetInfo.append([
                    "macho": m,
                    "isMain": m == mainBinary,
                    "hasBackup": hasAlternate(m)
                ])
            }
        }
        let modified = collectModifiedMachOs(app)
        return [
            "app": app.name,
            "bundleId": bundleId,
            "mainBinary": mainBinary,
            "injected": injected,
            "hasBackup": !modified.isEmpty,
            "target_machos": targetInfo,
            "modified_machos": modified,
            "injected_assets": injectedAssets(in: app),
            "sensitive": Self.isSensitive(bundleId),
            "bundledTools": availableBinaries()
        ]
    }

    /// 列出真正已注入的 App (存在 .troll-fools.bak / .bak_macho 备份即代表曾被注入）
    /// v2.9.58：root 诊断——执行 /usr/bin/id 验证 persona spawn 后子进程真实 uid/gid
    /// 返回 "uid=0(root) gid=0(wheel) ..." 或错误信息
    func diagnoseRoot() -> [String: Any] {
        // v6.6.14：**不再用 /bin/sh**（那是 Alpine guest 路径，iOS 主机不存在），
        // 改用系统 /usr/bin/id；不存在则退回 App 自带 helper 探测。
        let idPath = "/usr/bin/id"
        var (code, output): (Int32, String)
        if FileManager.default.fileExists(atPath: idPath) {
            (code, output) = spawnRoot(idPath, args: [])
        } else if let probe = binaryPath("ldid") ?? binaryPath("cp") {
            (code, output) = spawnRoot(probe, args: ["--version"])
        } else {
            return ["error": "no usable probe binary", "exit_code": -1, "id_output": "(no probe)", "is_root": false]
        }
        return [
            "exit_code": Int(code),
            "id_output": output.isEmpty ? "(空输出)" : output,
            "is_root": output.contains("uid=0(root)"),
            "note": "Child process real identity after persona spawn. uid!=0 = persona not effective."
        ]
    }

    /// v6.6.7: 完整 root 提权链路诊断（不依赖 spawnRoot，因为 spawnRoot 本身可能已经挂了）。
    /// 用于判断 spawnRoot failed (85 ENOSYS) 等错误的根因，一键给 Xosvi 用户和 AI 完整报告。
    /// 归因逻辑：
    ///   (A) Xosvi 主二进制缺 persona-mgmt entitlement → build-ipa.sh 签名步骤坏了
    ///   (B) TSRootBinaries helper 的 setuid 位没被 TrollStore 打上 → TrollStore 版本过旧或安装链路坏
    ///   (C) 前两者都 OK 但仍 ENOSYS → iOS 17+ AMFI 拒绝，需要 Xosvi 双架构原生运行 (arm64+arm64e)
    func diagnoseRootChain() -> [String: Any] {
        var result: [String: Any] = [:]

        // 1. 系统信息
        let v = ProcessInfo.processInfo.operatingSystemVersion
        result["ios_version"] = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        result["ios_major"] = v.majorVersion

        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { rawPtr in
            String(cString: rawPtr.bindMemory(to: CChar.self).baseAddress!)
        }
        result["hw_machine"] = machine

        var procTranslated = false
        var val: CInt = 0
        var size = MemoryLayout<CInt>.size
        if sysctlbyname("sysctl.proc_translated", &val, &size, nil, 0) == 0 {
            procTranslated = (val != 0)
        }
        result["proc_translated"] = procTranslated ? "arm64e (A12+)" : "arm64"

        result["process_name"] = ProcessInfo.processInfo.processName
        result["main_bundle_id"] = Bundle.main.bundleIdentifier ?? "?"

        // 1b. v6.6.10：越狱环境（决定提权路径——rootHide 下 persona spawn 必然失败）
        result["jailbreak_env"] = JBEnvironment.kind.rawValue
        result["jailbreak_root"] = JBEnvironment.rootPrefix.isEmpty ? "(none)" : JBEnvironment.rootPrefix
        result["jailbreak_root_launcher"] = JBEnvironment.rootLaunchPath() ?? "(none)"
        if JBEnvironment.isJailbroken {
            result["jailbreak_toolchain"] = JBEnvironment.toolchainSnapshot()
            // 注意：此处 mainBundlePath 尚未声明（在主二进制路径段才赋值），直接用 Bundle.main
            result["helper_owner"] = JBEnvironment.helperOwnerReport(Bundle.main.bundlePath + "/bin")
        }

        // 2. 主二进制路径 & 文件权限
        let mainBundlePath = Bundle.main.bundlePath
        let mainBundleBin = Bundle.main.executablePath ?? (mainBundlePath + "/Xosvi")
        result["main_bundle"] = mainBundlePath
        result["main_bin"] = mainBundleBin

        var binInfo: [String: Any] = [:]
        if let attrs = try? FileManager.default.attributesOfItem(atPath: mainBundleBin) {
            if let mode = attrs[.posixPermissions] as? Int {
                binInfo["permissions_octal"] = String(format: "%o", mode & 0o777)
                binInfo["has_setuid"] = (mode & 0o4000) != 0
                binInfo["has_executable"] = (mode & 0o111) != 0
            }
            if let uid = attrs[.ownerAccountID] as? Int {
                binInfo["uid"] = uid
                binInfo["is_root_owned"] = uid == 0
            }
            if let gid = attrs[.groupOwnerAccountID] as? Int {
                binInfo["gid"] = gid
            }
            if let size = attrs[.size] as? NSNumber {
                binInfo["size"] = size.intValue
            }
        }
        result["main_bin_info"] = binInfo
        result["geteuid"] = geteuid()

        // 3. 主二进制的 entitlements（用普通 spawn 跑 ldid -e，不需要 root）
        var entitlements: [String: Any] = [:]
        if let ldid = binaryPath("ldid") {
            let r = spawn(ldid, args: ["-e", mainBundleBin], timeout: 20)
            entitlements["exit_code"] = Int(r.0)
            entitlements["output"] = r.1
            let keys = [
                "com.apple.private.persona-mgmt",
                "com.apple.private.security.no-sandbox",
                "com.apple.private.security.container-manager",
                "com.apple.private.MobileContainerManager.allowed",
                "com.apple.private.mobileinstall.allowedSPI",
                "com.apple.developer.team-identifier"
            ]
            var found: [String: Bool] = [:]
            for k in keys {
                found[k] = r.1.contains(k)
            }
            entitlements["key_checks"] = found
            entitlements["has_persona_mgmt"] = found["com.apple.private.persona-mgmt"] ?? false
            entitlements["has_no_sandbox"] = found["com.apple.private.security.no-sandbox"] ?? false
            entitlements["has_container_manager"] = found["com.apple.private.security.container-manager"] ?? false
        } else {
            entitlements["error"] = "ldid not bundled"
        }
        result["main_bin_entitlements"] = entitlements

        // 4. TSRootBinaries 的 setuid 位
        let tsBinaries = ["insert_dylib", "ldid", "cp", "cp-15", "mv", "mv-15", "rm",
                          "chown", "mkdir", "ct_bypass", "install_name_tool", "optool",
                          "opainject", "python3", "lua", "node", "r2", "cstool"]
        var binSetuid: [String: [String: Any]] = [:]
        var setuidCount = 0
        var totalCount = 0
        for b in tsBinaries {
            if let p = binaryPath(b) {
                totalCount += 1
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let mode = attrs[.posixPermissions] as? Int {
                    let hasSetuid = (mode & 0o4000) != 0
                    if hasSetuid { setuidCount += 1 }
                    var uid = -1
                    if let u = attrs[.ownerAccountID] as? Int { uid = u }
                    binSetuid[b] = [
                        "path": p,
                        "permissions_octal": String(format: "%o", mode & 0o777),
                        "has_setuid": hasSetuid,
                        "uid": uid
                    ]
                }
            }
        }
        let setuidSummary = setuidCount == totalCount ? "OK all setuid"
                           : (setuidCount == 0 ? "FAIL none setuid" : "WARN partial setuid")
        result["ts_root_binaries"] = [
            "setuid_count": setuidCount,
            "total_count": totalCount,
            "summary": setuidSummary,
            "details": binSetuid
        ]

        // 5. 提权派发测试
        // v6.6.14：**不能用 /bin/sh** —— 那是 Alpine guest 内的路径，iOS 主机侧没有，
        // 导致测试恒返回 ENOENT（用户实测 spawn_persona_test 报 /bin/sh not found，
        // 完全无法反映真实提权状态）。改用 App 自带 helper（bundle 内一定存在）。
        var spawnTest: [String: Any] = [:]
        let probeBin = binaryPath("ldid") ?? binaryPath("cp") ?? mainBundleBin
        if FileManager.default.fileExists(atPath: probeBin) {
            spawnTest["probe_binary"] = probeBin
            // ① persona 路径（越狱/rootHide 下预期 85）
            let r1 = spawnRootDetailed(probeBin, args: ["--version"], timeout: 8)
            spawnTest["code"] = Int(r1.code)
            spawnTest["diag_prefix"] = r1.diagPrefix
            spawnTest["stdout"] = r1.stdout
            spawnTest["stderr"] = r1.stderr
            // ② 非 persona 路径（越狱下的真实提权方式）
            let r2 = spawnRootDetailed(probeBin, args: ["--version"], timeout: 8, usePersona: false)
            spawnTest["no_persona_code"] = Int(r2.code)
            spawnTest["no_persona_stdout"] = r2.stdout
            // ③ 真实身份：能跑就说明 euid 是否 root
            let idBin = "/usr/bin/id"
            if FileManager.default.fileExists(atPath: idBin) {
                let rid = spawnRootDetailed(idBin, args: [], timeout: 8, usePersona: false)
                spawnTest["id_code"] = Int(rid.code)
                spawnTest["id_output"] = rid.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // ④ v6.6.15：**裸 posix_spawn**（完全不带任何 attr）——判定瓶颈到底在哪：
            //    code=0        → exec 本身 OK，之前的 85 来自 persona attr
            //    code=85       → 连裸 spawn 都 ENOSYS，说明内核/沙盒层面禁 exec
            //    code=1/13     → EPERM/EACCES，权限或沙盒
            //    code=8        → ENOEXEC，二进制格式/签名问题
            let raw = spawn(probeBin, args: ["--version"], timeout: 8)
            spawnTest["raw_spawn_code"] = Int(raw.0)
            spawnTest["raw_spawn_output"] = String(raw.1.prefix(200))
        } else {
            spawnTest["error"] = "no probe binary in bundle"
        }
        result["spawn_persona_test"] = spawnTest

        // 5b. setuid fallback 结果——直接复用上面 5 段已经跑过的 no_persona 测试，
        // 不再单独 spawn 一次（原实现用 /bin/sh，iOS 主机不存在，恒失败）。
        var fallbackTest: [String: Any] = [:]
        if let c = spawnTest["no_persona_code"] as? Int {
            fallbackTest["code"] = c
            fallbackTest["stdout"] = spawnTest["no_persona_stdout"] ?? ""
            fallbackTest["note"] = "复用 spawn_persona_test.no_persona_code"
        }
        result["spawn_no_persona_test"] = fallbackTest

        // 6. TrollStore 位置探测（尽力而为）
        var trollPaths: [String] = []
        let candidatePaths = [
            "/var/installd/TrollStore.mobileprovision",
            "/var/jb/usr/lib/TrollStore",
            "/usr/lib/TrollStore",
            "/var/installd/iPhoneOS"
        ]
        for p in candidatePaths where FileManager.default.fileExists(atPath: p) {
            trollPaths.append(p)
        }
        result["trollstore_paths"] = trollPaths

        // 7. 自动归因（v6.6.10：按环境分流——越狱与 TrollStore 的提权模型完全不同）
        var diagnosis: [String] = []
        var severity: String = "ok"

        let hasPersonaMgmt = entitlements["has_persona_mgmt"] as? Bool ?? false
        let hasNoSandbox = entitlements["has_no_sandbox"] as? Bool ?? false
        let isJB = JBEnvironment.isJailbroken

        if isJB {
            // ===== 越狱环境：persona spawn 不适用，唯一提权手段是 helper 的 setuid + root 属主 =====
            diagnosis.append("[JB] 越狱环境：\(JBEnvironment.kind.rawValue)（根路径 \(JBEnvironment.rootPrefix)）")
            diagnosis.append("    → 越狱下不使用 persona spawn；rootHide/Relaxin 会拦截它并返回 85，属预期")
            if let launcher = JBEnvironment.rootLaunchPath() {
                diagnosis.append("    → 可用越狱提权入口：\(launcher)")
            } else {
                diagnosis.append("    → 未找到越狱提权入口（sudo/jbctl），越狱工具链可能不完整")
            }

            if setuidCount == 0 {
                severity = "critical"
                diagnosis.append("[B CRITICAL] 全部 \(totalCount) 个 helper 缺 setuid 位——越狱下这是唯一的提权手段")
                // v6.6.13：setuid 只对 root 属主生效，先看属主
                let ownerInfo = JBEnvironment.helperOwnerReport(mainBundlePath + "/bin")
                if let rootOwned = ownerInfo["root_owned"] as? Int, rootOwned == 0 {
                    diagnosis.append("    → 且 helper 属主不是 root（root_owned=0）——**即使 chmod u+s 也不会提权**")
                    if let samples = ownerInfo["samples"] as? [String], !samples.isEmpty {
                        diagnosis.append("    → 实际属主样例：\(samples.joined(separator: "、"))")
                    }
                    diagnosis.append("    → 所以 chown root:wheel 是必须的第一步，不能只做 chmod")
                }
                diagnosis.append("    → 在越狱终端（NewTerm / Filza 以 root）执行以下命令，然后回 App 重试：")
                for line in JBEnvironment.privilegeFixCommand(appPath: mainBundlePath).split(separator: "\n") {
                    diagnosis.append("      " + String(line))
                }
            } else if setuidCount < totalCount {
                if severity != "critical" { severity = "high" }
                diagnosis.append("[B HIGH] 部分 helper 有 setuid（\(setuidCount)/\(totalCount)）——部分操作可用，建议全部补齐")
                diagnosis.append("    → 在越狱终端以 root 执行：")
                for line in JBEnvironment.privilegeFixCommand(appPath: mainBundlePath).split(separator: "\n") {
                    diagnosis.append("      " + String(line))
                }
            } else {
                diagnosis.append("[B OK] 全部 helper 有 setuid（\(setuidCount)/\(totalCount)）——越狱提权路径可用")
            }

            if !hasNoSandbox {
                if severity == "ok" { severity = "high" }
                diagnosis.append("[A2 HIGH] 主二进制缺 no-sandbox —— 越狱下写其他 App Bundle 需要它")
            }

            // v6.6.14：关键澄清——不是所有注入都需要 root
            // 目标 App 若由 TrollStore/越狱安装，bundle 属主常是 mobile(501)，
            // Xosvi 同为 501 时可直接读写，走 runAsRoot 的 native fallback 即可成功。
            diagnosis.append("[NOTES] 并非所有注入都需要 root：目标 App 的 bundle 属主若是 mobile(501)，")
            diagnosis.append("    本机（同为 501）可直接写入，runAsRoot 会自动走 native fallback。")
            diagnosis.append("    只有目标属主是 root 时，才必须先修复 setuid/属主。")

            if let code = spawnTest["code"] as? Int, code == 85 {
                diagnosis.append("[C INFO] persona spawn 返回 85 是**预期行为**（越狱/rootHide 不加载 persona 链路），不代表故障")
            }
            if let fb = fallbackTest["code"] as? Int {
                if fb == 0 {
                    diagnosis.append("[FALLBACK OK] 不带 persona 的 spawn 成功——越狱路径已生效")
                    if severity == "critical" { severity = "high" }
                }
            }
        } else {
            // ===== 非越狱（TrollStore）：原有归因 =====
            if !hasPersonaMgmt {
                severity = "critical"
                diagnosis.append("[A CRITICAL] Xosvi 主二进制缺 com.apple.private.persona-mgmt entitlement")
                diagnosis.append("    → 原因1: build-ipa.sh 的 ldid -S Support/Xosvi.entitlements 步骤未生效")
                diagnosis.append("    → 原因2: TrollStore 安装时未保留特权 entitlements (可能 TrollStore 版本过旧)")
                diagnosis.append("    → 修复: 检查 scripts/build-ipa.sh 的签名段；确认 TrollStore ≥ 1.1.1；卸载重装 Xosvi")
            }
            if hasPersonaMgmt && !hasNoSandbox {
                if severity != "critical" { severity = "high" }
                diagnosis.append("[A2 HIGH] Xosvi 主二进制有 persona-mgmt 但缺 no-sandbox (影响 App Bundle 写)")
            }

            if setuidCount == 0 {
                if severity != "critical" { severity = "high" }
                diagnosis.append("[B HIGH] 所有 TSRootBinaries helper 都没有 setuid 位")
                diagnosis.append("    → TrollStore 未应用 Info.plist TSRootBinaries 声明的 setuid")
                diagnosis.append("    → setuid fallback 路径不可用；必须走 persona spawn 链路")
                diagnosis.append("    → 修复: 升级 TrollStore 到 ≥ 1.1.1；卸载重装 Xosvi")
            } else if setuidCount < totalCount {
                diagnosis.append("[B WARN] 部分 helper 有 setuid 位 (\(setuidCount)/\(totalCount))——setuid fallback 部分可用")
            } else if totalCount > 0 {
                diagnosis.append("[B OK] 所有 helper 都有 setuid 位 (\(setuidCount)/\(totalCount))——setuid fallback 路径可用")
            }

            if let code = spawnTest["code"] as? Int {
                if code == 85 {
                    if severity == "ok" { severity = "critical" }
                    diagnosis.append("[C CRITICAL] posix_spawn 返回 85 (ENOSYS)——persona spawn 被内核拒")
                    if hasPersonaMgmt {
                        diagnosis.append("    → persona-mgmt entitlement 存在但被 iOS \(v.majorVersion).\(v.minorVersion) AMFI 拒绝")
                        diagnosis.append("    → iOS 17+ 高发：Xosvi 需双架构原生运行 (arm64+arm64e)")
                        diagnosis.append("    → 检查 Xosvi 主二进制 lipo -info 是否含 arm64e slice")
                    } else {
                        diagnosis.append("    → persona-mgmt entitlement 不存在 (见 [A])")
                    }
                } else if code == 0 {
                    if let out = spawnTest["stdout"] as? String, out.contains("uid=0") {
                        diagnosis.append("[C OK] persona spawn 工作正常，uid=0")
                    } else if let out = spawnTest["stdout"] as? String, !out.isEmpty {
                        if severity != "critical" { severity = "high" }
                        diagnosis.append("[C HIGH] spawnRoot 成功但 uid!=0——persona 属性未真正生效")
                    } else {
                        diagnosis.append("[C WARN] spawnRoot code=0 但空输出，无法确认提权状态")
                    }
                } else if code == -2 {
                    diagnosis.append("[C WARN] spawnRoot 超时")
                } else {
                    diagnosis.append("[C INFO] spawnRoot code=\(code)")
                }
            }
        }

        // fallback 结果摘要
        if let fbCode = fallbackTest["code"] as? Int {
            let fbLine: String
            if fbCode == 0 {
                fbLine = "setuid fallback (usePersona=false) 成功，可在 ENOSYS 时自动降级"
            } else if fbCode == 85 {
                fbLine = "setuid fallback 也返回 85 (helper 本身也无法 exec)"
            } else if fbCode == 13 {
                fbLine = "setuid fallback 返回 13 (EACCES)——helper 无 root 权限，setuid 位缺失或 sandbox 拒绝"
            } else {
                fbLine = "setuid fallback code=\(fbCode)"
            }
            diagnosis.append("[FALLBACK] \(fbLine)")
        }

        result["diagnosis"] = diagnosis
        result["severity"] = severity
        result["severity_hint"] = severity == "ok"
            ? "root 提权链路正常，注入类工具可用"
            : "root 提权链路断裂，注入类工具不可用。按 diagnosis 首条 [A]/[B]/[C] 归因决定修复方向"
        result["advice"] = severity == "critical"
            ? "1) 若 [A]: 重跑 scripts/build-ipa.sh 确保 ldid -S 签名带 entitlements; 2) 若 [B]: 升级 TrollStore ≥ 1.1.1 + 卸载重装 Xosvi; 3) 若 [C]: 检查 Xosvi 主二进制是否含 arm64e slice (lipo -info)"
            : "root 链路正常，无需操作"

        return result
    }

    func status() -> [String: Any] {
        let apps = AppCatalog.list()
        var injectedApps: [[String: Any]] = []
        for app in apps {
            let modified = collectModifiedMachOs(app)
            if !modified.isEmpty || !injectedAssets(in: app).isEmpty {
                injectedApps.append([
                    "bundleId": app.bundleId,
                    "name": app.name,
                    "injected": !modified.isEmpty,
                    "hasBackup": !modified.isEmpty
                ])
            }
        }
        // v2.9.58：加入 root 诊断
        let rootDiag = diagnoseRoot()
        // v6.6.7：完整 root 链路诊断（entitlements + setuid 位 + fallback 测试结果 + 自动归因）
        let rootChain = diagnoseRootChain()
        let jbStatus = jailbreakStatus()

        var result: [String: Any] = [
            "total_apps": apps.count,
            "bundled_tools": availableBinaries(),
            "injected_count": injectedApps.count,
            "injected_apps": injectedApps,
            // v8（R⑪）：注入路径计划——探测驱动的策略结论（静态/内存/不可用）
            "injection_strategy": ExecutionStrategy.report(),
            "root_diagnosis": rootDiag,
            "root_chain": rootChain,
            "jailbreak": jbStatus
        ]

        // v6.6.7：severity 醒目提示——AI 一眼看到严重度，不用深挖 root_chain
        let severity = rootChain["severity"] as? String ?? "ok"
        if severity == "critical" || severity == "high" {
            let diagLines = rootChain["diagnosis"] as? [String] ?? []
            let firstLines = diagLines.prefix(2).joined(separator: " | ")
            result["root_chain_severity"] = severity
            result["root_chain_summary"] = firstLines
            result["hint"] = "!! root 提权链路断裂 (\(severity))——注入类工具不可用。root_chain 字段含完整归因和修复建议。Use injection.list to find bundle_id + name for specific App."
        } else {
            result["hint"] = "Use injection.list to find bundle_id + name for specific App."
        }

        return result
    }

    /// v3.1.71：单查指定 App 的注入态 (inject status bundle_id:xxx）。
    /// AI 实测反馈：inject status 只按已注入列表返回，未注入的目标 App 不会单列，需先 enable 才出现。
    func status(for bundleId: String) -> [String: Any] {
        guard let app = AppCatalog.list().first(where: { $0.bundleId == bundleId }) else {
            return ["bundle_id": bundleId, "injected": false,
                    "hint": "bundle_id not found in installed list (use inject list to confirm spelling)"]
        }
        let modified = collectModifiedMachOs(app)
        let assets = injectedAssets(in: app)
        let injected = !modified.isEmpty || !assets.isEmpty
        return [
            "bundle_id": app.bundleId,
            "name": app.name,
            "injected": injected,
            "modified_binaries": modified,
            "injected_dylibs": assets,
            "hasBackup": !modified.isEmpty,
            "hint": injected
                ? "已注入；用 inject inspect bundle_id:\(bundleId) 看加载明细"
                : "未注入；需要时用 injection.enable bundle_id:\(bundleId)"
        ]
    }

    // MARK: - v3.1.1：越狱状态检测 + ElleKit 运行时注入
    /// Detect jailbreak status (Relaxin/RootHide/Dopamine) and ElleKit availability
    func jailbreakStatus() -> [String: Any] {
        let fm = FileManager.default
        var checks: [String: Bool] = [:]

        // Check common jailbreak paths
        let jbPaths = [
            "/jb",
            "/var/jb",
            "/private/var/jb",
            "/etc/apt",
            "/private/etc/apt",
            "/var/binpack",
            "/Library/Frameworks/ElleKit.framework",
            "/var/jb/Library/Frameworks/ElleKit.framework",
            "/jb/Library/Frameworks/ElleKit.framework"
        ]
        for path in jbPaths {
            checks[path] = fm.fileExists(atPath: path)
        }

        // Check if ElleKit is loaded
        var hasElleKit = false
        let dyldPaths = [
            "/Library/Frameworks/ElleKit.framework/ElleKit",
            "/var/jb/Library/Frameworks/ElleKit.framework/ElleKit",
            "/jb/Library/Frameworks/ElleKit.framework/ElleKit"
        ]
        for p in dyldPaths {
            if fm.fileExists(atPath: p) {
                hasElleKit = true
                break
            }
        }

        // Check for Dopamine/Relaxin/RootHide
        let hasDopamine = fm.fileExists(atPath: "/var/jb/.dopamine") || fm.fileExists(atPath: "/jb/.dopamine")
        let hasRootHide = fm.fileExists(atPath: "/var/jb/roothide") || fm.fileExists(atPath: "/jb/roothide")
        let hasSileo = fm.fileExists(atPath: "/var/jb/AppInfo") || fm.fileExists(atPath: "/jb/AppInfo")

        let isJailbroken = checks.values.contains(true) || hasElleKit || hasDopamine || hasRootHide

        return [
            "is_jailbroken": isJailbroken,
            "has_ellekit": hasElleKit,
            "has_dopamine": hasDopamine,
            "has_roothide": hasRootHide,
            "has_sileo": hasSileo,
            "jb_paths_found": checks.filter { $0.value }.map { $0.key },
            "injection_mode": isJailbroken ? "ellekit_runtime" : (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 17 ? "static_only" : "ct_bypass"),
            "note": isJailbroken ? "Jailbreak detected. Use injection.enable for runtime injection." : "No jailbreak detected. Use injection.enable for static/ct_bypass injection."
        ]
    }

    /// Dylib injection via ElleKit (jailbreak environment only)
    /// Note: ElleKit loads dylib at app startup (not runtime attach).
    /// Put dylib in TweakInject directory → next app launch loads it.
    /// - Parameters:
    ///   - bundleId: target app bundle id
    ///   - dylibPath: path to dylib to inject
    ///   - mode: "once" (temporary) or "persist" (permanent)
    func injectViaElleKit(bundleId: String, dylibPath: String, mode: String = "persist") -> (Bool, String) {
        // Verify jailbreak environment
        let jb = jailbreakStatus()
        guard jb["is_jailbroken"] as? Bool == true else {
            return (false, "No jailbreak detected. ElleKit injection requires a jailbroken environment (Relaxin/RootHide/Dopamine).")
        }
        guard jb["has_ellekit"] as? Bool == true else {
            return (false, "ElleKit not found. Install ElleKit first.")
        }

        guard let app = AppCatalog.find(bundleId) else {
            return (false, "App not found: \(bundleId)")
        }

        // v3.1.1：安全限制——不能注入系统应用，防止白苹果
        // 方法：检查 app 是否在系统目录 (/Applications）下，而不是用户安装目录
        let isSystemApp = app.path.hasPrefix("/Applications/") ||
                           app.path.hasPrefix("/System/Library/CoreServices/")
        if isSystemApp {
            return (false, "Safety block: Cannot inject into system app (\(bundleId)). This could cause a white screen / boot loop. Only third-party apps are allowed.")
        }

        let fm = FileManager.default
        let dylibName = (dylibPath as NSString).lastPathComponent

        // Determine jailbreak root
        let jbRoot: String
        if fm.fileExists(atPath: "/var/jb") {
            jbRoot = "/var/jb"
        } else if fm.fileExists(atPath: "/jb") {
            jbRoot = "/jb"
        } else {
            return (false, "Jailbreak root not found")
        }

        // Copy dylib to jailbreak tweak directory
        let tweakDir = "\(jbRoot)/Library/TweakInject"
        try? fm.createDirectory(atPath: tweakDir, withIntermediateDirectories: true)
        let destDylib = "\(tweakDir)/\(dylibName)"

        // Copy dylib
        do {
            if fm.fileExists(atPath: destDylib) {
                try fm.removeItem(atPath: destDylib)
            }
            try fm.copyItem(atPath: dylibPath, toPath: destDylib)
        } catch {
            return (false, "Failed to copy dylib: \(error.localizedDescription)")
        }

        // Set permissions (use root to ensure correct ownership)
        _ = spawnRoot("/bin/chmod", args: ["755", destDylib], timeout: 5)
        _ = spawnRoot("/usr/sbin/chown", args: ["33:33", destDylib], timeout: 5)

        // Note: ElleKit loads all dylibs in /var/jb/Library/TweakInject/ globally
        // To target specific apps, we would need to configure ellekit.plist
        // For simplicity, this implementation loads globally (all apps)

        // Restart the app to load the dylib
        // Use executable name, not display name
        let execName = (app.path as NSString).lastPathComponent
        let (killRc, killOut) = spawnRoot("/usr/bin/killall", args: [execName], timeout: 5)
        _ = killRc; _ = killOut  // Ignore errors, app may not be running

        return (true, """
            ElleKit injection successful!
            - App: \(app.name) (\(bundleId))
            - Dylib: \(dylibName)
            - Mode: \(mode)
            - Note: ElleKit loads globally (all apps) at startup. Restart the target app to load the dylib.
            """)
    }

    // MARK: - v3.0.89：iOS 17 兼容的静态injected (insert_dylib + trollstorehelper 重装）
    /// 原理：复制 App bundle → 把 dylib 放进去 → insert_dylib 改主二进制 → 删旧签名 → 打包 IPA → trollstorehelper 重装
    /// 为什么 iOS 17 能用：TrollStore 安装时自动用它的漏洞重签，不需要 ct_bypass 运行时改签名
    func injectStatic(bundleId: String, dylibPath: String) -> (Bool, String) {
        let fm = FileManager.default
        guard let app = AppCatalog.find(bundleId) else {
            return (false, "App not found: \(bundleId)")
        }

        let workspace = Workspace.root
        let injectRoot = workspace.appendingPathComponent("static_inject").path
        try? fm.createDirectory(atPath: injectRoot, withIntermediateDirectories: true)

        // 1. 复制 App bundle 到临时目录
        let appDirName = (app.path as NSString).lastPathComponent
        let destApp = injectRoot + "/" + appDirName
        _ = try? fm.removeItem(atPath: destApp)
        let (cpRc, cpOut) = spawnRoot("/bin/cp", args: ["-a", app.path, destApp], timeout: 180)
        guard cpRc == 0 else {
            return (false, "Copy app failed: \(cpOut.prefix(200))")
        }

        // 2. 把 dylib 复制到 App bundle 的 Frameworks 目录
        let frameworksDir = destApp + "/Frameworks"
        try? fm.createDirectory(atPath: frameworksDir, withIntermediateDirectories: true)
        let dylibName = (dylibPath as NSString).lastPathComponent
        let destDylib = frameworksDir + "/" + dylibName
        let (cpDylibRc, cpDylibOut) = spawnRoot("/bin/cp", args: [dylibPath, destDylib], timeout: 60)
        guard cpDylibRc == 0 else {
            return (false, "Copy dylib failed: \(cpDylibOut.prefix(200))")
        }

        // 3. 找主二进制路径
        guard let plist = NSDictionary(contentsOfFile: destApp + "/Info.plist"),
              let execName = plist["CFBundleExecutable"] as? String else {
            return (false, "Cannot read Info.plist or find CFBundleExecutable")
        }
        let mainBin = destApp + "/" + execName

        // 4. 用 insert_dylib 修改主二进制 (添加 load command）
        let dylibLoadPath = "@executable_path/Frameworks/" + dylibName
        guard let insertDylib = binaryPath("insert_dylib") else {
            return (false, "insert_dylib not bundled")
        }
        let (insRc, insOut) = spawnRoot(insertDylib, args: ["--inplace", dylibLoadPath, mainBin], timeout: 30)
        guard insRc == 0 else {
            return (false, "insert_dylib failed: \(insOut.prefix(300))")
        }

        // 5. 删除旧签名 (TrollStore 安装时会重新签名）
        let codeSign = destApp + "/_CodeSignature"
        if fm.fileExists(atPath: codeSign) {
            _ = spawnRoot("/bin/rm", args: ["-rf", codeSign])
        }
        let codeResources = destApp + "/CodeResources"
        if fm.fileExists(atPath: codeResources) {
            _ = spawnRoot("/bin/rm", args: ["-rf", codeResources])
        }

        // 6. 打包成 IPA (Payload/App.app 结构）
        let ipaName = bundleId + "_injected.ipa"
        let ipaPath = injectRoot + "/" + ipaName
        let payloadRoot = injectRoot + "/Payload-" + bundleId
        _ = try? fm.removeItem(atPath: payloadRoot)
        try? fm.createDirectory(atPath: payloadRoot + "/Payload", withIntermediateDirectories: true)
        let payloadApp = payloadRoot + "/Payload/" + appDirName
        _ = try? fm.removeItem(atPath: payloadApp)
        let (cpPayloadRc, cpPayloadOut) = spawnRoot("/bin/cp", args: ["-a", destApp, payloadApp], timeout: 180)
        guard cpPayloadRc == 0 else {
            return (false, "Assemble Payload failed: \(cpPayloadOut.prefix(200))")
        }
        _ = try? fm.removeItem(atPath: ipaPath)
        guard ZipStorer.createZip(at: ipaPath, fromDirectory: payloadRoot) else {
            return (false, "Zip IPA failed")
        }
        _ = try? fm.removeItem(atPath: payloadRoot)
        _ = try? fm.removeItem(atPath: destApp)

        // 7. 安装注入后的 IPA：按档位选择安装器（v8 R⑦：JB 侧优先，TrollStore 兜底）
        let (installed, installMsg) = installIPA(ipaPath)
        guard installed else {
            return (false, "安装失败：\(installMsg)。IPA 已生成：\(ipaPath)")
        }

        AppCatalog.invalidateCache()
        return (true, "Static injection success. App reinstalled with dylib: \(dylibName). \(installMsg). IPA at: \(ipaPath)")
    }

    // MARK: - v8（R⑦/R⑪）：IPA 安装链（TrollStore / JB 双档）
    //
    // 17.1 + Relaxin 上 trollstorehelper 不存在，必须走 JB 侧 appinst/jbctl。
    // 依次尝试，全部失败时把 IPA 路径交给用户手动安装（不静默失败）。
    func installIPA(_ ipaPath: String) -> (Bool, String) {
        let fm = FileManager.default
        let candidates: [(path: String, args: [String], label: String)] = [
            ("/var/jb/usr/bin/appinst", ["install", ipaPath], "jb-appinst"),
            ("/var/jb/usr/bin/jbctl", ["install", ipaPath], "jbctl"),
            ("/var/jb/usr/bin/trollstorehelper", ["install", ipaPath], "jb-trollstorehelper"),
            ("/usr/bin/appinst", ["install", ipaPath], "root-appinst"),
            ("/var/usr/bin/trollstorehelper", ["install", ipaPath], "trollstorehelper"),
        ]
        for c in candidates {
            guard fm.isExecutableFile(atPath: c.path) else { continue }
            let (rc, out) = spawnRoot(c.path, args: c.args, timeout: 240)
            if rc == 0 { return (true, "installed via \(c.label)") }
            lastInstallError = "[\(c.label)] \(out.prefix(200))"
        }
        return (false, lastInstallError ?? "no installer found (appinst/jbctl/trollstorehelper 均不可用)")
    }

    private var lastInstallError: String?
}
