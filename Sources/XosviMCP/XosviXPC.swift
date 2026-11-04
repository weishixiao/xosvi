import Foundation
import XPC
import Darwin

/// App 侧通往 root 守护 `xosvid` 的 XPC 客户端（MachService `wiki.qaq.xosvi.service`）。
///
/// 取代旧 rootd 的 1777 目录 `.cmd/.out/.status` 轮询：那条路在 roothide 下 App 与 root
/// 是两套文件视图，心跳/写入探针常年误判。XPC 走 launchd 的 Mach bootstrap，
/// 不依赖任何共享目录，也没有可被其他进程抢占的命令文件。
///
/// 协议（与 tools/xosvid.c、tools/xosvi-cli.c 一致）：
///   请求 `{command: ping|status|helper, name, args:[String], timeout:Int, dryrun:Bool}`
///   回复 `{status, error, resolved, pid, uid, exit_code, stdout:Data, timed_out, elapsed_ms}`
///
/// 本机实测：`xpc_connection_create_mach_service` 对**任何**服务都返回 `Connection invalid`
/// （系统服务同样如此），所以这里把失败原样报出去，不做"连不上就当守护不在"的猜测。
enum XosviXPC {
    static let serviceName = "wiki.qaq.xosvi.service"
    /// 守护只接受带这个 entitlement 的客户端（见 tools/xosvid.c 的 peer_allowed）
    static let clientEntitlement = "wiki.qaq.xosvi.client"
    /// 守护允许的 helper 白名单，与 tools/xosvid.c 的 normalize_helper 一致
    static let allowedHelpers = ["xosvi-build", "xosvi-install", "xosvi-symbolicate"]

    // 公共头把这两个符号标为 iOS 不可用，但运行时一直都在；按 LaunchdLauncher 的做法用 dlsym 取。
    private typealias CreateMachFn = @convention(c) (UnsafePointer<CChar>, dispatch_queue_t, UInt64) -> xpc_connection_t?
    private typealias GetPIDFn = @convention(c) (xpc_connection_t) -> pid_t

    private static let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func createMach() -> CreateMachFn? {
        guard let fn = dlsym(rtlDefault, "xpc_connection_create_mach_service") else { return nil }
        return unsafeBitCast(fn, to: CreateMachFn.self)
    }

    private static func getPID() -> GetPIDFn? {
        guard let fn = dlsym(rtlDefault, "xpc_connection_get_pid") else { return nil }
        return unsafeBitCast(fn, to: GetPIDFn.self)
    }

    /// 一次性把回复取回来的盒子：回调在 XPC 的连接队列上跑，主线程等信号量。
    private final class Box {
        var reply: xpc_object_t?
        var error: String?
        var done = false
    }

    private static func str(_ obj: xpc_object_t?, _ key: String) -> String? {
        guard let obj = obj else { return nil }
        return xpc_dictionary_get_string(obj, key).map { String(cString: $0) }
    }

    private static func replyDict(_ obj: xpc_object_t?) -> [String: Any]? {
        guard let obj = obj else { return nil }
        var out: [String: Any] = [:]
        for key in ["status", "error", "bootstrap", "resolved", "dash", "helper", "peer"] {
            if let v = str(obj, key) { out[key] = v }
        }
        for key in ["pid", "uid", "exit_code"] {
            if xpc_dictionary_get_value(obj, key) != nil {
                out[key] = Int(xpc_dictionary_get_int64(obj, key))
            }
        }
        if xpc_dictionary_get_value(obj, "elapsed_ms") != nil {
            out["elapsed_ms"] = xpc_dictionary_get_double(obj, "elapsed_ms")
        }
        if xpc_dictionary_get_bool(obj, "timed_out") { out["timed_out"] = true }
        var len = 0
        if let data = xpc_dictionary_get_data(obj, "stdout", &len), len > 0 {
            out["stdout"] = String(decoding: Data(bytes: data, count: len), as: UTF8.self)
        } else {
            out["stdout"] = ""
        }
        return out
    }

    private static func errorText(_ obj: xpc_object_t) -> String {
        return str(obj, XPC_ERROR_KEY_DESCRIPTION) ?? "unknown xpc error"
    }

    /// 发一条请求并等回复。
    /// - Returns: `ok:false` 时 `error` 是连接层的原因（创建失败 / 错误事件 / 超时），
    ///            `ok:true` 时 `reply` 是守护返回的字典（可能仍带守护侧的 `error` 字段）。
    static func request(_ message: [String: Any], timeout: Double) -> [String: Any] {
        guard let create = createMach() else {
            return ["ok": false, "error": "libxpc 缺 xpc_connection_create_mach_service"]
        }
        guard let conn = create(serviceName, nil, 0) else {
            return ["ok": false, "error": "xpc_connection_create_mach_service(\(serviceName)) 返回 NULL"]
        }

        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        xpc_connection_set_event_handler(conn) { event in
            guard !box.done else { return }
            if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
                box.reply = event
            } else if xpc_get_type(event) == XPC_TYPE_ERROR {
                // 服务没加载时典型就是这里的 Connection invalid
                box.error = errorText(event)
            }
            box.done = true
            sem.signal()
        }
        xpc_connection_resume(conn)

        let msg = xpc_dictionary_create(nil, nil, 0)
        for (k, v) in message {
            switch v {
            case let s as String: xpc_dictionary_set_string(msg, k, s)
            case let i as Int: xpc_dictionary_set_int64(msg, k, Int64(i))
            case let b as Bool: xpc_dictionary_set_bool(msg, k, b)
            case let a as [String]:
                let arr = xpc_array_create(nil, 0)
                for s in a { xpc_array_set_string(arr, XPC_ARRAY_APPEND, s) }
                xpc_dictionary_set_value(msg, k, arr)
            default: break
            }
        }

        // 发送也要走同一个连接；连接不可用时这里常常是**同步**回调错误事件。
        xpc_connection_send_message_with_reply(conn, msg, nil) { reply in
            guard !box.done else { return }
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY {
                box.reply = reply
            } else if xpc_get_type(reply) == XPC_TYPE_ERROR {
                box.error = errorText(reply)
            }
            box.done = true
            sem.signal()
        }

        let waited = sem.wait(timeout: .now() + timeout)
        let reply = box.reply.map { replyDict($0) }
        xpc_connection_cancel(conn)

        if waited == .timedOut {
            return ["ok": false, "error": "等待 xosvid 回复超时（\(Int(timeout))s）",
                    "hint": "守护可能没在 system 域加载：看 root command:status"]
        }
        if let e = box.error, reply == nil {
            return ["ok": false, "error": "xosvid 不可达：\(e)",
                    "hint": "服务 \(serviceName) 未在 launchd 注册；Connection invalid 是本机对任何 MachService 都出现的返回，需要先让守护在 system 域加载"]
        }
        guard let r = reply else {
            return ["ok": false, "error": "xosvid 没有返回字典"]
        }
        var out = r
        out["ok"] = true
        return out
    }

    // MARK: - 便捷封装

    static func ping(timeout: Double = 5) -> [String: Any] {
        request(["command": "ping"], timeout: timeout)
    }

    static func serviceStatus(timeout: Double = 5) -> [String: Any] {
        request(["command": "status"], timeout: timeout)
    }

    /// 调一个 helper。`args` 的第一项必须是项目目录（守护侧的要求）。
    static func helper(_ name: String, args: [String], timeout: Int, dryrun: Bool = false) -> [String: Any] {
        var msg: [String: Any] = ["command": "helper", "name": name, "args": args]
        if timeout > 0 { msg["timeout"] = timeout }
        if dryrun { msg["dryrun"] = true }
        // 客户端等待要比守护侧的超时更长，否则先超时的永远是客户端
        return request(msg, timeout: Double(max(timeout, 30)) + 10)
    }

    // SecTask 是私有 API（公开 SDK 不导出），按 DeviceProbe 的做法直接声明符号。
    @_silgen_name("SecTaskCreateFromSelf")
    private static func secTaskCreateFromSelf(_ allocator: CFAllocator?) -> CFTypeRef?

    @_silgen_name("SecTaskCopyValueForEntitlement")
    private static func secTaskCopyValueForEntitlement(_ task: CFTypeRef, _ entitlement: CFString,
                                                      _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> CFTypeRef?

    /// 本进程是否带客户端 entitlement（带不上时守护会直接 cancel 连接，表现为错误事件）。
    static func hasClientEntitlement() -> Bool {
        guard let task = secTaskCreateFromSelf(nil) else { return false }
        guard let raw = secTaskCopyValueForEntitlement(task, clientEntitlement as CFString, nil) else {
            return false
        }
        return CFGetTypeID(raw) == CFBooleanGetTypeID() && CFBooleanGetValue((raw as! CFBoolean))
    }
}
