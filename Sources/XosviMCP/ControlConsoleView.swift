import SwiftUI
import UIKit

// MARK: - v9.9 控制台（重新设计 + 功能补全）
//
// 原来的控制台是十段独立表单：先手输 bundle id、点注入、再逐个点按坐标，参数散在各处，
// 也看不到「注入后该启动哪个 App」。现在改成一条链路 + 四个工作区：
//
//   ① 目标：已注入目标卡（从设置里选 App，一键注入并放到前台）+ 状态刷新
//   ② 界面：读 UI 树 → 列出可点元素（点元素 = 直接点它，不必算坐标）；截图可看/可存相册/可复制路径
//   ③ 操作：点按 / 滑动（含四个方向速滑）/ 点文字 / 输入到焦点 / 按占位符填字 / 按键
//   ④ 结果：最近一次调用的来源与结果（json），排障时直接看这一条
//
// 所有动作仍走 ToolRegistry 的 control 工具（注入、状态、树、截图、点按、滑动、输入、按键）。

struct ControlConsoleView: View {
    private static let bundleKey = "control.lastBundle"

    @State private var bundleId = UserDefaults.standard.string(forKey: ControlConsoleView.bundleKey) ?? ""
    @State private var appName = ""
    @State private var connected = false
    @State private var injecting = false
    @State private var statusText = "未连接"
    @State private var controlPath = ""
    @State private var busy = false
    /// v9.10：注入成功到 ControlAgent 应答之间有窗口期（App 启动 + 4789 监听约 1.5s）。
    /// 这段里状态行显示"等待连接"并自动复查 3 次（2s / 3.5s / 5.5s），
    /// 全都没应答才落回"未连接"——避免刚注入完就被判成没注入。
    @State private var awaitingAgent = false
    @State private var autoChecksLeft = 0

    // 应用选择
    @State private var showAppPicker = false

    // UI 树
    @State private var treeLoading = false
    @State private var tappables: [Tappable] = []
    @State private var treeSignature = ""
    @State private var treeNote = ""

    // 截图
    @State private var shot: UIImage?
    @State private var shotPath = ""

    // 输入
    @State private var tapX = ""
    @State private var tapY = ""
    @State private var swX1 = ""
    @State private var swY1 = ""
    @State private var swX2 = ""
    @State private var swY2 = ""
    @State private var typeText = ""
    @State private var tapLabel = ""
    @State private var fillPlaceholder = ""
    @State private var fillText = ""
    @State private var pressEnter = false

    // 结果
    @State private var lastAction = ""
    @State private var lastResult = ""
    @State private var lastFailed = false
    @State private var toast: String?

    var body: some View {
        List {
            // v10：页首大标题卡（与「环境」页同一套排版）
            Section {
                XHeroHeader(icon: "hand.tap",
                            title: connected ? "已连接目标 App" : "未连接",
                            subtitle: statusText,
                            tint: connected ? .green : .primary)
            }
            targetSection
            screenSection
            gestureSection
            keyboardSection
            resultSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("控制台")
        .navigationBarTitleDisplayMode(.inline)
        .xGroupedPage()
        .onAppear {
            if bundleId.isEmpty, let last = UserDefaults.standard.string(forKey: Self.bundleKey) {
                bundleId = last
            }
            reloadTargetName()
            checkStatus()
        }
        .sheet(isPresented: $showAppPicker) {
            AppPickerView { app in
                bundleId = app.bundleId
                appName = app.name
                UserDefaults.standard.set(app.bundleId, forKey: Self.bundleKey)
                connected = false
                awaitingAgent = false
                autoChecksLeft = 0
                statusText = "未注入（点「注入并打开」）"
            }
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
    }

    // MARK: - ① 目标

    private var targetSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(UIColor.secondarySystemFill))
                        .frame(width: 38, height: 38)
                    Image(systemName: bundleId.isEmpty ? "questionmark.app" : "app.badge.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName.isEmpty ? (bundleId.isEmpty ? "未选择目标 App" : bundleId) : appName)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(bundleId.isEmpty ? "点「选择 App」指定控制目标" : bundleId)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showAppPicker = true
                } label: {
                    Text("选择 App").font(XType.note)
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(DoubaoTheme.accent)
            }

            Button {
                injectAndLaunch()
            } label: {
                HStack(spacing: 10) {
                    if injecting {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .foregroundColor(.primary)
                    }
                    Text(injecting ? "注入中…" : "注入并打开")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("ControlAgent")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .disabled(bundleId.isEmpty || injecting)

            Button {
                checkStatus()
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(connected ? Color.green : Color(UIColor.tertiaryLabel))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("连接状态").font(.subheadline).foregroundColor(.primary)
                        Text(statusText).font(.system(size: 11.5)).foregroundColor(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if controlPath.isEmpty {
                        Image(systemName: "arrow.clockwise").font(XType.note).foregroundColor(.secondary)
                    } else {
                        Text(controlPath).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(busy)
        } header: {
            sectionHeader("目标", "iphone.and.arrow.forward")
        } footer: {
            Text("ControlAgent 注入到目标 App 后，App 需在前台运行约 1.5 秒才能被读到界面。点按 / 滑动在多条路径可用时优先走 HID，不依赖注入。")
                .font(XType.section)
        }
    }

    // MARK: - ② 界面

    private var screenSection: some View {
        Section {
            Button {
                loadTree()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "list.bullet.indent").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(treeLoading ? "读取中…" : "读取界面元素").foregroundColor(.primary)
                        Text(treeNote.isEmpty ? "拍平可点元素，点一下就点它" : treeNote)
                            .font(.system(size: 11.5)).foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if treeLoading { ProgressView().scaleEffect(0.7) }
                }
            }
            .disabled(treeLoading || busy)

            Button {
                screenshot()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "camera.viewfinder").frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("截图").foregroundColor(.primary)
                        Text(shotPath.isEmpty ? "截取目标 App 当前画面" : (shotPath as NSString).lastPathComponent)
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
            .disabled(busy)

            if let img = shot {
                VStack(spacing: 8) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    HStack(spacing: 16) {
                        Button("保存到相册") { saveShotToPhotos() }
                            .font(XType.note)
                        Button("复制路径") {
                            UIPasteboard.general.string = shotPath
                            toast = "已复制路径"
                        }
                        .font(XType.note)
                        Spacer()
                    }
                }
            }

            if !tappables.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("可点元素 · \(tappables.count) · 签名 \(treeSignature.prefix(6))")
                        .font(XType.section).foregroundColor(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(tappables.prefix(40).enumerated()), id: \.offset) { _, item in
                                Button {
                                    tapElement(item)
                                } label: {
                                    Text(item.label)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(Capsule().fill(Color(UIColor.secondarySystemFill)))
                                        .foregroundColor(.primary)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            sectionHeader("界面", "rectangle.dashed")
        } footer: {
            Text("元素坐标来自 ControlAgent 读到的界面树（归一化），点元素即点它的中心。界面变了要重新读取。")
                .font(XType.section)
        }
    }

    // MARK: - ③ 手势

    private var gestureSection: some View {
        Section {
            HStack(spacing: 8) {
                numField("X", $tapX)
                numField("Y", $tapY)
                Spacer()
                smallButton("点按") { tapXY() }
                    .disabled(tapX.isEmpty || tapY.isEmpty || busy)
            }

            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 13)).foregroundColor(.secondary).frame(width: 22)
                Text("方向滑动").font(.subheadline)
                Spacer()
                swipeArrow("chevron.up", "up")
                swipeArrow("chevron.down", "down")
                swipeArrow("chevron.left", "left")
                swipeArrow("chevron.right", "right")
            }

            DisclosureGroup("自定义滑动") {
                HStack(spacing: 6) {
                    numField("x1", $swX1)
                    numField("y1", $swY1)
                    numField("x2", $swX2)
                    numField("y2", $swY2)
                }
                .padding(.top, 6)
                HStack {
                    Spacer()
                    smallButton("从 (x1,y1) 滑到 (x2,y2)") { swipe() }
                        .disabled(swX1.isEmpty || swY1.isEmpty || swX2.isEmpty || swY2.isEmpty || busy)
                }
            }

            HStack(spacing: 8) {
                TextField("元素文字，如「登录」", text: $tapLabel)
                    .font(.system(size: 14))
                    .textFieldStyle(.roundedBorder)
                smallButton("点文字") { tapText() }
                    .disabled(tapLabel.isEmpty || busy)
            }
        } header: {
            sectionHeader("手势", "hand.tap")
        }
    }

    // MARK: - ④ 键盘

    private var keyboardSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("要输入到当前焦点的文字", text: $typeText)
                    .font(.system(size: 14))
                    .textFieldStyle(.roundedBorder)
                smallButton("输入") { typeInto() }
                    .disabled(typeText.isEmpty || busy)
            }

            DisclosureGroup("按占位符填字") {
                VStack(spacing: 8) {
                    TextField("输入框占位符（如「搜索」）", text: $fillPlaceholder)
                        .font(.system(size: 13))
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        TextField("要填的内容", text: $fillText)
                            .font(.system(size: 13))
                            .textFieldStyle(.roundedBorder)
                        Toggle("回车", isOn: $pressEnter)
                            .labelsHidden()
                    }
                    HStack {
                        Text("开启后填完自动按回车")
                            .font(XType.section).foregroundColor(.secondary)
                        Spacer()
                        smallButton("点输入框并填写") { fillByPlaceholder() }
                            .disabled(fillPlaceholder.isEmpty || fillText.isEmpty || busy)
                    }
                }
                .padding(.top, 6)
            }

            HStack(spacing: 10) {
                keyButton("主屏", "home")
                keyButton("返回", "back")
                keyButton("回车", "enter")
            }
        } header: {
            sectionHeader("键入与按键", "keyboard")
        } footer: {
            Text("「输入」只发给当前焦点：先在目标 App 里点一下输入框。按键走 ControlAgent 的 home/back/enter。")
                .font(XType.section)
        }
    }

    // MARK: - ⑤ 结果

    @ViewBuilder
    private var resultSection: some View {
        if !lastAction.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: lastFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(lastFailed ? .red : .green)
                        Text(lastAction).font(.subheadline.weight(.medium))
                        Spacer()
                        Button {
                            UIPasteboard.general.string = lastResult
                            toast = "已复制结果"
                        } label: {
                            Image(systemName: "doc.on.doc").font(XType.note)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    if lastFailed {
                        Text(lastResult)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        DisclosureGroup("查看返回数据") {
                            Text(lastResult)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                        .font(XType.note)
                        .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                sectionHeader("最近一次", "doc.text.magnifyingglass")
            }
        }
    }

    // MARK: - 小组件

    private func sectionHeader(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(title)
        }
    }

    private func numField(_ ph: String, _ binding: Binding<String>) -> some View {
        TextField(ph, text: binding)
            .font(.system(size: 13, design: .monospaced))
            .keyboardType(.numbersAndPunctuation)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 64)
    }

    private func smallButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.tertiarySystemFill)))
                .foregroundColor(.primary)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func swipeArrow(_ icon: String, _ dir: String) -> some View {
        Button {
            swipeDir(dir)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.tertiarySystemFill)))
                .foregroundColor(.primary)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(busy)
    }

    private func keyButton(_ title: String, _ key: String) -> some View {
        Button {
            run(["command": "key", "key": key], "按键 \(title)")
        } label: {
            Text(title)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.tertiarySystemFill)))
                .foregroundColor(.primary)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(busy)
    }

    // MARK: - 动作

    /// v9.10：所有 control 调用统一走这里。
    /// dispatch 抛错时旧实现用 `try?` 吞成 [:]——控制台既看不到失败原因，又因为拿不到
    /// "error" 键而把失败当成功（"注入成功、实际没注入"就是这条路径）。现在把抛错、
    /// 顶层 ok=false 信封、嵌套 error 字典三种失败形态都折叠成同一个 "error" 字符串。
    private static func callControl(_ params: [String: Any]) -> [String: Any] {
        let raw: [String: Any]
        do {
            raw = try ToolRegistry.shared.dispatch(name: "control", params: params)
        } catch {
            return ["error": readable(error)]
        }
        return normalize(raw)
    }

    private static func readable(_ error: Error) -> String {
        if let e = error as? MCPError { return e.description }
        return "\(error)"
    }

    private static func normalize(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = (raw["data"] as? [String: Any]) ?? raw
        if (raw["ok"] as? Bool) == false {
            out["error"] = (raw["message"] as? String)
                ?? (raw["code"] as? String)
                ?? "调用失败"
            if let code = raw["code"] { out["code"] = code }
        }
        // error 可能是字符串，也可能是 {code, reason, next_step} 字典
        if let e = out["error"] as? String {
            if e.isEmpty { out.removeValue(forKey: "error") }
        } else if let e = out["error"] as? [String: Any] {
            out["error"] = (e["reason"] as? String) ?? (e["message"] as? String)
                ?? (e["code"] as? String) ?? "调用失败"
        } else if out["error"] != nil {
            out["error"] = String(describing: out["error"]!)
        }
        if out["error"] == nil, (out["ok"] as? Bool) == false {
            out["error"] = "调用失败"
        }
        return out
    }

    private func run(_ params: [String: Any], _ label: String, then: (([String: Any]) -> Void)? = nil) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.callControl(params)
            DispatchQueue.main.async {
                busy = false
                record(label, r)
                if let err = r["error"] as? String {
                    toast = "\(label)失败：\(err)"
                } else {
                    toast = "\(label) 完成"
                    then?(r)
                }
            }
        }
    }

    private func record(_ label: String, _ r: [String: Any]) {
        lastAction = label
        lastFailed = (r["error"] as? String) != nil
        lastResult = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: r)
    }

    private func reloadTargetName() {
        if let app = AppCatalog.find(bundleId), !app.name.isEmpty {
            appName = app.name
        }
    }

    private func injectAndLaunch() {
        guard !bundleId.isEmpty else { return }
        UserDefaults.standard.set(bundleId, forKey: Self.bundleKey)
        injecting = true
        statusText = "正在注入…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.callControl(["command": "inject", "bundle_id": bundleId])
            DispatchQueue.main.async {
                record("注入 \(bundleId)", r)
                if let err = r["error"] as? String {
                    injecting = false
                    statusText = "未连接"
                    toast = "注入失败：\(err)"
                    return
                }
                // v9.10：注入接口如实返回 injected —— 没成功就不打开 App、不报"完成"
                if let injected = r["injected"] as? Bool, injected == false {
                    injecting = false
                    statusText = "未连接"
                    toast = "注入未生效，App 未改动"
                    return
                }
                toast = "注入完成，正在打开 \(appName.isEmpty ? bundleId : appName)"
                awaitingAgent = true
                autoChecksLeft = 3
                DispatchQueue.global(qos: .userInitiated).async {
                    let res = ProcessHelper.launchApp(bundleId: bundleId)
                    DispatchQueue.main.async {
                        injecting = false
                        if !res.0 {
                            toast = "注入成功，但打开 App 失败：\(res.1)"
                        }
                        // 等 ControlAgent 起来（约 1.5s）再查一次状态
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { checkStatus() }
                    }
                }
            }
        }
    }

    private func checkStatus() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.callControl(["command": "status"])
            DispatchQueue.main.async {
                busy = false
                connected = (r["connected"] as? Bool) ?? false
                if let p = r["control_path"] as? [String: Any] {
                    let prefer = (p["prefer"] as? String) ?? ""
                    controlPath = prefer.isEmpty ? "" : "\(prefer) 路径"
                } else if let path = r["control_path"] as? String {
                    controlPath = path
                }
                if connected {
                    awaitingAgent = false
                    autoChecksLeft = 0
                    let bid = (r["bundle_id"] as? String) ?? (r["app"] as? String) ?? ""
                    statusText = bid.isEmpty ? "已连接 ControlAgent" : "已连接 · \(bid)"
                } else if awaitingAgent && autoChecksLeft > 0 {
                    // 刚注入完的窗口期：ControlAgent 还没监听，等下一轮复查，不判定失败
                    autoChecksLeft -= 1
                    let waitReason = (r["error"] as? String) ?? ""
                    statusText = waitReason.isEmpty
                        ? "等待 ControlAgent 连接…"
                        : "等待 ControlAgent 连接…（\(waitReason)）"
                    if autoChecksLeft > 0 {
                        let delay: Double = autoChecksLeft == 2 ? 1.5 : 2.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { checkStatus() }
                    } else {
                        awaitingAgent = false
                        statusText = "已注入但未连上：确认目标 App 已打开（或 App 启动即崩溃），再点一次状态"
                    }
                } else {
                    awaitingAgent = false
                    // v9.10：未连接是"未连接"，不是失败 toast——只是把原因写进状态行
                    statusText = (r["error"] as? String) ?? "未连接（先注入并打开目标 App）"
                }
            }
        }
    }

    private func loadTree() {
        treeLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var params: [String: Any] = ["command": "ui_tree"]
            if !bundleId.isEmpty { params["bundle_id"] = bundleId }
            let r = Self.callControl(params)
            let items = GhostRunner.tappables(r)
            let sig = GhostRunner.screenSignature(r)
            DispatchQueue.main.async {
                treeLoading = false
                record("读取界面元素", r)
                if let err = r["error"] as? String {
                    treeNote = "读取失败"
                    tappables = []
                    toast = "读取失败：\(err)"
                } else {
                    tappables = items
                    treeSignature = sig
                    treeNote = items.isEmpty ? "读到了，但没有可点元素" : "\(items.count) 个可点元素"
                    toast = "界面已刷新"
                    if let injected = r["injection_suspected"] as? Bool, injected {
                        toast = "注意：界面文案含疑似提示注入文本（已按数据处理）"
                    }
                }
            }
        }
    }

    private func screenshot() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var params: [String: Any] = ["command": "screenshot"]
            if !bundleId.isEmpty { params["bundle_id"] = bundleId }
            let r = Self.callControl(params)
            let path = (r["path"] as? String) ?? ""
            let img = path.isEmpty ? nil : UIImage(contentsOfFile: path)
            DispatchQueue.main.async {
                busy = false
                record("截图", r)
                if let err = r["error"] as? String {
                    toast = "截图失败：\(err)"
                } else {
                    shotPath = path
                    shot = img
                    toast = img == nil ? "已截图，但读取图片失败（看路径）" : "已截图"
                }
            }
        }
    }

    private func saveShotToPhotos() {
        guard let img = shot else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        toast = "已保存到相册"
    }

    private func tapXY() {
        guard let x = Double(tapX), let y = Double(tapY) else { toast = "坐标要填数字"; return }
        run(["command": "tap", "x": x, "y": y], "点按 (\(Int(x)),\(Int(y)))")
    }

    private func tapElement(_ item: Tappable) {
        let size = UIScreen.main.bounds.size
        let x = item.cx * Double(size.width)
        let y = item.cy * Double(size.height)
        run(["command": "tap", "x": x, "y": y], "点元素「\(item.label)」")
    }

    private func swipe() {
        guard let x1 = Double(swX1), let y1 = Double(swY1),
              let x2 = Double(swX2), let y2 = Double(swY2) else { toast = "坐标要填数字"; return }
        run(["command": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2], "滑动")
    }

    private func swipeDir(_ dir: String) {
        let s = UIScreen.main.bounds.size
        let cx = Double(s.width) / 2, cy = Double(s.height) / 2
        let dx = Double(s.width) * 0.3, dy = Double(s.height) * 0.25
        var p: [String: Any] = ["command": "swipe"]
        switch dir {
        case "up":    p["x1"] = cx; p["y1"] = cy + dy; p["x2"] = cx; p["y2"] = cy - dy
        case "down":  p["x1"] = cx; p["y1"] = cy - dy; p["x2"] = cx; p["y2"] = cy + dy
        case "left":  p["x1"] = cx + dx; p["y1"] = cy; p["x2"] = cx - dx; p["y2"] = cy
        default:      p["x1"] = cx - dx; p["y1"] = cy; p["x2"] = cx + dx; p["y2"] = cy
        }
        run(p, "向\(dir == "up" ? "上" : dir == "down" ? "下" : dir == "left" ? "左" : "右")滑动")
    }

    private func tapText() {
        var p: [String: Any] = ["command": "tap_text", "text": tapLabel]
        if !bundleId.isEmpty { p["bundle_id"] = bundleId }
        run(p, "点文字「\(tapLabel)」")
    }

    private func typeInto() {
        run(["command": "type", "text": typeText], "输入到焦点")
    }

    private func fillByPlaceholder() {
        // v9.9：control type_text 只收 placeholder + text（回车由保证焦点后的 key 补发）
        var p: [String: Any] = ["command": "type_text", "placeholder": fillPlaceholder, "text": fillText]
        if !bundleId.isEmpty { p["bundle_id"] = bundleId }
        run(p, "填写「\(fillPlaceholder)」") { _ in
            if pressEnter {
                self.run(["command": "key", "key": "enter"], "回车确认")
            }
        }
    }
}
