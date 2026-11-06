# Runbook：HID 触摸注入验证矩阵

> 适用：`Sources/XosviMCP/ControlUITools.swift` 中的 `HIDTouchInjector`（IOHIDEventSystemClient 合成触摸）。
> 该实现全部符号用 `dlsym` 动态加载、代码自述"云端无法真机验证，按社区通用实现"，因此必须**按环境逐项留档**。
> 本文件是**可执行清单**：命令全部使用真实注册工具名，结果按 `✅PASS / ⚠️PARTIAL / ❌FAIL + 备注` 填表。

## 0. 先读：HID 的唯一致入口

| 事实 | 说明 |
|---|---|
| `control` 不走 HID | `control command:tap / swipe / type / key` 全部经 **ControlAgent**（注入 dylib，localhost:4789 HTTP），与 HID 无关 |
| HID 只由 `macro` 回放触发 | `MacroRunner.execute` 把 `ui.tap` / `ui.long_press` / `ui.swipe` 三步交给 `HIDTouchInjector`；没有单独暴露 HID 的工具 |
| 录制不可用 | `macro command:record` 只置录制标志，`MacroRecorder.capture` 目前**没有调用点**，`macro command:stop` 会因 0 步报 `macro is empty`。要跑 HID 必须**手写宏 JSON** |
| 失败原因不外露 | `macro command:run` 失败只抛 `step N failed`（`MacroRunner` 仅返回 Bool），`ensureClient()` 的 reason 不会进工具返回。判定必须靠"界面有无变化 + `ui_tree` 对比 + 设备日志" |

因此本矩阵测的是"**HID 这条腿**"；`control` 那条腿用同样用例做对照组，才能区分"HID 坏了"与"坐标算错了"。

## 1. 环境列

| 代号 | 环境 | 备注 |
|---|---|---|
| E1 | iOS 15.6 + TrollStore | 老系统边界 |
| E2 | iOS 16.3 + TrollStore | ReplayKit 崩溃环境（截图走 ControlAgent 降级链） |
| E3 | iOS 17.0 + TrollStore | ct_bypass 上限 |
| E4 | iOS 17.x + rootHide 越狱 | 越狱差异（`posix_spawn` 可能 85 / ENOSYS） |

每台设备开始前先记录：`device command:info`、`system.overview` 的 `version`、机型、屏幕 scale（2x / 3x）。

## 2. 前置条件（不满足不开始）

1. TrollStore 已开启「编辑 Entitlements」，且**卸载重装**过本 App（`com.apple.private.hid.client.event-dispatch` 随安装写入）。
2. 目标 App 已安装并置于前台；已用 `control command:inject` 注入 ControlAgent（对照组需要）。
3. `control command:status` 返回 `connected: true`（该调用内部最多重试 4 次、每次间隔 0.6s）。
4. 工作区可写：`Workspace` 固定在 `/var/mobile/Documents/wiki.qaq.xosvi/Workspace`（v9.12 起的独立数据根，不再在 App 沙盒里）。

## 3. 校准流程（每个环境做一次）

```text
# ① 取目标元素与屏幕信息
control command:ui_tree
control command:screenshot

# ② 从 ui_tree 里选一个稳定元素（有 text/label、frame 不随滚动变化），记下 frame 中心点 (x, y)（单位 pt）

# ③ 写 HID 探针宏（一次点击）
artifact command:write filename:macros/hid_tap_probe.json text:'{"name":"hid_tap_probe","created":0,"steps":[{"tool":"ui.tap","params":{"x":200,"y":400,"reason":"hid probe"}}]}'

# ④ 跑宏（阻塞直到回放结束；失败会抛 step N failed）
macro command:run name:hid_tap_probe step_delay_ms:300

# ⑤ 再取一次树，比较命中前后
control command:ui_tree
```

判定"命中"的客观口径（`ui_tree` 返回体**不含** `screenSignature` 字段，签名由 App 内 `ControlTreeKit.screenSignature` 计算；外部用等效哈希）：

```text
# 把两次 ui_tree 结果分别存文件后比对结构差异（推荐）
control command:ui_tree        # 结果存 ui_tree_before.json
control command:ui_tree        # 结果存 ui_tree_after.json
shell.exec command:"shasum -a 256 /var/mobile/Documents/wiki.qaq.xosvi/Workspace/ui_tree_before.json /var/mobile/Documents/wiki.qaq.xosvi/Workspace/ui_tree_after.json"
```

- 哈希不同 + 目标界面出现预期变化 → ✅
- 哈希相同但目标有响应（如键盘弹起） → ⚠️（树未刷新，补截图）
- 无任何变化 → ❌，先重跑对照组（`control command:tap x: y:`）确认是 HID 还是坐标问题。

## 4. 用例矩阵

每格填 `✅PASS` / `⚠️PARTIAL` / `❌FAIL` + 备注（设备、偏差 pt、日志片段）。

| # | 用例 | 执行方式（真实命令） | 客观判据 |
|---|---|---|---|
| 1 | HID client 创建 | `macro command:run name:hid_tap_probe` | 宏回放不报 `step 1 failed`；否则记录失败环境（reason 需从设备日志取） |
| 2 | 中心点 tap | 宏步骤 `ui.tap`，坐标 = `ui_tree` 元素 frame 中心 | 前后 `ui_tree` 哈希变化；对照组 `control command:tap x: y:` 同样变化 |
| 3 | 边缘 tap | 宏步骤 `ui.tap`，`x = 1`、`y = 1`；再测 `x = 屏宽-2` | 无崩溃、无 `step N failed`；事件是否落地记录到备注 |
| 4 | 长按 600ms | 宏步骤 `ui.long_press`，`duration_ms: 600` | 触发长按态（菜单/拖拽），或界面变化 |
| 5 | 长按 1500ms | `duration_ms: 1500` | 同上且更稳（`longPress` 真实 `sleep` 该时长） |
| 6 | 横向滑动 300px / 200ms | 宏步骤 `ui.swipe`，`duration_ms: 200`，Δx=300 | 翻页/切换；`ui_tree` 首项或页面标识变化 |
| 7 | 纵向滑动 600px / 400ms | `ui.swipe`，Δy=600，`duration_ms: 400` | 列表滚动（对比滚动前后 `ui_tree` 首项） |
| 8 | 惯性滚动中 tap | 先 `ui.swipe` 大 Δy，紧接 `ui.tap`（宏内两步、`step_delay_ms: 50`） | 事件不被吞（点击目标有响应） |
| 9 | 2x 屏坐标精度 | 选一元素，`ui_tree` 期望中心 vs 实际命中点 | 偏差 ≤ 2pt（截图量像素后换算） |
| 10 | 3x 屏坐标精度 | 同上（3x 设备） | 偏差 ≤ 2pt；注意 `HIDTouchInjector` 内部按 `UIScreen.main.scale` 把 pt 转 px |
| 11 | VPN 隧道开启时 | `vpn.capture command:start` 后重跑用例 2 | 仍 PASS（HID 与隧道互不影响） |
| 12 | 与 ControlAgent 并存 | 目标 App 已注入 ControlAgent，重跑用例 2 | HID 与 `control command:tap` 两条路径都能工作 |

宏模板（按用例改 `tool` / `params`）：

```json
{
  "name": "hid_case",
  "created": 0,
  "steps": [
    {"tool": "ui.tap",        "params": {"x": 200, "y": 400, "reason": "case 2 center tap"}},
    {"tool": "ui.long_press", "params": {"x": 200, "y": 400, "duration_ms": 600, "reason": "case 4"}},
    {"tool": "ui.swipe",      "params": {"x": 200, "y": 700, "x2": 200, "y2": 100, "duration_ms": 400, "reason": "case 7"}}
  ]
}
```

> 写入方式：`artifact command:write filename:macros/hid_case.json text:'<上面的 JSON 单行>'`。
> 宏文件名即 `macro command:run name:` 的名字（扩展名 `.json` 由 `MacroStore` 追加）。

## 5. 降级决策树

```text
HID 用例失败（对应环境）
├─ 宏回放第 1 步就 failed（疑似 ensureClient 失败：entitlement / IOKit 符号不可用）
│     → 记录环境 + 机型，标注「HID 不可用」，默认切 ControlAgent
│     → 排查：TrollStore「编辑 Entitlements」是否开启 → 卸载重装 → 再跑用例 1
├─ 宏回放成功但界面无变化（事件不落地）
│     → 先用 control command:tap 验证坐标本身是否正确
│         ├─ 对照组有效 → HID 事件被系统吞掉 → 标注「HID 不落地」，切 ControlAgent
│         └─ 对照组也无效 → 是坐标/前台 App 问题，不是 HID 问题
└─ 两条路径都失败
      → 明确报错并说明原因（不静默降级），引导用户检查：
         1) TrollStore「编辑 Entitlements」→ com.apple.private.hid.client.event-dispatch
         2) control command:status 是否为 connected:true
         3) control_agent.log 尾部（/var/mobile/Documents/wiki.qaq.xosvi/Workspace/control_agent.log）
```

## 6. 证据采集与归档

每个环境各留一份：

1. 录屏（系统录屏或外部拍摄，覆盖用例 2/4/6/8）；
2. `control_agent.log` 尾部：`shell.exec command:"tail -n 200 /var/mobile/Documents/wiki.qaq.xosvi/Workspace/control_agent.log"`；
3. 矩阵表截图/CSV（本文件的表 + 填写结果）；
4. `device command:info` 与 `system.overview` 输出（版本/机型/iOS）。

归档目录约定：`tests/device/results/hid/<环境代号>-<机型>-<iOS版本>/`（仓库当前只有 `tests/vanson/`，首次执行时新建）。
