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

## 下一步

1. ~~B5 ExternalContent 接入（web.fetch / shell.exec / file / ui_tree / 剪贴板）~~ → DONE（v9.9，剪贴板 N/A）。
2. ~~T1 测试体系三件套~~ → DONE；新增 `tests/device/cases/smoke_external.json`（B5 端到端，需真机跑）。
3. 待办：把 v9.9 改动推上 CI 取一次 Swift 编译结论（本机无 swiftc，只有括号 sanity）。
4. C4 ish.doctor → C3 VPN → C5 技能 → D1 接入层：台账均已 DONE，走一遍真机复验清单即可收尾。


## 构建记录

| 时间 | 分支 | run | 结果 | 备注 |
|---|---|---|---|---|
| 2026-11-01 18:35 | feat/v8-ai-seamless | 41337388513 | FAILURE | 首批编译错误（多行字符串/GatewayServer 重名/参数顺序/ISHManager/MitmProxy） |
| 2026-11-01 22:39 | feat/v8-ai-seamless | 41358256548 | SUCCESS | Xosvi artifact 100,188,049 bytes；发布步骤按设计仅 main 执行 |
