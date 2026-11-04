import SwiftUI
import UIKit

// MARK: - v7.9.0 环境（严格按 Kelivo 的页面结构重排）
//
// 三页对应 Kelivo 的三张截图：
//   ① 环境：Alpine 卡片（状态/大小/安装于/架构）+ 浏览 + 镜像
//   ② 环境预设：6 个预设（点进去是详情页）+ 刷新工具状态 + 环境变量 + 操作（修复/检查更新/重置）
//   ③ 预设详情（如 Python）：标题卡 + 软件包源 + 安装按钮

// MARK: - ① 环境

/// v9：环境 Pane——页面内容只写一次，壳（EnvironmentView）只负责路由与返回按钮。
/// 这是文档「壳 + Pane」结构的落地：以后要做桌面端/多布局，各自包一层壳即可复用本 Pane。
struct EnvironmentPane: View {
    @ObservedObject private var installer = EnvironmentInstaller.shared
    @State private var booted = false
    @State private var version = ""
    @State private var size: Int64 = 0
    @State private var installedAt: Date?
    @State private var mountPicker = false
    @State private var mounts: [(name: String, path: String)] = []
    @State private var speedRows: [(AlpineMirror, Double)] = []
    @State private var bootError: String = ""
    @State private var speedBusy = false
    @State private var toast: String?

    var body: some View {
        List {
            // ── 环境 ─────────────────────────────
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "cube.box")
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Alpine \(version.isEmpty ? "—" : version) (iSH)")
                            .font(.system(size: 16))
                        Text(booted ? "就绪" : "未启动")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)

                infoRow("状态", booted || ISH.rootfsInstalled ? "已安装" : "未安装", check: ISH.rootfsInstalled)
                infoRow("大小", size > 0 ? String(format: "%.2f MB", Double(size) / 1048576) : "—")
                infoRow("安装于", installedAt.map { relative($0) } ?? "—")
                infoRow("架构", "arm64 · \(version.isEmpty ? "—" : version)")
            } header: {
                Text("环境")
            } footer: {
                if !booted {
                    Button {
                        startSandbox()
                    } label: {
                        Label("启动沙盒", systemImage: "play")
                    }
                    Button {
                        reinstall()
                    } label: {
                        Label("重装 rootfs", systemImage: "arrow.clockwise")
                    }
                }
                if !bootError.isEmpty {
                    Text(bootError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            // ── 浏览 ─────────────────────────────
            Section {
                NavigationLink {
                    GuestFilesystemView(path: "/")
                } label: {
                    row("浏览文件系统", "查看沙盒中的完整目录", "externaldrive")
                }
                Button {
                    mountPicker = true
                } label: {
                    row("挂载外部文件夹", "所选文件夹挂载到 /mounts/<name>，供模型与终端访问", "folder")
                }
                ForEach(mounts, id: \.path) { m in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundColor(.secondary).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).font(.system(size: 15))
                            Text("/mounts/\(m.name)").font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            } header: {
                Text("浏览")
            }

            // ── 镜像 ─────────────────────────────
            Section {
                Button {
                    runSpeedTest()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "speedometer").frame(width: 24)
                        Text(speedBusy ? "测速中…" : "检测快速镜像")
                        Spacer()
                        if speedBusy { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(speedBusy)

                Picker(selection: Binding(
                    get: { MirrorCatalog.current("apk").id },
                    set: { id in
                        if let m = MirrorCatalog.apk.first(where: { $0.id == id }) {
                            MirrorCatalog.setCurrent("apk", m); applyMirrors()
                        }
                    }
                )) {
                    ForEach(MirrorCatalog.apk) { Text($0.displayName).tag($0.id) }
                } label: {
                    Label("APK", systemImage: "cube.box")
                }

                Picker(selection: Binding(
                    get: { MirrorCatalog.current("pip").id },
                    set: { id in
                        if let m = MirrorCatalog.pip.first(where: { $0.id == id }) {
                            MirrorCatalog.setCurrent("pip", m); applyMirrors()
                        }
                    }
                )) {
                    ForEach(MirrorCatalog.pip) { Text($0.displayName).tag($0.id) }
                } label: {
                    Label("pip", systemImage: "cube.box")
                }

                Picker(selection: Binding(
                    get: { MirrorCatalog.current("npm").id },
                    set: { id in
                        if let m = MirrorCatalog.npm.first(where: { $0.id == id }) {
                            MirrorCatalog.setCurrent("npm", m); applyMirrors()
                        }
                    }
                )) {
                    ForEach(MirrorCatalog.npm) { Text($0.displayName).tag($0.id) }
                } label: {
                    Label("npm", systemImage: "cube.box")
                }

                if !speedRows.isEmpty {
                    ForEach(speedRows, id: \.0.id) { row in
                        HStack {
                            Text(row.0.name).font(.system(size: 14))
                            Spacer()
                            Text(String(format: "%.1fs", row.1))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("镜像")
            }

            // ── 环境预设（入口）──────────────────
            Section {
                NavigationLink {
                    EnvironmentPresetsView()
                } label: {
                    row("环境预设", "Python · Node.js · Git · SSH · 网络 / 压缩工具", "square.stack.3d.up")
                }
            }
        }
        .navigationTitle("环境")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
        .sheet(isPresented: $mountPicker) {
            DocumentFolderPicker { url in
                let name = url.lastPathComponent
                    .replacingOccurrences(of: " ", with: "_").lowercased()
                let rc = ISH.mountExternal(hostPath: url.path, name: name)
                if rc == 0 {
                    mounts.append((name, url.path)); saveMounts()
                    toast = "已挂载到 /mounts/\(name)"
                } else { toast = "挂载失败 rc=\(rc)" }
            }
        }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: 组件

    private func infoRow(_ label: String, _ value: String, check: Bool = false) -> some View {
        HStack {
            Text(label).foregroundColor(.primary)
            Spacer()
            Text(value).foregroundColor(.secondary)
            if check {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.green)
            }
        }
    }

    private func row(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16)).foregroundColor(.primary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundColor(.primary)
                Text(subtitle).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let t = toast {
            Text(t)
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .foregroundColor(.white)
                .padding(.bottom, 24)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        withAnimation { toast = nil }
                    }
                }
        }
    }

    // MARK: 动作

    private func refresh() {
        booted = ISH.isBooted
        version = ISH.runtimeVersion
        size = ISH.rootfsSize
        let ts = UserDefaults.standard.double(forKey: "ishInstalledAt")
        installedAt = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
        loadMounts()
    }

    private func startSandbox() {
        toast = "正在启动…"
        DispatchQueue.global(qos: .userInitiated).async {
            let rc = ISH.boot()
            DispatchQueue.main.async {
                refresh()
                if rc == 0 {
                    toast = "沙盒已就绪"
                } else {
                    // v7.12.0：把具体原因显示出来（是 zip 缺失、解压不完整、还是内核错误）
                    bootError = ISH.lastError ?? "启动失败 rc=\(rc)"
                    toast = bootError
                }
            }
        }
    }

    /// 强制重装 rootfs（解压失败时用；内核已 boot 则需重开 App）
    private func reinstall() {
        toast = "正在重装 rootfs…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try ISH.installRootfsIfNeeded(force: true)
                DispatchQueue.main.async {
                    refresh()
                    bootError = ""
                    toast = "rootfs 已重装，点「启动沙盒」"
                }
            } catch {
                DispatchQueue.main.async {
                    bootError = error.localizedDescription
                    toast = "重装失败"
                }
            }
        }
    }

    private func applyMirrors() {
        let apk = MirrorCatalog.current("apk")
        let pip = MirrorCatalog.current("pip")
        let npm = MirrorCatalog.current("npm")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ISH.run("""
            set -e
            mkdir -p /etc/apk /etc/pip /root
            printf '%s\n%s\n' '\(apk.guestBase)\(AlpineVersion.branch())/main' '\(apk.guestBase)\(AlpineVersion.branch())/community' > /etc/apk/repositories
            # v9.3：兜底降级 https→http + 清残锁（iSH 里 TLS 挂死、残锁会让 apk 死等）
            sed -i 's|^https://|http://|' /etc/apk/repositories
            rm -f /lib/apk/db/lock 2>/dev/null || true
            printf '[global]\\nindex-url = \(pip.pipIndexURL())\\ntrusted-host = mirrors.aliyun.com pypi.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn pypi.org\\n' > /etc/pip.conf
            printf 'registry=\(npm.npmRegistry)\\n' > /root/.npmrc
            """, timeout: 30)
            DispatchQueue.main.async { toast = "已切换源：\(apk.displayName)" }
        }
    }

    private func runSpeedTest() {
        speedBusy = true
        speedRows = []
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = MirrorCatalog.speedTest(MirrorCatalog.apk)
            DispatchQueue.main.async {
                speedRows = rows
                speedBusy = false
                if let best = rows.first {
                    MirrorCatalog.setCurrent("apk", best.0)
                    applyMirrors()
                    toast = "已选最快：\(best.0.displayName)（\(String(format: "%.1fs", best.1))）"
                } else {
                    toast = "测速全部超时，保留当前源"
                }
            }
        }
    }

    private func loadMounts() {
        guard let arr = UserDefaults.standard.array(forKey: "ish.mounts") as? [[String: String]] else { return }
        mounts = arr.compactMap { d in
            guard let n = d["name"], let p = d["path"] else { return nil }
            return (n, p)
        }
    }
    private func saveMounts() {
        UserDefaults.standard.set(mounts.map { ["name": $0.name, "path": $0.path] }, forKey: "ish.mounts")
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: "zh_CN")
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - ② 环境预设

struct EnvironmentPresetsView: View {
    @ObservedObject private var installer = EnvironmentInstaller.shared
    @State private var confirmReset = false
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                ForEach(EnvDependency.allCases) { dep in
                    NavigationLink {
                        DependencyDetailView(dependency: dep)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: dep.icon)
                                .font(.system(size: 16))
                                .foregroundColor(.primary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dep.title).font(.system(size: 15))
                                Text(dep.subtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            statusText(dep)
                        }
                    }
                }
                Button {
                    installer.refresh()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise").frame(width: 24)
                        Text(installer.busy ? "检测中…" : "刷新工具状态")
                        Spacer()
                        if installer.busy { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(installer.busy)
            } header: {
                Text("环境预设")
            } footer: {
                Text("安装到共享沙盒，所有工作区均可使用。")
                    .font(.caption2)
            }

            Section {
                NavigationLink {
                    EnvVarsView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key").frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("环境变量").font(.system(size: 15))
                            Text("管理命令使用的变量与输出隐私")
                                .font(.system(size: 11.5)).foregroundColor(.secondary)
                        }
                    }
                }
            } header: {
                Text("环境变量")
            }

            Section {
                Button {
                    repair()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wrench.and.screwdriver").frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("修复").font(.system(size: 15)).foregroundColor(.primary)
                            Text("重新校验并修补文件")
                                .font(.system(size: 11.5)).foregroundColor(.secondary)
                        }
                    }
                }
                Button {
                    installer.refresh()
                    toast = "已重新检测环境"
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").frame(width: 24)
                        Text("检查更新").font(.system(size: 15)).foregroundColor(.primary)
                    }
                }
                Button(role: .destructive) {
                    confirmReset = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash").frame(width: 24)
                        Text("重置").font(.system(size: 15))
                    }
                }
            } header: {
                Text("操作")
            } footer: {
                Text("环境是沙盒使用的 Linux 根文件系统。工作区单独存放，重置环境不会删除工作区文件。数据保存在本机已解压的 rootfs 中。")
                    .font(.caption2)
            }
        }
        .navigationTitle("环境预设")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { installer.refresh() }
        .alert("重置环境？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) { reset() }
        } message: {
            Text("会重新解压 Alpine rootfs，已安装的软件包会丢失。需要完全退出 App 后重开才能重新启动内核。")
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func statusText(_ dep: EnvDependency) -> some View {
        if installer.installing == dep {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.7)
                Text("安装中").font(.system(size: 12)).foregroundColor(.secondary)
            }
        } else {
            switch installer.status(dep) {
            case .installed:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.green)
            case .missing:
                Text("未安装").font(.system(size: 12)).foregroundColor(.secondary)
            case .unknown:
                Text("—").font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
    }

    private func repair() {
        toast = "正在修复…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ISH.repair()
                DispatchQueue.main.async { toast = "已重装 rootfs，请完全退出 App 后重开" }
            } catch {
                DispatchQueue.main.async { toast = error.localizedDescription }
            }
        }
    }

    private func reset() {
        toast = "正在重置…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try ISH.repair()
                DispatchQueue.main.async {
                    toast = "已重置，请完全退出 App 后重开"
                    installer.refresh()
                }
            } catch {
                DispatchQueue.main.async { toast = error.localizedDescription }
            }
        }
    }
}

// MARK: - ③ 单个预设详情（Kelivo 的 Python 页）

struct DependencyDetailView: View {
    let dependency: EnvDependency
    // v7.14.12：进度卡要读这里的 installer，不能是 private
    @ObservedObject var installer = EnvironmentInstaller.shared
    @State private var speedBusy = false
    @State private var showLog = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: dependency.icon)
                        .font(.system(size: 20))
                        .foregroundColor(.primary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dependency.title).font(.system(size: 16))
                        Text(dependency.subtitle)
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    Spacer()
                    if installer.status(dependency) == .installed {
                        Text("已安装").font(.system(size: 12)).foregroundColor(.secondary)
                    } else {
                        Text("未安装").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker(selection: Binding(
                    get: { MirrorCatalog.current("apk").id },
                    set: { id in
                        if let m = MirrorCatalog.apk.first(where: { $0.id == id }) {
                            MirrorCatalog.setCurrent("apk", m)
                        }
                    }
                )) {
                    ForEach(MirrorCatalog.apk) { Text($0.displayName).tag($0.id) }
                } label: {
                    Label("APK", systemImage: "cube.box")
                }
                Picker(selection: Binding(
                    get: { MirrorCatalog.current("pip").id },
                    set: { id in
                        if let m = MirrorCatalog.pip.first(where: { $0.id == id }) {
                            MirrorCatalog.setCurrent("pip", m)
                        }
                    }
                )) {
                    ForEach(MirrorCatalog.pip) { Text($0.displayName).tag($0.id) }
                } label: {
                    Label("pip", systemImage: "cube.box")
                }
                Button {
                    speedBusy = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let rows = MirrorCatalog.speedTest(MirrorCatalog.apk)
                        DispatchQueue.main.async {
                            speedBusy = false
                            if let best = rows.first { MirrorCatalog.setCurrent("apk", best.0) }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "speedometer").frame(width: 24)
                        Text(speedBusy ? "测速中…" : "检测快速镜像")
                        Spacer()
                        if speedBusy { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(speedBusy)
            } header: {
                Text("软件包源")
            } footer: {
                Text("预设使用所选 apt/apk 源安装；pip 和 npm 源用于后续安装的软件包。")
                    .font(.caption2)
            }

            Section {
                if installer.installing == dependency {
                    // v7.14.12：实时进度框——阶段文字 + 进度条 + (n/m) + 最后几行输出
                    InstallProgressCard(installer: installer, dependency: dependency)
                } else {
                    Button {
                        installer.install(dependency)
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.down.circle")
                            Text(installer.status(dependency) == .installed ? "重新安装" : "安装")
                                .font(.system(size: 16, weight: .medium))
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                }

                if installer.failure != nil, installer.installing == nil,
                   installer.status(dependency) != .installed, !installer.log.isEmpty {
                    Button {
                        showLog = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundColor(.orange)
                            Text(installer.diagnose(dependency))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(dependency.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { installer.refresh() }
        .sheet(isPresented: $showLog) {
            NavigationView {
                ScrollView {
                    Text(installer.log)
                        .font(.system(size: 11, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("安装日志")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showLog = false }
                    }
                }
            }
        }
    }
}

// MARK: - v7.14.12：安装进度卡

/// 显示「现在在干什么、下载到哪、装到第几个包」，并给出最后几行 apk 输出。
/// 数据全部来自 EnvironmentInstaller 的流式回调（phase / pkgDone / pkgTotal / log）。
struct InstallProgressCard: View {
    @ObservedObject var installer: EnvironmentInstaller
    let dependency: EnvDependency

    private var tail: [String] {
        installer.log
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(4)
            .map { String($0.prefix(120)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text(installer.phase.text)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if installer.pkgTotal > 0 {
                    Text("\(installer.pkgDone)/\(installer.pkgTotal)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if let frac = installer.progressFraction {
                ProgressView(value: frac)
                    .tint(.accentColor)
            } else {
                // 没有 (n/m) 时（例如正在拉索引）用不确定进度条
                ProgressView()
                    .progressViewStyle(.linear)
            }

            ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Text(dependency.packages)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("如长时间停在「拉取包索引」= 网络到镜像不通，换源后重试")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 沙盒文件浏览

struct GuestFilesystemView: View {
    let path: String
    @State private var entries: [ISH.Entry] = []
    @State private var loading = true

    var body: some View {
        List {
            if loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if entries.isEmpty {
                Text("空目录").foregroundColor(.secondary)
            }
            ForEach(entries, id: \.name) { e in
                if e.isDir {
                    NavigationLink {
                        GuestFilesystemView(path: join(path, e.name))
                    } label: { entryRow(e) }
                } else {
                    entryRow(e)
                }
            }
        }
        .navigationTitle(path == "/" ? "沙盒根目录" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let list = ISH.listGuest(path)
                DispatchQueue.main.async {
                    entries = list
                    loading = false
                }
            }
        }
    }

    private func entryRow(_ e: ISH.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.isDir ? "folder" : "doc")
                .font(.system(size: 14)).foregroundColor(.secondary).frame(width: 22)
            Text(e.name).font(.system(size: 14)).lineLimit(1)
            Spacer()
            if !e.isDir {
                Text(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }
}


// MARK: - v9：环境页壳（文档「壳 + Pane」结构）

struct EnvironmentView: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        // 注意：本页由 SettingsView 的 NavigationStack push 进来，不能再套 CompatNav
        //（嵌套 NavigationStack 会导致返回按钮/侧滑失效）。
        EnvironmentPane()
            .navigationTitle("环境")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("返回"))
                }
            }
    }
}
