import SwiftUI
import UIKit

/// v2.9.128：工作区文件浏览器——像文件夹一样点开
/// 懒加载目录树（进子目录才加载）、类型图标、大小/时间、文本/plist/图片/二进制预览、
/// 搜索过滤、复制路径、分享、删除（确认）、新建文件夹
struct WorkspaceBrowserView: View {
    /// 每层目录一个入口，NavigationStack push 子目录
    struct DirEntry: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let name: String
    }

    /// v6.4.8：模态呈现（聊天框的工作区 sheet）时的关闭回调——非 nil 则工具栏显示"完成"按钮。
    /// 之前聊天框直接用 sheet{ WorkspaceBrowserView() } 且没包 NavigationView →
    /// 没有导航栏，导致"上一级/上传/新建"都不显示、也没有返回入口（用户实测反馈）。
    var onClose: (() -> Void)? = nil

    @State private var currentPath: String = Workspace.root.path
    @State private var query = ""
    @State private var items: [FileItem] = []
    @State private var previewItem: FileItem?
    @State private var confirmDelete: FileItem?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var toast: String?
    // v6.4.4：上传用的 document picker delegate（需强引用，否则点击无回调）
    @State private var importDelegate: WorkspaceImportDelegate?
    // v9：顶部双 Tab——文件 / 工具（ZStack 保活，切换不销毁另一侧）
    @State private var tab = 0

    struct FileItem: Identifiable, Hashable {
        let id = UUID()
        let path: String
        let name: String
        let isDir: Bool
        let size: Int
        let mtime: Date
        var note: String? = nil   // v2.9.292：目录中文用途说明
    }

    /// v2.9.292：已知目录的中文用途说明（给人看的）
    static let dirNotes: [String: String] = [
        "audit": "审计日志",
        "control_shots": "远程控制截图",
        "crash": "崩溃日志",
        "decrypted": "解密(砸壳)产物",
        "downloads": "下载文件",
        "duplicates": "重复文件",
        "logs": "运行日志",
        "macros": "宏/脚本",
        "network_capture": "抓包数据",
        "plugins": "插件",
        "projects": "编译项目",
        "reports": "分析报告",
        "uploads": "用户上传附件",
        "screenshots": "截图",
        "tweaks": "注入插件(dylib)",
        "tool_spill": "工具大输出",
        "backup": "备份",
        "tmp": "临时文件",
        "deb": "deb 包缓存"
    ]

    /// v6.4.4：返回上一级
    private func goUp() {
        let root = Workspace.root.path
        guard currentPath != root else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        currentPath = parent.hasPrefix(root) ? parent : root
    }

    /// v6.4.4：是否压缩包（bsdtar 可解：zip/tar/gz/tgz）
    static func isArchive(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.hasSuffix(".zip") || n.hasSuffix(".tar") || n.hasSuffix(".tar.gz")
            || n.hasSuffix(".tgz") || n.hasSuffix(".gz")
    }

    /// v6.4.4：上传——从"文件"App 选择（asCopy）后复制进当前目录
    private func importFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        let cur = currentPath
        let delegate = WorkspaceImportDelegate { urls in
            var ok = 0
            for u in urls {
                let dst = cur + "/" + u.lastPathComponent
                do {
                    if FileManager.default.fileExists(atPath: dst) {
                        try FileManager.default.removeItem(atPath: dst)
                    }
                    try FileManager.default.copyItem(at: u, to: URL(fileURLWithPath: dst))
                    ok += 1
                } catch { /* 单个失败不影响其它 */ }
            }
            self.toast = "已上传 \(ok)/\(urls.count) 个文件"
            self.reload()
        }
        importDelegate = delegate
        picker.delegate = delegate
        Self.topVC()?.present(picker, animated: true)
    }

    /// v6.4.4：下载——存储到"文件"App（复用 ShareCenter 的导出选择器）
    private func exportToFiles(_ item: FileItem) {
        ShareCenter.shared.saveToFiles(URL(fileURLWithPath: item.path))
    }

    /// v6.4.5：解压到同名目录。
    /// 主路：内置原生 bsdtar（libarchive，Mach-O）。若该二进制在本机被 AMFI 拒
    /// （实测 posix_spawn: Bad executable），**回退到内置原生 python3**
    /// （Python 自带 zipfile/tarfile/gzip，且 python3 在本机已验证可执行）。
    private func extract(_ item: FileItem) {
        let dest = currentPath + "/" + (item.name as NSString).deletingPathExtension
        try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)

        let bt = Bundle.main.bundlePath + "/bin/bsdtar"
        if FileManager.default.isExecutableFile(atPath: bt) {
            let res = BuildRunner.shared.run(executable: bt, args: ["xf", item.path, "-C", dest], env: [:], timeout: 180)
            let out = res.stdout + res.stderr
            if res.exitCode == 0 && !out.lowercased().contains("error") {
                toast = "已解压到 \((dest as NSString).lastPathComponent)"
                reload()
                return
            }
            // 仅在"无法执行"时回退（其它错误说明 bsdtar 跑了但失败，直接报错更清楚）
            let spawnFailed = res.exitCode == -1 || out.lowercased().contains("posix_spawn")
                || out.lowercased().contains("bad executable")
            if !spawnFailed {
                toast = "解压失败(\(res.exitCode))：" + String(out.suffix(90))
                reload()
                return
            }
        }

        // 回退：进程内 CPython（zipfile/tarfile/gzip）——不再 spawn bin/python3
        let script = """
        import sys, os, zipfile, tarfile, gzip, shutil
        src, dst = sys.argv[1], sys.argv[2]
        os.makedirs(dst, exist_ok=True)
        low = src.lower()
        if low.endswith('.zip'):
            with zipfile.ZipFile(src) as z:
                z.extractall(dst)
        elif low.endswith(('.tar', '.tar.gz', '.tgz', '.tar.bz2', '.tar.xz')):
            with tarfile.open(src) as t:
                t.extractall(dst)
        elif low.endswith('.gz'):
            out = os.path.join(dst, os.path.basename(src)[:-3])
            with gzip.open(src, 'rb') as f, open(out, 'wb') as o:
                shutil.copyfileobj(f, o)
        else:
            sys.exit('unsupported archive type')
        print('EXTRACT_OK')
        """
        let wrapped = "import sys as _s; _s.argv = [\"-c\", "
            + PythonInProcessBridge.pyStringLiteral(item.path) + ", "
            + PythonInProcessBridge.pyStringLiteral(dest) + "]\n" + script
        var out2 = ""
        do {
            let r = try PyEvalTool().invoke(["command": "eval", "code": wrapped, "limit": 200_000])
            out2 = (r["stdout"] as? String) ?? ""
        } catch {
            out2 = "进程内解释器不可用：" + String(describing: error)
        }
        if out2.contains("EXTRACT_OK") {
            toast = "已解压到 \((dest as NSString).lastPathComponent)"
        } else {
            toast = "解压失败：" + String(out2.suffix(90))
        }
        reload()
    }

    /// 顶层 VC（用于 present document picker）
    static func topVC() -> UIViewController? {
        var vc = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    /// v3.0.90：目录备注——先精确匹配，再模糊匹配（动态名字）
    static func noteForDir(_ name: String) -> String? {
        // 精确匹配
        if let note = dirNotes[name] { return note }
        // 模糊匹配（动态前缀）
        if name.hasPrefix("replace_tmp_") { return "替换临时文件（注入用）" }
        if name.hasPrefix("crash_repro_") { return "崩溃复现" }
        if name.hasPrefix("static_inject") { return "静态注入临时目录" }
        if name.hasSuffix(".db") { return "数据库文件" }
        if name.hasSuffix(".plist") { return "配置文件" }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                icon: "folder",
                title: L10n.t("page_workspace"),
                subtitle: currentPath.replacingOccurrences(of: Workspace.root.path, with: "Workspace"),
                colors: [.tmIndigo, .blue]
            )
            .padding(.vertical, 8)

            // v9：文件 / 工具 双 Tab（对应 Kelivo WorkspaceDetailTabs）
            WorkspaceDetailTabs(index: $tab)

            WorkspaceTabsContainer(tab: $tab,
                                   files: filesPane,
                                   tools: WorkspaceToolsPane())
        }
        .background(DoubaoTheme.bg)
        .navigationTitle(L10n.t("page_workspace"))
        .deepseekPage()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                if let onClose = onClose {
                    Button("完成") { onClose() }
                }
                Button { goUp() } label: { Label("上一级", systemImage: "arrow.up") }
                    .disabled(currentPath == Workspace.root.path || tab != 0)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { importFiles() } label: { Label("上传", systemImage: "square.and.arrow.down") }
                    .disabled(tab != 0)
                Button { showNewFolder = true } label: { Label("新建", systemImage: "folder.badge.plus") }
                    .disabled(tab != 0)
            }
        }
        .onAppear { reload() }
        .onChange(of: currentPath) { _ in reload() }
        .sheet(item: $previewItem) { item in
             FilePreviewView(item: item)
        }
        .alert("删除确认", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("取消", role: .cancel) { confirmDelete = nil }
            Button("删除", role: .destructive) {
                if let item = confirmDelete {
                    do {
                        try FileManager.default.removeItem(atPath: item.path)
                        toast = "已删除 \(item.name)"
                    } catch {
                        toast = "删除失败：\(error.localizedDescription)"
                    }
                    confirmDelete = nil
                    reload()
                }
            }
        } message: {
            Text("确定删除 \(confirmDelete?.name ?? "")？此操作不可恢复。")
        }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("名称", text: $newFolderName)
            Button("创建") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    let dir = currentPath + "/" + name
                    do {
                        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                        toast = "已创建 \(name)"
                    } catch {
                        toast = "创建失败：\(error.localizedDescription)"
                    }
                    newFolderName = ""
                    reload()
                }
            }
            Button("取消", role: .cancel) { newFolderName = "" }
        }
        // v4.3.41：文件分享统一走系统分享页（SharePresenter.present）
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray5).opacity(0.95))
                    .clipShape(Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    /// v9：文件 Tab 的内容（搜索 / 面包屑 / 列表）
    private var filesPane: some View {
        VStack(spacing: 0) {

            // 搜索
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("搜索文件名", text: $query)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            // 面包屑
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    Button { jump(to: Workspace.root.path) } label: { crumb("Workspace", bold: currentPath == Workspace.root.path) }
                    let rel = currentPath.replacingOccurrences(of: Workspace.root.path, with: "")
                    let parts = rel.split(separator: "/").filter { !$0.isEmpty }
                    ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(.secondary)
                        let target = Workspace.root.path + "/" + parts[0...(idx)].joined(separator: "/")
                        Button { jump(to: String(target)) } label: { crumb(String(part), bold: idx == parts.count - 1) }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 4)

            if items.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_102"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filtered) { item in
                        Button {
                            if item.isDir {
                                jump(to: item.path)
                            } else {
                                previewItem = item
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: iconName(item))
                                    .font(.system(size: 22))
                                    .foregroundColor(item.isDir ? .tmIndigo : iconColor(item))
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    // v2.9.292：目录显示递归总大小 + 中文用途说明
                                    if item.isDir {
                                        Text("\(bytesLabel(item.size)) · \(timeString(item.mtime))\(item.note.map { " · \($0)" } ?? "")")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    } else {
                                        Text("\(bytesLabel(item.size)) · \(timeString(item.mtime))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if !item.isDir {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .contextMenu {
                            Button { copyPath(item.path) } label: { Label("复制路径", systemImage: "doc.on.doc") }
                            if !item.isDir {
                                // v6.4.4：下载——存储到"文件"App
                                Button { exportToFiles(item) } label: { Label("存储到文件（下载）", systemImage: "square.and.arrow.up") }
                                // v6.4.4：解压——内置原生 bsdtar（Mach-O libarchive），不经 x86 模拟器
                                if Self.isArchive(item.name) {
                                    Button { extract(item) } label: { Label("解压到此处", systemImage: "archivebox") }
                                }
                                // v4.3.44：文件分享走 QuickLook 中间层（menuShare 低版本分支设 binding）
                                SharePresenter.menuShare(url: URL(fileURLWithPath: item.path))
                            }
                            Button(role: .destructive) { confirmDelete = item } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .deepseekList()
                .refreshable { reload() }
            }
        }
    }

    private var filtered: [FileItem] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func crumb(_ name: String, bold: Bool) -> some View {
        Text(name)
            .font(.caption2)
            .fontWeight(bold ? .semibold : .regular)
            .foregroundColor(bold ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(Capsule())
    }

    private func jump(to path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        currentPath = path
    }

    private func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: currentPath),
                                                includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url -> FileItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let isDir = values?.isDirectory else { return nil }
            let name = url.lastPathComponent
            return FileItem(path: url.path,
                            name: name,
                            isDir: isDir,
                            size: isDir ? 0 : (values?.fileSize ?? 0),
                            mtime: values?.contentModificationDate ?? Date.distantPast,
                            note: isDir ? Self.noteForDir(name) : nil)
        }
        .sorted { $0.isDir && !$1.isDir ? true : (!$0.isDir && $1.isDir ? false : $0.name.localizedStandardCompare($1.name) == .orderedAscending) }
        // v2.9.292：目录总大小异步递归统计（主线程刷新，避免大目录卡 UI）
        for idx in items.indices where items[idx].isDir {
            let dirPath = items[idx].path
            let itemId = items[idx].id
            DispatchQueue.global(qos: .userInitiated).async {
                let total = Self.recursiveSize(dirPath)
                DispatchQueue.main.async {
                    guard let i = self.items.firstIndex(where: { $0.id == itemId }) else { return }
                    let old = self.items[i]
                    self.items[i] = FileItem(path: old.path,
                                             name: old.name,
                                             isDir: true,
                                             size: total,
                                             mtime: old.mtime,
                                             note: old.note)
                }
            }
        }
    }

    /// v2.9.292：递归统计目录总大小（限制 50000 个文件防卡死）
    static func recursiveSize(_ path: String) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total = 0
        var count = 0
        while let file = enumerator.nextObject() as? String, count < 50000 {
            count += 1
            let full = (path as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                if let attrs = try? fm.attributesOfItem(atPath: full) {
                    total += (attrs[.size] as? Int) ?? 0
                }
            }
        }
        return total
    }

    private func copyPath(_ path: String) {
        UIPasteboard.general.string = path
        toast = "已复制路径"
    }

    private func iconName(_ item: FileItem) -> String {
        if item.isDir { return "folder.fill" }
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "dylib", "framework", "tbd": return "gearshape.2"
        case "ipa", "deb", "zip", "tar", "gz", "xz", "zst", "lz4": return "archivebox"
        case "plist", "json", "yaml", "yml", "xml": return "curlybraces"
        case "log", "txt", "md": return "doc.text"
        case "swift", "m", "mm", "h", "c", "cpp", "py", "sh": return "chevron.left.forwardslash.chevron.right"
        case "pdf": return "doc.richtext"
        case "db", "sqlite", "sqlite3": return "cylinder.split.1x2"
        default: return "doc"
        }
    }

    private func iconColor(_ item: FileItem) -> Color {
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "dylib", "framework": return .blue
        case "ipa", "deb": return .orange
        case "plist", "json": return .purple
        case "png", "jpg", "jpeg": return .green
        case "log", "txt", "md": return .secondary
        case "db", "sqlite", "sqlite3": return .teal
        default: return .secondary
        }
    }

    private func bytesLabel(_ b: Int) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: d)
    }
}

/// 文件预览：文本/plist/JSON 格式化、图片、二进制 hex 头
struct FilePreviewView: View {
    let item: WorkspaceBrowserView.FileItem
    @State private var text = ""
    @State private var mode: Mode = .loading
    @State private var image: UIImage?

    enum Mode {
        case loading, text, image, binary, tooLarge
    }

    var body: some View {
        Group {
            switch mode {
            case .loading:
                ProgressView("读取中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .text:
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .image:
                if let image = image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    }
                }
            case .binary:
                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .tooLarge:
                VStack(spacing: 10) {
                    Image(systemName: "doc")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(L10n.t("ui_167", bytesLabel(item.size)))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("仍要读取") { loadText(force: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { UIPasteboard.general.string = item.path } label: { Label("复制路径", systemImage: "doc.on.doc") }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let imgExts = ["png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff"]
        if imgExts.contains(ext) {
            // v2.9.292：大图/HEIC 用 ImageIO 降采样读取，避免 UIImage(contentsOfFile:)
            // 对超大图/特殊格式失败导致预览空白
            if let img = Self.downsampledImage(at: item.path) {
                image = img
                mode = .image
                return
            }
            text = "图片加载失败（格式或尺寸不支持）：\(item.name)"
            mode = .binary
            return
        }
        if item.size > 64 * 1024 {
            mode = .tooLarge
            return
        }
        loadText(force: false)
    }

    /// v2.9.292：ImageIO 降采样读图（目标最长边 1600px，兼容 HEIC/大图）
    static func downsampledImage(at path: String, maxDim: CGFloat = 1600) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func loadText(force: Bool) {
        if force {
            // 大文件只读前 64KB
            guard let handle = FileHandle(forReadingAtPath: item.path) else { return }
            defer { try? handle.close() }
            let data = handle.readData(ofLength: 64 * 1024)
            render(data)
        } else {
            guard let data = FileManager.default.contents(atPath: item.path) else {
                mode = .binary
                text = "无法读取文件"
                return
            }
            render(data)
        }
    }

    private func render(_ data: Data) {
        // 判文本：前 512 字节无可视控制字符
        let sample = data.prefix(512)
        let isText = sample.allSatisfy { b in
            b == 9 || b == 10 || b == 13 || (b >= 32 && b != 127)
        } || sample.isEmpty
        let ext = (item.name as NSString).pathExtension.lowercased()
        if isText {
            var s = String(data: data, encoding: .utf8) ?? "（非 UTF-8，按二进制显示）"
            if ext == "plist" {
                if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                    s = pretty(plist)
                }
            } else if ext == "json" {
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                   let str = String(data: pretty, encoding: .utf8) {
                    s = str
                }
            }
            text = s
            mode = .text
        } else {
            // 二进制 hex：前 512 字节
            var lines: [String] = []
            let head = data.prefix(512)
            for (i, byte) in head.enumerated() {
                if i % 16 == 0 {
                    lines.append(String(format: "%08x  ", i))
                }
                lines[lines.count - 1] += String(format: "%02x ", byte)
                if i % 16 == 15 { lines.append("") }
            }
            text = "文件大小：\(bytesLabel(data.count))\n\n" + lines.joined(separator: "\n")
            mode = .binary
        }
    }

    private func pretty(_ obj: Any) -> String {
        if let dict = obj as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: d, encoding: .utf8) {
            return s
        }
        return String(describing: obj)
    }

    private func bytesLabel(_ b: Int) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }
}

/// 系统分享（复用 ChatView.ShareSheet，此处不再定义）


/// v6.4.4：工作区上传的文件选择回调（UIDocumentPickerDelegate 需 NSObject 实现）
final class WorkspaceImportDelegate: NSObject, UIDocumentPickerDelegate {
    private let onPick: ([URL]) -> Void
    init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }
}
