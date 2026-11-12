# 底座 UI 仿 OpenMinis（Minis iOS）—— 视觉令牌层 + 抽屉/会话行改造

- 参考源：`tests/loopguard/om/`（从 GitHub 拉下来的 OpenMinis iOS 端源码，`src/ios/Agent`）
  —— 第三方源码，**仅本地对照，不入库**（已在 `.gitignore` 忽略）
  - `ChatColors.swift`、`ComposerSurface.swift`、`SidebarSurfaces.swift`、`SessionRow.swift`、
    `ContentView+Layout.swift`、`ContentView+Navigation.swift`、`MinisApp.swift`
- 落地文件：`Sources/XosviMCP/XDesign.swift`（新增）、`DrawerConversationRow.swift`、`RootView.swift`
- 版本：v10.2

---

## 一、Minis 的「底座」是怎么搭的

Minis 的底座不是一套主题系统，而是**三个正交的层面**，每一层各管一件事：

### 1. 颜色层：`ChatColors`（一个 enum，29 行）

```swift
enum ChatColors {
    static let background   = Color(UIColor.systemBackground)
    static let secondaryBg  = Color(UIColor.secondarySystemBackground)
    static let inputBg      = Color(UIColor { $0.userInterfaceStyle == .dark ? .init(white: 0.12, alpha: 1) : .white })
    static let primaryText  = Color(UIColor.label)
    static let secondaryText = Color(UIColor.secondaryLabel)
    static let userBubble   = Color(UIColor.tertiarySystemFill)
    static let toolBg       = Color(UIColor.tertiarySystemGroupedBackground)
    static let accent       = Color(UIColor.label)      // ← 强调色就是 label 本身
    static let sendButton   = Color(UIColor.label)
}
```

三条可照搬的原则：

1. **只用 UIKit 语义色包一层**，一个 RGB 都不写死 → 深色模式零成本。
   唯一的「写死」是 `inputBg` 的 dark 0.12 / light 纯白，因为输入卡要跟消息区拉开一档，
   语义色里没有正好的那一档（用 `UIColor { traits in ... }` 的动态 provider 表达，仍然不是全局常量）。
2. **强调色收敛成单色**：`accent = label`。彩色只留给**状态**（成功/失败/警告），
   所以整页只有黑白灰 + 少量语义色，视觉噪音极低。
3. **颜色按「角色」命名而不是按「色相」命名**：`userBubble`、`toolBg`、`inputBg`、`sendButton`。
   页面里不出现 `.gray`、`.blue`，只出现角色名。

### 2. 面层：三个 ViewModifier（`ComposerSurface.swift` / `SidebarSurfaces.swift`）

底座里所有「面」（卡片、输入卡、浮钮）都由修饰器产出，页面自己绝不写 `.background(...)`：

| 修饰器 | 形状 | 降级分支（iOS < 26） |
|---|---|---|
| `ComposerSurface` | `RoundedRectangle(20, .continuous)` | `shape.fill(ChatColors.inputBg)` + `.clipShape` + 两层阴影（0.12/8/y2 与深色-only 的 y-4 上浮阴影） |
| `FloatingCircleButtonSurface` | `Circle()` | `systemBackground` 0.92 白 + `gray 0.35` 0.5pt 描边 + 0.18/5/y2 阴影 |
| `FolderSurface` / `SearchBarSurface` | `RoundedRectangle(16)` / `Capsule()` | `secondarySystemBackground` + hairline + 轻阴影 |

关键工程结论（注释里写得很直白，值得抄）：

- **填充必须画在形状「里面」**（`shape.fill(color)`），绝不能 `.background(color).clipShape(shape)`
  这种组合。后者会让宿主 CALayer 带上**矩形**的 backgroundColor，长按文本弹出编辑菜单时，
  系统快照在 mask 生效前拍下那一帧，圆角外会闪一个色块（`T-popup-white-patch`）。
- **绝不 `.blur`**：离屏渲染，列表滚动掉帧。侧栏注释明确说这里是两次滚动性能事故的现场。
  要「玻璃感」就用材质（`regularMaterial`）或者干脆一档填充 + hairline 描边。
- **iOS 26 才有 `glassEffect`**，低版本必须能独立跑，所以每个面都是 `if #available(iOS 26.0, *)` 双分支。

### 3. 行层：`SessionRow`（图标 + 两行文本 + 尾部时间）

```
HStack(spacing: 8)
├─ providerIcon 44×44        圆形底 iconColor.opacity(0.18)，右下角挂 badge（锁/暂停/iCloud）
├─ VStack(spacing: 4)
│   ├─ 标题 16 semibold  label            lineLimit(1)
│   └─ 预览 14 regular   secondaryLabel   lineLimit(1~2，搜索命中时换成 snippet)
├─ Spacer(minLength: 1)
└─ VStack(alignment: .trailing, spacing: 4)
    ├─ 相对时间 13 tertiaryLabel
    └─ pin / lock 小图标 10pt
.padding(.horizontal, 16).padding(.vertical, 12)
```

要点：

- **行高不写死**，靠 44 头像 + 上下各 12 撑出来 → 约 66pt；字号随 App 字体缩放乘系数。
- **行本身没有卡片面**：侧栏是分组列表底色，行是透明行；只有「文件夹」才有卡片面
  （`FolderSurface`）。层级靠「头像的浅色圆」和「分组标题」建立，不靠每行一个白卡。
- **尾部时间是相对时间**（Just now / N min ago / Yesterday / 周三 / 7月8日），不是绝对时间戳。
- `Equatable` 手写：只比较**这一行真正渲染的字段**，避免 SwiftUI 拿整个模型 struct 深比较。

### 4. 壳层：`ContentView` = 一套 state + 两套布局

`ContentView.swift` 持有选中会话、导航路径等全部状态；布局拆到 `ContentView+Layout.swift`：

- `splitLayout`：`NavigationSplitView`（iPad / 宽窗口），侧栏 `sessionList` + `detailView`
- `stackLayout`：`NavigationStack(path:)`（iPhone），`navigationDestination(for: String.self)`
- `detailView` 空选态是「图标 48 + 标题 title3.bold + 说明 subheadline.secondary」居中

即：**布局与状态分离，宽窄两套壳共用同一套行视图与令牌**。iOS 16 起才有的
`NavigationSplitView` 在这里是有 `#available` 兜底的（应用 floor 是 16）。

---

## 二、映射到 xosvi（本项目的底座现状）

本项目底座是 `RootView`（`ZStack` + 手绘抽屉 + 遮罩 + `fullScreenCover` 设置页），
抽屉内容在 `ConversationDrawerView`，会话行在 `DrawerConversationRow`。与 Minis 的差距：

| 维度 | xosvi 改造前 | Minis | 本次动作 |
|---|---|---|---|
| 颜色 | 页面里散落 `Color(uiColor: .systemBackground)` / `.primary.opacity(0.07)` / `.red` | `ChatColors` 单 enum | 新增 `XColor`（角色命名、全语义色），页面改用令牌 |
| 面 | 每处手写 `RoundedRectangle.fill + overlay(stroke) + shadow` | 修饰器 | 新增 `xSurface()` / `xComposerSurface()` / `xFloatCircle()` |
| 字号 | 行里 15/13/11 混用 | 16 / 14 / 13 三档 | 新增 `XType.rowTitle / rowSubtitle / rowMeta / groupHeader` |
| 会话行 | 单行标题 + 选中才显示的 `…`，白卡 + 描边，行高 50 | 44 头像 + 两行 + 尾部时间，无卡片面，约 66 | 重写 `DrawerConversationRow`：`XAvatar` + 标题/预览 + 相对时间 |
| 搜索框 | 手写 HStack + `Capsule().fill(secondarySystemGroupedBackground)`，高 44 | 36 高、12 圆角、`secondarySystemBackground` 填充 | 换成 `XSearchField` |
| 底栏 | 手写卡面 | 面修饰器 | 换 `xSurface(radius: XRadius.sheet)` |

**没有动的**：`RootView` 的抽屉开合结构（`ZStack` + 遮罩 + 偏移）、聊天页 `MonoChat` 的黑白主题
（用户显式要求，不属本层）、`XTheme.swift` 里设置页那套 21/17/13 令牌（设置页已经统一，无需再改）。

### 为什么不用 `NavigationSplitView`

`NavigationSplitView` 是 iOS 16+，而本项目 floor 是 15；且抽屉的「左滑手势 + 遮罩 + 偏移动画」
是现有交互契约，换成分栏会改掉整条交互路径。本次只做**视觉层**模仿，壳层结构保持原样。

### 为什么没有 `glassEffect`

当前绑定 SDK 是 iPhoneOS 18.5，`glassEffect(in:)` 这个符号在 SDK 里不存在，
`#available(iOS 26.0, *)` **挡不住编译错误**（编译器要先看到符号）。因此 `XDesign.swift`
只实现降级分支，注释里留好将来加 `if #available(iOS 26.0, *)` 的位置。

---

## 三、落地清单

| 文件 | 变更 |
|---|---|
| `Sources/XosviMCP/XDesign.swift` | 新增。`XColor` / `XRadius` / `XMetric` / `XType.row*` / `xSurface` / `xComposerSurface` / `xFloatCircle` / `XAvatar` / `XSearchField` / `XFloatingActionButton` |
| `Sources/XosviMCP/DrawerConversationRow.swift` | 行改为 44 头像 + 标题 16 + 预览 14 + 尾部时间 13；行面由 `XColor.page`（不透明，盖住滑动露出的删除键）+ 选中 `XColor.fill` 组成，圆角 `XRadius.row`；行高 50 → 66；滑动删除手势与 `swipedId` 契约不变 |
| `Sources/XosviMCP/RootView.swift` | 抽屉底色→`XColor.page`；搜索框→`XSearchField`；分组标题→`XType.groupHeader`；边距→`XMetric.gutter`；底栏→`xSurface(radius: XRadius.sheet)`，齿轮键→`XColor.fill` + `XRadius.row`；行调用点补 `subtitle` / `meta` |

`XFloatingActionButton` 本次未挂到界面上（新建会话入口已在抽屉头部，不重复造），
留作设计层原语，后续工具页/工作区页可直接用。

---

## 四、验证限制

本机无 `swiftc`，Swift 改动**无法在本设备编译**。只能：

1. `clang -fsyntax-only` 不行（Swift 语法），`swift-syntax` 的 CI job 只做 `swiftc -parse`（不查类型）；
2. 推 main 触发 iOS 构建（冷缓存 30–60 分钟）拿到真正的类型检查。

因此本次改动刻意只用**已在项目里出现过的 API**（`RoundedRectangle(style:.continuous)`、
`.background(shape.fill())`、`.foregroundColor`、`PlainTextFieldStyle`、`UITraitCollection` 动态 provider），
不引入任何新 SDK 符号，把类型风险压到最低。
