import Foundation
import Darwin

// MARK: - R①②③④：iOS 17.1 + Relaxin 设备专项 —— 探测驱动的执行策略层
//
// 依据 docs/plan/03-relaxin-18.md（设备专项改造清单）：
//   - 第一目标设备 iOS 17.1 + Relaxin（RootHide 系，A14–A17）
//   - TrollStore 路径不可用；ct_bypass 不可用（>17.0）；kfd 不可用（>16.6.1）
//   - persona spawn 恒返回 85 (ENOSYS)；rootHide 可能拦截 App 容器内第三方二进制执行（EBADEXEC 85）
//   - 方向：注入支持静态路径；提权走 JB 侧二进制（/var/jb）与 native 直写；工具链优先 JB 侧
//   - 一切策略由探测结果驱动（spawn_probe → ExecutionStrategy），禁止写死设备假设
//   - 不得破坏 TrollStore（≤17.0）与其它越狱档的既有路径；新逻辑一律「探测驱动/档位开关」

// MARK: - R②：spawn 四类探测

/// spawn 探测的四个方向，结果合并出执行档位。
enum SpawnProbe {
    struct Verdict {
        /// 1. 原生 spawn（mobile 身份）——决定「App 容器内能不能起第三方二进制」
        var native: SpawnResult = .untested
        /// 2. persona spawn（uid0）——TrollStore 路径的核心
        var persona: SpawnResult = .untested
        /// 3. JB 侧二进制 spawn——/var/jb 工具链可用性
        var jbSide: SpawnResult = .untested
        /// 4. setuid 直跑（不带 persona）——JB/TS setuid 位是否生效
        var setuid: SpawnResult = .untested

        /// 给 AI/UI 的一句话结论
        var summary: String {
            let parts = [
                "native=\(native.short)",
                "persona=\(persona.short)",
                "jb=\(jbSide.short)",
                "setuid=\(setuid.short)",
            ]
            return parts.joined(separator: " ")
        }

        var json: [String: Any] {
            [
                "native": native.detailDict,
                "persona": persona.detailDict,
                "jb_side": jbSide.detailDict,
                "setuid": setuid.detailDict,
                "summary": summary,
            ]
        }
    }

    enum SpawnResult {
        case untested
        case ok
        case failed(code: Int32, detail: String)

        var short: String {
            switch self {
            case .untested: return "untested"
            case .ok: return "ok"
            case .failed(let c, _): return "err\(c)"
            }
        }

        var detailDict: [String: Any] {
            switch self {
            case .untested: return ["status": "untested"]
            case .ok: return ["status": "ok"]
            case .failed(let c, let d): return ["status": "failed", "errno": Int(c), "detail": d]
            }
        }

        var code: Int32 {
            switch self {
            case .failed(let c, _): return c
            default: return 0
            }
        }
    }

    /// 探测用二进制：原生用系统 /bin/echo；JB 侧用 /var/jb/usr/bin/echo 之类
    // v8.1（P0-3 修正）：/bin/echo 在 iOS 不存在（errno 2），/usr/bin/echo 在 rootless 下
    // 解析也常失败（errno 14）——改用一定存在的 /bin/sh 做「能不能 spawn」探针。
    private static var nativeProbeBin: String { "/bin/sh" }
    private static var jbProbeBin: String? {
        for c in ["/usr/bin/sh", "/bin/sh", "/usr/bin/dash", "/bin/dash"] {
            if let p = JBEnvironment.firstExistingPath(c) { return p }
        }
        return nil
    }

    /// 完整探测（缓存 30s，避免每次 dispatch 都跑）
    static func probe() -> Verdict {
        // 缓存
        if let cached = cachedVerdict, Date().timeIntervalSince(cachedAt) < 30 {
            return cached
        }
        var v = Verdict()

        // 1. 原生 spawn（sh -c exit 0）
        v.native = run(nativeProbeBin, args: ["-c", "exit 0"])

        // 2. JB 侧二进制
        if let jbBin = jbProbeBin {
            v.jbSide = run(jbBin, args: ["-c", "exit 0"])
        } else {
            v.jbSide = .failed(code: 2, detail: "no jb-side echo found")
        }

        // 3. setuid（无 persona）——必须验证「真的拿到 uid 0」，不是 spawn 成功就算 ok
        v.setuid = InjectionManager.shared.spawnPrivilegeProbe(usePersona: false)

        // 4. persona（同样验证真实 uid；17.1 上通常 85 或仍 501）
        v.persona = InjectionManager.shared.spawnPrivilegeProbe(usePersona: true)

        cachedVerdict = v
        cachedAt = Date()
        return v
    }

    /// 使缓存失效（环境变化/设置变更后调用）
    static func invalidate() {
        cachedVerdict = nil
        cachedAt = Date(timeIntervalSince1970: 0)
    }

    private static var cachedVerdict: Verdict?
    private static var cachedAt = Date(timeIntervalSince1970: 0)

    /// 跑一个二进制，返回结果分类
    static func run(_ bin: String, args: [String], timeout: Double = 8) -> SpawnResult {
        // posix_spawn 探针（不走 runAsRoot，避免递归依赖策略层）
        var pid: pid_t = 0
        var argv = ([bin] + args).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // 输出丢到 /dev/null，避免污染探针结果
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        let rc = argv.withUnsafeBufferPointer { buf in
            posix_spawn(&pid, bin, &fileActions, &attr, buf.baseAddress, nil)
        }
        if rc != 0 {
            let detail: String
            switch rc {
            case 85: detail = "ENOSYS(85)：容器内 spawn 被拦截（rootHide/Relaxin 或 AMFI）"
            case 86: detail = "EBADEXEC(86)：二进制格式不被认可（第三方 Mach-O 被拦）"
            case 13: detail = "EACCES(13)：权限不足"
            default: detail = "errno \(rc)"
            }
            return .failed(code: rc, detail: detail)
        }
        // 等它结束，回收——必须看退出码：spawn 成功 ≠ 命令成功
        var status: Int32 = 0
        var waited = 0
        while waitpid(pid, &status, WNOHANG) == 0 && waited < 300 {
            usleep(20_000)
            waited += 1
        }
        let exitCode = (status & 0x7f) == 0 ? Int32((status >> 8) & 0xff) : -1
        if exitCode == 0 { return .ok }
        return .failed(code: exitCode, detail: "spawn ok but exit=\(exitCode)")
    }
}

// MARK: - R③：ExecutionStrategy（档位）

/// 由探测结果合并出的「执行档位」。所有提权/注入/工具链决策都查这里。
enum ExecutionStrategy {
    enum Tier: String {
        case trollStore     // TrollStore（≤17.0）：persona + setuid 可用
        case jailbroken     // 标准越狱（rootless/rootHide）：JB 侧二进制 + native 直写
        case rootHide       // RootHide/Relaxin：JB 侧可用但容器内 spawn 被拦
        case containerOnly  // 无提权路径：仅容器内能力
        case locked         // 什么都不可用
    }

    /// 目标设备约束（写进代码的硬事实，探测只确认、不推翻）
    struct DeviceFacts {
        static var iosMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

        /// TrollStore 运行时注入上限 iOS 17.0
        static var trollStoreUsable: Bool { iosMajor <= 17 && !JBEnvironment.isJailbroken }
        /// ct_bypass 上限 17.0
        static var ctBypassUsable: Bool { iosMajor <= 17 }
        /// kfd 上限 16.6.1
        static var kfdUsable: Bool { iosMajor < 17 || (iosMajor == 16 && ProcessInfo.processInfo.operatingSystemVersion.minorVersion <= 6) }
        /// persona spawn 在 iOS 17+ AMFI 下被拒（85）
        static var personaExpectedBlocked: Bool { iosMajor >= 17 }
    }

    /// 计算档位（探测驱动；探测失败按保守档位处理）
    static func current() -> Tier {
        let facts = DeviceFacts.self
        let probe = SpawnProbe.probe()
        let jb = JBEnvironment.isJailbroken

        if jb {
            if probe.jbSide.isOk || probe.setuid.isOk || probe.native.isOk {
                // JB 侧工具链可用 → rootHide 系（Relaxin）或 rootless
                return JBEnvironment.isRootHide ? .rootHide : .jailbroken
            }
            // JB 判定为是但三条链都失败 → 只剩容器内能力
            return .containerOnly
        }
        if facts.trollStoreUsable {
            if probe.persona.isOk || probe.setuid.isOk { return .trollStore }
            return .containerOnly
        }
        if probe.native.isOk { return .containerOnly }
        return .locked
    }

    /// 缓存档位（30s，与 probe 缓存一致）
    private static var cachedTier: Tier?
    private static var cachedTierAt = Date(timeIntervalSince1970: 0)

    static func tier() -> Tier {
        if let c = cachedTier, Date().timeIntervalSince(cachedTierAt) < 30 { return c }
        let t = current()
        cachedTier = t
        cachedTierAt = Date()
        return t
    }

    static func invalidate() {
        cachedTier = nil
        cachedTierAt = Date(timeIntervalSince1970: 0)
        SpawnProbe.invalidate()
    }

    // MARK: 能力查询（各模块查这里，不写死）

    /// 提权路径：JB 侧优先，native 直写兜底（R⑤⑥）
    static var canUsePersona: Bool {
        if DeviceFacts.personaExpectedBlocked { return false }
        return tier() == .trollStore && SpawnProbe.probe().persona.isOk
    }

    /// 是否应优先 JB 侧工具链（/var/jb）
    static var preferJBToolchain: Bool {
        switch tier() {
        case .jailbroken, .rootHide: return true
        default: return false
        }
    }

    /// 容器内能否 spawn 第三方二进制
    static var canSpawnNative: Bool {
        switch tier() {
        case .locked: return false
        default: return SpawnProbe.probe().native.isOk
        }
    }

    /// 注入路径：静态注入可用性（R⑦）
    static var staticInjectionUsable: Bool {
        switch tier() {
        case .jailbroken, .rootHide: return true
        case .trollStore: return DeviceFacts.ctBypassUsable
        default: return false
        }
    }

    /// 内存注入：v10.0 起永久不可用。
    /// opainject 的 remote dlopen 依赖 task_for_pid + 线程创建，iOS 17 起被内核封堵
    /// （root 下 createRemotePthread 挂死、mobile 下 spawnPacChild 拿不到 task port = 5），
    /// 且项目已把 opainject 整个移除。注入只有静态重打包一条路。
    static var memoryInjectionUsable: Bool { false }

    /// kfd 可用性（R⑨ VPN 信任注入守卫）
    static var kfdUsable: Bool { DeviceFacts.kfdUsable }

    /// 给 AI/UI 的完整状态（R⑯）
    static func report() -> [String: Any] {
        let t = tier()
        let probe = SpawnProbe.probe()
        let facts = DeviceFacts.self
        let jb = JBEnvironment.isJailbroken
        return [
            "tier": t.rawValue,
            "spawn_probe": probe.json,
            "prefer_jb_toolchain": preferJBToolchain,
            "can_persona": canUsePersona,
            "static_injection": staticInjectionUsable,
            "memory_injection": memoryInjectionUsable,
            "kfd": facts.kfdUsable,
            "trollstore": facts.trollStoreUsable,
            "ios_major": facts.iosMajor,
            "jailbreak": jb,
            "jb_kind": JBEnvironment.kind.rawValue,
            "note": t == .rootHide
                ? "rootHide/Relaxin：提权走 JB 侧二进制与 native 直写，persona/ct_bypass/kfd 不可用"
                : (t == .jailbroken ? "越狱：JB 侧工具链优先" : ""),
            // v8（R⑮）：entitlements 指引——越狱档不需要 TrollStore 的「编辑 Entitlements」，
            // 权限由 amfid 绕过签名校验 + 越狱注入库提供
            "entitlements_guidance": jb
                ? "越狱环境：无需 TrollStore「编辑 Entitlements」；权限来自 amfid 绕过签名校验，App 自带 entitlements 由 ldid 直接签入"
                : "TrollStore：安装时开启「编辑 Entitlements」并卸载重装才生效",
            // v8（R⑰）：档位已缓存 30s，避免每次 dispatch 都重跑四类 spawn 探测
            "probe_cached_ttl_seconds": 30,
        ]
    }
}

private extension SpawnProbe.SpawnResult {
    var isOk: Bool {
        if case .ok = self { return true }
        return false
    }
}