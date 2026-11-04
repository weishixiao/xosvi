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
/// 编译约定（踩过的坑，改动时别退回去）：
///   * `xpc_connection_create_mach_service` 在 iOS SDK 里标了 API_UNAVAILABLE(ios)，
///     只能用 dlsym 取；它的第二参数是 `dispatch_queue_t`，Swift 没有对应的 C 兼容名字，
///     这里按指针（`UnsafeMutableRawPointer?`）传 NULL —— 传 NULL 就是走默认队列，语义不变。
///   * `XPC_TYPE_*` 是 `&_xpc_type_xxx` 这类宏，Swift 侧不一定能取；判断"是不是错误"
///     一律用错误字典里的 XPCErrorDescription 键，不碰类型常量。
///   * `XPC_ARRAY_APPEND` 是 `((size_t)(-1))` 宏，Swift 侧同样靠不住，用 `Int(bitPattern: UInt.max)`。
///
/// 本机实测：`xpc_connection_create_mach_service` 对**任何**服务都返回 `Connection invalid`
/// （系统服务同样如此），所以这里把失败原样报出去，不做"连不上就当守护不在"的猜测。
enum XosviXPC {
    static let serviceName = "wiki.qaq.xosvi.service"
    /// 守护只接受带这个 entitlement 的客户端（见 tools/xosvid.c 的 peer_allowed）
    static let clientEntitlement = "wiki.qaq.xosvi.client"
    /// 守护允许的 helper 白名单，与 tools/xosvid.c 的 normalize_helper 一致
    static let allowedHelpers = ["xosvi-build", "xosvi-install", "xosvi-symbolicate"]

    /// XPC_ERROR_KEY_DESCRIPTION 的字面值（xpc/xpc.h）：错误事件就是带这个键的字典。
    private static let errorKey = "XPCErrorDescription"
    /// XPC_ARRAY_APPEND == (size_t)-1
    private static let arrayAppend = Int(bitPattern: UInt.max)

    // 公共头把这两个符号标为 iOS 不可用，但运行时一直都在；按 LaunchdLauncher 的做法用 dlsym 取。
    private typealias CreateMachFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?, UInt64) -> xpc_connection_t?

    private static let rtlDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func createMach() -> CreateMachFn? {
        guard let fn = dlsym(rtlDefault, "xpc_connection_create_mach_service") else { return nil }
        return unsafeBitCast(fn, to: CreateMachFn.self)
    }

    /// 一次性把回复取回来的盒子：回调在 XPC 的连接队列上跑，主线程等信号量。
    private final class Box {
        var reply: xpc_object_t?
        var error: String?
        var done = false
    }

    private static func str(_ obj: xpc_object_t, _ key: String) -> String? {
        guard let p = xpc_dictionary_get_string(obj, key) else { return nil }
        return String(cString: p)
    }

    private static func replyDict(_ obj: xpc_object_t) -> [String: Any] {
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

    /// 错误事件（含 Connection invalid / Interrupted）都是带 XPCErrorDescription 的字典；
    /// 正常回复没有这个键。返回 nil 表示"这不是错误"。
    private static func errorText(_ obj: xpc_object_t) -> String? {
        return str(obj, errorKey)
    }

    /// 发一条请求并等回复。
    /// - Returns: `ok:false` 时 `error` 是连接层的原因（创建失败 / 错误事件 / 超时），
    ///            `ok:true` 时其余键来自守护返回的字典（可能仍带守护侧的 `error` 字段）。
    static func request(_ message: [String: Any], timeout: Double) -> [String: Any] {
        guard let create = createMach() else {
            return ["ok": false, "error": "libxpc 缺 xpc_connection_create_mach_service"]
        }
        let made: xpc_connection_t? = serviceName.withCString { name in
            create(name, nil, 0)
        }
        guard let conn = made else {
            return ["ok": false, "error": "xpc_connection_create_mach_service(\(serviceName)) 返回 NULL"]
        }

        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        xpc_connection_set_event_handler(conn) { event in
            guard !box.done else { return }
            if let e = errorText(event) {
                box.error = e
            } else {
                box.reply = event
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
                for s in a { xpc_array_set_string(arr, arrayAppend, s) }
                xpc_dictionary_set_value(msg, k, arr)
            default: break
            }
        }

        // 发送也要走同一个连接；连接不可用时这里常常是**同步**回调错误事件。
        xpc_connection_send_message_with_reply(conn, msg, nil) { reply in
            guard !box.done else { return }
            if let e = errorText(reply) {
                box.error = e
            } else {
                box.reply = reply
            }
            box.done = true
            sem.signal()
        }

        let waited = sem.wait(timeout: .now() + timeout)
        let reply: [String: Any]? = box.reply.map { replyDict($0) }
        let err = box.error
        xpc_connection_cancel(conn)

        if waited == .timedOut {
            return ["ok": false, "error": "等待 xosvid 回复超时（\(Int(timeout))s）",
                    "hint": "守护可能没在 system 域加载：看 root command:status"]
        }
        if reply == nil, let e = err {
            return ["ok": false, "error": "xosvid 不可达：\(e)",
                    "hint": "服务 \(serviceName) 未在 launchd 注册；Connection invalid 是本机对任何 MachService 都出现的返回，需要先让守护在 system 域加载"]
        }
        guard var out = reply else {
            return ["ok": false, "error": "xosvid 没有返回字典"]
        }
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

    // SecTask 是私有 API（公开 SDK 不导出）。这里不用 @_silgen_name：那两个符号在 DeviceProbe
    // 里已经用 @_silgen_name 声明成**实例方法**，Swift 把它们当作多带一个 self 的 C 函数，
    // 于是这里一调用就报 convention mismatch（declared `@guaranteed DeviceProbe`）。
    // 按 MachRaw 的做法走 dlsym + @convention(c)，参数全用裸指针，ABI 与 C 侧一致。
    private typealias SecTaskCreateFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SecTaskCopyFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer,
                                                      UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

    private static let secTaskCreateFn: SecTaskCreateFn? = {
        guard let p = dlsym(rtlDefault, "SecTaskCreateFromSelf") else { return nil }
        return unsafeBitCast(p, to: SecTaskCreateFn.self)
    }()

    private static let secTaskCopyFn: SecTaskCopyFn? = {
        guard let p = dlsym(rtlDefault, "SecTaskCopyValueForEntitlement") else { return nil }
        return unsafeBitCast(p, to: SecTaskCopyFn.self)
    }()

    /// 本进程是否带客户端 entitlement（带不上时守护会直接 cancel 连接，表现为错误事件）。
    static func hasClientEntitlement() -> Bool {
        guard let createTask = secTaskCreateFn, let copyValue = secTaskCopyFn else { return false }
        guard let task = createTask(nil) else { return false }
        defer { Unmanaged<AnyObject>.fromOpaque(task).release() }

        // 先把 CFString 桥接出来**绑在局部变量上**：`clientEntitlement as CFString` 是临时对象，
        // 直接 passUnretained 会拿到已释放的指针（栈上是野指针），SecTaskCopyValueForEntitlement
        // 内部 objc_msgSend 取 objectForKey 时就炸了 —— 这是实测的 hasClientEntitlement 崩溃点。
        // 这里改成 passRetained，并在 defer 里配对释放，指针在整个调用期间有效。
        let cfKey = clientEntitlement as CFString
        let key = UnsafeMutableRawPointer(Unmanaged.passRetained(cfKey).toOpaque())
        defer { Unmanaged<CFString>.fromOpaque(key).release() }
        guard let raw = copyValue(task, key, nil) else { return false }
        // +1 由 takeRetainedValue 收下，交给 ARC 释放；CFBoolean 与 Bool 免费桥接
        let value = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
        return (value as? Bool) ?? false
    }
}
