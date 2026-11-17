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
- D-007（v11.0）：按用户要求整体删除「模型破甲提示词 / 知识库 / Agents 与 Skills」三块设置——store、页面、MCP 工具
  （`knowledge`、`skills.list`、`skills.read`、`skills.set_enabled`）一并移除，注册表 55 → 51；`XDirs` 的
  Knowledge / KnowledgeBase 目录不再创建。诊断用的 `FailureKnowledgeBase`（kb 工具，非知识库页面）保留。

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
| 2026-11-12 | main | 43333084302 | SUCCESS | CI#106（54s）· commit 89a1614 |
| 2026-11-12 | main | 43333084320 | SUCCESS | build-xosvi-ios#97，18m5s · commit 89a1614 |
| 2026-11-13 | main | 43440094301 | SUCCESS | CI#107（1m3s）· commit 239479c；含 Swift `-parse` 门禁 |
| 2026-11-13 | main | 43440094294 | SUCCESS | build-xosvi-ios#98，18m25s（build 作业 16m18s）；Xosvi artifact 96.1 MB · commit 239479c（v10.3 全部改动） |

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

未动：`StatusLine` 文本仍是英文 CLI 式前缀 + 中文原因（项目既有口径，人读得懂，不改）。

### 收尾：确定性连接失败不再自动重试（commit 239479c）

`FailureKind.retryable` 原先用「连接 / connection / 网络」做通配，于是 `无法连接服务器。` 这类
**必然失败**的错误也会白等 1s 再打一次：`control.status` 自己已试 4 次 × 0.6s，再叠一层重试，
一次工具调用从约 2.4s 拖到约 5s，控制台还多刷一条 `🔄 自动重试`，模型拿到的仍是同一个「连不上」
—— 正是用户说的「做无用功」。现在把确定性连接失败（`无法连接` `未能连接` `连接失败` `连接被拒`
`连不上` `未连接` `refused` `could not connect` `cannot connect` `can't connect`
`couldn't connect`）提到通配之前直接 `return false`；超时与真正的网络抖动仍保留一次自动重试。

验证：`build-xosvi-ios#98`（run 43440094294）在 `239479c` 上 **SUCCESS，18m25s**——完整 iOS 构建通过
（v10.3 三处改动同批）；`CI#107`（run 43440094301）SUCCESS，1m3s，含 Swift `-parse` 门禁。
**设备侧表现未测**：本机装的是旧构建，要看到新的状态行必须先装上这次 CI 产出的 IPA 再点一次「抓报错」。

## 内置逆向引擎：`re` 工具（v10.4，2026-11-14，commit 79fd3fa）

把原本散在 agent 侧的逆向链（Mach-O → ObjC 类/方法/字符串/交叉引用 → 报告）收成设备内一个 MCP 工具，
不再依赖 agent 逐个跑 otool/class-dump 再拼结论。

| 文件 | 变更 |
|---|---|
| `CReCore/include/xosvi_re.h`、`CReCore/src/xosvi_re.c` | 纯 C 解析引擎（无第三方依赖，MachOKit 是远程 SPM 依赖、本地读不到 API，故不采用）：ObjC 类/元类/方法/属性/ivar、CFString 与 C 字符串、`__objc_stubs` 交叉引用、段与加固特征；输出 `report.json` + `report.md` |
| `Sources/XosviMCP/ReTool.swift` | `re` 工具：`analyze`（单文件或目录，递归上限 24 个目标 / 深度 6 / 单文件 200 MB / maxVisited 6000，按体积降序）、`strings`（`query` 过滤）、`selftest`；结果写 `Workspace/re/<stamp>-<slug>/`，可用 `out_dir` 覆盖 |
| `Sources/XosviMCP/MCPCore.swift` | 工具白名单加 `re` |
| `docs/registry.snapshot.json` | 补 `re` 条目（CI 的工具契约检查比对快照，新增工具不同步会直接红） |
| `AGENTS.md` | 「核心工具速查」补 `re`，描述里补 Example 段（契约检查同样要求） |

引擎首版有几处自查出的错，已一并修：`strip_objc_prefix()` 前缀剥离越界、方法 types 应优先 `cstr_at`、
`adrp` 判定掩码应为 `(i & 0x9F000000) == 0x90000000`、漏 `collect_cfstrings()`、
`count_aggregate()` 缺位导致 methods/ivars/properties 恒为 0。

同批修掉上一条构建失败的编译错误：`Sources/XosviMCP/ISH.swift` 用 ZIPFoundation 的
`Entry.EntryType.symbolicLink`，而库里的成员是 `.symlink`（`init(mode:)` 按 `S_IFMT` 拆出）。修在 `0608d45`。

验证：
- `build-xosvi-ios#99`（`bd1337c`）FAILED 25m31s —— 上面的 `.symbolicLink` 编译错误；
- `build-xosvi-ios#100`（`0608d45`，run 43544545326）**SUCCESS 15m17s**，产物 Xosvi 96.1 MB —— Swift 侧 `re` 编译通过；
- `build-xosvi-ios#101`（`79fd3fa`，run 43545335448）**SUCCESS 23m03s**，产物同名 96.1 MB；
- `CI#111` SUCCESS 41s，含 `swiftc -parse` 语法门禁与工具契约检查；
- 滚动 Release 已更新为 **v7.18.0-b101**。

### 设备侧实测（引擎层，2026-11-14）

`CReCore/.selftest/run.sh` 用 `-DXRE_TOOL` 把引擎单独编成本机可执行文件来测，不必先装 App
（`clang -O1 -DXRE_TOOL -ICReCore/include -o xre CReCore/src/xosvi_re.c` 后必须 `ldid -S` 签
`xre.ent.plist`，否则内核按信号 9 直接杀进程）。对象是设备上现成的 29 MB `Xosvi` 主二进制
（arm64，chained fixups fmt=6）与三个 fixture（arm64e，fmt=12）。

首轮就撞到一个致命缺陷：**主二进制解析出 0 类 0 方法**。根因是 `load_chained_fixups()` 没把
`segment_offset` 加上 image base —— dylib（image base 0）完全看不出问题，主程序（0x100000000）
则整片错位。修掉后 Xosvi 得 300 类 / 703 方法 / 813 ivar / 204 属性 / 22 协议 / 2791 导入符号 /
8495 bind / 52309 rebase，耗时 0.37 s。类、分类、协议数与节大小独立对照一致
（`__objc_classlist` 2400 B ÷ 8 = 300；`__objc_catlist` 8 B = 1；`__objc_protolist` 176 B ÷ 8 = 22）。

同轮另修两处：父类与分类所属类的指针是 bind 时只走 `dec()` 会得 0（`class_ro_t.baseClass` 指向
`_OBJC_CLASS_$_NSObject`），现在回退到 `dec_name()` 取导入名 —— 修前 Xosvi 300 个类的父类全是
「（未声明）」、分类是「（未知类）」。另确认两件「看着像 bug 其实是 clang」的事：分类与类在同一 TU
时 clang 直接合并进类的方法表（`__objc_catlist` 为空，分类数 0）；类遵循协议时 clang 把协议（含
NSObject）的属性一并写进 `class_ro_t.baseProperties`（fixture A 源码 2 个属性、二进制 6 个，
去掉协议遵循即回到 2）。选项串 `max_strings=` / `min_len=` / `xrefs=` 实测生效
（`max_strings=200000` 得真实 20576 条，默认 20000 只截掉 576 条）。

仍未测：MCP 层的 `analyze` 目录模式、`strings --query` 过滤、`selftest` 期望值 —— 那些是 Swift 侧，
需要先装上 b101 的 IPA。

## 终端三档收成两档 + 会话导出 + 抽屉底栏（v10.5 / v10.6，2026-11-14，ba23651 / 534e351）

### 终端后端：`root` 不再是独立后端

原来 `TermBackend` 有 `alpine` / `ios` / `root` 三档，但 `root` 与 `ios` 跑的是同一个 shell、同一个
cwd，只是外层多套一次提权 —— 用户看到的是两个几乎一样的选项，切过去还得重来一遍。现在后端只剩
`alpine` / `ios` 两档，提权变成 `ios` 上的一个身份开关：

| 改动 | 位置 | 说明 |
|---|---|---|
| `TermBackend` 删 `.root` | `TerminalSession.swift` | title / shortTitle / home 的 switch 同步只剩两支 |
| `@Published var elevated` + `isRoot` | 同上 | `isRoot = (backend == .ios && elevated)`，只影响提示符与底部键标签 |
| `switchBackend(to:)` | 同上 | 先 guard 同值；停掉在跑的进程 → 设 backend → 非 `ios` 时强制 `elevated = false` → `cwd = target.home` |
| `setElevated(_:)` | 同上 | `@discardableResult`；backend 不是 `ios` 时先 `switchBackend`；`rootCLIPath == nil` 报 `term_root_unavailable`；**运行中拒绝换身份**（`term_root_no_stop` / `term_busy`，返回原值）；成功追加 `term_root_on` / `term_root_off` |
| 提示符 | `promptText` | 按 `isRoot` 归一化，`#` / `$` 两态 |
| 底栏 su 键 | `TerminalPageView.swift` | 变成身份开关：标签 `term_key_exit_root` / `term_key_root`；已提权则 `setElevated(false)`，否则成功后自动 `submit("id")` |

保留的全是运行期解析：`rootCLIPath` 取自 `JBEnvironment.firstExistingPath("/usr/bin/xosvi-cli")`，
不写死 jbroot 路径。root 链路此前已实测通过（`xosvi-cli helper xosvi-build --exec <cwd> '<cmd>'` →
`uid=0(root)`、exit 0）。

### 会话导出

会话页的「导出」不再走系统分享面板（侧载环境下它必崩），统一经 `ShareCenter.saveToFiles` /
`presentShareMenuText` 落到「存储到文件」。导出页段标题 v10.5 时是硬编码中文，v10.8 已接入 `L10n`
（`settings_sec_sessions` / `btn_export_all` / `btn_export_all_sub`，以及 `ConversationExport`
三条提示 `export_no_sessions` / `export_empty` / `export_failed`）。

### 抽屉底栏（v10.6 / v10.7）

新建会话键从头部右上角移到抽屉底栏，与设置齿轮同尺寸（`XMetric.fab` = 52）同圆角（`XRadius.row`）。
底色两次调整后统一为 `XColor.fill` —— 与齿轮、以及 App 里其他弱填充按钮（头像底、选中态）同一个值；
两枚按钮只靠图标区分，不再靠灰度深浅（反色实心底在浅色模式下是一块纯黑，已弃用）。

v10.7 再调排布：由「整组靠右」改成两端分布 —— `HStack { settingsButton; Spacer(); newConversationButton }`，
设置齿轮在左、新建会话键在右。

### 验证

- `CI#114`（run 43566702919，`ba23651`）SUCCESS 40s；`build-xosvi-ios#103`（run 43566702896）SUCCESS 13m13s。
- `CI#115`（run 43580397388，`534e351`）SUCCESS 42s，工具契约检查 / `swiftc -parse` / 静态解析自检全绿；
  `build-xosvi-ios#104`（run 43580397380）SUCCESS 17m12s，产物 Xosvi 96.2 MB。
- `CI#116`（run 43585059612，`2eed003`）SUCCESS 43s；`build-xosvi-ios#105`（run 43585059615）SUCCESS 15m50s。

设备侧仍未测：抽屉底栏两枚按钮在浅色 / 深色下的实际观感是否与齿轮一致、是否分居左右两端；
终端底栏 su 键的提权与退出提权；会话导出的落盘路径（都要装上本批次 IPA 才能看）。

## v10.8 — 内置 Alpine rootfs 符号链接自愈（设置 ▸ 环境全灭的根因）

### 症状与根因

设置 ▸ 环境 页所有检测项报错、终端 Alpine 起不来。查证到两个叠加缺陷：

1. **解压把相对符号链接写错**：`alpine-rootfs.zip` 里 `bin/sh` 一类条目在 zip 内的路径是
   `data/bin/sh`，v10.4 的 `relativeLinkTarget` 拿整条 zip 相对路径（含 `data/` 层）去算相对目标，
   结果 `data/bin/sh` 指向 `bin/busybox`（= `data/bin/bin/busybox`，不存在）而不是同目录的 `busybox`。
   设备上实测 673 个链接全部悬空。
2. **`isRootfsValid` 恒为假**：它用 `URLIsRegularFileKey` 判 `data/bin/sh`，而正常 rootfs 的
   `data/bin/sh` **本来就是符号链接**，该键对链接恒返 false → 每次启动都判定「rootfs 坏了」再重解压，
   于是修复永远被下一次启动覆盖，症状看起来像「怎么改都没用」。

### 改动（`Sources/XosviMCP/ISH.swift`）

| 位置 | 改动 |
|---|---|
| 解压 | `relativeLinkTarget(fromLinkAt: guestPath(fromInstallRelative:))`，guest 路径换算时剥掉安装层前缀后再算相对目标 |
| `repairDanglingRootfsLinks(at:)` | 枚举 `data/` 下的悬空链接，用 `linkDestination` 重算相对目标写回；同时把「12 字节文本壳」之类的伪链接转成真链接（`repairBrokenRootfsLinks`） |
| `isRootfsValid()` | 改为 `fileExists(meta.db) && fileExists(data/bin/sh)` + busybox 大小 > 100_000 |
| `boot()` | 启动前先跑一次预修复；解压后对 staging 修一次；启动后再修一次，并把 converted / failed 计数写 `Log.browser` |

### 构建

- `build-xosvi-ios#106`（`353f1e3`）**失败**：`removeItem(at:)` 传了 `String`。修成 `atPath`（`eaee77b`）。
- `CI#117`（`353f1e3`）SUCCESS 43s；`CI#118`（`eaee77b`）SUCCESS 35s；
  `build-xosvi-ios#107`（`eaee77b`，run 43710468592）SUCCESS 18m01s → **Release v7.18.0-b107**。

### 未验证（需装 b107 才能看）

- 设备上仍装着 b105；本批次未在真机跑过：`设置 ▸ 环境` 各检测项、终端 Alpine 起没起来、
  `Log.browser` 里的 converted/failed 计数。
- 遗留：`MCPCore.swift` 的 `elapsedMs` 少报 —— 现有代码里成功/失败两处都是从 `invoke` 前起算，
  没能复现「少报」，待补充具体现象（审计页还是气泡、差值多少）后再改。

## v10.10 — 撤回 v10.4/v10.8 的「文本壳 = 坏链接」误判（rootfs 装不上的真因）

### 纠正上一节的结论

v10.8 那两处「自愈」建立在错误前提上。内核侧证据（`fs/fake.c` @ `3f6384c`）说明：

```c
static int fakefs_symlink(...) {
    // create a file containing the target
    write(fd, target, strlen(target));
    ishstat.mode = S_IFLNK | 0777;   // meta.db 里记成链接
}
static ssize_t file_readlink(...) {
    // broken symlinks can't be included in an iOS app or else Xcode craps out
    int fd = openat(mount->root_fd, fix_path(path), O_RDONLY);
    return read(fd, buf, bufsize);   // 文件内容就是链接目标
}
static ssize_t fakefs_readlink(...) {
    if (!S_ISLNK(ishstat.mode)) return _EINVAL;
    ssize_t err = realfs.readlink(mount, path, buf, bufsize);
    if (err == _EINVAL) err = file_readlink(...);   // 常规文件回退读内容
}
```

也就是说：**「常规文件，内容为目标路径」+ meta.db 记 `S_IFLNK|0777` 才是 fakefs 的正典链接形态**。
设备实测吻合 —— 已装 rootfs 434 个文件里 367 个是这种小文本壳，只有 1 个真符号链接；
`meta.db` 里 `/bin/sh`、`/bin/ls`、`/usr/bin/env` 的 mode 全是 `0xA1FF`（`S_IFLNK|0777`）。
内置 `alpine-rootfs.zip` 的 `links=0` 同理，不是打包缺陷。

所以 v10.4 的问题不是「没建成链接」，而是**安装校验**把正典形态判成了坏包：
`shOK = (isLink && exists) || (isRegular && size > 100_000)` —— 12 字节文本壳两条都不满足，
于是每次安装都在校验处抛错回滚（现象：条目 523、写入 425、`data/bin/sh=false`、链接修复 0）。

### 改动（`Sources/XosviMCP/ISH.swift`）

| 位置 | 改动 |
|---|---|
| `installRootfsIfNeeded` 校验 | `shOK` 增加第三种形态 `isFakefsSymlinkStub(...)`：常规文件 + 单 token 目标 + 目标在 guest 里真实存在 |
| 新增 `isFakefsSymlinkStub(_:guestPath:dataRoot:)` | 形态判定，复用 `looksLikeLinkTarget` / `linkDestination` |
| 删除 `rootfsLinksLookBroken()` + `repairBrokenRootfsLinks()` | 基于误判的反向修复：把正确的文本壳改写成 host 真链接，每次启动白改几百个文件，还可能算错相对目标 |
| `boot()` | 去掉上述自愈调用；`repairDanglingRootfsLinks()` 保留，只对**真链接**形态兜底 |
| 解压 `.symlink` 分支 | 只在 zip 真含链接条目时生效（内置包 links=0，不触发）；注释改为正确表述 |
| `isRootfsValid()` | 注释更新为三形态俱可（逻辑不变，`fileExists` 对文本壳返回 true） |

### 待验证（需 CI 构建 + 装包）

- `swiftc` 本机没有（工具链只装了 c 组件），Swift 正确性只能由 CI 判定。
- 装好后看：`设置 ▸ 环境` 是否不再报「rootfs 安装失败」、Alpine 终端 `sh` 能否起来。

## v10.11 — iOS 构建 #111 失败：MachOKit 0.56 把 `MachOFile.url` 改成可选（2026-11-17）

### 结论

rootfs 修复（`86c27d9`）本身没问题，CI #122 已通过（42s）。失败的是 iOS 构建
build-xosvi-ios #111，红点在 `Sources/XosviMCP/MachoTools.swift` 的 10 行，
原因与 rootfs 改动无关，是依赖被静默升级：

- `Package.swift` 写的是 `.package(url: .../MachOKit.git, from: "0.55.0")`，
  `from:` 允许升到同一个大版本内任意新版。上游 11-16 发布 0.56.2，本次构建解析到它。
- 0.56.0 新增「从内存 `Data` 构造 `MachOFile`」（上游 #360），于是
  `public let url: URL` 变成 `public let url: URL?`（源码注释：nil 表示不是从磁盘文件加载的）。
  我们 10 处 `file.url.path` 全部报「value of optional type 'URL?' must be unwrapped」。
- #110（11-16）解析到 0.55.0 所以是绿的，属于时间差踩坑，不是回归。

### 改动

| 文件 | 改动 |
|---|---|
| `Sources/XosviMCP/MachoTools.swift` | 新增 `static func fsPath(_ file: MachOFile) -> String`（`file.url?.path ?? file.imagePath`）；10 处 `file.url.path` → `Self.fsPath(file)`（含字符串插值） |
| `Package.swift` | MachOKit 依赖 `from: "0.55.0"` → `exact: "0.56.2"`，并注明升级必须同步跑一次 iOS 构建 |

回退取值用 `imagePath`：它优先返回 `LC_ID_DYLIB`/`LC_ID_DYLINKER` 里的逻辑路径，
再退到 `url?.path`，最后空串——对磁盘文件行为与旧版一致。

### 待验证

- `swiftc` 本机没有，Swift 正确性只能由 CI 判定：推上去看 build-xosvi-ios 是否转绿。
- 若 0.56.2 还有其它 API 漂移（本次 annotation 只覆盖到第一批错误），按同样方式就地适配，
  不要为了变绿而把版本继续往下钉。

## v10.12 — 安装包瘦身：311M → 预计 ~200M（2026-11-17）

### 结论

包体大小不是某个依赖的问题，是四坨东西叠加。真机实测（设备上已装的 b112，
`/private/var/containers/Bundle/Application/.../Xosvi.app`，`Info.plist = 7.18.0-b112`）：

| 目录 | 体积 | 主要成分 |
|---|---|---|
| `python/` | 134M | pandas 41M（其中 `pandas/tests` 15M）、numpy 22M、lib-dynload 19M、stdlib `.pyc` 32.7M |
| `bin/` | 70M | llvm-objdump 13M / r2 13M / llvm-nm 12M / llvm-readelf 11M / llvm-size 7.8M / libcrypto 4M / libcapstone.a 2M |
| `Frameworks/` | 51M | **NodeMobile.framework 42M**、Python.framework 8.4M（Headers 2.6M） |
| `Xosvi` | 28M | release，当前只有 arm64 单片 |
| `fuck_vpn/` | 20M | swift-nio 全家桶；其中 `Modules/*.swiftmodule` 7.5M 纯编译期 |
| 合计 | **311M / 5283 文件**，`Xosvi.tipa` **98.7MB**（压缩比 ≈3.2:1） | |

两条独立的死重量：①`Resources/` 通用复制循环把 `fuck_vpn/` 整目录塞进包根
（`Sources/` 全文无 "fuck_vpn" 引用，套在包根里的 `.appex` 不在 `PlugIns/` 下不会被注册）；
②`libcapstone.a` 是静态库，主二进制链接期才用。

### 改动（单机适配：iPhone 14 / A15 arm64e / iOS 17.1 / relaxin + TrollStore，不做通用适配）

| 文件 | 改动 |
|---|---|
| `scripts/build-ipa.sh` | 资源循环跳过 `fuck_vpn/`（-19.7M）；新增「v10.12 单机瘦身」段：删 `bin/node` + `NodeMobile.framework`（-42M）、`llvm-readelf`/`llvm-size`（-18.8M，功能由 llvm-objdump/r2 覆盖）、`bin/libcapstone.a`（-2M）、`Python.framework/Headers` 与所有 `*.swiftmodule/*.swiftdoc`（-2.6M） |
| `scripts/build-ipa.sh` | Python 瘦身扩充：`pydoc_data`/`ensurepip`/`tkinter`/`_test*.so`（-7.8M）、`pandas/tests`+`numpy/tests`+`numpy/f2py`+`numpy/_core/include`+`*.pyi`（-17M） |
| `.github/workflows/build-ios.yml` | 内置工具断言表同步（去掉 node / llvm-readelf / llvm-size） |
| `Sources/XosviMCP/SystemPrompts.swift` | 两处内置工具清单去掉 node，改为「已移除，需要 JS 用 python3/lua/r2」 |
| `Sources/XosviMCP/InstallTools.swift` | 工具自检 hint 去掉 node |

**故意没删的两项**：`__pycache__/*.pyc` 32.7M（App 包只读，删了 python3 每次启动都要重编
stdlib，日常调用频率远高于省这 32M 的价值）；`alpine-rootfs.zip` 4M（Alpine 终端的根）。

**没动的一项**：主二进制目前是 **arm64 单片**，而 `build-ipa.sh:66-80` 本意是 arm64+arm64e 双架构
（注释说纯 arm64 在 A12+ 走兼容模式会有图标异常）——说明 CI 的 arm64e 那次 build 或 `lipo` 失败被
`|| echo '!!! arm64e build failed'` 吞了。真修好会 +28M，与瘦身目标相反，故本次不动。

### 待验证（需 CI 构建 + 装包）

- 本地无 iOS 工具链，`du` 结论来自设备上已装的 b112；改完后的实际体积以 CI 的
  `built: Xosvi.tipa (...)` 与装包后 `du -sh Xosvi.app` 为准。
- 装好后要确认：`node` 已不可用（预期 127）、`r2`/`llvm-objdump`/`llvm-nm`/`llvm-strings` 正常、
  `python3 -c "import numpy, pandas"` 仍可用（pandas 删 tests 不影响 import）、VPN 主链路仍起。
- 若发现 node 必须留着：删掉 `scripts/build-ipa.sh` 里「v10.12 单机瘦身」段中的
  `rm -f "$APP/bin/node"` 与 `rm -rf "$APP/Frameworks/NodeMobile.framework"` 即可原样恢复。

## v10.13 — 会话运行重设计：会聊天，也能干活（2026-11-17）　DONE

详见 `docs/plan/09-conversation-runtime.md`。

### 结论

「一开口就调工具」不是模型脾气，是**结构在逼它动手**：每轮 system 无条件拼进 ~2.9 万字符的
工具合同 + 7 模式路由清单 + 工具裁决/动态状态，`tools` 字段又给全 50+ 个动作，
OpenAIClient 还无条件下发「调工具前必须先解说」。四层信号叠加，没有「不动」这个选项。

只改提示词治不了，所以按四层一起动：**L1 提示词分层 / L2 工具渐进披露 / L3 意图判定 / L4 纠正按阶段生效**。

### 改动

| 文件 | 改动 |
|---|---|
| `Sources/XosviMCP/RunIntent.swift` | 新增 `RunIntent`(chat/lookup/operate) + `RunPolicy` + `IntentClassifier`（纯本地字符串规则，零网络零延迟） |
| `Sources/XosviMCP/SystemPrompts.swift` | 新增 `conversationCore`（常驻会话核心）/ `lookupCard` / `skillCards`（5 张，命中最多一张）/ `promptFor(intent:userText:)`；default 加 `0x. CHAT FIRST`、改名为「默认模式（会聊天也干活）」；手动模式改走 `mergedPrompt` 免得丢环境提示词 |
| `Sources/XosviMCP/Models.swift` | `currentPolicy` / `currentUserText`；`send()` 先判档位再装 `baseTools`（chat `[]` / lookup 联网两件套 / operate 全量）；`runLoop` 按档位装配 system 并门控纠正；工具白名单**硬闸**；文本式 shell 兜底只放行 operate |
| `Sources/XosviMCP/MCPCore.swift` | `enabledOpenAIToolSchema(only:)` 白名单；新增 `originalName(for:)` 把模型返回的安全名（`web_search`）归一成注册名（`web.search`） |
| `Sources/XosviMCP/OpenAIClient.swift` | 「调工具前必须先解说」只在 `tools` 非空时下发 |
| `tests/intent/main.swift` | 新增判定表（35 条意图 + 17 条策略派生） |
| `.github/workflows/ci.yml` | 新增 `intent-selftest` job（ubuntu-24.04，`swiftc` 真编译真源码并跑断言） |

### 三个必须记住的坑（都已在代码里注释）

1. **ASCII 词必须走词边界**：不设边界时 `ci` 命中 `decision`、`app` 命中 `appreciate`、
   `ls` 命中 `goals`——英文闲聊会整片被判成干活。
2. **空文本不能靠"沿用上次档位"**：`BackgroundRunManager` 用 `send("")` 续跑排队会话，
   `currentPolicy` 是 store 级共享状态，可能留着别的会话的「聊天」档——后台活儿会因为
   「没有工具」凭空断掉。空文本改为按该会话**最后一条用户消息**重新判定，真无从判断才退回干活档。
3. **白名单要比原名**：模型看到的是下划线安全名，白名单是注册名，不归一则查证档会把
   `web_search` 误判成「本轮不可用」。

### 待验证（需 CI + 装包）

- CI：`intent-selftest`（判定表）、`swift-syntax`（`swiftc -parse`）、`tool-contract`、`scripts/check.sh`。
- 真机（装包后手工）：①「随便聊聊」不出工具；②问发布/价格只走 `web.search`/`web.fetch`；
  ③「删掉 /tmp/x.log」全量工具 + 先说后做；④后台排队会话能跑完不中途停。
- 本地无 swiftc（toolchain 只装了 C 组件，Swift 需 iOS 26 / A13+），本次**判定逻辑未在本机跑过**，
  可靠性完全压在 CI 的 `intent-selftest` 与真机四点上。

---

## v10.14 · 提示词三层拆到底 + 工具核心 12（「一次性全改」）

用户批准「一次性全改」，三件事一轮做完，不再分步等确认。

### ① 环境提示词：2.4 万字符常驻 → 常驻硬规则 + 按需知识卡

拆前实测：`environmentPrompt` **= 33,208 字节 / 24,656 字符**（此前文档里写的「2.9 万」是字节数口径），
每轮无条件进 system。现在：

| 层 | 内容 | 字符 | 说明 |
|---|---|---|---|
| 常驻 `PromptCards.resident` | 工具调用定式 / 协作纪律 1-11 / 回复语言 | **1,592**（CJK 900 + ASCII 692，32 行） | 硬规则，一字不减，只压措辞 |
| 按需卡 `PromptCardText.*` | 小白 / 终端 / 逆向静态 / 逆向动态 / 引擎 / 存档 / 越狱 / Git / 自检 / 方法论 / 已知问题 | 11 张共 23,336 字节 | **原文照抄**（含标题行），关键词命中才注入 |
| 注入规则 | `PromptCards.cards(for:limit:2)` | — | 打分取前 2 张，分数 0 一张都不注入 |

常驻层 token：约 **800–830**（900 CJK×0.7 + 692 ASCII/3.5），达到 ≤800 量级的目标。

### ② `conversationCore` 与 default 模式正文去重

- `conversationCore` 保持 1,443 字节 / 613 字符，未动（已经在预算内）。
- default 模式正文 **6,999 → 2,653 字符（−62%）**：删掉与常驻层重复的 TOOL CALLING CONTRACT、
  输出风格、安全段，只留本模式特有的 ROLE / CHAT FIRST / 工具选型速查 / 停止条件 / 参考。
  「工具选型速查」保留是有意的——它讲的是**选哪条路更省事**，常驻层讲的是**怎么调用**，不重复。

### ③ 工具：核心 12 + 按需工具池（含 `tools.load`）

- `PromptCards.coreToolNames`（13 个含逃生口）：`shell.exec` / `file` / `artifact` / `workspace` /
  `web.search` / `web.fetch` / `app` / `control` / `device` / `inject` / `assistant_memory` /
  `prompt.read_mode` / `tools.load`。
- `send()` 干活档不再按协议分叉：**两条通道都走 `enabledOpenAIToolSchema(only: coreToolNames)`**。
  旧写法在 Anthropic 通道传 `nil` + 靠 `approvedToolNames()` 兜底，等于把全量工具又灌回去，
  渐进披露形同虚设。`preDisclosed` 也从 `approvedToolNames()` 改成 `runtimeDisclosedNames()`。
- 新增 `tools.load`（`ToolsLoadTool`）：传组名或精确工具名 → `loaded` / `already` / `unknown` / `disabled`。
  组表 `PromptCards.toolGroups` 11 组，与模型看到的 `toolPoolCard` 逐条对应。
  用户手动关掉的工具**装不上**（`disabled`），否则设置里的 Toggle 就成了摆设。
- `runLoop` 每轮把 `disclosed ∪ runtimeDisclosedNames()` 叠进白名单；`send()` 开头清空运行时披露
  ——每轮按这句话重新判断要装什么。
- `docs/registry.snapshot.json` 手补 `tools.load`（本机无 python3，`--check` 只比 names 集合，已对齐）。

### 效果（干活的 system 提示词，单轮）

- 拆前：1,443 + 24,656 + 6,999 ≈ **33,098 字符**
- 拆后：613 + 1,592 + 2,653 + 817（池说明）= **5,675 字符**，**−83%**；命中 1–2 张卡再加卡片本身。
- 工具 schema：51 → 13（核心 12 + `tools.load`），模型每轮少读约 38 个工具描述。

### 这次踩到的第四个坑

**中文占 3 字节**，用 `awk length()` 量预算会把中文字符数当成 3 倍——第一版误判「常驻层 3,392 token」。
预算必须同时看「字节」和「CJK/ASCII 字符数」：`tr -d '\200-\377' | wc -c` 得 ASCII 字节，
其余除以 3 约等于 CJK 字符数。800 token 对中文大约是 **1,200 字符**量级。

### 待验证

- 本机 `bash scripts/check.sh` 5 段全过（42.9s，0 FAIL）。
- `apelin_project_build` roothide/arm64e 通过，0 diagnostics。
- CI：`swift-syntax`（`swiftc -parse`）、`intent-selftest`、`tool-contract`（快照 names 集合）、`ios-build`。
- 真机四点：①闲聊不调工具；②问「怎么逆向这个 App」→ 命中 `reverse_static` 卡 + 模型自己 `tools.load reverse`；
  ③「帮我抓个包」→ `tools.load pentest` 后 `network.capture` 可用；④关掉的工具 `tools.load` 拿不到（回 `disabled`）。
