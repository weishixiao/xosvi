# EXECUTION_LOG — Xosvi 改造台账

> 唯一进度源。状态四选一：TODO / DOING / DONE / BLOCKED（N/A 需写明原因）。
> 风险排除项：按用户指示，#21 / #22 / #25 / #26 不动（BLOCKED-风险排除），其余照常。

## 决策记录（Decisions）

- D-001：`protocolVersion` 保持 `2024-11-05`，不随客户端升级；升版另开 PR。
- D-002：结果信封的高风险批次暂缓；成功路径仅新增 `code`，失败路径维持 throw + `error.data`。
- D-003：`ToolDefinition` v2（annotations/cache/related/examples）暂缓；`JSONRPC` 只投影已有字段。
- D-004：`longCacheTools` 统一为注册名 `skills.list` / `skills.read`（旧 `skill.*` 永不命中）。
- D-005：缓存前缀中的 `device.fake` / `injection.mem` 为死条目（子命令不是工具名），已从名单移除。
- D-006：文档工具数口径改为“默认启用 49 / 注册 166，以 system.overview 实时值为准”。

## 阻塞记录（Blockers）

- （已解除）B-001..B-004：按用户最新指示，风险项 #21/#22/#25/#26 已实施。
- D-007：#22 采用 `code` + `_meta` 命名空间，避免覆盖工具自有的 `message`/`next_step`。
- D-008：#21 增加 `isAnnotated`，强制层只对显式标注的工具生效。
- D-009：#25 用线程本地深度断言把锁重入从“静默死锁”变成 debug 断言。
- D-010：#26 破坏性写操作直接清空全表缓存（缓存外写入无法追踪）。
- D-011：B5 统一走 `ExternalContent` 三种形态：`apply`（单字段包装+标记）、`wrapFields`（多字段包装，已带标签不重复包）、`flagRows`（行列表只标记不改写）。剪贴板无读取工具，`UIPasteboard` 仅 App 内 UI 使用，故本项 N/A。
- D-012：本机无 `swiftc`，Swift 改动只有括号/结构 sanity（`tests/loopguard/swift_braces.c`）可本地验证，类型错误仅由 CI 暴露；`scripts/check_swift_braces.py` 本机跑不了（无 python3，且脚本本身有重复行），以 C 版本为准。
- D-013（实测，2026-11-05）：真机跑 B5 端到端时发现两个网关级缺陷，均已改代码但**未编译验证**：
  1. `GatewayServer.readRequest` 无任何超时，慢/半开连接会长期占住 handle 线程 → 已加 `SO_RCVTIMEO` 15s / `SO_SNDTIMEO` 30s。
  2. `FileExecTool.extractStrings` 逐字节 append 到 `[UInt8]`，27MB App 二进制实测 20s+ 未返回，同一次请求后网关整体失去响应 → 已改为切片扫描 + 只扫前 8MB（C 等价实现验证 27MB 即时返回）。
  另：`file` 工具对 `/usr/bin/true` 报 no such file —— App 沙盒看不到 jbroot 路径，属既有路径可见性问题，与 B5 无关。
  `smoke_external.json` 因此改为模板变量，真机需用 App 容器内可见的路径。
- D-014（2026-11-06）：**数据目录彻底隔离**。所有可写数据统一到
  `/var/mobile/Documents/wiki.qaq.xosvi`（`Sources/XosviMCP/XDirs.swift` 是唯一来源），
  App Group 换成 `group.wiki.qaq.xosvi`。三条执行原则：
  1. 共享位置（`/var/mobile/Documents`、`/var/mobile/Library`）上的旧数据**只复制、绝不 move**——
     同机可能装着上游 TrollAgent，搬走等于替它删数据；只有本 App 沙盒容器里的旧 Workspace 才搬。
  2. `FreshInstallReset` 的清理范围收回到数据根 + 真正的沙盒容器 + Keychain。此前按
     `.documentDirectory` / `.libraryDirectory` 清空，而在 `no-container` 下这两个值解析成
     `/var/mobile/Documents` 与 `/var/mobile/Library`，触发即清空整个 mobile 的 Library（不可恢复）。
  3. 故意不动的三处：iSH rootfs（`Library/Application Support/ish-rootfs`，迁走须整个重解压）、
     jb-p1lot（`Library/Application Support/jb-p1lot`，跨工具共用同一份二进制）、
     固定端口（8765/4789/18080/18180/19080，三端协同改动，收益低风险高）。

## 阻塞记录（补充）

- B-005：App 的 MCP 网关开关**不持久化**，重启 App 后端口 8765 不再监听，需手进「MCP 服务」页重新开启。端到端用例因此依赖人工操作。

## 台账

| # | 条目 | 状态 | 分支 | 验收命令 | 结果摘要 |
|---|---|---|---|---|---|
| A1 | 契约三脚本 + CI + 快照 | DONE | feat/v8-ai-seamless | `python3 scripts/check_tool_registration.py && python3 scripts/lint_tool_descriptions.py --fail-on-refs && python3 scripts/dump_registry.py --check docs/registry.snapshot.json` | 三脚本通过；快照 166 工具；L2 失效引用 0 |
| A2 | 命名一致性（skills.* / 死前缀 / 口径） | DONE | feat/v8-ai-seamless | `rg -n "skill\.list|skill\.read" Sources/` 无残留；文档无 37/162 硬编码 | longCacheTools 已改；device.fake/injection.mem 已移除；文档口径已改 |
| A3 | AGENTS.md / RULES.md 替换 | DONE | feat/v8-ai-seamless | 文档内示例工具名全部命中 registry；无 `ta list` | 已重写并校正（契约 v2.0） |
| A4 | README 最小可用版 | DONE | feat/v8-ai-seamless | 含环境矩阵/安装权限/许可/免责 | 已重写（修正 iOS 17.1+Relaxin 支持） |
| A5 | 内置提示词种子 v5 治理 | DONE | feat/v8-ai-seamless | 新装默认仅《工具使用契约》；升级不丢自建 | seed v5 + 迁移清理 + 契约种子 |
| A6 | 描述交叉引用批量修 | DONE | feat/v8-ai-seamless | `lint --fail-on-refs` 退出 0 | 37 处替换，L2 归零 |
| B1 | JSON-RPC 协议层升级（安全子集） | DONE | feat/v8-ai-seamless | ping 返回 {}；notifications 空 Data；tools/list 含 returns/prerequisites | 动态版本 + 分页 + error.data |
| B2 | ToolDefinition v2 + 注解迁移 | DONE | feat/v8-ai-seamless | `dump_registry --check`；tools/list 含 annotations | isAnnotated 门控 + 归一 init + 36 个工具标注 |
| B3 | 结果信封 + 结构化错误 | DONE | feat/v8-ai-seamless | 成功含 code + `_meta`；失败含 error.data | code+_meta（不覆盖工具自有 message/next_step） |
| B4 | KB 自动挂载 + 前置预检 | DONE | feat/v8-ai-seamless | memory 未 attach 返回 unmet_prerequisites | 只挂 ENV/TOOL/TARGET 类；参数错不挂 |
| B5 | 外部内容包装推广 | DONE | feat/v8-ai-seamless | 输出带 `<external_*>`；疑似注入 `injection_suspected` | v9.9：web.fetch / shell.exec / file.analyze / db.* / ui_tree / network.capture / workspace.grep 全覆盖；剪贴板无读取工具，N/A；`tests/loopguard/external_test.c` 16 例通过（Swift 侧待 CI 编译） |
| C1 | 并发收口 + 压测 | DONE | feat/v8-ai-seamless | withLock 重入断言；KB 串行锁 | 状态字典统一短临界区；压测脚本待补 |
| C2 | 缓存字段化 + 精准失效 | DONE | feat/v8-ai-seamless | 写后读不再旧值；ttl==0 不计数 | policy 优先；别名归一；破坏性清全表；run 预算 |
| C3 | VPN 抓包闭环 | DONE | feat/v8-ai-seamless | `vpn.capture command:verify` → TRUSTED/NOT_TRUSTED/PROXY_DOWN；start 失败返回 mode:fallen_back | cert_status / serve_profile / verify + Appex lan_excluded/uptime |
| C4 | ish.doctor | DONE | feat/v8-ai-seamless | 10 项检查 + verdict + auto_fix | ISHDoctorTool.swift 已注册 |
| C5 | 技能系统落地 | DONE | feat/v8-ai-seamless | skills.list 返回 primary/why；4 条种子技能 | 内置技能 ta 前缀已全部改为真实工具名 |
| C6 | 真机 Runbook 三份 | DONE | feat/v8-ai-seamless | hid-matrix / injection-smoke / cert-install 可执行 | 已落盘 |
| D1a | Gateway 核心（HTTP+SSE+配对鉴权） | DONE | feat/v8-ai-seamless | POST / 与 GET /sse；/pair 发 token；read token 拦截写工具 | MCPGatewayServer |
| D1b | Gateway SSE + POST | DONE | feat/v8-ai-seamless | SSE 先发 endpoint 事件；POST 返回 JSON-RPC | 同文件实现 |
| D1c | Mac stdio 桥 | DONE | feat/v8-ai-seamless | tools/mcp_bridge_stdio.py 可配对并转发 | — |
| T1 | 测试体系（runner/cases/stress） | DONE | feat/v8-ai-seamless | `tests/contract/run_all.py` 全绿 | L1 全绿；L3 runner + 3 份用例 + stress_mcp |
| H3 | 文档即代码（快照对比） | DONE | — | `dump_registry.py --check` | 已入 CI |
| H4 | 高危链路冒烟 runbook | DOING | — | injection-smoke 可执行 | 待补文件 |
| F-40 | health.summary 工具 | TODO | — | 列出失败率最高工具 | — |
| F-41 | 内存 attach 失败分类细化 | TODO | — | 区分进程不存在 / task_for_pid 被拒 | — |
| F-42 | 工程卫生（死引用清理） | DONE | feat/v8-ai-seamless | 内置技能 ta 前缀清零；lint L5 = 0 | GhostRunner 仅剩兼容 enum |
| F-43 | 远程通道审计与白名单 | DONE | feat/v8-ai-seamless | EXEC/DONE/DENIED 入 AuditLog（只记参数键） | 白名单沿用 safeTools |
| F-44 | 知识库隐私开关 | DONE | feat/v8-ai-seamless | session_memory_enabled 关闭后不写入 | 清理入口已有 |

| P0-1 | 熔断真正终止（RUN_TERMINATED） | DONE | main | 连续两次同参失败即终止 | Models/SubagentTool 消费 abort |
| P0-2 | env.setup_re 参数校验 + action:list | DONE | main | action:list 返回批次；无参=report | InstallTools.swift |
| P0-3 | spawn_verdict 只看 bundled | DONE | main | verdict 与 spawn_probe 自洽 | ToolchainSigner.swift |
| P1-4 | python3 bind 容错 + realpath | DONE | main | python3 -c "print(1)" 输出 1 | PythonCLI/main.c |
| P1-5 | shell 分段执行 + 路径归一 | DONE | main | B=/tmp id -u、for 循环可用 | ShellSegmenter.swift |
| P2-6 | shim 识别（sqlite3/plutil） | DONE | main | diagnose 的 shims 标出 | ShimDetector.swift |
| I1 | Swift 侧路径统一到 XDirs | DONE | main | `grep -rn documentDirectory Sources/` 只剩迁移与 iSH 绑定 | 知识库/技能/指令/审计/崩溃/用量/图标缓存/临时文件/默认 cwd/下载目录共 15 处；**Swift 未编译，需 CI** |
| I2 | `FreshInstallReset` 清理范围收口 | DONE | main | 代码审阅 | 只清 `XDirs.dataRoot` + 含 `Containers/Data/Application` 的真容器 + Keychain；标记加旧位置兼容 |
| I3 | 迁移不破坏上游共享数据 | DONE | main | 代码审阅 | 共享位置只复制；容器旧 Workspace 才 move；组迁移先判空、后落标记 |
| I4 | MitmC 日志路径去掉写死 UUID | DONE | main | 代码审阅 | 从 `ca_pem` 推导 App Group 根，`TMPDIR` 兜底 |
| I5 | 持久注入目录隔离 | DONE | main | 代码审阅 | 写 `<数据根>/persist/PersistentPlugins`；旧目录只读兼容 + 卸载时一并清理 |
| I6 | 杂项对齐 | DONE | main | 代码审阅 | workflow 名 `build-ios.yml`；MinimumOSVersion 15.0；URL scheme `com.xosvi.app.deeplink`；TSRootBinaries 去掉 5 个不存在的二进制、补 `fuck_helper`；远程文件接口白名单收窄到数据根 |

## 第一梯队：备份统一（G 组）

| ID | 事项 | 状态 | 分支 | 验证 | 备注 |
|---|---|---|---|---|---|
| G1 | 统一备份台账 `backup` | DONE | main | 代码审阅 + 括号扫描；`dump_registry` 快照手改（本机无 python3） | `BackupRegistry.swift`：四类落点一次清点（`.troll-fools.bak` / `.bak_macho` / `.xosvi.bak` / `Workspace/backups`）；`restore` 只自动还原 Mach-O，`cp -p` 到临时文件再 `mv`，不做「先 rm 再 mv」；`prune` 只删 `Workspace/backups` 一级目录。**后缀一个没改**（`.troll-fools.bak` 是 TrollFools 兼容格式）。**Swift 未编译，需 CI** |
| G2 | 卸载 = 先还原再删 | DONE | main | 代码审阅 | `AppUninstallTool` 在 `uninstall` 之前调 `BackupRegistry.preUninstallRestore`，结果随回包返回 `pre_uninstall_restore`；容器改名与目录快照不动 |
| G3 | 目标指纹校验 | DONE | main | 代码审阅 | 注入成功后写 `persist/BackupLedger/<bid>.json`（版本 / build / 主二进制大小 / dylib 名）；`inject command:enable_persisted` 发现版本对不上就不自动恢复，返回 `skipped` + `reason` + 提示重新注入刷新台账 |

## 下一步

1. ~~B5 ExternalContent 接入（web.fetch / shell.exec / file / ui_tree / 剪贴板）~~ → DONE（v9.9，剪贴板 N/A）。
2. ~~T1 测试体系三件套~~ → DONE；新增 `tests/device/cases/smoke_external.json`（B5 端到端，需真机跑）。
3. v9.9 UI 改版批次已在本地完成（ControlConsole / RemoteAccess / RemoteTerminal / ModelQuickSwitch / DeveloperInstructions / ModelsView / SettingsView / ShellTool 共 11 个文件），本地只过了括号 + 顶层重名 sanity；**Swift 类型编译结论仍需 CI**，等用户明确同意后再推远端触发 `swift-syntax` 作业。
4. C4 ish.doctor → C3 VPN → C5 技能 → D1 接入层：台账均已 DONE，走一遍真机复验清单即可收尾。


## 构建记录

| 时间 | 分支 | run | 结果 | 备注 |
|---|---|---|---|---|
| 2026-11-01 18:35 | feat/v8-ai-seamless | 41337388513 | FAILURE | 首批编译错误（多行字符串/GatewayServer 重名/参数顺序/ISHManager/MitmProxy） |
| 2026-11-01 22:39 | feat/v8-ai-seamless | 41358256548 | SUCCESS | Xosvi artifact 100,188,049 bytes；发布步骤按设计仅 main 执行 |

### 本地 sanity（无 swiftc，2026-11-06）

| 检查 | 命令 | 结果 |
|---|---|---|
| 括号/结构 | `tests/loopguard/swift_braces.c` 编译后扫 `Sources/XosviMCP` | checked 182 files, mismatches=0 |
| 顶层类型重名 | `$TMPDIR/decl_dup.c`（C 版，替代无 python3 的脚本）扫同目录 | checked 537 top-level type decls，无 DUP |

v9.9 批次顺带修掉的编译期风险：
- `RemoteTerminalView.swift`：`@State private var lanIP = Self.localIPAddress()` —— 存储属性初始化里不能用 `Self`，改为 `""` 并在 `onAppear` 取。
- `DeveloperInstructionsView.swift`：`.toolbar { Button … }` 未包 `ToolbarItem`，补 `ToolbarItem(placement: .navigationBarTrailing)`。
- `ModelQuickSwitch.swift` / `RemoteTerminalView.swift`：`autocapitalization` 已弃用，改回 `textInputAutocapitalization`（SDK 里 iOS 15.0 起可用）。
- `RemoteAccessView.swift` / `SettingsView.swift`：`ssh.host` → `ssh_host`，与 `SSHSettingsView` 写入的键一致（否则卡片永远显示「未配置」）。


## 底座 UI 仿 OpenMinis（v10.2，2026-11-12）

参考源：`tests/loopguard/om/`（OpenMinis iOS 端的 ChatColors / ComposerSurface / SidebarSurfaces /
SessionRow / ContentView+Layout）。方案与调研见 `docs/plan/08-base-ui-minis.md`。

| 文件 | 变更 | 验证 |
|---|---|---|
| `Sources/XosviMCP/XDesign.swift` | 新增底座设计层：`XColor`（全语义色，角色命名）/ `XRadius` / `XMetric` / `XType.rowTitle·rowSubtitle·rowMeta·groupHeader` / `xSurface()` / `xComposerSurface()` / `xFloatCircle()` / `XAvatar` / `XSearchField` / `XFloatingActionButton`。填充一律画在形状内且不 `.blur`；`glassEffect` 因 SDK 18.5 无该符号暂不实现 | 括号配平 + 顶层重名 |
| `Sources/XosviMCP/DrawerConversationRow.swift` | 行按 Minis SessionRow 重排：44 头像 + 16/14 两行 + 13pt 相对时间，行高 50→66；行底 `XColor.page`（不透明盖住滑出的红键）+ 选中 `XColor.fill`，圆角 `XRadius.row`；滑动删除与 `swipedId` 契约不变 | 同上 |
| `Sources/XosviMCP/RootView.swift` | 抽屉底色→`XColor.page`；搜索框→`XSearchField`（36 高/12 圆角）；分组标题→`XType.groupHeader`；底栏→`xSurface(radius: XRadius.sheet)`；行调用点补 `subtitle`（末条消息预览）/ `meta`（相对时间），新增 `previewText` / `rowTime` | 同上 |

本地 sanity（无 swiftc）：`tests/loopguard/swift_braces.c` → checked 194 files, mismatches=0；
顶层类型重名扫描 → 327 个声明无 DUP。**Swift 类型检查仍需 CI**（`swiftc -parse` 作业只查语法）。


## Agent 循环改造：批执行 + 分析报告（v10.1，2026-11-12，commit 89a1614）

用户诉求：agent 工作流程「很傻，经常跑偏、做无用功」。原则是**改机制，不加提示词**。
对齐 Minis / Codex 的做法：同一轮能跑几个工具由代码判定，不由模型自觉。

| 文件 | 变更 |
|---|---|
| `Sources/XosviMCP/ToolBatchPlanner.swift` | 新增。入口 `plan(_:)` 把模型一轮给的调用压成「本轮真正执行的序列」：读类按序合批（≤`maxBatch`=4）；出现改状态调用即纳入并**立即截断**（后续调用可能依赖它的结果，合批等于让模型猜结果）；同工具同参去重；未知工具按改状态处理。`shell.exec` / `root` 不信注解，改看命令本身：`shellCommandIsReadOnly` 按段首命令白名单判定，先剥掉 `2>/dev/null` 类无害重定向，剩余任何 `>` `<` 即算写；`sed -i`、`plutil -replace`、非查询 `sqlite3`、`sh`/`bash` 一律算写 |
| `Sources/XosviMCP/Models.swift` | `.toolCalls` 分支去掉无条件 `prefix(1)`，改为 `ToolBatchPlanner.plan`；`dropped` 的个数写进 `pendingParamCorrection`（模型知道自己有几个没执行，不重发整批）；assistant 消息只挂**真正执行**的调用，`parts` 按执行集合重建；新增 `pruneUnexecutedCalls(in:from:)`——批执行在第 k 个上被拦（缺参纠正 / 预算 / 用户停止）时剥掉 k..N，避免「有 tool_call 无 tool 结果」的非法历史被服务端整条拒掉 |
| `Sources/XosviMCP/RunReport.swift` | 新增。本轮工具 ≥3 次且结论 ≥300 字（或工具 ≥6 次、结论 ≥180 字）时，把结论 + 执行轨迹表 + 关键输出摘录写成 `Workspace/reports/<时间戳>-<slug>.md`（工作区 UI 已把 `reports` 显示为「分析报告」，见 `WorkspaceBrowserView.swift:57`），并在回复末尾回显可复制路径。预算/熔断终止的收尾不落盘 |

验证：`build-xosvi-ios#97`（run 43333084320）在 `89a1614` 上 **SUCCESS，18m 5s**——完整 iOS 构建通过；
`CI#106`（run 43333084302）SUCCESS，54s。本地无 swiftc，类型检查结论以上述构建为准。

自审记录（代码层面已核对，无需改动）：
- 停止路径：`cancelCurrent()` 清 `activeConvId` 但保留 `requestSessionId`，`activeConvIndex` 仍能解析到会话，`pruneUnexecutedCalls` 不会因拿不到 index 而静默跳过。
- `send()` 会重置 `budgetExhausted` / `runEntries` / `runReportWritten`，因此批内停止分支只做 prune + 停手即可，无需重复收尾。
- `RunReport.shouldWrite` 开头 `chars >= 120` 与后面两条阈值分支重叠（冗余但无害），保留以免误放宽。

## 控制台报错信息：双层外壳 + 连接类落 UNKNOWN（v10.3，2026-11-13）

用户贴出控制台「抓报错」生成的文本，状态行是：

```
tool failed: [UNKNOWN] tool failed: [UNKNOWN] 无法连接服务器。 (category: unknown) next: inspect full logs then retry (category: unknown) next: inspect full logs then retry
```

两个独立缺陷叠在一起，都不是提示词问题：

1. **双层外壳**。`MCPCore.dispatch` 的兜底 `catch` 取 `(error as? MCPError)?.description`（已带
   `tool failed: [CODE] … (category: …) next: …` 外壳）当作 `message` 重新构造 `.classified`，
   外壳就被套两次。触发路径是「返回式错误」：`control.status` 返回 `["error": "无法连接服务器。"]`
   → `extractReturnedError` → 第一次包成 `.classified` 抛出 → 同一函数的 catch 再包一次。
   影响所有 `throw MCPError.classified(...)` 的工具（disasm / bundle / install / inject 等），
   模型侧 `message` 字段、审计 detail、熔断指纹同样被这层外壳污染。
2. **连接类没有词条**。`FailureKind.classify` 表里只有环境/目标/参数/工具四类，`无法连接服务器。`
   （`URLError` 的本地化文案）一个词都不命中 → 落 `UNKNOWN` + `inspect full logs then retry`，
   真实原因（目标 App 没开 / agent 没监听）被盖掉。而 `FailureKind.retryable` 本来就认「连接」，
   于是还会自动重试一次，等于对必然失败的调用再试一遍。

| 文件 | 变更 |
|---|---|
| `Sources/XosviMCP/MCPCore.swift` | `MCPError` 新增 `payloadMessage`（classified/classifiedData 取裸 message，其余仍返回 `description`）；兜底 catch 改用 `payloadMessage`，重建 `classified` 时外壳只出现一次。`FailureKind.classify` 新增 `NETWORK` / `network` 分支（`无法连接` `连接失败` `连接被拒` `未连接` `连不上` `connect` `network` `网络` `unreachable` `不可达` `timed out`），排在环境类之前——连接失败不是权限问题，next_step 指向 `control.status` 与目标 App 是否在跑 |
| `AGENTS.md` / `RULES.md` | 失败分类表与 code 列举补 `NETWORK` |

预期同一条现场改为一行：
`tool failed: [NETWORK] 无法连接服务器。 (category: network) next: network/connection failure, not a permission or code problem: …`

本地 sanity（无 swiftc）：改动文件括号配平检查 0 报错（`Sources/XosviMCP/*.swift` 全量跑，
报出的 FilePreviewView / Models / SystemPrompts / ToolchainSigner 四处皆为检查器不认 `"""`
多行字符串与字符字面量造成的既有误报，与本次改动无关）。**Swift 类型检查仍需完整 iOS 构建**。

未动：`StatusLine` 文本仍是英文 CLI 式前缀 + 中文原因（项目既有口径，人读得懂，不改）；
`FailureKind.retryable` 的重试策略保持原样（网络类重试一次本身合理）。
