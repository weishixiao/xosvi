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

                Section(header: SettingSectionHeader(title: L10n.t("settings_sec_sessions"))) {
                    // v10.5：会话导出的总入口——抽屉里是单会话，这里是把全部会话拼成一份存档
                    SettingRowButton(
                        title: L10n.t("btn_export_all"),
                        subtitle: L10n.t("btn_export_all_sub"),
                        icon: "square.and.arrow.up",
                        color: .blue
                    ) {
                        ConversationExport.presentAll()
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

