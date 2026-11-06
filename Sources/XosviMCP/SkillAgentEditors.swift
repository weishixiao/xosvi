// MARK: - Skills / Agents 编辑页（从已废弃的 OriginalViews.swift 迁出）
//
// v9.8：OriginalViews.swift 里的 24 个视图只剩这三个还在用（MoreViews 的
// SkillsAgentsView 以 sheet 弹出），其余全部是旧版界面残留，随文件一起删除。
// 迁移时保持实现原样，只去掉对被删文件的依赖。

import SwiftUI

/// Agent 保存（独立实现，写 KnowledgeBase/agents.json）
enum AgentJSONStore {
    static func upsert(file: String, entry: [String: String]) {
        let kb = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KnowledgeBase")
        try? FileManager.default.createDirectory(at: kb, withIntermediateDirectories: true)
        let url = kb.appendingPathComponent(file)
        var list: [[String: String]] = []
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            list = json
        }
        if let name = entry["name"], let idx = list.firstIndex(where: { $0["name"] == name }) {
            list[idx] = entry
        } else {
            list.append(entry)
        }
        if let data = try? JSONSerialization.data(withJSONObject: list, options: .prettyPrinted) {
            try? data.write(to: url)
        }
        AuditLog.shared.log("agents", detail: "保存 \(entry["name"] ?? "")")
    }
}

struct SkillEditorView: View {
    @State private var name = ""
    @State private var summary = ""
    @State private var instruction = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            Form {
                Section(header: SettingSectionHeader(title: "Skill")) {
                    TextField("名称", text: $name)
                    TextField("用途摘要（AI 判断何时使用的依据）", text: $summary)
                    TextEditor(text: $instruction)
                        .frame(minHeight: 120)
                }
                Section {
                    Button("保存") {
                        SkillStore.shared.upsert(
                            SkillItem(name: name, summary: summary, instruction: instruction))
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                Section(header: SettingSectionHeader(title: "说明")) {
                    Text(L10n.t("ui_66"))
                        .font(XType.note)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("新建 Skill")
        }
        .navigationViewStyle(.stack)
    }
}

struct AgentEditorView: View {
    @State private var name = ""
    @State private var systemPrompt = ""
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        CompatNav {
            Form {
                Section(header: SettingSectionHeader(title: "Agent")) {
                    TextField("名称", text: $name)
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 120)
                }
                Section {
                    Button("保存到 agents.json") {
                        AgentJSONStore.upsert(
                            file: "agents.json",
                            entry: ["name": name, "systemPrompt": systemPrompt])
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
            .navigationTitle("新建 Agent")
        }
        .navigationViewStyle(.stack)
    }
}
