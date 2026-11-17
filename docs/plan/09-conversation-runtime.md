# 09 · 会话运行逻辑重设计（会聊天，也能干活）

> 版本：v10.13　　触发点：用户三点反馈
>
> 1. 「一开口它就去调工具」——闲聊也进执行态。
> 2. 把 default 模式改成「会聊天也干活」。
> 3. 按 L1/L2/L3/L4 四层落地，别只改提示词。

## 问题定位（不是模型笨，是结构在逼它动手）

旧结构里每一轮请求的 system 都由四块无条件拼成：

| 块 | 体积 | 副作用 |
|---|---|---|
| 环境提示词（工具合同 / 边解说边执行） | ~2.9 万字符 | 通篇都是「你要调工具」 |
| 模式路由清单（7 个模式摘要） | ~3 千字符 | 每轮先判定「任务性质」→ 判定成任务 |
| 工具裁决 + 动态状态 | ~2 千字符 | 每轮播报设备/工作区状态 |
| `tools` 字段（全量已启用工具） | 50+ schema | 模型有 50 个动作可选，没有「不动」这个选项 |

再叠加 OpenAIClient 里无条件下发的「**调工具前必须先解说**」，四层信号共同把模型推进执行态。
用户说「今天心情不太好」，模型收到的是：「你是执行代理，本轮有 53 个工具，先判定任务性质，
调工具前先解说你要做什么」。

结论：**只改提示词治不了**。要么不给工具，要么不给工具纪律。

## 四层设计

```
用户这一句
   │
   ├─ L3 意图判定（本地字符串规则，零延迟）→ RunIntent
   │
   ├─ L2 工具渐进披露：按档位决定 tools 字段
   │      chat    → []（连字段都不发）
   │      lookup  → 只有 web.search / web.fetch
   │      operate → 全量已启用工具
   │
   ├─ L1 提示词分层：按档位决定 system 内容
   │      chat    → 会话核心（~1.5 千字符）
   │      lookup  → 会话核心 + 工作层 + 查证卡
   │      operate → 会话核心 + 工作层 + 命中的技能卡（最多一张）
   │
   └─ L4 纠正按阶段生效：解说/参数/批量/空回复纠正只在 operate 档注入
```

### L1 提示词分层（`SystemPrompts.swift`）

| 新增 | 作用 |
|---|---|
| `conversationCore` | 常驻会话核心：定「会聊天也能干活，两者平等」；每轮先判 聊天/查证/干活；**拿不准先答再问「要我去做吗」**；本轮无工具就直说，不许假装调用 |
| `lookupCard` | 只在查证档注入的联网纪律（先 search 再 fetch、最多 2 轮、带 `[cite:sN]`） |
| `skillCards` | 5 张技能卡（逆向取证 / 渗透验证 / 构建门禁 / 内存定位 / 界面操作），只在干活档、且文本命中关键词时注入**得分最高的一张** |
| `promptFor(intent:userText:)` | 装配入口。chat → 只给核心；lookup/operate → 核心 + `mergedPrompt(default)`（含环境提示词）+ 卡；关掉自动路由时尊重用户在设置里选的模式（同样走 `mergedPrompt`，不丢环境提示词） |

default 模式正文新增 `0x. CHAT FIRST` 段，并明确 **§1 工具合同只在判定为干活之后适用**；
模式名从「综合模式」改为「默认模式（会聊天也干活）」，路由清单同步。

### L2 工具渐进披露（`MCPCore.swift` / `Models.swift`）

- `ToolRegistry.enabledOpenAIToolSchema(only:)` 加白名单过滤（`nil` = 全量，行为不变）。
- `send()` 按档位构造 `baseTools`：chat 空数组 / lookup 联网两件套 / operate 全量。
- `handleToolCall` 加**硬闸**：白名单外的调用直接回 `[[TOOL_NOT_AVAILABLE]]` 工具结果，不执行。
  模型在正文里凭记忆编出来的调用也拦得住（chat 轮本来没有 `tools` 字段，这是第二道闸）。
- 硬闸比对先经 `ToolRegistry.originalName(for:)` 归一：模型返回的是下划线安全名
  （`web_search`），白名单是注册原名（`web.search`）——不归一的话查证档会把合法调用误判成不可用。
- 已授权工具（`approvedToolNames`）的 schema 只在干活档叠加，否则 L2 白名单会被 disclosed 灌回全量。
- 文本式 shell 兜底（模型把命令写成正文）只在干活档放行，否则闲聊时它偷偷跑命令就绕过了白名单。

### L3 意图判定（`RunIntent.swift`，纯本地）

```swift
enum RunIntent { case chat, lookup, operate }
struct RunPolicy { intent, allowsTools, usesWorkLayers, usesCorrections,
                   allowsAllTools, allowsTextualToolFallback, toolWhitelist }
```

判定顺序（先命中先返回）：

1. 带图/带附件 → operate（看图、改图、分析截图一定是让干活）。
2. 明确不让动手（「别调工具」「直接回答」「随便聊聊」）+ 问身份（「你是谁」）→ chat。
3. 干活词（文件/编译/安装/点击/截图/日志/grep/tweak/deb/ci…）→ operate。
4. 像路径（`/var/`、`~/`、`./`）→ operate。
5. 上一轮 AI 在提议动手 + 这一句是短肯定（好 / 去吧 / 嗯嗯 / 动手吧）→ operate。
6. 联网词（查一下/最新/多少钱/新闻/`https://`）→ lookup。
7. 兜底 → chat。

**判错的取舍**：宁可多聊一句。判成 chat 的成本是用户补一句「去做啊」（第 5 条会接住）；
判成 operate 的成本正是用户抱怨的那种体验。所以兜底往 chat 倒。

两个实现细节，都是真踩过的坑：

- **ASCII 词走词边界**。不加边界时 `ci` 命中 `decision`、`app` 命中 `appreciate`、
  `ls` 命中 `goals`——英文闲聊整片被判成干活。
- **短肯定要看上一轮是不是在提议**。上一轮尾句是问句（「要我做吗？」）也算提议，
  否则「去吧」这种省略主语的回答会掉回 chat，用户会觉得它装傻。
- **空文本不参与判定**。`BackgroundRunManager` 用 `send("")` 续跑排队的会话，
  若空串被判成 chat，后台活儿会「没有工具可用」凭空断掉——所以空文本沿用当前档位（默认 operate）。

### L4 纠正按阶段生效

| 注入项 | 旧行为 | 新行为 |
|---|---|---|
| 解说纠正（漏了「先解说后执行」） | 每轮都可能注入 | 只在 operate 档注入；其它档位**顺手清空**，避免残留带进下一轮 |
| 参数缺失纠正 / 空回复纠正 | 同上 | 同上 |
| OpenAIClient 的「调工具前必须先解说」指令 | 无条件下发 | 本轮 `tools` 非空才下发 |

## 改动清单

| 文件 | 改动 |
|---|---|
| `Sources/XosviMCP/RunIntent.swift` | 新增：`RunIntent` / `RunPolicy` / `IntentClassifier` |
| `Sources/XosviMCP/SystemPrompts.swift` | 新增 `conversationCore` / `lookupCard` / `skillCards` / `skillCard(for:)` / `promptFor(intent:userText:)`；default 加 `0x. CHAT FIRST`、改名；路由清单同步 |
| `Sources/XosviMCP/Models.swift` | `currentPolicy` / `currentUserText`；`send()` 判定档位 + 按档位构造 `baseTools`；`runLoop` 按档位装配 system、门控纠正；工具白名单硬闸；文本式 shell 兜底门控 |
| `Sources/XosviMCP/MCPCore.swift` | `enabledOpenAIToolSchema(only:)` 白名单；`originalName(for:)` 安全名归一 |
| `Sources/XosviMCP/OpenAIClient.swift` | 解说纪律指令只在有工具的轮次下发 |
| `tests/intent/main.swift` | 新增：判定表断言（35 条意图 + 17 条策略派生） |
| `.github/workflows/ci.yml` | 新增 `intent-selftest` job：真源码编译 `RunIntent.swift` + 断言表并跑 |

## 验证

| 方式 | 覆盖什么 | 状态 |
|---|---|---|
| CI `intent-selftest`（ubuntu，swiftc 真编译 + 真跑断言） | L3 判定表、档位派生门控 | 待 CI |
| CI `swift-syntax`（`swiftc -parse` 全部 Sources） | 新增文件语法、括号配平 | 待 CI |
| CI `tool-contract` + `scripts/check.sh` | 工具注册/文档口径/门禁脚本 | 本地已过（无 python3 的部分 CI 补） |
| 装包真机 | 「闲聊不调工具」「查资料只走联网」「干活全量工具」「后台续跑不断」 | 待构建 + 装包 |

真机要看的四个点：

1. 说「今天有点累，随便聊聊」——不出工具、不写执行计划，正常聊天。
2. 问「iOS 18.2 什么时候发」——只调 `web.search` / `web.fetch`，不出现 `shell.exec`。
3. 说「帮我把 /tmp/x.log 删掉」——全量工具、先说后做、删前确认。
4. 排队/后台会话能跑完，不会因为「没有工具」停在中途。

## 已知取舍

- 判定是关键词规则，不是分类模型：词汇表之外的表述会判成 chat（安全方向），
  需要时往 `RunIntent.swift` 的词表里加，一并补 `tests/intent/main.swift` 的断言。
- 干活档仍是全量工具（没做「按任务只给相关工具」），因为工具选择本身就是模型的活；
  下一步若还要压缩，做法是把 `skillCards` 与工具子集绑定（如逆向卡只放 `inject`/`macho`/`disasm`）。
- chat 档没有任何工具，所以闲聊中用户顺口说「顺便看下版本」会被判到 lookup 而不是 operate——
  这是想要的：看版本本来只需联网。
