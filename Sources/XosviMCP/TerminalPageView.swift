import SwiftUI
import UIKit

// MARK: - v9.13 本地终端页（Apple 风格整页终端）
//
// 结构（对齐 OpenMinis 终端页）：
//   · 顶部：‹ 返回 + 标题「终端」+ ＋（新会话）
//   · 会话标签条：多会话切换，长按/点 × 关闭
//   · 输出区：深色底、等宽字体、可选中复制，点击即聚焦输入
//   · 底部：提示符输入行 + 回车 / 停止 + 键盘工具条（⌃C ⌃D Tab ↑ ↓ / 清屏 粘贴）
//
// 数据层在 TerminalSession.swift：命令走 iSH（Alpine）沙盒的 /bin/sh，无 PTY，
// 所以是「一轮一次」的执行模型，vim/top 这类全屏交互程序不可用。

struct TerminalPageView: View {
    @ObservedObject private var manager = TermManager.shared
    @ObservedObject private var lang = LanguageManager.shared
    var onClose: () -> Void

    @State private var input = ""
    @State private var historyCursor: Int = -1
    @FocusState private var focused: Bool

    private var session: TermSession? { manager.selected }

    /// v10.4：流式输出是往最后一行**追加**，行数不变 —— 只盯 lines.count 的自动滚动
    /// 在输出过程中不会跟到底部。把「行数 + 末行长度」拼成 key。
    private var scrollKey: String {
        guard let s = session, let last = s.lines.last else { return "0" }
        return "\(s.lines.count):\(last.text.count)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sessionTabs
            Divider()
            outputArea
            inputBar
            keyboardBar
        }
        .background(TermTheme.bg.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            manager.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true }
        }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(TermTheme.fg)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Text(L10n.t("term_title"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(TermTheme.fg)
            Spacer()
            // 后端切换（v9.14）：原先用 Menu，切换后菜单收起、会话没有重新绑定，
            // 提示符/cwd 还是旧后端那一套 —— 看起来「不是实时切换」。改成始终可见的分段条：
            // 点一下立刻生效，并把 cwd 归位到该后端的家目录。
            backendSwitch
            if let s = session, s.running {
                Button(action: { s.stop() }) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(TermTheme.red)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Button(action: {
                manager.newSession()
                input = ""
                focused = true
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(TermTheme.fg)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(TermTheme.bg)
    }

    /// 后端分段条：一眼看到当前后端，点另一个键立刻切换
    private var backendSwitch: some View {
        HStack(spacing: 2) {
            ForEach(TermBackend.allCases) { b in
                let active = (session?.backend ?? .alpine) == b
                Button(action: {
                    guard let s = session, s.backend != b else { return }
                    s.switchBackend(to: b)
                    focused = true
                }) {
                    Text(b.shortTitle)
                        .font(.system(size: 11, weight: active ? .semibold : .regular))
                        .foregroundColor(active ? TermTheme.bg : TermTheme.dim)
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(active ? TermTheme.fg : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(TermTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(TermTheme.stroke, lineWidth: 0.6)
        )
    }

    // MARK: 会话标签

    private var sessionTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.sessions) { s in
                    let active = s.id == manager.selectedId
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .semibold))
                        Text(s.title)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        if manager.sessions.count > 1 {
                            Button(action: { manager.close(s.id) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(TermTheme.dim)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .foregroundColor(active ? TermTheme.fg : TermTheme.dim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(active ? TermTheme.surface : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(active ? TermTheme.stroke : Color.clear, lineWidth: 0.8)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { manager.selectedId = s.id }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(TermTheme.bg)
    }

    // MARK: 输出区

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let s = session {
                        ForEach(s.lines) { line in
                            Text(attributed(line))
                                .font(.system(size: 12.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                        // 输入行镜像：让用户看到「提示符 + 正在敲的字」，位置紧跟在输出末尾
                        HStack(alignment: .top, spacing: 0) {
                            Text(s.promptText + " ")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundColor(TermTheme.green)
                            if input.isEmpty {
                                Text(focused ? "▌" : "")
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundColor(TermTheme.dim)
                            } else {
                                Text(input)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundColor(TermTheme.fg)
                                if focused {
                                    Text("▌")
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .foregroundColor(TermTheme.dim)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .id("mirror")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scrollKey) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("mirror", anchor: .bottom) }
            }
            .onChange(of: input) { _ in
                proxy.scrollTo("mirror", anchor: .bottom)
            }
            .onTapGesture { focused = true }
        }
        .background(TermTheme.bg)
    }

    private func attributed(_ line: TermLine) -> AttributedString {
        var s = AttributedString(line.text)
        switch line.kind {
        case .output: s.foregroundColor = TermTheme.fg
        case .command: s.foregroundColor = TermTheme.green
        case .notice: s.foregroundColor = TermTheme.yellow
        case .prompt: s.foregroundColor = TermTheme.dim
        }
        return s
    }

    // MARK: 输入栏

    private var inputBar: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(session?.promptText ?? "$")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(TermTheme.green)
                .lineLimit(1)
                .layoutPriority(1)
            TextField("", text: $input)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(TermTheme.fg)
                .tint(TermTheme.green)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                .focused($focused)
                .submitLabel(.send)
                // v10.4：键盘上的回车原本什么都不做（注释说「回车在工具条上」），
                // 用户按 Return 以为发出去了，其实一条命令都没跑。现在 Return = 执行。
                .onSubmit { send() }
            if let s = session, s.running {
                Button(action: { s.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(TermTheme.red))
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: { send() }) {
                    Image(systemName: "arrow.turn.down.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(TermTheme.bg)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(TermTheme.green))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TermTheme.surface)
    }

    // MARK: 键盘工具条

    private var keyboardBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("⌃C") { interrupt() }
                key("⌃D") { focused = false }
                key("Tab") { input += "\t" }
                key("↑") { recallHistory(-1) }
                key("↓") { recallHistory(1) }
                key("↩") { send() }
                key(L10n.t("term_key_clear")) {
                    session?.lines.removeAll()
                }
                key(L10n.t("term_key_paste")) {
                    if let s = UIPasteboard.general.string { input += s.replacingOccurrences(of: "\n", with: " ") }
                }
                key("\u{2318}⇧V") {
                    // 直接粘贴并执行，避免长命令在输入框里滚动
                    if let s = UIPasteboard.general.string, session?.running == false {
                        let cmd = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !cmd.isEmpty { session?.submit(cmd); input = "" }
                    }
                }
                key(L10n.t("term_key_root")) {
                    // v10.5：su 键不再往输入框里摆一条命令 —— 旧实现只是填字不提交，
                    // 看起来就是「点了没反应」；本机后端又是 mobile 身份，id 永远是 501。
                    // 现在切到 root 后端（经 xosvid 以 uid=0 执行）并立刻跑一次 id。
                    guard let s = session else { return }
                    if s.backend != .root { s.switchBackend(to: .root) }
                    s.submit("id")
                    input = ""
                    focused = true
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(TermTheme.surface)
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(TermTheme.fg)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(TermTheme.surfaceRaised))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(TermTheme.stroke, lineWidth: 0.6))
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: 动作

    private func send() {
        guard let s = session else { return }
        let cmd = input
        input = ""
        historyCursor = -1
        s.submit(cmd)
        // v10.4：onSubmit 之后系统会收掉焦点，这里补回来，连续敲命令不用每次点输入框
        DispatchQueue.main.async { focused = true }
    }

    private func interrupt() {
        if let s = session, s.running {
            s.stop()
        } else {
            // 没有在跑的命令：清空当前输入行（等价于终端里的 ⌃C）
            input = ""
        }
    }

    private func recallHistory(_ dir: Int) {
        guard let s = session, !s.history.isEmpty else { return }
        if historyCursor < 0 { historyCursor = s.history.count - 1 } else { historyCursor += dir }
        if historyCursor < 0 { historyCursor = 0 }
        if historyCursor >= s.history.count {
            historyCursor = -1
            input = ""
            return
        }
        input = s.history[historyCursor]
    }
}

// MARK: - 主题（黑底终端配色，跟随系统深浅都保持深色）

enum TermTheme {
    static let bg = Color(UIColor { _ in UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1) })
    static let surface = Color(UIColor { _ in UIColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1) })
    static let surfaceRaised = Color(UIColor { _ in UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1) })
    static let stroke = Color.white.opacity(0.10)
    static let fg = Color(red: 0.90, green: 0.91, blue: 0.92)
    static let dim = Color(red: 0.55, green: 0.57, blue: 0.60)
    static let green = Color(red: 0.42, green: 0.86, blue: 0.52)
    static let yellow = Color(red: 0.95, green: 0.76, blue: 0.36)
    static let red = Color(red: 0.93, green: 0.38, blue: 0.38)
}
