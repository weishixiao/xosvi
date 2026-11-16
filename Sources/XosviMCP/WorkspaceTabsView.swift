import SwiftUI

// MARK: - v9：工作区「工具」面板（对应 Kelivo workspace_tools_pane）
//
// 与「文件」Tab 并存：两个 Tab 用 ZStack + opacity 保活（等价 Flutter 的 IndexedStack），
// 切换不销毁另一侧，滚动位置与展开状态都保留；非激活侧关闭动画（等价 TickerMode(enabled:false)）。

struct WorkspaceToolsPane: View {
    @State private var expanded: Set<String> = []
    @State private var query = ""

    private let groups: [(String, String, [String])] = [
        ("文件", "folder", ["artifact.read_text", "artifact.write_text", "artifact.list",
                            "workspace.info", "file.inspect"]),
        ("命令", "terminal", ["shell.exec", "workspace", "process.list"]),
        ("检索", "magnifyingglass", ["web.search", "web.fetch"]),
        ("App", "square.grid.2x2", ["app", "bind_app", "app_write_file", "app_decrypt"]),
        ("注入", "syringe", ["injection.enable", "injection.disable", "injection.status",
                             "injection.list", "injection.inspect"]),
        ("控制", "cursorarrow.click", ["control", "app_launch"]),
        ("构建", "hammer", ["build.runner.token", "project.generate_tweak", "package"])
    ]

    /// 工具定义只在首次访问时建一次索引——165 个工具，避免每次 body 重算都重建字典
    private static let defsIndex: [String: ToolDefinition] = {
        Dictionary(uniqueKeysWithValues: ToolRegistry.shared.definitions.map { ($0.name, $0) })
    }()
    private var defs: [String: ToolDefinition] { Self.defsIndex }

    private var filteredGroups: [(String, String, [ToolDefinition])] {
        let map = defs
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.compactMap { (name: String, icon: String, names: [String]) -> (String, String, [ToolDefinition])? in
            var items = names.compactMap { map[$0] }
            if !q.isEmpty {
                items = items.filter {
                    $0.name.lowercased().contains(q) || $0.summary.lowercased().contains(q)
                }
            }
            return items.isEmpty ? nil : (name, icon, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 内联搜索框（不用 .searchable：本 Pane 在 ZStack 里，挂 navigationBarDrawer
            // 会跟外层工作区页的导航栏/toolbar 抢位置）
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("搜索工具名 / 说明", text: $query)
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

            toolsList
        }
    }

    private var toolsList: some View {
        List {
            if filteredGroups.isEmpty {
                Section {
                    Text(query.isEmpty ? "暂无工具" : "没有匹配的工具")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            ForEach(filteredGroups, id: \.0) { group in
                Section(header: SettingSectionHeader(title: group.0)) {
                    ForEach(group.2, id: \.name) { def in
                        let isOpen = expanded.contains(def.name)
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isOpen { expanded.remove(def.name) }
                                    else { expanded.insert(def.name) }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: group.1)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .frame(width: 16)
                                    Text(def.name)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundColor(def.verified
                                                         ? Color(red: 0.25, green: 0.65, blue: 0.35)
                                                         : .primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())

                            Text(def.summary)
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                                .lineLimit(isOpen ? nil : 2)
                                .fixedSize(horizontal: false, vertical: true)

                            if isOpen, !def.parameters.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(def.parameters.keys.sorted(), id: \.self) { key in
                                        HStack(alignment: .top, spacing: 6) {
                                            Text(key)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.primary.opacity(0.8))
                                                .frame(minWidth: 70, alignment: .leading)
                                            Text(def.parameters[key] ?? "")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .padding(.top, 2)
                                .padding(.leading, 24)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .deepseekList()
    }
}

// MARK: - v9：工作区双 Tab 容器（文件 / 工具）
//
// 文档要点：IndexedStack → 切换不销毁；TickerMode(enabled:) → 非激活页暂停动画。
// SwiftUI 等价写法：ZStack + opacity + allowsHitTesting，非激活页 .animation(nil)。

struct WorkspaceTabsContainer<Files: View, Tools: View>: View {
    @Binding var tab: Int

    let files: Files
    let tools: Tools

    var body: some View {
        ZStack {
            // 非激活侧 opacity=0 且不接受点击，但**不销毁**（等价 Flutter IndexedStack）：
            // 滚动位置、展开状态、正在进行的加载都保留。
            // 注意：不用 .animation(nil) —— SwiftUI 的 animation(_:value:) 传 nil 是合法的，
            // 但这里显式给一个短时长，避免切换时闪一下。
            files
                .opacity(tab == 0 ? 1 : 0)
                .allowsHitTesting(tab == 0)
                .accessibilityHidden(tab != 0)

            tools
                .opacity(tab == 1 ? 1 : 0)
                .allowsHitTesting(tab == 1)
                .accessibilityHidden(tab != 1)
        }
        .animation(.easeInOut(duration: 0.16), value: tab)
    }
}

/// 顶部两个 Tab（对应 WorkspaceDetailTabs）
struct WorkspaceDetailTabs: View {
    @Binding var index: Int

    var body: some View {
        HStack(spacing: 0) {
            tabButton(0, "文件", "folder")
            tabButton(1, "工具", "wrench.and.screwdriver")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.tertiarySystemFill).opacity(0.55))
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func tabButton(_ idx: Int, _ title: String, _ icon: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { index = idx }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 13, weight: index == idx ? .semibold : .regular))
            }
            .foregroundColor(index == idx ? .primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(index == idx ? DoubaoTheme.card : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}
