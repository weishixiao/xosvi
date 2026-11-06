import SwiftUI
import UniformTypeIdentifiers

struct BuildView: View {
    @State private var token = ""

    var body: some View {
        CompatNav {
            List {
                Section(header: SettingSectionHeader(title: "编译模式")) {
                    SettingRowButton(
                        title: "生成编译令牌",
                        subtitle: "用于验证本地编译请求",
                        icon: "key.fill",
                        color: .orange
                    ) {
                        if let result = try? ToolRegistry.shared.dispatch(name: "build.runner.token", params: ["action": "generate"]),
                           let t = result["token"] as? String {
                            token = t
                        }
                    }
                    if !token.isEmpty {
                        Section {
                            Text(token)
                                .font(.system(.body, design: .monospaced))
                                .padding(.vertical, 4)
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "项目模板")) {
                    SettingRowButton(
                        title: "生成 Tweak 项目模板",
                        subtitle: "在工作区创建 MyTweak 模板",
                        icon: "doc.badge.plus",
                        color: .blue
                    ) {
                        _ = try? ToolRegistry.shared.dispatch(name: "project.generate_tweak", params: ["name": "MyTweak"])
                    }
                }

                Section(header: SettingSectionHeader(title: "说明")) {
                    Text(L10n.t("ui_125"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
            .navigationTitle("编译")
        }
        .navigationViewStyle(.stack)
    }
}

struct SystemCapabilitiesView: View {
    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "cpu.fill",
                title: L10n.t("page_capabilities"),
                subtitle: L10n.t("page_capabilities_sub"),
                colors: [.tmIndigo, .purple]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: "系统能力")) {
                    capRow("通讯录搜索", "contacts.search", "person.crop.circle", .blue)
                    capRow("日历事件", "calendar.list", "calendar", .red)
                    capRow("提醒事项", "reminder.create", "checkmark.square", .green)
                    capRow("定位", "location.get", "location", .tmIndigo)
                    capRow("本地通知", "notification.send", "bell", .orange)
                    capRow("扫码识别", "scan.qr", "qrcode.viewfinder", .purple)
                    capRow("进程枚举", "process.list", "list.bullet", .gray)
                }

                Section(header: SettingSectionHeader(title: "说明")) {
                    Text(L10n.t("ui_143"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_capabilities"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func capRow(_ name: String, _ tool: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color)
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                Text(tool)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 工具权限策略
// v7.16.11：ToolPermissionPoliciesView 已按用户要求整块删除（入口 + 源码）。


// MARK: - 数据管理

struct DataManagementView: View {
    @State private var files: [WorkspaceItem] = []
    @State private var showingImporter = false

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "internaldrive.fill",
                title: L10n.t("page_data"),
                subtitle: L10n.t("page_data_sub"),
                colors: [.green, .tmTeal]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: "工作区")) {
                    LabeledRow(label: "路径", value: Workspace.root.path)
                    SettingRowButton(
                        title: "在会话工具中打开",
                        subtitle: "使用 artifact.* 读写",
                        icon: "folder",
                        color: .blue
                    ) {
                        AuditLog.shared.log("data.open_workspace", detail: Workspace.root.path)
                    }
                    SettingRowButton(
                        title: "清空工作区",
                        subtitle: "删除 Documents/wiki.qaq.xosvi/Workspace 下所有文件",
                        icon: "trash",
                        color: .red
                    ) {
                        try? FileManager.default.removeItem(at: Workspace.root)
                        Workspace.ensure()
                        refresh()
                    }
                }

                Section(header: SettingSectionHeader(title: "文件")) {
                    ForEach(files) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.body)
                                Text(item.size)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            try? FileManager.default.removeItem(at: files[i].url)
                        }
                        refresh()
                    }
                }

                Section(header: SettingSectionHeader(title: "导入")) {
                    SettingRowButton(
                        title: "导入文件到工作区",
                        subtitle: "选择外部文件复制到工作区",
                        icon: "doc.badge.plus",
                        color: .green
                    ) {
                        showingImporter = true
                    }
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
            .toolbar {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
            }
            .sheet(isPresented: $showingImporter) {
                DocumentImporter { url in
                    _ = try? FileManager.default.copyItem(at: url, to: Workspace.root.appendingPathComponent(url.lastPathComponent))
                    refresh()
                }
            }
            .onAppear(perform: refresh)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_data"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refresh() {
        Workspace.ensure()
        var items: [WorkspaceItem] = []
        let fm = FileManager.default
        if let enumerator = fm.enumerator(at: Workspace.root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if !isDir.boolValue {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    items.append(WorkspaceItem(name: url.lastPathComponent, size: byteString(size), url: url))
                }
            }
        }
        files = items.sorted { $0.name < $1.name }
    }

    private func byteString(_ bytes: Int) -> String {
        let b = Double(bytes)
        if b < 1024 { return "\(bytes) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        return String(format: "%.1f MB", b / (1024 * 1024))
    }
}

struct WorkspaceItem: Identifiable {
    var id = UUID()
    let name: String
    let size: String
    let url: URL
}

// MARK: - 文档导入器

struct DocumentImporter: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            urls.first.map(onPick)
        }
    }
}

// MARK: - 开发者指令编辑器（v9.9：列表页已移到 DeveloperInstructionsView.swift，这里只留编辑弹窗）

struct DevInstructionEditorView: View {
    enum Mode { case create, edit }
    let name: String
    let initialContent: String
    let mode: Mode

    @State private var title = ""
    @State private var content = ""
    @State private var keyboardHeight: CGFloat = 0
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            // v2.9.22：Form 里 TextEditor 滚动冲突/键盘遮挡导致"难往下滑"，
            // 改为 ScrollView + 大高度 TextEditor + 键盘高度避让
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: "指令名称")
                        TextField("如：我的工程规范", text: $title)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: "指令内容（Markdown）")
                        TextEditor(text: $content)
                            .frame(minHeight: 520)
                            .font(.system(.body, design: .monospaced))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color(.separator), lineWidth: 0.5)
                            )
                            .cornerRadius(10)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        SettingSectionHeader(title: "说明")
                        Text(L10n.t("ui_145"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // v3.3.0：隐藏标记说明——标记内的内容只给用户看，不注入 AI
                        Text("用 <!--用户可见--> ... <!--/用户可见--> 包住的段落只显示给你，不会注入 AI 请求（适合放“为什么有效”这类说明）")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    // v2.9.22：iOS14 兼容的收起键盘按钮
                    Button(action: hideKeyboard) {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard.chevron.compact.down")
                            Text(L10n.t("ui_74"))
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }
                .padding()
                // 键盘弹出时底部留白，确保能滚到末尾
                .padding(.bottom, keyboardHeight > 0 ? keyboardHeight + 16 : 24)
            }
            .navigationTitle(mode == .create ? "新建指令" : "编辑指令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { presentationMode.wrappedValue.dismiss() }
                }
                // v2.9.24：编辑时一键复制当前内容
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: copyContent) {
                            Image(systemName: "doc.on.doc")
                        }
                        Button("保存") { save() }
                    }
                }
            }
            .onAppear {
                if mode == .edit && title.isEmpty {
                    title = name
                    content = initialContent
                }
                observeKeyboard()
            }
        }
        .navigationViewStyle(.stack)
    }

    /// v2.9.22：监听键盘高度（iOS14 兼容，不用 scrollDismissesKeyboard）
    private func observeKeyboard() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            if let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue.height {
                keyboardHeight = h
            }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { _ in
            keyboardHeight = 0
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mode == .create {
            DeveloperInstructionStore.shared.create(name: trimmed, content: content)
        } else {
            DeveloperInstructionStore.shared.update(name: trimmed, content: content)
        }
        presentationMode.wrappedValue.dismiss()
    }

    /// v2.9.24：编辑器一键复制当前内容
    private func copyContent() {
        UIPasteboard.general.string = content
    }
}
// MARK: - Webhooks 设置

struct WebhooksView: View {
    @State private var url = ""
    @State private var secret = ""
    @State private var events = ""
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            // v2.9.77：美化头部
            PageHeader(
                icon: "link.circle.fill",
                title: L10n.t("page_webhooks"),
                subtitle: L10n.t("page_webhooks_sub"),
                colors: [.purple, .tmIndigo]
            )
            .padding(.vertical, 8)

            List {
                Section(header: SettingSectionHeader(title: "端点")) {
                    editorRow("URL", text: $url, placeholder: "https://example.com/webhook")
                    editorRow("Secret", text: $secret, placeholder: "可选签名密钥")
                    editorRow("事件", text: $events, placeholder: "audit,tool_call")
                }

                Section(header: SettingSectionHeader(title: "操作")) {
                    Button(action: save) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                            Text(L10n.t("ui_28"))
                                .foregroundColor(.blue)
                        }
                    }
                    Button(action: test) {
                        HStack {
                            Image(systemName: "paperplane")
                            Text(L10n.t("ui_39"))
                                .foregroundColor(.blue)
                            Spacer()
                        }
                    }
                }

                if !status.isEmpty {
                    Section(header: SettingSectionHeader(title: "状态")) {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        .deepseekList()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.t("page_webhooks"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func editorRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
        }
    }

    private func save() {
        UserDefaults.standard.set(["url": url, "secret": secret, "events": events], forKey: "xosvi.webhook")
        status = "已保存"
    }

    private func test() {
        guard let target = URL(string: url), !url.isEmpty else {
            status = "URL 无效"
            return
        }
        var req = URLRequest(url: target, timeoutInterval: 15)
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["event": "test", "timestamp": ISO8601DateFormatter().string(from: Date()), "app": "Xosvi"] as [String: Any]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    status = "失败: \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse {
                    status = "HTTP \(http.statusCode)"
                } else {
                    status = "已发送"
                }
            }
        }.resume()
    }
}

// MARK: - Agents 与 Skills

struct AgentsAndSkillsView: View {
    @State private var skills: [SkillItem] = []
    @State private var agents: [AgentItem] = []
    @State private var showSkillEditor = false
    @State private var showAgentEditor = false

    var body: some View {
        List {
            Section {
                XHeroHeader(icon: "person.2",
                            title: L10n.t("page_agents"),
                            subtitle: L10n.t("page_agents_sub"))
            }

            Section(header: SettingSectionHeader(title: "Skills")) {
                    if skills.isEmpty {
                        Text(L10n.t("ui_87"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(skills) { s in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                        .font(.body)
                                        .foregroundColor(SkillStore.shared.isEnabled(s.name) ? .primary : .secondary)
                                    Text(s.summary.isEmpty ? s.instruction : s.summary)
                                        .font(XType.note)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { SkillStore.shared.isEnabled(s.name) },
                                    set: { SkillStore.shared.setEnabled(s.name, $0); reload() }
                                ))
                                .labelsHidden()
                                .accentColor(DoubaoTheme.accent)
                                .frame(width: 46)
                                Button(action: {
                                    SkillStore.shared.delete(named: s.name)
                                    reload()
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "Agents")) {
                    if agents.isEmpty {
                        Text(L10n.t("ui_91"))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(agents) { a in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name)
                                        .font(.body)
                                    Text(a.systemPrompt)
                                        .font(XType.note)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section(header: SettingSectionHeader(title: "说明")) {
                    Text(L10n.t("ui_67"))
                        .font(XType.note)
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_2"))
                        .font(XType.note)
                        .foregroundColor(.secondary)
                }
            }
            .xGroupedPage()
            .onAppear {
                SkillStore.shared.seedIfEmpty()
                reload()
            }
            .toolbar {
                Button(action: { showSkillEditor = true }) { Image(systemName: "plus.square.on.square") }
                Button(action: { showAgentEditor = true }) { Image(systemName: "person.badge.plus") }
            }
            .sheet(isPresented: $showSkillEditor) { SkillEditorView() }
            .sheet(isPresented: $showAgentEditor) { AgentEditorView() }
        .navigationTitle(L10n.t("page_agents"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reload() {
        skills = SkillStore.shared.all
        let kb = URL(fileURLWithPath: XDirs.knowledgeBase, isDirectory: true)
        if let data = try? Data(contentsOf: kb.appendingPathComponent("agents.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            agents = json.map { AgentItem(name: $0["name"] ?? "", systemPrompt: $0["systemPrompt"] ?? "") }
        }
    }
}

struct AgentItem: Identifiable {
    var id = UUID()
    let name: String
    let systemPrompt: String
}
