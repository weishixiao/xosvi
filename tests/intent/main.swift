// tests/intent/main.swift —— L3 意图判定自检（v10.13）
//
// 为什么有这个东西：`RunIntent.swift` 全是纯字符串规则，判错的后果是「闲聊被打进执行态」
// （用户抱怨的原始故障）或「该干活却被当聊天」。本机没有 swiftc，真机只能靠手感验证，
// 所以把判定规则做成一张可执行的断言表，在 CI 上真跑一遍。
//
// 只依赖 Foundation，不碰设备、不联网。任何一条断言失败 → 退出码非 0 → CI 变红。
//
// 编译（CI job `intent-selftest`）：
//   swiftc -O -o intent_selftest Sources/XosviMCP/RunIntent.swift tests/intent/main.swift

import Foundation

var failures = 0
var passes = 0

func expect(_ cond: Bool, _ label: String) {
    if cond {
        passes += 1
        print("  PASS  \(label)")
    } else {
        failures += 1
        print("  FAIL  \(label)")
    }
}

func section(_ name: String) { print("\n== \(name)") }

func isIntent(_ text: String, _ want: RunIntent, previous: String = "", label: String? = nil) {
    let got = IntentClassifier.intent(for: text, previousAssistant: previous)
    expect(got == want, "\(label ?? text) → \(got.label)（期望 \(want.label)）")
}

// MARK: - 聊天档：闲聊不能进执行态

section("chat —— 寒暄 / 观点 / 情绪 / 身份")
isIntent("你好", .chat)
isIntent("你是？", .chat)
isIntent("你是谁呀", .chat)
isIntent("谢谢，辛苦了", .chat)
isIntent("今天心情不太好，随便聊聊", .chat)
isIntent("这个设计你觉得好看吗？", .chat)
isIntent("嗯，我明白了", .chat)
isIntent("讲个笑话", .chat)

section("chat —— 英文闲聊不能被子串误判（app / ci / cat / ls 走词边界）")
// "appreciate" 里有 "app"、"decision/specific/efficient" 里有 "ci"、"goals" 里有 "ls"
isIntent("I appreciate it, thanks a lot", .chat)
isIntent("That was a specific and efficient decision", .chat)
isIntent("My goals for this week are simple", .chat)
isIntent("who are you?", .chat)

section("chat —— 用户明确不让动手")
isIntent("别调工具，直接回答我", .chat)
isIntent("这个不用查，你就聊聊你的看法", .chat)

// MARK: - 查证档：要资讯才联网

section("lookup —— 需要核实的事实")
isIntent("查一下 iOS 18.2 什么时候发布", .lookup)
isIntent("搜一下最近有什么新闻", .lookup)
isIntent("Python 最新版本是多少", .lookup)
isIntent("这台机器现在多少钱", .lookup)
isIntent("https://example.com 这个页面讲了什么", .lookup)

// MARK: - 干活档

section("operate —— 动文件 / 动工程 / 动设备")
isIntent("帮我把 /var/mobile/tmp/a.txt 删掉", .operate)
isIntent("重新编译一下这个 tweak", .operate)
isIntent("点一下设置里的那个按钮", .operate)
isIntent("看下这个 App 的 bundle id", .operate)
isIntent("grep 一下日志里的报错", .operate)
isIntent("截个图发我", .operate)
isIntent("跑一遍这个脚本", .operate)
isIntent("看看 /tmp/x.log", .operate)

section("operate —— 带附件一定干活（看图 / 改图 / 分析截图）")
expect(IntentClassifier.intent(for: "随便", hasAttachments: true) == .operate,
       "带附件 → 干活")
expect(IntentClassifier.policy(for: "随便", hasAttachments: true)
        .intent == .operate, "policy 同步为干活")

// MARK: - 承接上一轮：AI 提议动手 + 用户短肯定

section("operate —— 上一轮提议动手，用户回「好 / 去吧」")
isIntent("去吧", .operate, previous: "要我去做吗？")
isIntent("好", .operate, previous: "我可以帮你把这个 deb 装上，需要我继续吗")
isIntent("嗯嗯", .operate, previous: "确认后我就开始跑脚本了")
isIntent("动手吧", .operate, previous: "要不要我把它改掉？")

section("chat —— 上一轮没提议，短肯定不能升档")
isIntent("好", .chat, previous: "今天天气不错")
isIntent("嗯", .chat, previous: "这个问题挺有意思的")

// MARK: - 空输入（后台续跑路径）

section("空输入 —— 判定层给 chat，调用方负责找回这一轮的文本")
// send() 里空文本不会直接拿来判定（BackgroundRunManager 的 worker 续跑走这条路）：
// 调用方会改判这条会话最后一条用户消息，完全无从判断时才退回干活档。
// 这条断言把契约钉住：判定器本身对空串只给 chat，谁想拿空串当"继续干活"必须自己指定档位。
isIntent("", .chat)
isIntent("   \n ", .chat)

// MARK: - 策略派生

section("RunPolicy —— 档位派生出的门控")
let chat = RunPolicy(intent: .chat)
expect(!chat.allowsTools, "chat 不给工具")
expect(chat.toolWhitelist?.isEmpty == true, "chat 白名单为空集合（硬闸拒绝一切调用）")
expect(!chat.usesWorkLayers, "chat 不注入工作层")
expect(!chat.usesCorrections, "chat 不启用纠正机制")
expect(!chat.allowsTextualToolFallback, "chat 不放行文本式 shell 兜底")

let lookup = RunPolicy(intent: .lookup)
expect(lookup.allowsTools, "lookup 给工具")
expect(lookup.toolWhitelist == RunPolicy.lookupTools, "lookup 只放联网两件套")
expect(RunPolicy.lookupTools == ["web.search", "web.fetch"], "联网两件套名字没写错")
expect(!lookup.allowsAllTools, "lookup 不叠全量已授权工具")
expect(!lookup.allowsTextualToolFallback, "lookup 不放行文本式 shell 兜底")

let operate = RunPolicy(intent: .operate)
expect(operate.allowsTools, "operate 给工具")
expect(operate.toolWhitelist == nil, "operate 无白名单限制（全量已启用工具）")
expect(operate.allowsAllTools, "operate 叠加已授权工具")
expect(operate.usesCorrections, "operate 启用纠正机制")
expect(operate.allowsTextualToolFallback, "operate 放行文本式 shell 兜底")

// MARK: - 汇总

print("\n=== 意图判定自检结果：\(passes) passed, \(failures) failed ===")
if failures > 0 {
    print("FAILED")
    exit(1)
}
print("ALL GREEN")
exit(0)
