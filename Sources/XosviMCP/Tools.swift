import Foundation
import UIKit

// MARK: - 已内联进大工具的历史独立工具（保留类供引用/兼容）：
//   artifact.* → ArtifactExecTool（read/write/list 内联，见 v4.0.0）
//   device.* → DeviceExecTool（委托调用 DeviceInfoTool/DeviceProbeTool 等）

final class DeviceInfoTool: MCPTool {
    let definition = ToolDefinition(name: "device.info", summary: "Get device info: iOS version, iPhone model, memory/storage, battery, Xosvi version, workspace path. Use for: check what iOS version, know device specs, find workspace path. Don't use for: wipe keychain (use device.keychain_wipe). Example: user says 'what model is my phone' → get device info.", verified: true, category: "device", annotations: .readOnlyLocal, cache: ToolCachePolicy.short)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        [
            "system": UIDevice.current.systemName,
            "systemVersion": UIDevice.current.systemVersion,
            "model": UIDevice.current.model,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-",
            "workspace": Workspace.root.path,
            // v8（R①/R③/R⑯）：探测驱动的执行档位（container-ok / jb-only / locked）
            "execution_strategy": ExecutionStrategy.report(),
        ]
    }
}

final class DeviceProbeTool: MCPTool {
    let definition = ToolDefinition(
        name: "device.probe",
        summary: "Probe/check device environment: TrollStore installed, can we inject, what permissions available. Use for: check if device supports injection, see what capabilities are available. Don't use for: get device specs (use device.info), check battery/memory (use device.snapshot). Example: user says 'can my phone inject, how is the environment' → probe device.",
        verified: true, category: "device", annotations: .readOnlyLocal, cache: ToolCachePolicy.short)

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let r = DeviceProbe.shared.run()
        // v2.9.125：CLI 式一句话结论 (dispatch 取 message 放顶层）
        let failedChecks = r.checks.filter { !$0.passed }
        let message: String
        if r.ready {
            message = "environment ready (TrollStore OK, permissions OK, toolchain OK)"
        } else {
            let labels = failedChecks.prefix(3).map { $0.label }.joined(separator: "、")
            message = "environment not ready: \(labels.isEmpty ? "unknown reason" : labels)"
        }
        return [
            "message": message,
            "device": [
                "name": r.deviceName,
                "model": r.model,
                "systemVersion": r.systemVersion,
                "vendorID": r.vendorID,
            ],
            "trollStore": r.trollStore,
            "jailbreakEnv": r.jailbreakEnv,
            // v8（R①）：spawn 四类探针 + 档位
            "execution_strategy": ExecutionStrategy.report(),
            "jailbreakRoot": r.jailbreakRoot,
            "trollFools": r.trollFools,
            "task_for_pid": r.taskForPid,
            "appContainerWrite": r.containerWrite,
            "injectionBinaries": r.injectionBinaries,
            "amfidBypassInferred": r.amfidBypassInferred,
            "entitlementsOK": r.entitlementsOK,
            "rootDiagnosis": r.rootDiagnosis ?? [:],
            "ready": r.ready,
            "issues": failedChecks.map { $0.label },
            "checks": r.checks.map { ["label": $0.label, "passed": $0.passed, "detail": $0.detail] },
        ]
    }
}

// MARK: - MemoryTweak：VansonMod 原生引擎 + 向后兼容的 dylib HTTP 回退

final class MemoryTweakTool: MCPTool {
    let definition = ToolDefinition(
        name: "memory",
        summary: "Game memory modification (GameGuardian/H5GG style). Two backends: (A) native — built-in VansonMod engine, works out of the box, attach by pid or bundle_id, supports exact/fuzzy scan, refine, filter, read/write, freeze; (B) legacy — HTTP proxy to MemoryTweak.dylib injected into target app. Params: action, target, bundle_id, pid, value, value2, type, address, offset, limit, mode. Native is default; set backend:legacy to force dylib mode.",
        parameters: [
            "action": "selfcheck (verify engine linked, no attach needed) / attach (bind target process) / search (first exact scan) / fuzzy (first fuzzy scan) / refine (filter current results by new value) / filter (filter by condition) / results (page through results) / read (read memory at address) / write (set value) / read_raw (hex dump) / write_raw (hex write) / freeze (lock value) / unfreeze / frozen / status / clear / undo",
            "backend": "native (default, built-in VansonMod engine) / legacy (HTTP → MemoryTweak.dylib on 127.0.0.1:8765)",
            "target": "Process name or bundle id to attach (e.g. com.example.game). Same as bundle_id when it contains a dot.",
            "bundle_id": "Bundle id of target app (attach)",
            "pid": "PID of target process (attach; alternative to bundle_id)",
            "value": "Value to search / write / freeze (search, refine, write, freeze)",
            "value2": "Second value for between / range mode",
            "type": "Data type: int(int32, default) / int64 / int16 / int8 / uint32 / float / double / string / byte / short",
            "address": "Memory address (0x hex, required for read/write/read_raw/write_raw/freeze/unfreeze)",
            "offset": "Results paging offset (results), default 0",
            "limit": "Max results to return (results) or max scan results kept (search), default 50 / 2000",
            "mode": "Fuzzy/filter mode: greater / less / between / increased / decreased / changed / unchanged"
        ],
        prerequisites: [
            "native 后端：目标 App 需运行中；需 task_for_pid-allow entitlement（Xosvi 已内置）；越狱环境下目标若带加固/AMFI 保护可能拿不到 task port",
            "legacy 后端：目标游戏已注入 MemoryTweak.dylib 且 127.0.0.1:8765 可达",
            "search/fuzzy 是首扫，结果可能上万条；先 results 看几条，再用 refine 缩小，最后 write"
        ]
    , annotations: .destructiveSystem, cache: ToolCachePolicy.none)

    private let port = 8765

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let action = params["action"] as? String else {
            throw MCPError.invalidParams("action required")
        }
        let backend = (params["backend"] as? String ?? "native").lowercased()

        // 旧的 dylib 后端保持原样（用户显式指定 legacy 时走这里）
        if backend == "legacy" {
            // v8（R⑧）：iOS 17.1 + Relaxin 上，legacy 依赖把 MemoryTweak.dylib 注入目标进程；
            // 注入在 rootHide 下只能走静态重打包，成本高且常失败 → 直接引导用原生直连引擎。
            if ExecutionStrategy.preferJBToolchain || !ExecutionStrategy.memoryInjectionUsable {
                throw MCPError.classified(
                    "legacy 后端不可用：当前档位 \(ExecutionStrategy.tier().rawValue) 不支持 dylib 注入式内存后端",
                    code: "ENV_PERMISSION",
                    reason: "iOS 17.1+Relaxin：MemoryTweak 需静态注入目标 App，rootHide 下不可行",
                    nextStep: "移除 backend:legacy，使用默认 native 引擎（进程内 VansonMod，attach 用 pid/bundle_id）")
            }
            return try legacyInvoke(action: action, params: params)
        }
        return try nativeInvoke(action: action, params: params)
    }

    // MARK: native（VansonMod 引擎）

    private func nativeInvoke(action: String, params: [String: Any]) throws -> [String: Any] {
        // 引擎阻塞式扫描，不能在主线程跑，否则 UI 卡死
        if Thread.isMainThread {
            var output: [String: Any] = [:]
            var thrown: Error?
            DispatchQueue.global(qos: .userInitiated).sync {
                do { output = try self.nativeInvokeOffMain(action: action, params: params) }
                catch { thrown = error }
            }
            if let e = thrown { throw e }
            return output
        }
        return try nativeInvokeOffMain(action: action, params: params)
    }

    private func nativeInvokeOffMain(action: String, params: [String: Any]) throws -> [String: Any] {
        let bridge = VansonMemoryBridge.shared
        let type = VansonValueType.parse(params["type"] as? String) ?? .int32
        let value = params["value"].map { "\($0)" }
        let value2 = params["value2"].map { "\($0)" }

        func requireAddress() throws -> UInt64 {
            guard let raw = params["address"] as? String ?? (params["address"].map { "\($0)" }),
                  let addr = VansonMemoryBridge.parseAddress(raw) else {
                throw MCPError.invalidParams("address required (0x hex)")
            }
            return addr
        }

        switch action {
        case "attach":
            // 支持 pid 直接指定，或通过 bundle_id / target 找进程
            if let pidNum = params["pid"], let pid = Int32("\(pidNum)") {
                // pid_t == Int32，Swift 侧一致
                let name = try bridge.attach(pid: pid)
                return ["ok": true, "backend": "native", "pid": Int(pid), "process": name, "status": bridge.status]
            }
            guard let bundleRaw = params["bundle_id"] as? String ?? params["target"] as? String else {
                throw MCPError.invalidParams("attach 需要 bundle_id / target / pid 之一")
            }
            let bundle = bundleRaw.trimmingCharacters(in: .whitespaces)
            // findPid(by:)（ProcessTools.swift）已内含 libproc → ps → comm 列三级回退
            let pid = findPid(by: bundle)
            guard pid > 0 else {
                throw MCPError.invalidParams("找不到运行中的进程: \(bundle)（确认 App 已启动；用 app 工具查 bundle_id）")
            }
            let name = try bridge.attach(pid: pid)
            return ["ok": true, "backend": "native", "pid": Int(pid), "process": name, "status": bridge.status]

        case "status", "frozen":
            var out = bridge.status
            out["ok"] = true
            out["backend"] = "native"
            return out

        case "selfcheck":
            // 确认 VansonMod 引擎已链入并可用；不需要 attach 任何进程
            var out = bridge.selfCheck
            out["ok"] = true
            out["backend"] = "native"
            out["note"] = "engine_class 应为 VMMemoryEngine；singleton_ok 应为 true。若此动作报 unknown action 或崩溃，说明静态库没链进来。"
            return out

        case "search":
            guard let v = value else { throw MCPError.invalidParams("value required for search") }
            let limit = Int("\(params["limit"] ?? 2000)") ?? 2000
            let r = try bridge.searchExact(value: v, type: type, limit: limit)
            return ["ok": true, "backend": "native", "count": r.count,
                    "message": r.message, "type": type.rawValue,
                    "hint": r.count > 0 ? "用 results 查看前几条，再用 refine 逐步缩小" : "换 type 或模糊搜索试试"]

        case "fuzzy":
            guard let v = value else { throw MCPError.invalidParams("value required for fuzzy") }
            let mode = (params["mode"] as? String) ?? "changed"
            let r = try bridge.searchFuzzy(mode: mode, value: v, value2: value2, type: type)
            return ["ok": true, "backend": "native", "count": r.count,
                    "message": r.message, "mode": mode]

        case "refine":
            guard let v = value else { throw MCPError.invalidParams("value required for refine") }
            let r = try bridge.refine(value: v, type: type)
            return ["ok": true, "backend": "native", "count": r.count, "message": r.message]

        case "filter":
            guard let v = value else { throw MCPError.invalidParams("value required for filter") }
            let mode = (params["mode"] as? String) ?? "changed"
            let r = try bridge.filter(mode: mode, value1: v, value2: value2, type: type)
            return ["ok": true, "backend": "native", "count": r.count, "message": r.message]

        case "results":
            let offset = Int("\(params["offset"] ?? 0)") ?? 0
            let limit = Int("\(params["limit"] ?? 50)") ?? 50
            let items = try bridge.results(offset: offset, limit: limit, type: type)
            return ["ok": true, "backend": "native", "total": bridge.resultCount,
                    "offset": offset, "returned": items.count, "results": items]

        case "read":
            let addr = try requireAddress()
            let len = Int("\(params["limit"] ?? 64)") ?? 64
            let v = try bridge.read(address: addr, type: type, length: len)
            return ["ok": true, "backend": "native",
                    "address": String(format: "0x%llx", addr), "value": v, "type": type.rawValue]

        case "write":
            guard let v = value else { throw MCPError.invalidParams("value required for write") }
            let addr = try requireAddress()
            let ok = try bridge.write(address: addr, value: v, type: type)
            return ["ok": ok, "backend": "native", "address": String(format: "0x%llx", addr),
                    "value": v, "type": type.rawValue,
                    "error": ok ? nil : "写入失败：地址不可写或越界"].compactMapValues { $0 }

        case "read_raw":
            let addr = try requireAddress()
            let len = Int("\(params["limit"] ?? 64)") ?? 64
            let hex = try bridge.readRaw(address: addr, length: len)
            return ["ok": true, "backend": "native",
                    "address": String(format: "0x%llx", addr), "length": len, "hex": hex]

        case "write_raw":
            guard let hex = params["value"] as? String ?? value else {
                throw MCPError.invalidParams("value required (hex string) for write_raw")
            }
            let addr = try requireAddress()
            let ok = try bridge.writeRaw(address: addr, hex: hex)
            return ["ok": ok, "backend": "native", "address": String(format: "0x%llx", addr)]

        case "clear":
            try bridge.clearResults()
            return ["ok": true, "backend": "native", "count": 0]

        case "undo":
            let n = bridge.undoLastWrite()
            return ["ok": true, "backend": "native", "restored": n]

        case "freeze", "unfreeze":
            // 冻结走原生引擎 + 定时回写引擎（VMLockEngine）
            throw MCPError.invalidParams("native 后端的 freeze 请用 legacy 方案或等待 v6.7.x 接入 VMLockEngine（当前原生后端支持 search/refine/write/read）")

        default:
            throw MCPError.invalidParams("unknown action: \(action)")
        }
    }

    // MARK: legacy（注入的 MemoryTweak.dylib，127.0.0.1:8765）

    private func legacyInvoke(action: String, params: [String: Any]) throws -> [String: Any] {
        let method: String
        let path: String
        var body: [String: Any] = [:]

        switch action {
        // v3.1.69: attach —— 指引里反复提 "memory attach"，但此前无此动作 (AI 反馈属实）。
        // MemoryTweak.dylib 被注入目标进程后 HTTP 服务即已 attach (无独立 attach 端点），
        // attach 动作等价确认服务在线/进程已注入，转发 /status。
        case "attach":
            method = "GET"; path = "/status"
        case "search":
            guard let value = params["value"] else { throw MCPError.invalidParams("value required for search") }
            method = "POST"; path = "/search"
            body = ["value": value, "type": params["type"] as? String ?? "int"]
        case "refine":
            guard let value = params["value"] else { throw MCPError.invalidParams("value required for refine") }
            method = "POST"; path = "/refine"
            body = ["value": value, "type": params["type"] as? String ?? "int"]
        case "write":
            guard let value = params["value"], let addr = params["address"] as? String else {
                throw MCPError.invalidParams("value and address required for write")
            }
            method = "POST"; path = "/write"
            body = ["value": value, "address": addr, "type": params["type"] as? String ?? "int"]
        case "freeze":
            guard let value = params["value"], let addr = params["address"] as? String else {
                throw MCPError.invalidParams("value and address required for freeze")
            }
            method = "POST"; path = "/freeze"
            body = ["value": value, "address": addr, "type": params["type"] as? String ?? "int"]
        case "unfreeze":
            guard let addr = params["address"] as? String else { throw MCPError.invalidParams("address required for unfreeze") }
            method = "POST"; path = "/unfreeze"
            body = ["address": addr]
        case "status":
            method = "GET"; path = "/status"
        case "frozen":
            method = "GET"; path = "/frozen"
        case "results":
            method = "GET"; path = "/results"
        default:
            throw MCPError.invalidParams("unknown action: \(action)")
        }

        return try httpRequest(method: method, path: path, body: body)
    }

    private func httpRequest(method: String, path: String, body: [String: Any]) throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
        var request = URLRequest(url: url)
        setHTTPMethod(method, on: &request)
        setTimeoutInterval(30, on: &request)

        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 35)

        if let error = resultError {
            return ["error": "failed to connect MemoryTweak (\(error.localizedDescription). Confirm MemoryTweak.dylib injected into target App and target App is running.", "connected": false]
        }
        guard let data = resultData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": "failed to parse response", "connected": false]
        }
        return json
    }
}



// MARK: - v3.1.39: artifact 大工具 + 子命令 (合并 3 个 artifact.* 工具）

final class ArtifactExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "artifact",
        summary: "Manage workspace files. Subcommands: read / write / list / output_name_get / output_name_set / output_bookmark. Params: filename (read/write), text (write), name (output_name_set). App container files use container.*, system files use shell.exec.",
        parameters: [
            "command": "Subcommand (required): read / write / list / output_name_get / output_name_set / output_bookmark",
            "filename": "File name — REQUIRED for read/write",
            "text": "Text to write — REQUIRED for write",
            "name": "Output name — REQUIRED for output_name_set"
        ],
        verified: true, category: "fs")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("artifact", detail: command)
        
        switch command {
        case "read":
            guard let filename = params["filename"] as? String else {
                throw MCPError.invalidParams("filename required. Usage: artifact read filename:report.txt")
            }
            // v4.0.0: 内联自 ArtifactReadTextTool（修复原委托调用传参 key 不一致的隐藏 bug）
            let url = try Workspace.resolve(filename)
            let text = try String(contentsOf: url, encoding: .utf8)
            return ["content": text]
            
        case "write":
            guard let filename = params["filename"] as? String else {
                throw MCPError.invalidParams("filename required. Usage: artifact write filename:notes.txt text:<content>")
            }
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: artifact write filename:notes.txt text:<content>")
            }
            // v4.0.0: 内联自 ArtifactWriteTextTool（修复委托传参 key 不一致的隐藏 bug）
            let url = try Workspace.resolve(filename)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ["written": true, "bytes": text.utf8.count]
            
        case "list":
            // v4.0.0: 内联自 ArtifactListTool（subpath 可选；文件返回单条，目录返回前 50 条）
            let sub = params["subpath"] as? String ?? ""
            let dir = try Workspace.resolve(sub)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
                return ["entries": [], "error": "path does not exist: \(sub)"]
            }
            if !isDir.boolValue {
                let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return ["entries": [
                    ["name": dir.lastPathComponent,
                     "path": dir.path,
                     "isDirectory": false,
                     "size": size,
                     "hint": "this is a file not a directory; to read it use artifact read (text) or shell.exec for the raw file"]
                ]]
            }
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let entries = items.map { name -> [String: Any] in
                var isD: ObjCBool = false
                let p = (dir.path as NSString).appendingPathComponent(name)
                _ = FileManager.default.fileExists(atPath: p, isDirectory: &isD)
                return ["name": name, "path": p, "isDirectory": isD.boolValue]
            }
            let limited = Array(entries.prefix(50))
            return ["entries": limited, "total": entries.count, "truncated": entries.count > 50, "hint": entries.count > 50 ? "directory has \(entries.count) items, only first 50 returned; use shell.exec find for precise search" : ""]

        case "output_name_get":
            // v4.0.0: 内联自 WorkspaceOutputNameTool
            return ["name": UserDefaults.standard.string(forKey: "xosvi.output_name") ?? "artifact"]

        case "output_name_set":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required. Usage: artifact output_name_set name:<output name>")
            }
            // v4.0.0: 内联自 WorkspaceOutputNameTool
            UserDefaults.standard.set(name, forKey: "xosvi.output_name")
            return ["set": name]

        case "output_bookmark":
            // v4.0.0: 内联自 WorkspaceOutputBookmarkTool（返回当前输出书签路径，默认工作区根）
            let key = "xosvi.output_bookmark"
            return ["bookmark": UserDefaults.standard.string(forKey: key) ?? "/var/mobile/Documents/wiki.qaq.xosvi/Workspace"]

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: read/write/list/output_name_get/output_name_set/output_bookmark")
        }
    }
}

// MARK: - v3.1.40: device 大工具 + 子命令 (合并 4 个 device.* 工具）

final class DeviceExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "device",
        summary: "Device info & snapshot. Subcommands: info / probe / snapshot. info=specs, probe=environment/capabilities, snapshot=health. App management use app.*.",
        parameters: [
            "command": "Subcommand: info / probe / snapshot"
        ],
        verified: true, category: "device",
        paramSpecs: [.e("command", "子命令", values: ["info", "probe", "snapshot"], required: true)],
        variants: [
            ToolVariant("info", requires: [], accepts: [], annotations: .readOnlyLocal),
            ToolVariant("probe", requires: [], accepts: [], annotations: .readOnlyLocal),
            ToolVariant("snapshot", requires: [], accepts: [], annotations: .readOnlyLocal),
        ],
        annotations: .readOnlyLocal,
        cache: ToolCachePolicy.none)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("device", detail: command)
        
        switch command {
        case "info":
            return try DeviceInfoTool().invoke([:])
            
        case "probe":
            return try DeviceProbeTool().invoke([:])
            
        case "snapshot":
            return try DeviceSnapshotTool().invoke([:])

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: info/probe/snapshot")
        }
    }
}

// MARK: - v3.1.41: container 大工具 + 子命令 (合并 3 个 container.* 工具）

final class ContainerExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "container",
        summary: "Manage app data container: read/write/delete files inside an installed app sandbox, resolve bundle_id to install+data paths. Subcommands: refresh / resolve / write / delete. Params: bundle_id (resolve/write/delete), path (write/delete), text (write). Workspace files use artifact.*, system files use shell.exec.",
        parameters: [
            "command": "Subcommand (required): refresh / resolve / write / delete",
            "bundle_id": "App bundle ID — REQUIRED for resolve/write/delete",
            "path": "File path — REQUIRED for write/delete",
            "text": "Text to write — REQUIRED for write"
        ],
        verified: true, category: "fs", prerequisites: ["resolve/write/delete 的 bundle_id 必须对应已安装 App (先 app status 确认)", "refresh has no prerequisite, callable anytime"])
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("container", detail: command)
        
        switch command {
        case "refresh":
            return try RefreshContainerTool().invoke([:])
            
        case "write":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required. Usage: container write bundle_id:com.xxx path:Documents/a.txt text:<content>")
            }
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required. Usage: container write bundle_id:com.xxx path:Documents/a.txt text:<content>")
            }
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required. Usage: container write bundle_id:com.xxx path:Documents/a.txt text:<content>")
            }
            return try ContainerWriteTextTool().invoke(["bundle_id": bundleId, "path": path, "text": text])
            
        case "delete":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required. Usage: container delete bundle_id:com.xxx path:Documents/a.txt")
            }
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required. Usage: container delete bundle_id:com.xxx path:Documents/a.txt")
            }
            return try ContainerDeleteTool().invoke(["bundle_id": bundleId, "path": path])
            
        // v3.1.68: container resolve —— bundle_id → 安装目录 + 数据容器 + 沙盒路径
        // 此前 AI 为了找某 App 的数据目录要 loop 几百个目录跑 plutil (又慢又易崩），
        // 一条 resolve 直接给出全部路径 (D items修复，2026-09-23 实测确认缺失）
        case "resolve":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required. Usage: container resolve bundle_id:com.xxx")
            }
            return try ContainerResolveTool().invoke(["bundle_id": bundleId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: refresh/resolve/write/delete")
        }
    }
}

// MARK: - v3.1.42: diagnose 大工具 + 子命令 (合并 2 个 diagnose.* 工具）

final class DiagnoseExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "diagnose",
        summary: "Diagnose app/injection/environment issues. Subcommands: startup (app won't launch) / injection (inject failure) / spawn (bundled binaries fail with Bad executable) / toolchain (bundled tools signature self-check and self-sign) / lasttool (which tool ran before the last crash) / rootchain (full root privilege chain - spawnRoot/persona/setuid/entitlements, for iOS 17+ ENOSYS/85 failures). Use for: diagnose why app won't launch, why injection failed, why root operations fail. Don't use for: fix issues (use inject.*), restart app (use app restart). Example: startup → diagnose startup bundle_id:com.xxx; injection → diagnose injection bundle_id:com.xxx; rootchain → diagnose rootchain (no params).",
        parameters: [
            "command": "Subcommand: startup / injection / spawn / toolchain / lasttool / rootchain / tools",
            "repair": "toolchain only: true = try re-signing bundled binaries with the bundled ldid",
            "bundle_id": "App bundle ID (required for startup/injection; ignore for rootchain)"
        ],
        verified: true, category: "diagnose", prerequisites: ["App 已安装且 bundle_id 有效 (先 app status 确认，rootchain 不需要)", "startup 诊断依赖 App 曾启动过 (有崩溃日志才有意义)"])
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("diagnose", detail: command)
        
        switch command {
        case "startup":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try DiagnoseStartupTool().invoke(["bundle_id": bundleId])
            
        case "injection":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try InjectionDiagnoseTool().invoke(["bundle_id": bundleId])
        
        case "spawn":
            // v6.6.13：内置二进制（python3/r2/bsdtar…）为什么起不来。
            // 全部在进程内完成——即使所有 spawn 都失败，这个诊断仍能跑。
            return SpawnDiag.run()

        case "lasttool":
            // v7.9.7：上一次工具调用（闪退排查用）——phase=start 说明那条没跑完
            var out: [String: Any] = ["ok": true]
            if let last = ToolBlackBox.read() {
                out["last"] = last
                out["suspected_crash"] = (last["phase"] as? String) == "start"
            } else {
                out["last"] = NSNull()
                out["hint"] = "还没有记录（黑匣子从这一版开始记）"
            }
            return out

        case "tools":
            // v7.16.9：工具可见性自检——注册了但被 isEnabled 挡掉的工具，AI 是"看不见"的。
            // 现场：root 工具写好了却没加进默认白名单，模型只能拿 diagnose/jb 硬凑，表现为"跑偏"。
            let all = ToolRegistry.shared.allToolNames()
            var off: [String] = []
            for n in all where !ToolRegistry.shared.isEnabled(name: n) { off.append(n) }
            var tmp: [String] = []
            for d in ToolRegistry.shared.definitions where d.remoteOnly { tmp.append(d.name) }
            return [
                "registered": all.count,
                "enabled": all.count - off.count,
                "disabled": off,
                "remote_only": tmp,
                "names": all,
                "hint": off.isEmpty ? "所有已注册工具都可见" : "这些工具注册了但不在默认白名单/被手动关闭 → AI 看不到，别用别的工具硬凑"
            ]

        case "toolchain":
            // v7.7.0：内置工具链自检 + 自签（errno 85 排查）
            let repair = (params["repair"] as? Bool) ?? false
            return ToolchainSigner.run(repair: repair)

        case "engine":
            // v7.16.2：iSH 引擎体检——把"卡住"拆成可判定的几层
            // （rootfs → boot → guest → DNS → TCP）
            return ISH.diagnose()

        case "rootchain":
            // v6.6.7: 完整 root 提权链路诊断 (spawnRoot 85 ENOSYS / persona-mgmt / TSRootBinaries setuid / iOS 17 AMFI)
            let chain = InjectionManager.shared.diagnoseRootChain()
            let severity = chain["severity"] as? String ?? "ok"
            let diagLines = chain["diagnosis"] as? [String] ?? []
            let message = "root chain " + severity + (diagLines.isEmpty ? "" : ": " + diagLines.joined(separator: " | "))
            return [
                "message": message,
                "severity": severity,
                "diagnosis": diagLines,
                "advice": chain["advice"] ?? "",
                "chain": chain
            ]
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: startup/injection/spawn/rootchain/toolchain/engine")
        }
    }
}

// MARK: - v3.1.43: memory 大工具 + 子命令 (合并 3 个 assistant.memory.* 工具）

final class MemoryExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "assistant_memory",
        summary: "Manage assistant memory (set/list/delete). Use subcommand to specify action. Use for: save/list/delete memory notes. Don't use for: game memory modification (use memory action:search). Example: set → assistant_memory set key:user name value:xxx; list → assistant_memory list. Subcommands: set / list / delete.",
        parameters: [
            "command": "Subcommand: set / list / delete",
            "key": "Memory key (for set/delete)",
            "value": "Memory value (for set)"
        ],
        verified: true, category: "knowledge")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("assistant_memory", detail: command)
        
        switch command {
        case "set":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            guard let value = params["value"] as? String else {
                throw MCPError.invalidParams("value required")
            }
            return try AssistantMemorySetTool().invoke(["key": key, "value": value])
            
        case "list":
            return try AssistantMemoryListTool().invoke([:])
            
        case "delete":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            return try AssistantMemoryDeleteTool().invoke(["key": key])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: set/list/delete")
        }
    }
}

// MARK: - v3.1.44: verify 大工具 + 子命令 (合并 2 个 verify.* 工具）

final class VerifyExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "verify",
        summary: "Verify file/app status (file/app_running). Use subcommand to specify action. Use for: verify file exists, check if app is running. Don't use for: read file (use artifact read), launch app (use app launch). Example: file → verify file path:/var/mobile/xxx; app_running → verify app_running bundle_id:com.xxx. Subcommands: file / app_running.",
        parameters: [
            "command": "Subcommand: file / app_running",
            "path": "File path (for file)",
            "bundle_id": "App bundle ID (for app_running)"
        ],
        verified: true, category: "system", prerequisites: ["app_running 前确认 bundle_id 已安装且曾启动过 (app.launch 后验证才有意义)", "path must be a real absolute path before file verification"])
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("verify", detail: command)
        
        switch command {
        case "file":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required")
            }
            return try VerifyFileTool().invoke(["path": path])
            
        case "app_running":
            guard let bundleId = params["bundle_id"] as? String else {
                throw MCPError.invalidParams("bundle_id required")
            }
            return try VerifyAppRunningTool().invoke(["bundle_id": bundleId])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: file/app_running")
        }
    }
}

// MARK: - v3.1.45: ssh 大工具 + 子命令 (合并 2 个 ssh.* 工具）

final class SshExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "ssh",
        summary: "SSH remote connection (exec/scp). Use subcommand to specify action. Use for: run commands on remote server, transfer files. Don't use for: local shell (use shell.exec). Example: exec → ssh exec command:ls -la; scp → ssh scp local:xxx remote:/xxx. Subcommands: exec / scp.",
        parameters: [
            "command": "Subcommand: exec / scp",
            "cmd": "Command to run (for exec)",
            "local": "Local file path (for scp)",
            "remote": "Remote file path (for scp)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("ssh", detail: command)
        
        switch command {
        case "exec":
            guard let cmd = params["cmd"] as? String else {
                throw MCPError.invalidParams("cmd required")
            }
            return try SSHTool().invoke(["command": cmd])
            
        case "scp":
            guard let local = params["local"] as? String else {
                throw MCPError.invalidParams("local required")
            }
            guard let remote = params["remote"] as? String else {
                throw MCPError.invalidParams("remote required")
            }
            return try SCPTool().invoke(["local": local, "remote": remote])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: exec/scp")
        }
    }
}

// MARK: - v3.1.48: macro 大工具 + 子命令 (合并 6 个 macro.* 工具）

final class MacroExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "macro",
        summary: "Manage operation macros (record/stop/run/list/delete/export). Use subcommand to specify action. Use for: record and replay UI operations. Don't use for: one-off UI control (use control.*). Example: record → macro record name:login; run → macro run name:login. Subcommands: record / stop / run / list / delete / export.",
        parameters: [
            "command": "Subcommand: record / stop / run / list / delete / export",
            "name": "Macro name"
        ],
        verified: true, category: "automation")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("macro", detail: command)
        
        switch command {
        case "record":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroRecordTool().invoke(["name": name])
            
        case "stop":
            return try MacroStopTool().invoke([:])
            
        case "run":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroRunTool().invoke(["name": name])
            
        case "list":
            return try MacroListTool().invoke([:])
            
        case "delete":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroDeleteTool().invoke(["name": name])
            
        case "export":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try MacroExportTool().invoke(["name": name])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: record/stop/run/list/delete/export")
        }
    }
}

// MARK: - v3.1.49: model 大工具 + 子命令 (合并 6 个 model.* 工具）

final class ModelExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "model",
        summary: "Manage LLM model (config/update/auth/list/switch). Use subcommand to specify action. Use for: view/switch model config, update auth. Don't use for: chat (use chat.*). Example: list → model list; switch → model switch name:deepseek. Subcommands: config / update / auth / list / switch / selected.",
        parameters: [
            "command": "Subcommand: config / update / auth / list / switch / selected",
            "name": "Model name (for switch)",
            "key": "Auth key (for auth)"
        ],
        verified: true, category: "system")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("model", detail: command)
        
        switch command {
        case "config":
            return try ModelConfigTool().invoke([:])
            
        case "update":
            return try ModelUpdateTool().invoke([:])
            
        case "auth":
            guard let key = params["key"] as? String else {
                throw MCPError.invalidParams("key required")
            }
            return try ModelAuthenticationTool().invoke(["key": key])
            
        case "list":
            return try ModelListTool().invoke([:])
            
        case "switch":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try ModelSwitchTool().invoke(["name": name])
            
        case "selected":
            return try ModelSelectedProfileIDTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: config/update/auth/list/switch/selected")
        }
    }
}

// MARK: - v3.1.50: knowledge 大工具 + 子命令 (合并 4 个 knowledge.* 工具）

final class KnowledgeExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "knowledge",
        summary: "Persistent knowledge base. Commands: import_text / import_file / search / delete / clear. Params: text (import_text), name (import_text/delete), path (import_file), query (search). Chat memory use memory.*.",
        parameters: [
            "command": "Subcommand: import_text / import_file / search / delete / clear",
            "text": "Text to import (for import_text)",
            "name": "Entry name (optional for import_text, required for delete)",
            "path": "File path (for import_file)",
            "query": "Search query (for search)",
            "id": "Knowledge entry name (alias for name, for delete)"
        ],
        verified: true, category: "knowledge")
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("knowledge", detail: command)
        
        switch command {
        case "import_text":
            guard let text = params["text"] as? String else {
                throw MCPError.invalidParams("text required")
            }
            // v4.3.66：子工具要求 name+content（此前只传 text 必崩）；name 缺省自动生成
            let name = params["name"] as? String ?? "笔记-\(Int(Date().timeIntervalSince1970))"
            return try KnowledgeImportTextTool().invoke(["name": name, "content": text])
            
        case "import_file":
            guard let path = params["path"] as? String else {
                throw MCPError.invalidParams("path required")
            }
            return try KnowledgeImportFileTool().invoke(["path": path])
            
        case "search":
            guard let query = params["query"] as? String else {
                throw MCPError.invalidParams("query required")
            }
            return try KnowledgeSearchTool().invoke(["query": query])
            
        case "delete":
            // v4.3.66：子工具要求 name（此前传 id 必崩）；兼容 name/id 两种入参
            guard let name = params["name"] as? String ?? params["id"] as? String else {
                throw MCPError.invalidParams("name required")
            }
            return try KnowledgeDeleteTool().invoke(["name": name])

        case "clear":
            let removed = KnowledgeStore.shared.clearAll()
            return ["cleared": true, "removed": removed, "note": "已清空知识库（含 session_memory.md，将自动重建）"]

        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: import_text/import_file/search/delete/clear")
        }
    }
}

// MARK: - v3.1.51: location 大工具 + 子命令 (合并 4 个 location.* 工具）

final class LocationExecTool: MCPTool {
    let definition = ToolDefinition(
        name: "location",
        summary: "Manage location (get/fake/status/clear). Use subcommand to specify action. Use for: get current location, fake location. Don't use for: device info (use device info). Example: get → location get; fake → location fake lat:39.9 lng:116.4. Subcommands: get / fake / status / clear.",
        parameters: [
            "command": "Subcommand: get / fake / status / clear",
            "lat": "Latitude (for fake)",
            "lng": "Longitude (for fake)"
        ],
        verified: true, category: "device", annotations: .readOnlyNetwork, cache: ToolCachePolicy.none)
    
    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let command = params["command"] as? String else {
            throw MCPError.invalidParams("command required")
        }
        
        AuditLog.shared.log("location", detail: command)
        
        switch command {
        case "get":
            return try LocationGetTool().invoke([:])
            
        case "fake":
            guard let lat = params["lat"] as? Double else {
                throw MCPError.invalidParams("lat required")
            }
            guard let lng = params["lng"] as? Double else {
                throw MCPError.invalidParams("lng required")
            }
            return try LocationFakeTool().invoke(["lat": lat, "lng": lng])
            
        case "status":
            return try LocationFakeStatusTool().invoke([:])
            
        case "clear":
            return try LocationFakeClearTool().invoke([:])
            
        default:
            throw MCPError.invalidParams("Unknown command: \(command). Available: get/fake/status/clear")
        }
    }
}

// v7.6.5：github 工具（线上编译触发/查运行/下载产物）已随 GitHub 账号功能整体移除

