import SwiftUI
import UniformTypeIdentifiers

// MARK: - v9.4：知识库设置页（本机导入 + 内置知识 + 联网检索，三合一）
//
// 分层策略：知识**不会全局注入** system prompt（只放一行索引声明），
// 由 knowledge.search 工具按需检索后作为工具结果返回——省 token 且命中精准。
//
// v9.4 改动：
//   1. 并入原「本机知识库」（KnowledgeBaseView）的导入能力——原来它写的是
//      Documents/KnowledgeBase/，而 knowledge.search 只读 Workspace/knowledge/，
//      所以导入的文件 AI 根本检索不到。现在两个入口合并，导入直接落到
//      KnowledgeStore.shared.dir，并且导入后立刻重建 FTS5 索引。
//   2. 增加「联网检索」开关：开启后 knowledge.search 在没有本地命中时会
//      自动调用 web.search 取回外部资料（用户要求"AI 运行时直接本地和联网获取知识"）。
//   3. PDF/JPG 等非文本文件提示先经 OCR，避免导进来一条也搜不到。

struct KnowledgeSettingsView: View {
    // v9.4：KnowledgeStore 不是 ObservableObject，用本地状态驱动列表刷新，避免 @ObservedObject 编译失败
    @ObservedObject private var search = SearchSettings.shared

    @State private var entryCount = 0
    @State private var builtAt = ""
    @State private var query = ""
    @State private var hits: [KnowledgeHit] = []
    @State private var fileHits: [String] = []
    @State private var searched = false
    @State private var showingImporter = false
    @State private var importNote = ""

    /// v9.4：联网检索开关（knowledge.search 无本地命中时回退 web.search）
    @AppStorage("knowledge.web_fallback") private var webFallback = true

    private var localFiles: [String] { KnowledgeStore.shared.list() }

    var body: some View {
        List {
            // MARK: 本机文件
            Section(header: Text("本机文件"),
                    footer: Text("导入的文本文件直接进入 AI 的检索范围（knowledge.search）。支持 Markdown / TXT / JSON / CSV / 代码；PDF 与图片请先用 OCR 转成文字再导入。")) {
                Button {
                    showingImporter = true
                } label: {
                    rowLabel("doc.badge.plus", "导入文件")
                }
                Button {
                    importFromWorkspace()
                } label: {
                    rowLabel("folder.badge.plus", "从工作区导入")
                }
                if !importNote.isEmpty {
                    Text(importNote).font(.caption).foregroundColor(MonoChat.subtext)
                }
                HStack { Text("已导入"); Spacer(); Text("\(localFiles.count) 个").foregroundColor(MonoChat.subtext) }
                ForEach(localFiles, id: \.self) { name in
                    HStack {
                        Text(name).font(.system(size: 14)).lineLimit(1)
                        Spacer()
                        Text("\((KnowledgeStore.shared.size(of: name) / 1024)) KB")
                            .font(.caption).foregroundColor(MonoChat.subtext)
                    }
                }
                .onDelete { idx in
                    for i in idx { KnowledgeStore.shared.delete(localFiles[i]) }
                    rebuild()
                }
            }

            // MARK: 内置知识
            Section(header: Text("内置知识")) {
                HStack { Text("条目数"); Spacer(); Text("\(entryCount)").foregroundColor(MonoChat.subtext) }
                HStack { Text("索引构建时间"); Spacer(); Text(builtAt.isEmpty ? "未构建" : builtAt).foregroundColor(MonoChat.subtext) }
                Button {
                    rebuild()
                } label: {
                    rowLabel("arrow.clockwise", "重建索引")
                }
            }

            // MARK: 联网检索
            Section(header: Text("联网检索"),
                    footer: Text("开启后，AI 在本地知识没有命中时会自动联网搜索补资料（走「联网搜索」里配置的服务商，免费必应/DDG 可直接用）。限流：同一问题 10 分钟内只联网一次。")) {
                Toggle(isOn: $webFallback) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地无命中时联网补充")
                        Text("当前服务商：\(search.selectedService?.displayName ?? "必应")")
                            .font(.caption).foregroundColor(MonoChat.subtext)
                    }
                }
                .accentColor(MonoChat.text)
            }

            // MARK: 试检索
            Section(header: Text("试检索"),
                    footer: Text("模拟 knowledge.search 的行为：先查内置包，再查本机文件。")) {
                TextField("输入关键词，如：权限被拒绝 / inject / runtime", text: $query)
                    .autocorrectionDisabled()
                    .onSubmit { doSearch() }
                Button { doSearch() } label: { rowLabel("magnifyingglass", "检索") }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if searched && hits.isEmpty && fileHits.isEmpty {
                    Text("无匹配条目。可换更具体的词（错误原文、工具名）。")
                        .font(.caption).foregroundColor(MonoChat.subtext)
                }
                ForEach(hits, id: \.id) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(h.title).font(.system(size: 14, weight: .medium))
                        Text(String(h.body.prefix(120)))
                            .font(.caption).foregroundColor(MonoChat.subtext).lineLimit(2)
                        if !h.appliesIf.isEmpty {
                            Text("applies_if: \(h.appliesIf.joined(separator: ", "))")
                                .font(.caption2).foregroundColor(MonoChat.subtext)
                        }
                    }
                    .padding(.vertical, 2)
                }
                ForEach(Array(fileHits.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 12, design: .monospaced))
                        .foregroundColor(MonoChat.secondaryText).lineLimit(3)
                }
            }

            // MARK: 说明
            Section(header: Text("说明")) {
                Text("知识不会全局注入上下文，由 knowledge.search 按需检索后作为工具结果返回。")
                    .font(.caption).foregroundColor(MonoChat.subtext)
                Text("自定义结构化条目放 Documents/Knowledge/custom/*.json（结构见内置包），导入后点「重建索引」。")
                    .font(.caption2).foregroundColor(MonoChat.subtext)
            }
        }
        .listStyle(.insetGrouped)
        .deepseekList()
        .listRowSeparator(.hidden)
        .navigationTitle("知识库")
        .onAppear(perform: refresh)
        .sheet(isPresented: $showingImporter) {
            DocumentImporter { url in
                importFile(at: url)
            }
        }
    }

    /// 行样式：与设置页圆框行同一套图标 + 文案
    private func rowLabel(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundColor(MonoChat.text)
                .frame(width: 26, alignment: .center)
            Text(title).foregroundColor(MonoChat.text)
            Spacer()
        }
    }

    // MARK: - 导入

    private func importFile(at url: URL) {
        // 安全作用域：iCloud/文件中转来的 URL 必须先取权限
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let textExts: Set<String> = ["md", "markdown", "txt", "json", "csv", "log", "swift",
                                     "m", "h", "c", "cpp", "py", "sh", "js", "ts", "yml", "yaml", "xml", "html"]
        guard textExts.contains(ext) else {
            importNote = "「\(url.lastPathComponent)」不是文本格式，导入后检索不到。请先转成文本（PDF/图片先用 OCR）。"
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            importNote = "读取失败：文件不是 UTF-8 文本，或为空。"
            return
        }
        KnowledgeStore.shared.ensure()
        let dst = KnowledgeStore.shared.dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        do {
            try text.write(to: dst, atomically: true, encoding: .utf8)
            importNote = "已导入「\(url.lastPathComponent)」（\(text.count) 字），AI 现在可以检索到。"
            rebuild()
        } catch {
            importNote = "写入失败：\(error.localizedDescription)"
        }
        refresh()
    }

    private func importFromWorkspace() {
        let fm = FileManager.default
        var count = 0
        if let en = fm.enumerator(at: Workspace.root, includingPropertiesForKeys: nil,
                                  options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                // 跳过知识库自身目录，避免自己导自己
                if u.path.contains("/knowledge/") { continue }
                let ext = u.pathExtension.lowercased()
                guard ["md", "txt", "json", "csv", "log"].contains(ext) else { continue }
                guard let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                KnowledgeStore.shared.ensure()
                let dst = KnowledgeStore.shared.dir.appendingPathComponent(u.lastPathComponent)
                if (try? text.write(to: dst, atomically: true, encoding: .utf8)) != nil { count += 1 }
            }
        }
        importNote = count == 0 ? "工作区里没有可导入的文本文件。" : "从工作区导入 \(count) 个文本文件。"
        if count > 0 { rebuild() }
        refresh()
    }

    // MARK: - 检索与索引

    private func rebuild() {
        KnowledgeIndex.shared.rebuild(packs: KnowledgeLoader.loadAll())
        refresh()
    }

    private func doSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        hits = KnowledgeIndex.shared.search(q, context: KnowledgeLoader.deviceContext, limit: 3)
        fileHits = KnowledgeStore.shared.bm25Search(query: q, limit: 5)
            .map { "\($0.file):\($0.line)  \($0.snippet)" }
        searched = true
    }

    private func refresh() {
        KnowledgeStore.shared.ensure()
        entryCount = Int(KnowledgeIndex.shared.meta("entry_count") ?? "0") ?? 0
        if let ts = KnowledgeIndex.shared.meta("built_at"), let d = Double(ts) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            builtAt = f.string(from: Date(timeIntervalSince1970: d))
        } else {
            builtAt = ""
        }
    }
}
