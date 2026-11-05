# OpenMinis / Kelivo 借鉴笔记 —— 面向「工具调用执行 + 会话/对话处理」

调研对象：
- OpenMinis (SwiftUI, `src/ios/Agent`) —— Minis 的 iOS 端，Kelivo 的 iOS 沙箱与 workspace 设计来源之一。
- Kelivo (Flutter, `lib/`) —— 跨端 LLM 客户端，主打 workspace 八个工具 + MCP + ask-user。

背景：用户在自研 agent App 里，会话**在工具执行阶段卡住不动**（进程活着但不推进）。本文只挑与「工具循环稳健性」和「会话/对话基础设施」直接相关的可借鉴设计。

---

## 一、OpenMinis：工具循环守卫（最值得抄的一层）

### 1. `ToolLoopDetector` —— 有状态的循环检测器
`src/ios/Agent/ToolLoopDetector.swift`。核心：每条工具调用记一条 `ToolCallRecord`：
```
toolName, argsHash, resultHash, unknownToolName, toolCallId, timestamp
```
- **argsHash**：`sha256(toolName + 稳定序列化(params))`，`stableJson` 递归排序键；且**主动剔除 UI 噪声字段**（如 `tool_title`，模型会加 `#1/#2` 后缀）——否则「同一次逻辑调用」被误判成不同调用。
- **resultHash**：hash 前先 `stripVolatile`，抹掉时间戳、`elapsed/duration/took`、`request_id/call_id` 等易变字段，让**真正相同的产出坍缩成同一个 hash**。这是「no-progress 检测」成立的前提。
- 历史窗口 `history: [ToolCallRecord]`（默认 30），`check()` 在**执行前**判定、`record()` 在**执行后**回填 resultHash。

### 2. 四级阈值（全部可配置，自动纠正顺序 warning<critical<circuit）
- `warningThreshold=10`、`criticalThreshold=20`、`globalCircuitBreakerThreshold=30`、`unknownToolThreshold=10`。
- **策略1 unknown_tool_repeat**：连续调用不存在的工具达阈值 → `.critical` 阻断。错误信息正则 `extractUnknownToolName` 提取工具名。
- **策略2 global_circuit_breaker**：`getNoProgressStreak`（同一 toolName+argsHash 且 resultHash 恒等）达 30 → 全局熔断。
- **策略3 known_poll_no_progress**：轮询类工具（`command_status`、`process action=poll/log`）用双阈值（10 警告 / 20 阻断）。
- **策略4 generic_repeat**：非轮询工具，同 (name,argsHash) 累计达阈值 → 警告。
- `getNoProgressStreak` 从历史**尾部倒着数**同名同参、resultHash 不变的连续记录，一旦 resultHash 变了立即停 —— 这个是「是否真的原地踏步」的判据，比单纯计次数精确得多。

### 3. 阻断即「注入结果」，不抛异常
`check()` 返回 `.critical` 时，调用方**短路执行**，把 `[LOOP BLOCKED] …` 作为该工具的结果喂回模型。这样会话永远不会卡死：模型收到「别再重试」的指令继续产出。这是解决「卡在工具上不动」最直接的招式。

### 4. 告警节流
`shouldEmitWarning`：按 `currentCount / warningThreshold` 分桶，每涨一档才发一次，避免把 10→19 的每次调用都灌进上下文。

### 5. 计划任务的豁免
`exemptNextCallForScheduledFire()`：定时任务每次触发跑同一条命令（如每 2 分钟读一次屏幕）会被误判成循环。用一次性（不叠加）的豁免标记，下一次调用不计入 —— 定时任务 runaway 仍从它第 2 次调用起能被抓到。

---

## 二、OpenMinis：会话/对话基础设施

- **`SessionForkManager`**（`Session/SessionForkManager.swift`）：会话深拷贝（fork / duplicate）。要点：
  - 复制消息时维护 `oldToNewMessageId` 映射，把**压缩标记 CompactMarker**（引用 DB message id）重新映射到新消息，否则副本里压缩分隔线「悬空」丢失。
  - `reservedDuplicateTitles` 先占位再落库，防两个快速 Duplicate 抢同一个标题（`ISS-038`）。
  - 纯函数 `SessionDuplicateTitle`：`Foo (Copy)` → `Foo (Copy 2)`，跨语言识别后缀（"Copy"/"副本"），取**最小空号**回填，不留数字空洞。
- **锁状态外置**：`SessionLockStore` 把「会话锁 / 解锁时间戳」放 `UserDefaults` 旁路，不碰 `ChatSession` 模型，从而**不参与同步/导出流水线**。设计原则值得学：**敏感 UI 状态与会话模型解耦**。
- **`AIChatViewModel` / `Chat` 里**还有：RequestBudget、TurnCompletion、ToolPreflight、Compaction/Cancel、UserAskCenter、PromptQueue（见上次会话已读的清单）——本质是「一轮对话 = 有预算、可取消、可排队、可中断重试」的状态机。

---

## 三、Kelivo：工具权限与会话处理

### 1. 工具权限模式（`conversation_tool_permissions.dart`）
- `ToolPermissionMode`：`requestApproval`（每次问）/ `fullAccess`（全放行）。
- **`ConversationToolPermissions`**：权限绑定**会话**而非前台页面（`Expando` 按 ChatService 实例）。`setMode` 用**按会话串行的 `_tails` 队列 + revision 计数**：快速切换时旧写入不会覆盖新状态，`context_changed` 时抛异常 —— 这是「异步 UI 操作竞态」的干净解法。
- **`ToolCallPermission`**：**一次工具调用一次授权**（`_approvedOnce`）——「手动批准一次」绝不自动授权下一次。`authorize()` 处理：fullAccess 直接放行；否则请求审批 → 批准期间若模式被撤销则递归重取；`check()` 每步校验上下文未变。

### 2. 消息时间线 = 修订（revision）模型
- `LoadedTimelineSlot` / `ActiveTimelineSlot`：每条消息有 `revisionId, parentRevisionId, groupId(逻辑槽), versionCount`。
- **同一逻辑槽多版本**（regenerate / edit 产生多 revision），`versionSelections` 选当前显示版本；时间线按 slot 而不是按行加载，`loadTimelinePage` 支持 `before/after/around` 游标分页。
- **竞态防护**：每次异步加载前后比对 `_contextRevisions[convId]`，变了就递归重载；`_messageOrderIds` 只存**完整权威顺序**（注释明确：绝不存半填充骨架）。这对「流式 + 用户中途编辑/切换」非常关键。

### 3. 工具事件缓存
- `_toolEventsCache` / `_temporaryToolEvents`：按 messageId 缓存工具事件，随消息缓存一起淘汰。工具结果作为**消息附属**持久化，而非塞进消息正文 —— 渲染和重放都干净。

### 4. 上下文压缩与会话分叉
- `context_compression_service.dart`：把长会话压成新会话（对应 OpenMinis 的 CompactMarker）。
- `_unpublishedForks`：fork 出来但用户还没发第一条消息时标为「未发布」，不污染正常列表。

### 5. workspace 工具 + ask-user
- 八个工具 shell/read_file/view_image/write_file/edit_file/list_dir/glob/grep，命令输出流式、文件改动出 diff；文件越权与桌面命令需审批（除 `fullAccess`）。
- `ask user`：模型可暂停问多选题/开放题，拿到答案后继续 —— 对应 OpenMinis 的 `UserAskCenter`。这是「工具执行可以合法挂起等用户」而非「卡死」的关键区分。

---

## 四、映射到「工具执行卡死」——按优先级落地建议

> 当前症状：进程活着（wakeups 飙升、`EXC_GUARD/LIBXPC` 轻量 corpse），但会话不推进，请求没到 xosvid。典型是**工具调用循环里没有止损**或**流式/审批挂起却没有超时/中断**。

**P0 —— 立刻能止血（抄 OpenMinis ToolLoopDetector）**
1. 引入 `argsHash + resultHash`（resultHash 前 `stripVolatile` 抹时间戳/duration/id）。
2. 四策略：unknown_tool 连击阻断、no-progress 连击（同 resultHash）全局熔断、轮询双阈值、generic_repeat 警告。阈值先给 warning=10/critical=20/circuit=30。
3. 触发 `.critical` 时**不抛异常，把 `[LOOP BLOCKED] …` 注入成工具结果**让模型自己收尾 —— 这一条直接消灭「卡在工具上不动」。
4. 告警按桶节流，别把每次重试灌进上下文。

**P1 —— 会话状态机补全（抄 Kelivo 权限 + OpenMinis 预算/Turn）**
5. 一轮对话加 **turn 上限 + RequestBudget + TurnCompletion**，超预算强制收尾（不是无限等）。
6. 工具审批用**一次调用一次授权**（`_approvedOnce`），并做**按会话串行队列 + revision 校验**，避免「审批挂起但界面状态被别的操作改掉 → 永久等待」。
7. 所有「等待型」操作（审批、ask-user、流式）都要**可取消 + 有超时兜底**，超时按「失败/放弃」收尾并落日志，绝不无限挂起。

**P2 —— 稳健性/体验（抄两者）**
8. 消息用**逻辑槽 + 多 revision** 模型，异步加载前后比对 revision，避免流式中途编辑导致的陈旧覆盖。
9. 工具结果作为**消息附属事件**持久化（Kelivo `_toolEvents`），崩溃后能重放、能看到「卡在哪一步工具」。
10. 会话 fork/duplicate 时同步重映射压缩标记（OpenMinis `oldToNewMessageId`），避免副本丢压缩分隔线。
11. 崩溃面包屑：每次进入/退出工具调用写一行（工具名、argsHash、开始/结束时间、结果 hash），配合现有的 watch 桥就能定位卡死点。

**关于 xosvid 侧**
- 目前的 `EXC_GUARD / LIBXPC / XPC_EXIT_REASON_FAULT` 轻量 corpse + wakeups 飙升，指向 **XPC 守卫对象被跨队列误用/重复释放**，不一定是纯逻辑循环。P0 的循环守卫能避免「无限重试放大器」，但根因仍需在 XPC 调用处加断言/所有权校验。可先做 P0 把「越滚越卡」变成「一次就失败并落日志」，缩小 blast radius，再定位 XPC。

---

## 四之二、落地状态（v9.2，2026-11-05）

### 已完成

| 编号 | 落地文件 | 说明 |
|---|---|---|
| P0-1/2/3/4 | `Sources/XosviMCP/ToolLoopGuard.swift`（新增） | `argsHash`（工具名+归一化参数）+ `resultHash`（剔易变字段后稳定序列化哈希）；四策略：`unknown_tool` 连击、`no_progress`（同参同结果）、`no_progress_poll`（轮询双阈值，同参最多 15 次且结果不变也放行到 20）、`generic_repeat`（同参但结果在变）；阻断**不抛异常**，`dispatch` 直接返回 `{ok:false, code:"LOOP_BLOCKED"}` 作为工具结果喂回模型；告警按 `policy@tool` + 档位节流，每档只提示一次。 |
| P0-3 接入点 | `Sources/XosviMCP/MCPCore.swift` | `dispatch` 里在执行前调 `ToolLoopGuard.check`，`.block/.circuit` 短路执行；执行后 `record` 写入历史；`loop-blocked` 同时写 `ToolBlackBox` 与面包屑。 |
| P0 工具卡死 | `Sources/XosviMCP/ToolLoopGuard.swift`（`ToolResultLatch` 类）+ `Models.swift` | 根治「同步 dispatch 永不返回」：执行前 `begin(callId:)` 登记闩，工具线程与看门狗 `asyncAfter` 抢先 `settle`，先到者定局；超时（工具 180s / 子代理 1800s）由看门狗以 `TOOL_TIMEOUT` 失败结果收尾，run 继续推进而不是永久停住。 |
| P1-5 | `Models.swift` | 恢复轮次上限并改成**预算式收尾**：`maxToolRounds = 60` 起注入「必须给结论」纠正并置 `budgetExhausted`，此后任何工具调用都被拦成 `RUN_BUDGET_EXCEEDED` 结果（不再真执行）；`hardToolRounds = 80` 仍未收尾则硬停并给出说明。新 run 与「停止」时复位。 |
| P2-11 | `Models.swift` + `ToolBlackBox` | 面包屑 `tool-breadcrumbs.jsonl`：每次进入/阻断/完成写一行（工具名、argsHash、phase、耗时、结果 hash）。 |

**算法自测**：`tests/loopguard/guard_test.c` 用同一套判定算法在 C 里验证（本机无 swiftc），12 项用例全过——含「未知结果中断连击」「跨工具不串连击」「轮询 11 次不阻断」「结果变化时 no_progress 归 1」。

### 尚未完成（按原优先级）

- **P1-6**：工具审批「一次调用一次授权」+ 按会话串行队列 + revision 校验——需先确认当前是否存在工具审批流程，否则不适用。
- **P1-7**：其余等待型操作（ask-user / 流式）的取消与超时兜底；目前只有工具执行有闩超时。
- **P2-8**：消息逻辑槽 + 多 revision 模型（改动面大，牵涉 `ChatMessage` 与持久化格式）。
- **P2-9**：工具结果作为消息附属事件持久化（崩溃后可重放）。
- **P2-10**：fork/duplicate 时重映射压缩标记。

### 验证限制
本机工具链无 `swiftc`，Swift 改动**无法在本设备编译验证**；C 守护/CLI（`apelin/build.sh`）构建通过，算法层由 C 自测覆盖。CI 的 `swift-syntax` job（`swiftc -parse`，ubuntu 24.04）只校验语法、不校验类型，需 push 后跑 CI 才能得到第一道反馈。


---

## 五、一句话总结
- **OpenMinis 强在「工具循环守卫」**：hash 化的 no-progress 检测 + 多级熔断 + 阻断即注入结果。这是治卡死的主力。
- **Kelivo 强在「权限与时间线」**：会话级一次一授权 + revision 时间线 + 工具事件缓存。这是治「挂起/竞态/重放」的主力。
- 二者都强调：**任何一步都能取消、都有预算、失败要变成一条可读的结果喂回模型**，而不是让整个会话停在那里。
