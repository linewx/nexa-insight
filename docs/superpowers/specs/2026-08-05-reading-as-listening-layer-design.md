# 精读改为精听的标注层

日期: 2026-08-05

## 问题

精读上线时做成了与精听互斥的模式（`StudyMode.listening` / `.reading`），进入精读
就退出精听。这不只是"两种视图二选一"——它**删掉了精听的核心交互**。

`StudyView.swift` 原本是：

```swift
if studyMode == .reading {
    readingContent                              // 裸的，无 Button
} else {
    Button(action: onTap) { listeningContent }   // 只有精听有
}
```

精读下 `readingContent` 没有包在 `Button` 里，于是：

- 点句子跳转播放消失
- `selected` 只能靠播放进度自然命中，无法主动选中
- 那排操作（上一句/重听/循环/跟读/变速）调不出来

而精读的真实使用场景恰恰是「这句没听懂 → 看释义 → 再听一遍」，"再听一遍"正好被关掉。

### 为什么原实现会这样写

不是偷懒。`InlineExpressionText` 里每个高亮词组都是 `Button`，外层再包一个
`Button(action: onTap)` 就成了嵌套 Button——内层收不到点击，或外层把点击全吃掉。
去掉外层 Button 是绕开这个 SwiftUI 限制的代价。

## 目标

精读是**加法**：开启后转写里多出蓝色标注和可展开的释义卡片，精听的一切能力原样保留。

## 设计

### 1. 渲染改为 AttributedString + OpenURLAction

整句渲染成**一个原生 `Text`**，高亮词组挂自定义 scheme 的链接，
`OpenURLAction` 拦下来转成"展开卡片"：

```swift
run.link = URL(string: "nexa-expression://\(id)")
```

行本身挂 `onTapGesture` 做 seek。两种 tap target 平级并存，不存在嵌套。

`LearningExpressionLogic` 新增三个纯函数，均已单测覆盖：

- `expressionURL(_:)` / `expressionID(fromURL:)` —— URL 往返，非本 scheme 的
  真实链接不被误判（转写里的 http 链接仍要正常打开）
- `attributedSentence(segments:highlight:)` —— 拼装 AttributedString，只有高亮段带 link

**已在模拟器实测确认**（这是唯一无法靠单测回答的风险）：link 点击不会被父层
`onTapGesture` 吞掉。点蓝色词展开卡片、点空白处选中并调出操作栏，同屏共存。

### 2. 删掉手写 Layout

`InlineTextFlow`（自定义 `Layout`）和 `renderUnits`/`wrapUnits`（按词拆分）整个删除。

这两块原本是为了绕开截断 bug 而存在的：手写 `Layout` 只能在 subview **之间**折行，
一整句普通文字是单个 `Text` subview，超宽时无处可断，直接溢出右边界。当时的修法是
把普通段拆成一词一个 subview 给折行留落点。

改用原生 `Text` 后折行交回 SwiftUI，截断从根上消失，拆词逻辑不再需要。附带收益：
无障碍从"一句 20+ 个按钮"回到"一段文本"。

### 3. 开关存在 AppSettings，默认开

`showReadingAnnotations`，照现有 `localizedBylines` 的 `@Published` + `didSet`
写 `UserDefaults`，全局记住。

一个坑：`defaults.bool(forKey:)` 对未写入的 key 返回 `false`，与"用户手动关掉"
无法区分。默认开必须显式写成：

```swift
defaults.object(forKey: "showReadingAnnotations") as? Bool ?? true
```

顶部胶囊按钮保留为**本次会话的临时开关**（`annotationsOverride: Bool?`，nil 表示
跟随设置），不改写全局偏好。

### 4. 无标注时的状态提示

释义不是开关能变出来的，它依赖后端抽取过。现有数据：Lily 67 条、ep1 137 条，
另外四个 episode 是 0 条。开关打开后那四篇没有任何蓝色高亮，看起来像开关坏了。

因此：

- `annotationsAvailable == false` 时显示「精读内容会在新导入或重新解析的视频中生成。
  当前内容仍可正常精听。」
- 顶部胶囊按钮在无标注时**隐藏**——一个按了没有任何视觉变化的开关读起来像坏了
- `annotated` 同时要求偏好开启且本篇有标注：
  `(annotationsOverride ?? settings.showReadingAnnotations) && !learningExpressions.isEmpty`

### 5. 卡片形态

保持内联插在句子下方，最多展开一张（现有行为）。标注被关掉时清空
`expandedExpressionID`——没有高亮锚点的卡片会浮在空中。

## 不做

- **不改卡片为底部 sheet 或固定卡位**：内联让释义紧贴原句、视线不跳。代价是播放中
  展开会顶动布局，暂时接受。
- **不修 occurrence 丢失**：ep1 的 137 条表达只对应 128 个 occurrence，约 9 条在原文
  里搜不到、静默丢了高亮。这是 `c6288a2` 改成文本搜索定位后的既有取舍（宁可不高亮也
  不错位），独立于本次改动。

## 验证

- `swift test` 427 项全过
- 模拟器实测三项：标注默认可见无需切模式；点空白处选中并调出操作栏；点蓝色词展开
  卡片，且与选中状态同屏共存

## 遗留

`ExamplePracticeView`（跟读评测弹窗）始终未打开验证过。坐标点击驱动的成功率很低，
建议改用 XCUITest。
