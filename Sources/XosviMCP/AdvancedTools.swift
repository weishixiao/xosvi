import Foundation
// v6.9.5：app.entitlements 走静态 Mach-O 解析，不 spawn ldid。
// extractEntitlements 直接消费 MachOKit 的 MachOFile / CodeSign 结构，必须显式导入
// （与 MachoTools.swift 用同一 @_spi 访问级别）。
@_spi(Support) import MachOKit

import UIKit
import Security
import AdSupport



// v2.9.72：符号浏览器 + 插件系统 + 兼容矩阵 + 崩溃复现 hook 模板生成



// MARK: - 二进制符号浏览器



final class BinarySymbolsTool: MCPTool {

    let definition = ToolDefinition(

        name: "binary.symbols",

        summary: "Extract symbols from a binary file (ObjC classes/methods, strings, imports). Use for: reverse engineer an app, analyze binary structure, find interesting classes/methods to hook. Don't use for: inject dylib (use injection.enable), check app deps (use app.deps). Example: user says 'what classes does 小红书 have' → extract ObjC symbols.",

        parameters: [

            "path": "Path to binary file (get main binary path via ipa.inspect)",

            "type": "What to extract: objc (classes/methods) / strings / imports / all (default)",

            "search": "Search keyword filter (optional)",

            "limit": "Max results (default 100)"

        ],

    verified: true, category: "analysis", annotations: .readOnlyLocal, cache: ToolCachePolicy.long)



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        guard let path = params["path"] as? String, !path.isEmpty else {

            throw MCPError.invalidParams("path required")

        }

        let type = (params["type"] as? String) ?? "all"

        let search = (params["search"] as? String) ?? ""

        let limit = (params["limit"] as? Int) ?? 100
        let direction = (params["direction"] as? String) ?? ""



        guard FileManager.default.fileExists(atPath: path) else {

            return ["error": "file not found: \(path)"]

        }

        // v4.3.9: 定向分析模式——按方向(内购/VIP/广告)提取精简骨架, 大文件不全量喂 AI, AI 全读再分析原理
        if !direction.isEmpty {
            return directionalAnalyze(path: path, direction: direction)
        }



        var result: [String: Any] = ["path": path, "type": type]



        // 用 nm 提取符号 (如果有 nm）

        let nmPath = Bundle.main.path(forResource: "nm", ofType: nil, inDirectory: "bin") ?? "/usr/bin/nm"

        if FileManager.default.fileExists(atPath: nmPath) {

            let nmResult = InjectionManager.shared.spawnRootDetailed(nmPath, args: ["-g", "-U", path], timeout: 60)

            var symbols: [String] = []

            for line in nmResult.stdout.components(separatedBy: .newlines) {

                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if !trimmed.isEmpty && (search.isEmpty || trimmed.localizedCaseInsensitiveContains(search)) {

                    symbols.append(trimmed)

                }

            }

            result["symbols"] = Array(symbols.prefix(limit))

            result["total"] = symbols.count

        }



        // 用 strings 提取字符串

        if type == "strings" || type == "all" {

            let stringsPath = Bundle.main.path(forResource: "strings", ofType: nil, inDirectory: "bin") ?? "/usr/bin/strings"

            if FileManager.default.fileExists(atPath: stringsPath) {

                let strResult = InjectionManager.shared.spawnRootDetailed(stringsPath, args: [path], timeout: 60)

                var strings: [String] = []

                for line in strResult.stdout.components(separatedBy: .newlines) {

                    let trimmed = line.trimmingCharacters(in: .whitespaces)

                    if trimmed.count >= 4 && (search.isEmpty || trimmed.localizedCaseInsensitiveContains(search)) {

                        strings.append(trimmed)

                    }

                }

                result["strings"] = Array(strings.prefix(limit))

                result["strings_total"] = strings.count

            } else {

                // v4.3.3: bin/strings 未打包时, 用 Swift 原生分块扫描(不依赖外部工具)。
                // 原生 iOS 读大文件(如 22MB 砸壳二进制)内存充足, 不触发 Alpine OOM。
                let native = extractStringsNative(path: path, search: search)

                result["strings"] = Array(native.prefix(limit))

                result["strings_total"] = native.count

                result["strings_native"] = true

            }

        }



        // Objective-C class name (从字符串中提取）

        if type == "objc" || type == "all" {

            if let strings = result["strings"] as? [String] {

                let classes = strings.filter { $0.hasPrefix("_OBJC_CLASS_$_") || $0.hasPrefix("OBJC_CLASS_$_") }

                    .map { $0.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "").replacingOccurrences(of: "OBJC_CLASS_$_", with: "") }

                let selectors = strings.filter { $0.contains(":") && $0.count < 60 && !$0.contains(" ") }

                result["objc_classes"] = Array(classes.prefix(limit))

                result["objc_selectors_sample"] = Array(selectors.prefix(50))

            }

        }



        if result["symbols"] == nil && result["strings"] == nil {

            result["hint"] = "nm/strings 是内置原生实现（v9.15 起 `nm <path>` / `strings <path>` 直接可用）；也可用 otool -ov 看 ObjC 段，或 ldid -e 看签名"

        }



        return result

    }



    /// v4.3.3: 原生 strings 扫描（bin/strings 未打包时的 fallback）。
    /// 用 FileManager/Data 分块读取并扫描可读 ASCII 串, 不依赖外部二进制, 大文件(22MB)原生读不 OOM。
    private func extractStringsNative(path: String, search: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let chunkSize = 4 * 1024 * 1024
        var strings: [String] = []
        var tail = Data()
        var total = 0
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? nil
            guard let chunk, !chunk.isEmpty else { break }
            total += chunk.count
            if total > 256 * 1024 * 1024 { break } // 防御: 超 256MB 截断, 防耗时
            var buf = tail; buf.append(chunk)
            // 拆可读 ASCII 串
            var cur = Data()
            for byte in buf {
                if byte >= 0x20 && byte <= 0x7e {
                    cur.append(byte)
                } else {
                    if cur.count >= 4, let s = String(data: cur, encoding: .utf8),
                       (search.isEmpty || keywordsMatch(s, search)) {
                        strings.append(s)
                    }
                    cur = Data()
                }
            }
            // 保留末尾未闭合串到下一块(避免跨块切断)
            tail = cur
        }
        if tail.count >= 4, let s = String(data: tail, encoding: .utf8),
           (search.isEmpty || keywordsMatch(s, search)) {
            strings.append(s)
        }
        return strings
    }

    // v4.3.9: 多关键词匹配——search 支持 "|" 分隔(如 "StoreKit|SKPayment|VIP"), 命中任一即算。
    private func keywordsMatch(_ s: String, _ pattern: String) -> Bool {
        if pattern.isEmpty { return true }
        return pattern.split(separator: "|").contains { s.localizedCaseInsensitiveContains($0) }
    }

    // v4.3.9: 定向分析模式——按方向(内购/VIP/广告)提取精简骨架, 大文件不全量喂 AI。
    // 方法: 1) nm 符号表筛相关类/方法(符号表小, 不随文件大小长) 2) 分块扫 strings 按方向关键词筛命中
    //      3) 输出骨架(相关类+方法+关键字符串), AI 可全量读取再分析原理。
    func directionalAnalyze(path: String, direction: String) -> [String: Any] {
        let kws = directionalKeywords(direction)
        var related: [String] = []
        // 1) nm 符号表筛相关类/方法
        let nmPath = Bundle.main.path(forResource: "nm", ofType: nil, inDirectory: "bin") ?? "/usr/bin/nm"
        if FileManager.default.fileExists(atPath: nmPath) {
            let nmResult = InjectionManager.shared.spawnRootDetailed(nmPath, args: ["-g", "-U", path], timeout: 120)
            for line in nmResult.stdout.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, kws.contains(where: { t.localizedCaseInsensitiveContains($0) }) {
                    related.append(t)
                }
            }
        }
        // 2) 分块扫 strings 按方向关键词筛命中(定向, 不全量返回)
        let hits = extractStringsNative(path: path, search: kws.joined(separator: "|"))
        // 3) 骨架输出(精简, AI 全读)
        return [
            "status": "analyzed_direction",
            "direction": direction,
            "keywords": kws,
            "related_symbols": Array(related.prefix(200)),
            "related_symbols_total": related.count,
            "key_strings": Array(hits.prefix(150)),
            "key_strings_total": hits.count,
            "note": "定向骨架已精简(相关类/方法+关键字符串), AI 可全量读取并推导内购/校验原理"
        ]
    }

    // v4.3.9: 方向 → 关键词组
    private func directionalKeywords(_ d: String) -> [String] {
        let lc = d.lowercased()
        if lc.contains("内购") || lc.contains("iap") || lc.contains("purchase") || lc.contains("vip") || lc.contains("pay") {
            return ["StoreKit", "SKProduct", "SKPayment", "Transaction", "AppTransaction", "StoreKitManager",
                    "Payment", "Purchase", "Receipt", "Entitlement", "VIP", "RealPaidVIP", "lifetimeProduct",
                    "productID", "price", "iap", "subscription", "IAP"]
        }
        if lc.contains("广告") || lc.contains("ad") || lc.contains("banner") {
            return ["Advert", "Banner", "Reward", "Interstitial", "AdSDK", "AdManager", "SDKAd", "ADManager"]
        }
        return [d]
    }

}



// MARK: - 插件系统 (简化版）



final class PluginManager {

    static let shared = PluginManager()

    private(set) var plugins: [PluginInfo] = []



    struct PluginInfo: Identifiable {

        let id = UUID()

        let name: String

        let path: String

        let type: PluginType

        let version: String

        var enabled: Bool



        enum PluginType: String {

            case dylib = "dylib"

            case tool = "tool"

            case skill = "skill"

        }

    }



    func scan() {

        let pluginDir = XDirs.workspace + "/plugins"

        try? FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)



        plugins = []

        // 扫描内置 tweaks

        if let builtinDir = Bundle.main.path(forResource: "tweaks", ofType: nil) {

            if let files = try? FileManager.default.contentsOfDirectory(atPath: builtinDir) {

                for file in files where file.hasSuffix(".dylib") {

                    plugins.append(PluginInfo(

                        name: file.replacingOccurrences(of: ".dylib", with: ""),

                        path: builtinDir.appending("/\(file)"),

                        type: .dylib,

                        version: "builtin",

                        enabled: true

                    ))

                }

            }

        }

        // 扫描用户插件目录

        if let files = try? FileManager.default.contentsOfDirectory(atPath: pluginDir) {

            for file in files {

                let fullPath = pluginDir.appending("/\(file)")

                if file.hasSuffix(".dylib") {

                    plugins.append(PluginInfo(name: file, path: fullPath, type: .dylib, version: "user", enabled: true))

                }

            }

        }

    }



    func list() -> [[String: Any]] {

        scan()

        return plugins.map { [

            "name": $0.name,

            "path": $0.path,

            "type": $0.type.rawValue,

            "version": $0.version,

            "enabled": $0.enabled

        ] }

    }

}



final class PluginTool: MCPTool {

    let definition = ToolDefinition(

        name: "plugin.list",

        summary: "List installed dylib plugins (built-in + user). Use for: see what plugins are available, check plugin status. Don't use for: inject plugin into app (use injection.enable), list injected apps (use injection.status). Example: user says 'what plugins are available' → list plugins.",

        parameters: [

            "action": "list (show all) / enable / disable",

            "name": "Plugin name (required for enable/disable action)"

        ],

    verified: true, category: "analysis")



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        let action = (params["action"] as? String) ?? "list"

        if action == "list" {

            return ["plugins": PluginManager.shared.list(), "count": PluginManager.shared.plugins.count]

        }

        return ["error": "unsupported action: \(action)"]

    }

}



// MARK: - 崩溃复现 hook 模板生成



final class CrashReproTool: MCPTool {

    let definition = ToolDefinition(

        name: "crash.repro_template",

        summary: "Generate a Logos hook template from a crash report. Use for: debug why app crashes, create hook to reproduce/fix crash. Don't use for: collect crash logs (use log.collect), analyze crash (use diagnose.crash). Example: user says '小红书 keeps crashing, generate a hook for me' → generate repro template.",

        parameters: [

            "crash_log": "Crash log text (get from diagnose.crash first)",

            "bundle_id": "Target App bundle ID (for context)"

        ],

    verified: true, category: "diagnose")



    func invoke(_ params: [String: Any]) throws -> [String: Any] {

        guard let crashLog = params["crash_log"] as? String, !crashLog.isEmpty else {

            throw MCPError.invalidParams("crash_log required")

        }

        let bundleId = params["bundle_id"] as? String ?? "com.example.app"



        // 从崩溃日志中提取关键信息

        var exceptionType = ""

        var crashedThread = "0"



        for line in crashLog.components(separatedBy: .newlines) {

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Exception Type:") {

                exceptionType = trimmed.replacingOccurrences(of: "Exception Type: ", with: "")

            } else if trimmed.hasPrefix("Triggered by Thread:") {

                crashedThread = trimmed.replacingOccurrences(of: "Triggered by Thread: ", with: "")

            } else if trimmed.contains("Thread \(crashedThread) Crashed:") {

                // 下一帧是崩溃位置

            }

        }



        // 提取崩溃线程第一帧

        let lines = crashLog.components(separatedBy: .newlines)

        var inCrashedThread = false

        var firstFrame = ""

        for line in lines {

            if line.contains("Thread \(crashedThread) Crashed:") {

                inCrashedThread = true

                continue

            }

            if inCrashedThread && !line.isEmpty {

                firstFrame = line.trimmingCharacters(in: .whitespaces)

                break

            }

        }



        // 生成 hook 模板

        let template = """

        // 自动生成的崩溃复现 hook 模板

        // 崩溃类型: \(exceptionType)

        // 崩溃线程: \(crashedThread)

        // 崩溃帧: \(firstFrame)

        // 目标: \(bundleId)



        #import <Foundation/Foundation.h>

        #import <UIKit/UIKit.h>



        static NSString *kCrashLog = @"/var/mobile/Documents/wiki.qaq.xosvi/Workspace/crash_repro_\(bundleId).log";



        static void logRepro(NSString *msg) {

            NSString *ts = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];

            NSString *line = [NSString stringWithFormat:@"[%@] %@\\n", ts, msg];

            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kCrashLog];

            if (!fh) { [[NSData data] writeToFile:kCrashLog atomically:YES]; fh = [NSFileHandle fileHandleForWritingAtPath:kCrashLog]; }

            [fh seekToEndOfFile];

            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];

            [fh closeFile];

        }



        // TODO: 根据崩溃帧替换下面的 hook 目标

        // 用 binary.symbols 搜索崩溃帧中的class name和方法名

        %hook UIApplication



        - (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

            logRepro(@"[REPRO] application didFinishLaunching");

            logRepro([NSString stringWithFormat:@"[REPRO] launchOptions: %@", launchOptions]);

            return %orig;

        }



        %end



        // 崩溃帧 hook (需根据实际崩溃位置修改）

        // %hook <CrashedClass>

        // - (<ReturnType>)<crashedMethod>:(id)arg {

        //     logRepro([NSString stringWithFormat:@"[REPRO] %@ called with: %@", NSStringFromSelector(_cmd), arg]);

        //     @try {

        //         return %orig(arg);

        //     } @catch (NSException *e) {

        //         logRepro([NSString stringWithFormat:@"[REPRO] CAUGHT: %@", e]);

        //         logRepro([NSString stringWithFormat:@"[REPRO] callStack: %@", [e callStackSymbols]]);

        //         @throw e;

        //     }

        // }

        // %end



        __attribute__((constructor))

        static void init() {

            logRepro(@"[REPRO] CrashRepro dylib loaded");

        }

        """



        // 输出到工作区

        let outputPath = XDirs.workspace + "/crash_repro_\(bundleId).x"

        try? template.write(toFile: outputPath, atomically: true, encoding: .utf8)



        return [

            "exception_type": exceptionType,

            "crashed_thread": crashedThread,

            "crashed_frame": firstFrame,

            "template_path": outputPath,

            "template": template,

            "next_steps": [

                "1. use binary.symbols to find the class name and method name in the crash frame",

                "2. replace the TODO parts in the template to hook the crashing method",

                "3. compile the dylib online",

                "4. inject into the target App and reproduce the crash",

                "5. read crash_repro_*.log to inspect the call arguments"

            ]

        ]

    }

}

// MARK: - v2.9.90 高级工具组（v10.0：opainject 内存注入已移除，只剩 ProbeEngine 静态探测 / 配置化 Hook）

// MARK: - 进程/启动辅助

enum ProcessHelper {
    // MARK: - libproc 进程枚举 (v3.0.42：根治 pidOf——不依赖 /bin/ps 输出解析）
    // iOS 系统库 /usr/lib/libproc.dylib：proc_listpids 枚举全部 pid，proc_pidpath 拿可执行路径。
    // 比 ps 解析稳 (Darwin ps 的 comm= 列有 15 字符截断/格式差异问题），且无需额外权限。
    private enum LibProc {
        typealias ListPidsFn = @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?, Int32) -> Int32
        typealias PidPathFn = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
        static let handle: UnsafeMutableRawPointer? = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY)
        static let listPids: ListPidsFn? = {
            guard let h = handle, let s = dlsym(h, "proc_listpids") else { return nil }
            return unsafeBitCast(s, to: ListPidsFn.self)
        }()
        static let pidPath: PidPathFn? = {
            guard let h = handle, let s = dlsym(h, "proc_pidpath") else { return nil }
            return unsafeBitCast(s, to: PidPathFn.self)
        }()
    }

    /// 按可执行名查 pid：优先 libproc (枚举所有 pid + 完整可执行路径），failed回退 ps 解析。
    static func pidOf(executableName: String) -> Int? {
        // 方案 A：libproc (平台原生）
        if let pid = pidOfViaLibProc(executableName: executableName) {
            return pid
        }
        // 方案 B：ps -A 解析 (兜底）
        let (_, out) = InjectionManager.shared.spawn("/bin/ps", args: ["ps", "-A", "-o", "pid=,comm="])
        for line in out.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let spaceIdx = trimmed.firstIndex(of: " ") else { continue }
            let pidStr = String(trimmed[..<spaceIdx]).trimmingCharacters(in: .whitespaces)
            let comm = String(trimmed[trimmed.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
            // 精确匹配
            if comm == executableName, let pid = Int(pidStr) {
                return pid
            }
            // 包含匹配 (comm 可能是完整路径）
            if comm.contains(executableName), let pid = Int(pidStr) {
                // 确保是完整文件名匹配，不是子串
                let lastPath = (comm as NSString).lastPathComponent
                if lastPath == executableName {
                    return pid
                }
            }
        }
        return nil
    }

    private static func pidOfViaLibProc(executableName: String) -> Int? {
        guard let listPids = LibProc.listPids, let pidPath = LibProc.pidPath else { return nil }
        let capacity = 4096
        var pids = [Int32](repeating: 0, count: capacity)
        let bytes = listPids(1 /* PROC_ALL_PIDS */, 0, &pids, Int32(capacity * MemoryLayout<Int32>.size))
        guard bytes > 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<Int32>.size
        for i in 0..<min(count, capacity) {
            if pids[i] <= 0 { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            let len = pidPath(pids[i], &buf, UInt32(buf.count))
            if len > 0 {
                let path = String(cString: buf)
                if (path as NSString).lastPathComponent == executableName {
                    return Int(pids[i])
                }
            }
        }
        return nil
    }

    /// 启动 App：优先 SBSLaunchApplicationWithIdentifier (需 frontboard/springboard entitlements），
    /// failed 回退 LSApplicationWorkspace（主 App 有 backboardd.launchapplications），再回退 openURL，
    /// 再 failed 返回提示。v6.1.5-14f：加 LSWorkspace 兜底 + 代开日志（/var/mobile/Documents/wiki.qaq.xosvi/logs/hud.log）
    @discardableResult
    static func launchApp(bundleId: String) -> (Bool, String) {
        // v6.1.5-14f：代开日志——HUD 点菜单→主 App 代开的目标/结果，供真机诊断
        let logLine = "\(Date()): main-open bid=\(bundleId)\n"
        let logURL = URL(fileURLWithPath: "/var/mobile/Documents/wiki.qaq.xosvi/logs/hud.log")
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(logLine.data(using: .utf8)!); try? h.close() }
        else { try? logLine.data(using: .utf8)?.write(to: logURL, options: .atomic) }

        if let handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY) {
            typealias SBSLaunchFn = @convention(c) (CFString, Bool) -> Int32
            if let sym = dlsym(handle, "SBSLaunchApplicationWithIdentifier") {
                let fn = unsafeBitCast(sym, to: SBSLaunchFn.self)
                let ret = fn(bundleId as CFString, false)
                if ret == 0 {
                    return (true, "SBSLaunchApplicationWithIdentifier launch OK")
                }
            }
            dlclose(handle)
        }
        // v6.1.5-14f：LSApplicationWorkspace 兜底（主 App 有 backboardd.launchapplications）
        if let wsCls = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
           let wsUnmanaged = wsCls.perform(NSSelectorFromString("defaultWorkspace")) {
            let ws = wsUnmanaged.takeUnretainedValue()
            if ws.responds(to: NSSelectorFromString("openApplicationWithBundleID:")) {
                let ret = ws.perform(NSSelectorFromString("openApplicationWithBundleID:"), with: bundleId)
                if let num = ret?.takeUnretainedValue() as? NSNumber, num.boolValue {
                    return (true, "LSApplicationWorkspace open OK")
                }
            }
        }
        // v6.1.5-14i：SBSLaunchApplicationWithIdentifierAndLaunchOptions 第二路（新版 SBS API，
        // TheBall 二进制实测用这个打开 app，主 App 有 backboardd/frontboard launchapplications 权限）
        if let handle2 = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY) {
            typealias SBSLaunch2Fn = @convention(c) (CFString, CFDictionary?, CFDictionary?, Bool) -> Int32
            if let sym2 = dlsym(handle2, "SBSLaunchApplicationWithIdentifierAndLaunchOptions") {
                let fn2 = unsafeBitCast(sym2, to: SBSLaunch2Fn.self)
                let ret2 = fn2(bundleId as CFString, nil, nil, false)
                if ret2 == 0 {
                    return (true, "SBSLaunchApplicationWithIdentifierAndLaunchOptions launch OK")
                }
            }
            dlclose(handle2)
        }
        if let url = URL(string: "xosvi://") {
            if UIThreadBridge.openURL(url, timeout: 3) { return (true, "openURL launch OK") }
        }
        return (false, "cannot auto-launch (SBS unavailable and App has no URL scheme), open the target App manually on the home screen")
    }

    /// 找 App 主可执行名 (CFBundleExecutable）
    static func executableName(for app: AppCatalog.AppEntry) -> String {
        guard let dict = NSDictionary(contentsOfFile: app.path + "/Info.plist"),
              let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty else {
            return app.bundleId.components(separatedBy: ".").last ?? app.bundleId
        }
        return exe
    }

    /// tweaks 目录内 dylib 路径
    static func tweakPath(_ name: String) -> String? {
        let p = Bundle.main.bundleURL.appendingPathComponent("tweaks").appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// 写 JSON 配置文件到工作区
    static func writeWorkspaceConfig(_ fileName: String, dict: [String: Any]) -> Bool {
        let dir = "/var/mobile/Documents/wiki.qaq.xosvi/Workspace"
        if !FileManager.default.fileExists(atPath: dir) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let path = dir + "/" + fileName
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

    static func removeWorkspaceConfig(_ fileName: String) -> Bool {
        let path = "/var/mobile/Documents/wiki.qaq.xosvi/Workspace/" + fileName
        guard FileManager.default.fileExists(atPath: path) else { return true }
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - injection.mem：已移除（内存注入不再支持）

/// v10.0：运行时内存注入（opainject + remote dlopen）已从项目移除。
/// 保留这个工具名只为让旧调用拿到一条明确的迁移指引，不再执行任何注入。
final class InjectionMemTool: MCPTool {
    let definition = ToolDefinition(
        name: "injection.mem",
        summary: "REMOVED — runtime memory injection (opainject) is no longer supported. Injection is static re-packaging only: use injection.enable (insert_dylib + ldid + ct_bypass). Example: user says 'inject 小红书' → injection.enable, not injection.mem.",
        parameters: [
            "bundle_id": "Target App bundle ID (required, only used for the message)",
            "dylib_path": "Ignored (kept for compatibility)",
            "auto_launch": "Ignored (kept for compatibility)"
        ],
        returns: [
            "error": "always set: memory injection removed",
            "next_step": "injection.enable (static re-packaging)"
        ],
        verified: true
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let bundleId = (params["bundle_id"] as? String) ?? ""
        return [
            "status": "removed",
            "error": "内存注入（opainject 运行时 dlopen）已从 Xosvi 移除，iOS 17 起系统也封堵了这条路",
            "bundle_id": bundleId,
            "next_step": "injection.enable：静态重打包——insert_dylib 写 LC_LOAD_DYLIB + ldid 伪签 + ct_bypass 过 CoreTrust，越狱环境下原地改目标 Mach-O，必要时打 IPA 重装",
            "hint": "加密 App（cryptid=1）先 app command:decrypt 砸壳；静态注入一次生效、重开仍在，不需要内存注入"
        ]
    }
}

// MARK: - probe.inspect：运行时类探测 (ProbeAgent）——v10.0 已下线

/// 注意：本工具在 v10.0 随内存注入一起下线（dispatch 直接抛 UNSUPPORTED，不会再到这里）。
/// 它把 ProbeAgent 塞进目标进程的前提是 opainject 运行时注入，项目已不再提供。
/// 需要类/方法清单请用 `inject binary_symbols` 静态提取，或 `app command:decrypt` 砸壳后离线分析。
final class ProbeInspectTool: MCPTool {
    let definition = ToolDefinition(
        name: "probe.inspect",
        summary: "REMOVED (v10.0) — runtime class probing needed opainject memory injection, which is gone. Use inject binary_symbols (static class/method/string extraction, no running App needed) or app command:decrypt then offline analysis instead. Do not retry this tool.",
        parameters: [
            "bundle_id": "Target App bundle ID (required)",
            "query": "What to inspect: classes (list all) / class (details of one) / userdefaults / info",
            "class_name": "Specific class name (when query=class)",
            "prefix": "Filter classes by name prefix (reduces noise)",
            "limit": "Max classes to return (default 30, max 100)",
            "cleanup": "Remove ProbeAgent after query (default false)"
        ],
        prerequisites: ["【密文 App(cryptid=1)此工具无效】——报 TARGET_INCOMPATIBLE / 'encrypted (cryptid=1)' 时不重试, 先 app command=decrypt 砸壳 + replace_decrypted 后再分析", "必须先 inject enable ProbeAgent 注入探针(前置): 对加密 App 无法注入(见 inject prerequisites)"]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)", "hint": "use injection.list to search"]
        }

        // v3.0.89：iOS 17+ 不支持探针injected (opainject 依赖 ct_bypass，已失效）
        let majorVer = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if majorVer >= 17 {
            return [
                "error": "iOS 17+ does not support probe.inspect (depends on opainject/ct_bypass, deprecated)",
                "hint": "use injection.static (static injection) then retry",
                "ios_version": majorVer
            ]
        }

        let query = (params["query"] as? String) ?? "classes"
        let exeName = ProcessHelper.executableName(for: app)

        // v4.3.6: 前置自检——加密 App(cryptid=1) 直接提示先砸壳, 不浪费 opainject。
        // 之前 probe.inspect 无此检测, 对加密 app 直接试注入→TARGET_INCOMPATIBLE→AI 同参数循环重试。
        // 注入前拦截, 返回明确 code=TARGET_INCOMPATIBLE + next_step, 杜绝"加密 app 探针失败"循环源头。
        let probeMainBin = app.path + "/" + exeName
        if let pmo = MachOAnalyzer.analyze(probeMainBin), pmo.cryptID > 0 {
            return ["error": "target App is encrypted (cryptid=\(pmo.cryptID)), ProbeAgent cannot inject to read class structure",
                    "code": "TARGET_INCOMPATIBLE", "reason": "target",
                    "next_step": "switch to terminal: shell.exec run 'app.decrypt \(bundleId)' to decrypt, then use terminal to analyze decrypted_work/ decrypted binary. Do NOT retry probe.inspect (permanently ineffective)",
                    "hint": "all App Store apps are encrypted; probe is permanently ineffective here"]
        }

        var probeInjected = false
        if let pid = ProcessHelper.pidOf(executableName: exeName) {
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 {
                probeInjected = true
            } else {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.injectDylib(pid: pid, dylib: dylib)
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        } else {
            let (launched, msg) = ProcessHelper.launchApp(bundleId: bundleId)
            if !launched { return ["error": msg, "hint": "open target App manually then retry"] }
            var pid: Int? = nil
            for _ in 0..<12 {
                usleep(500_000)
                pid = ProcessHelper.pidOf(executableName: exeName)
                if pid != nil { break }
            }
            if let pid = pid {
                let dylib = ProcessHelper.tweakPath("ProbeAgent.dylib") ?? ""
                if !dylib.isEmpty {
                    let (_, out) = InjectionManager.shared.injectDylib(pid: pid, dylib: dylib)
                    probeInjected = out.contains("dlopen succeeded")
                }
            }
        }
        guard probeInjected else {
            let running = ProcessHelper.pidOf(executableName: exeName) != nil
            return ["error": "ProbeAgent injection failed (\(running ? "opainject rejected/anti-debug blocked" : "App not running"))",
                    "next_step": running ? "memory injection is gone (opainject removed); use inject binary_symbols for a static class/method dump instead" : "start target App with app.start bundle_id first, or open manually then retry",
                    "hint": "injection failure does not mean the App is broken; follow next_step first"]
        }

        var ready = false
        for _ in 0..<10 {
            usleep(400_000)
            if let (code, _) = httpGet(port: 4791, path: "/status"), code == 200 { ready = true; break }
        }
        guard ready else {
            return ["error": "ProbeAgent HTTP not ready (port 4791)"]
        }

        var path = "/probe/classes"
        var limit = params["limit"] as? Int ?? 30
        if limit > 100 { limit = 100 }
        let prefix = params["prefix"] as? String ?? ""
        switch query {
        case "class":
            guard let cn = params["class_name"] as? String, !cn.isEmpty else {
                throw MCPError.invalidParams("query=class requires class_name param")
            }
            path = "/probe/class?name=" + cn.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        case "userdefaults":
            path = "/probe/userdefaults"
        case "info":
            path = "/status"
        default:
            var qs = "limit=\(limit)"
            if !prefix.isEmpty { qs += "&prefix=" + prefix.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }
            path = "/probe/classes?" + qs
        }
        guard let (code, body) = httpGet(port: 4791, path: path) else {
            return ["error": "ProbeAgent query timeout"]
        }
        var result: [String: Any] = ["status": code == 200 ? "ok" : "error", "query": query, "bundle_id": bundleId, "app": app.name]
        if let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            result["data"] = obj
        } else {
            result["raw"] = body
        }

        let cleanup = (params["cleanup"] as? Bool) ?? false
        if cleanup {
            if let pid = ProcessHelper.pidOf(executableName: exeName) {
                _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exeName])
                result["cleanup"] = "target process killed; memory injection disappears with the process"
            }
        } else {
            result["cleanup"] = "injection kept (queryable while process alive); clear with cleanup=true or App restart"
        }
        AuditLog.shared.log("probe.inspect", detail: "\(bundleId) query=\(query)")
        return result
    }
}

// MARK: - hook.apply：配置化 Hook (ConfigHook）

final class HookApplyTool: MCPTool {
    let definition = ToolDefinition(
        name: "hook.apply",
        summary: "Apply UI customization hook (change navbar color, show startup alert, log methods). Use for: customize app UI, add startup popup, log specific method calls. Don't use for: memory modification (use memory). Example: user says 'change 小红书 navbar to red' → apply hook config.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "config": "JSON config: navbar color, tint color, startup alert, method log rules",
            "restart": "Restart app after applying (default true)"
        ], verified: true, category: "injection")

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        var config: [String: Any] = [:]
        if let cfg = params["config"] as? String, !cfg.isEmpty {
            guard let data = cfg.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPError.invalidParams("config is not valid JSON")
            }
            config = obj
        } else if let dict = params["config"] as? [String: Any] {
            config = dict
        }
        guard !config.isEmpty else {
            throw MCPError.invalidParams("config cannot be empty")
        }
        guard ProcessHelper.writeWorkspaceConfig("hook_config.json", dict: config) else {
            return ["error": "failed to write hook_config.json (workspace permission)"]
        }
        let injected = ((InjectionManager.shared.inspect(bundleId)["injected"] as? Bool) ?? false)
        if !injected {
            let dylib = ProcessHelper.tweakPath("ConfigHook.dylib") ?? ""
            guard !dylib.isEmpty else { return ["error": "built-in ConfigHook.dylib does not exist"] }
            let r = try InjectionManager.shared.enable(bundleId: bundleId, dylibSourcePath: dylib)
            if (r["status"] as? String) != "injected" {
                return ["error": "ConfigHook injection failed", "detail": r]
            }
        }
        let restart = (params["restart"] as? Bool) ?? true
        var relaunchNote = ""
        if restart {
            let exe = ProcessHelper.executableName(for: app)
            _ = InjectionManager.shared.runAsRoot("killall", args: ["killall", "-9", exe])
            _ = ProcessHelper.launchApp(bundleId: bundleId)
            relaunchNote = "已重启 App 使配置生效"
        } else {
            relaunchNote = "未重启；下次 App 启动时配置生效"
        }
        AuditLog.shared.log("hook.apply", detail: "\(bundleId) keys=\(config.keys)")
        return [
            "status": "applied",
            "bundle_id": bundleId,
            "app": app.name,
            "config_path": "/var/mobile/Documents/wiki.qaq.xosvi/Workspace/hook_config.json",
            "config": config,
            "injected": true,
            "note": relaunchNote + "; restart App after changing config (no re-injection needed)"
        ]
    }
}

/// 查看 App entitlements (ldid -e 解析）
final class AppEntitlementsTool: MCPTool {
    let definition = ToolDefinition(
        name: "app.entitlements",
        summary: "Check an app's code signing entitlements (cs_debug, task_for_pid, etc). Use for: check if app can be debugged, see if it has special permissions. Don't use for: check if encrypted (use app.encrypt_info), list dependencies (use app.deps). Example: user says 'can 小红书 be debugged' → check entitlements.",
        parameters: ["bundle_id": "Target App bundle ID (e.g. com.xingin.discover)"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        // v2.9.116：先查加密——加密二进制解不出 entitlements，不能当"没有"
        var cryptID: UInt32 = 0
        if let mo = MachOAnalyzer.analyze(main) { cryptID = mo.cryptID }

        // v6.9.5：静态解析为主路径。
        // entitlements 就在二进制 LC_CODE_SIGNATURE 里，根本不需要提权也不需要 ldid 进程。
        // 旧实现无条件先跑 ldid -e（runAsRoot），在 rootless/rootHide 环境下 syscall 被拦，
        // 每次 4ms 返回 85 (ENOSYS) —— 既慢又刷满审计日志，且一旦连续失败还会触发
        // 调用循环熔断（"已连续 N 次用相同参数调用"）。
        var dict: [String: Any] = [:]
        var source = "machokit"
        var parseError = ""
        var ldidDiag: [String: Any]? = nil

        if let staticEnts = Self.entitlementsViaMachO(path: main) {
            let inner = staticEnts["entitlements"] as? [String: Any] ?? [:]
            dict = inner
            if inner.isEmpty, let d = staticEnts["diagnosis"] { parseError = (d as? [String])?.first ?? "" }
        } else {
            // 静态解析失败（非 Mach-O / 截断文件）→ 才回退 ldid
            source = "ldid"
            let (rc, raw) = InjectionManager.shared.runAsRootData("ldid", args: ["-e", main])
            if rc == 0,
               let d = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any] {
                dict = d
            } else {
                parseError = Self.describeLdidFailure(rc, cryptID: cryptID)
                ldidDiag = [
                    "exit_code": Int(rc),
                    "errno_name": Self.errnoName(rc),
                    "classified": Self.classifyLdidErrno(rc),
                ]
            }
        }

        var out: [String: Any] = [
            "bundle_id": bundleId,
            "binary": main,
            "source": source,
            "entitlements": dict,
            "keychain_groups": dict["keychain-access-groups"] ?? [],
            "platform_app": dict["platform-application"] as? Bool ?? false,
            "no_sandbox": dict["com.apple.private.security.no-sandbox"] as? Bool ?? false,
            "task_for_pid": dict["task_for_pid-allow"] as? Bool ?? false,
            "get_task_allow": dict["get-task-allow"] as? Bool ?? false,
            "parse_error": parseError,
            "hint": parseError.isEmpty
                ? "keychain_groups can be passed to device.keychain_wipe to precisely clear the target App keychain"
                : parseError + " (empty value does not mean no permission)"
        ]
        if let d = ldidDiag { out["ldid"] = d }
        return out
    }

    // MARK: - 静态解析（MachOKit）

    /// 直接读二进制 LC_CODE_SIGNATURE 里的 entitlements blob，不 spawn 任何进程。
    /// 返回 nil 表示"这不是一个能解析的 Mach-O"（此时才值得退回 ldid）。
    static func entitlementsViaMachO(path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        // 复用 macho 工具的加载器：已处理 thin/fat、.app 目录、错误文案
        guard let file = try? MachoExecTool.openMachO(path: path) else { return nil }
        return Self.extractEntitlements(file)
    }

    /// 只取 entitlements 字典（没有则空字典）——调用方不需要关心中间 dict 结构。
    static func entitlementsDict(path: String) -> [String: Any] {
        guard let r = entitlementsViaMachO(path: path) else { return [:] }
        return r["entitlements"] as? [String: Any] ?? [:]
    }

    /// 把 entitlements 字典渲染成可读 JSON（空字典返回空串）。
    static func entitlementsJSON(_ dict: [String: Any], limit: Int) -> String {
        guard !dict.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return String(str.prefix(limit))
    }

    private static func extractEntitlements(_ file: MachOFile) -> [String: Any] {
        guard let cs = file.codeSign else {
            return [
                "entitlements": [:] as [String: Any],
                "diagnosis": ["[缺失] 二进制没有 LC_CODE_SIGNATURE（未签名或签名被剥离），不是“没有权限”"],
            ]
        }
        let ents = cs.embeddedEntitlements ?? [:]
        var out: [String: Any] = ["entitlements": ents, "count": ents.count]
        if ents.isEmpty {
            out["diagnosis"] = ["[空] 有签名但没有 entitlements blob（ad-hoc 签名或权限被剥离），不是“没有权限”"]
        }
        return out
    }

    // MARK: - ldid 兜底错误归因

    /// 把 runAsRoot 的退出码翻译成人话。iOS 上 spawn 失败常见 return = 128+signal
    /// 或直接透传 errno（85=ENOSYS 是 rootLESS/rootHide 环境的典型值）。
    static func errnoName(_ code: Int32) -> String {
        switch code {
        case 1: return "EPERM"
        case 2: return "ENOENT"
        case 13: return "EACCES"
        case 22: return "EINVAL"
        case 78: return "ENOSYS"
        case 85: return "ENOSYS"
        case 126: return "ENOEXEC"
        case 127: return "ENOENT(找不到 ldid 可执行文件)"
        default: return ""
        }
    }

    static func classifyLdidErrno(_ code: Int32) -> String {
        switch code {
        case 85, 78: return "环境不支持：persona/root spawn 被内核拒绝（rootless/rootHide）。读 entitlements 不需要提权，应走静态解析"
        case 127, 2: return "ldid 二进制不存在或路径错误（检查 Resources/bin/ldid 是否随包分发）"
        case 126: return "ldid 不是可执行文件或架构不匹配（arm64 vs arm64e）"
        case 1, 13: return "权限不足：ldid 需要 root，当前 App 无 platform-application/no-sandbox"
        default: return "未归类，需查看 ldid 原始 stderr"
        }
    }

    static func describeLdidFailure(_ rc: Int32, cryptID: UInt32) -> String {
        if cryptID > 0 {
            return "加密 App (cryptid=\(cryptID))，entitlements 需先砸壳（app.decrypt）"
        }
        let name = errnoName(rc)
        if !name.isEmpty {
            return "ldid -e failed (\(rc) \(name))：\(classifyLdidErrno(rc))"
        }
        return "ldid 输出非 plist，解析失败 (exit=\(rc))"
    }
}

/// 清理指定 App 钥匙串条目 (按 entitlements 的 keychain-access-groups 精确删除）
final class KeychainWipeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.keychain_wipe",
        summary: "Wipe an app's keychain (login tokens/passwords). Use for: reset app login state, force re-login. Don't use for: clear app cache (use `app` command:cache_clear), uninstall app (use app.uninstall). Warning: this will log the user out! Example: user says 'log out of 小红书' → wipe keychain.",
        parameters: ["bundle_id": "Target App bundle_id (required). e.g. com.xingin.discover"]
    )
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        let main = InjectionManager.shared.executablePath(app)
        // v6.9.5：与 app.entitlements 同源——直接读签名 blob，不再 spawn ldid
        // （rootHide 环境下 ldid 恒返回 85，旧实现会静默退回默认组，删不到目标 App 条目）
        var groups: [String] = []
        var entSource = "machokit"
        if let staticEnts = AppEntitlementsTool.entitlementsViaMachO(path: main),
           let gs = (staticEnts["entitlements"] as? [String: Any])?["keychain-access-groups"] as? [String] {
            groups = gs
        } else {
            entSource = "ldid"
            let (rc2, raw2) = InjectionManager.shared.runAsRootData("ldid", args: ["-e", main])
            if rc2 == 0,
               let d2 = try? PropertyListSerialization.propertyList(from: raw2, options: [], format: nil) as? [String: Any],
               let gs2 = d2["keychain-access-groups"] as? [String] {
                groups = gs2
            }
        }
        if groups.isEmpty { groups = ["TROLLTROLL.com.xosvi.app"] }
        var deleted = 0
        var failed = 0
        var errors: [String] = []
        // v2.9.96：优先 root 直改 keychain-2.db (sqlite_wipe 内置工具），
        // 不受跨组 entitlements 限制，精确删除目标 App 全部钥匙串条目。
        let im = InjectionManager.shared
        let (rc, rout) = im.runAsRoot("sqlite_wipe", args: ["sqlite_wipe"] + groups)
        if rc == 0 {
            let tokens = rout.split(separator: " ")
            let wiped = (tokens.count >= 3 ? Int(tokens[1]) : nil) ?? 0
            return [
                "bundle_id": bundleId,
                "method": "sqlite_wipe(root keychain-2.db)",
                "entitlements_source": entSource,
                "groups_tried": groups,
                "deleted_count": wiped,
                "output": rout.trimmingCharacters(in: .whitespacesAndNewlines),
                "hint": "deleted target App entries from system keychain database by keychain-access-groups (login state will reset). If App is still running, kill and restart it"
            ]
        }
        errors.append("sqlite_wipe: \(rc) \(rout)")
        // fallback：SecItemDelete (受本 App entitlements 限制，尽量删自己组）
        for g in groups {
            for cls in [kSecClassGenericPassword, kSecClassInternetPassword, kSecClassKey] {
                let q: [String: Any] = [
                    kSecClass as String: cls,
                    kSecAttrAccessGroup as String: g,
                    kSecMatchLimit as String: kSecMatchLimitAll
                ]
                let st = SecItemDelete(q as CFDictionary)
                if st == errSecSuccess { deleted += 1 }
                else if st != errSecItemNotFound {
                    failed += 1
                    errors.append("\(g): \(st)")
                }
            }
        }
        return [
            "bundle_id": bundleId,
            "groups_tried": groups,
            "deleted_count": deleted,
            "failed_count": failed,
            "errors": errors,
            "hint": failed > 0
                ? "部分条目需要系统级 keychain 权限 (本 App 未声明该组)。"
                : "已清理目标 App 钥匙串条目 (登录态将被重置)"
        ]
    }
}

// v2.9.312：device.keychain_reset 已删除——清空整机钥匙串太危险，
// 会导致所有 App 密码/登录态丢失。保留 device.keychain_wipe (按指定 App 清理）。

/// 刷新 (重置）指定 App 数据容器——数据保留在备份目录，可 restore 恢复
final class RefreshContainerTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.refresh_container",
        summary: "Reset app data container (rename old one to backup, system creates fresh empty one). Use for: factory reset app data but can restore later. Don't use for: wipe keychain only (use device.keychain_wipe), uninstall app (use app.uninstall). Warning: this clears all app data! Example: user says 'reset 小红书 to factory state' → refresh container.",
        parameters: [
            "bundle_id": "Target App bundle_id (required)",
            "restore": "If true, restore from previous backup instead of resetting"
        ], verified: true)
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let bundleId = params["bundle_id"] as? String, !bundleId.isEmpty else {
            throw MCPError.invalidParams("bundle_id required")
        }
        guard let app = AppCatalog.find(bundleId) else {
            return ["error": "app not found: \(bundleId)"]
        }
        guard let container = AppCatalog.lookupContainer(bundleId: app.bundleId), !container.isEmpty else {
            return ["error": "cannot locate data container", "hint": "LSApplicationProxy returned no dataContainerURL (may lack AppDataContainers entitlement)"]
        }
        let restore = (params["restore"] as? Bool) ?? false
        let bk = container + ".xosvi.bak"
        let im = InjectionManager.shared
        if restore {
            if !FileManager.default.fileExists(atPath: bk) {
                return ["error": "no backup directory found", "backup": bk]
            }
            _ = im.runAsRoot("rm", args: ["-rf", container])
            let (c, o) = im.runAsRoot("mv", args: [bk, container])
            if c != 0 { return ["error": "restore failed (\(c)): \(o)"] }
            _ = im.runAsRoot("chown", args: ["33:33", container])
            let exe = ProcessHelper.executableName(for: app)
            _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
            return ["status": "restored", "container": container, "hint": "container restored from backup and process killed, App data back to pre-reset state"]
        }
        if FileManager.default.fileExists(atPath: bk) {
            _ = im.runAsRoot("rm", args: ["-rf", bk])
        }
        let (c, o) = im.runAsRoot("mv", args: [container, bk])
        if c != 0 { return ["error": "reset failed (\(c)): \(o)"] }
        _ = im.runAsRoot("chown", args: ["33:33", bk])
        let exe = ProcessHelper.executableName(for: app)
        _ = im.runAsRoot("killall", args: ["killall", "-9", exe])
        return [
            "status": "refreshed",
            "container": container,
            "backup": bk,
            "hint": "container renamed as backup (data kept). System rebuilds an empty container on next App launch. To restore: call again with restore=true"
        ]
    }
}

// MARK: - HTTP 辅助 (localhost）

private func httpGet(port: Int, path: String, timeout: TimeInterval = 4) -> (Int, String)? {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    setTimeoutInterval(timeout, on: &request)
    var result: (Int, String)? = nil
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let data = data, let http = response as? HTTPURLResponse {
            result = (http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 1)
    return result
}

