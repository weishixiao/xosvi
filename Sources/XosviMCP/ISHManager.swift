import Foundation
// v7.6.0：Alpine 运行时回来了——换成移植自 Kelivo 的 iSH 沙盒（带崩溃保护）。
// ISHEngine 现在是 ISH 门面的薄封装，原有调用点（shell.exec / db / file / tool.install …）不用改。

enum ISHEngine {
    // MARK: - 状态（恒定：未启用）

    static var autoBindEnabled = true
    static var isBooted: Bool { ISH.isBooted }
    static var requiresRelaunch: Bool { false }
    static var cwd: String { FileManager.default.currentDirectoryPath }

    static func interruptCurrent() {}
    static func resetCwd() {}
    static func resetRuntimeState() throws {
        // 内核不卸载：只能标记需要重启（ISE 内无法换 fakefs）
        UserDefaults.standard.set(false, forKey: ISH.rootfsVersionKey)
    }

    struct BindResult {
        var ok: Bool
        var mountPath: String?
        var hostPath: String?
        var error: String?
    }

    static func resetRootfs() -> (ok: Bool, message: String, rootfsExists: Bool) {
        do {
            try ISH.repair()
            return (true, "rootfs 已重装，请完全退出 App 后重开以重新启动内核", true)
        } catch {
            return (false, "重装失败：\(error.localizedDescription)", ISH.rootfsInstalled)
        }
    }

    static func rootfsInfo() -> [String: Any] {
        ["installed": ISH.rootfsInstalled,
         "booted": ISH.isBooted,
         "version": ISH.runtimeVersion,
         "size": ISH.rootfsSize,
         "path": ISH.dataPath]
    }

    /// 把 App 数据容器挂到 guest 的 /mounts/ios_data_<app>
    static func bindAppContainer(bundleId: String, readOnly: Bool = true) -> BindResult {
        guard let container = BindAppTool.containerPath(for: bundleId) else {
            return BindResult(ok: false, mountPath: nil, hostPath: nil,
                              error: "找不到 \(bundleId) 的数据容器（App 未安装或不可见）")
        }
        let name = "ios_data_" + bundleId.replacingOccurrences(of: ".", with: "_").lowercased()
        let rc = ISH.mountExternal(hostPath: container, name: name, readOnly: readOnly)
        if rc != 0 {
            return BindResult(ok: false, mountPath: nil, hostPath: container, error: "挂载失败 rc=\(rc)")
        }
        return BindResult(ok: true, mountPath: "/mounts/\(name)", hostPath: container, error: nil)
    }

    /// 简单 bind mount（guest 路径 ← iOS 路径）
    @discardableResult
    static func bindMount(_ linuxPath: String, _ hostPath: String, readOnly: Bool) -> Int32 {
        ISH.mountExternal(hostPath: hostPath,
                          name: (linuxPath as NSString).lastPathComponent,
                          readOnly: readOnly)
    }

    @discardableResult
    static func bindUnmount(_ linuxPath: String) -> Int32 {
        ISH.unmountExternal(name: (linuxPath as NSString).lastPathComponent)
    }

    /// 命令执行：走 iSH 沙盒里的 /bin/sh -c
    static func exec(_ command: String, timeout: TimeInterval) -> (output: String, exitCode: Int32, timedOut: Bool) {
        let r = ISH.run(command, timeout: timeout)
        return (r.output, r.exitCode, r.timedOut)
    }

    /// apk 安装
    static func apkAdd(_ packages: [String], timeout: Double, onLine: ((String) -> Void)? = nil)
        -> (output: String, exitCode: Int32, timedOut: Bool) {
        let cmd = """
        set -e
        rm -f /lib/apk/db/lock 2>/dev/null || true
        sed -i 's|^https://|http://|' /etc/apk/repositories 2>/dev/null || true
        apk add --no-cache \(packages.joined(separator: " "))
        """
        let r = ISH.run(cmd, timeout: timeout)
        onLine?(r.output)
        return (r.output, r.exitCode, r.timedOut)
    }

    static func installDiagnose(_ output: String, timedOut: Bool, exitCode: Int32) -> String {
        if timedOut { return "安装超时（网络慢或源不可达）。可在 设置 → 环境 → 镜像 换个源后重试。" }
        if output.contains("unable to select package") || output.contains("No such package") {
            return "源里没有这个包。可在 设置 → 环境 → 镜像 切换源，或换包名。"
        }
        if exitCode != 0 { return "安装失败（exit \(exitCode)）：\(String(output.suffix(300)))" }
        return "已安装"
    }

    /// 路径改写：把 iOS 路径换成 guest 里能看到的挂载点（/mounts/ios_workspace 等）
    static func autoBind(_ command: String) -> String {
        var cmd = command
        let ws = Workspace.root.path
        cmd = cmd.replacingOccurrences(of: ws, with: "/mounts/ios_workspace")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        cmd = cmd.replacingOccurrences(of: docs, with: "/mounts/ios_documents")
        return cmd
    }
}
