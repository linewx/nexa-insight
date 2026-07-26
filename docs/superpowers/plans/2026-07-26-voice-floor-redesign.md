# 语音课堂重设计 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把讨论交互从"长按+上滑锁定"改成两个独立入口(长按=插话、点击=Live),并引入唯一的发言权令牌保证"同一时刻只有一方发声"。

**Architecture:** 三层隔离。(1) 纯函数 floor-token 状态机 `floorReducer` 在 `ClassroomLogic.swift`,决定令牌归属与应静音的方,可脱离 transport 单测。(2) `ClassroomController` 用令牌交接函数 `grantFloor(to:)` 取代散落的 pause/stopSpeaking/play,并暴露 `pressQuickAsk`/`releaseQuickAsk`/`enterLive`/`exitLive`。(3) `DiscussionDockContent` 手势层改为长按+点击两个独立入口,视觉按令牌持有者渲染。

**Tech Stack:** Swift, SwiftUI, XCTest。逻辑层经 SwiftPM 包 `NexaInsightCore` 单测;app 目标经 xcodebuild 构建、真机装机。

## Global Constraints

- 逻辑层纯函数必须在 `NexaInsightCore` 包内可单测(`swift test`),不依赖 WebRTC/UIKit。
- 保留 commit 3389b78 的 function-call 解析与 call_id 去重,不动。
- 保留真机签名配置(team `CCGQFW2P89`);真机 UDID `00008150-000E458E0C00401C`。
- 不引入新依赖。
- "同一时刻只有一方发声"是硬约束:任何令牌交接都必须令另两方静音。
- 现有 `classroomReducer` 状态机复用于视觉状态消息;floor token 是新增的正交状态,不替换它。

---

### Task 1: Floor-token 纯函数状态机

**Files:**
- Modify: `ios/NexaInsight/Logic/ClassroomLogic.swift`(在文件末尾新增)
- Test: `ios/NexaInsightCoreTests/ClassroomLogicTests.swift`(新增测试)

**Interfaces:**
- Consumes: 无(纯新增)
- Produces:
  - `enum FloorHolder: Equatable { case player, user, teacher, idle }`
  - `enum FloorEvent { case userTookFloor, userYielded, teacherFinished(resumePlayback: Bool), playbackRequested, playbackHeld, sessionEnded }`
  - `func floorReducer(_ holder: FloorHolder, _ event: FloorEvent) -> FloorHolder`
  - `func silenced(by holder: FloorHolder) -> (pausePlayer: Bool, stopTeacher: Bool)` — 返回令牌交给 holder 时,应否暂停播客 / 应否让老师闭嘴。

**令牌转移表(来自 spec 组件二):**

| event | 新 holder |
|---|---|
| userTookFloor | user |
| userYielded | teacher |
| teacherFinished(resumePlayback: true) | player |
| teacherFinished(resumePlayback: false) | idle |
| playbackRequested | player |
| playbackHeld | idle |
| sessionEnded | idle |

`silenced(by:)`:player→(false,true 让老师闭嘴);user→(true,true);teacher→(true,false);idle→(true,true)。

- [ ] **Step 1: Write the failing test**

```swift
func testFloorReducerTransitions() {
    XCTAssertEqual(floorReducer(.player, .userTookFloor), .user)
    XCTAssertEqual(floorReducer(.user, .userYielded), .teacher)
    XCTAssertEqual(floorReducer(.teacher, .teacherFinished(resumePlayback: true)), .player)
    XCTAssertEqual(floorReducer(.teacher, .teacherFinished(resumePlayback: false)), .idle)
    XCTAssertEqual(floorReducer(.idle, .playbackRequested), .player)
    XCTAssertEqual(floorReducer(.player, .playbackHeld), .idle)
    XCTAssertEqual(floorReducer(.user, .sessionEnded), .idle)
}

func testSilencedRuleIsSingleVoice() {
    // player 有令牌:播客响、老师闭嘴、不暂停播客
    XCTAssertEqual(silenced(by: .player).pausePlayer, false)
    XCTAssertEqual(silenced(by: .player).stopTeacher, true)
    // user 有令牌:两方都让路
    XCTAssertEqual(silenced(by: .user).pausePlayer, true)
    XCTAssertEqual(silenced(by: .user).stopTeacher, true)
    // teacher 有令牌:播客暂停、老师说
    XCTAssertEqual(silenced(by: .teacher).pausePlayer, true)
    XCTAssertEqual(silenced(by: .teacher).stopTeacher, false)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && swift test --filter ClassroomLogicTests`
Expected: FAIL(`FloorHolder`/`floorReducer`/`silenced` 未定义)

- [ ] **Step 3: Write minimal implementation**

在 `ClassroomLogic.swift` 末尾新增:

```swift
enum FloorHolder: Equatable { case player, user, teacher, idle }

enum FloorEvent {
    case userTookFloor
    case userYielded
    case teacherFinished(resumePlayback: Bool)
    case playbackRequested
    case playbackHeld
    case sessionEnded
}

func floorReducer(_ holder: FloorHolder, _ event: FloorEvent) -> FloorHolder {
    switch event {
    case .userTookFloor: return .user
    case .userYielded: return .teacher
    case let .teacherFinished(resume): return resume ? .player : .idle
    case .playbackRequested: return .player
    case .playbackHeld: return .idle
    case .sessionEnded: return .idle
    }
}

// 令牌交给 holder 时,是否要暂停播客 / 让老师闭嘴。保证单声道。
func silenced(by holder: FloorHolder) -> (pausePlayer: Bool, stopTeacher: Bool) {
    switch holder {
    case .player: return (false, true)
    case .user: return (true, true)
    case .teacher: return (true, false)
    case .idle: return (true, true)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && swift test --filter ClassroomLogicTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Logic/ClassroomLogic.swift ios/NexaInsightCoreTests/ClassroomLogicTests.swift
git commit -m "Add floor-token reducer: single-voice arbitration"
```

---

### Task 2: 控制器接入令牌交接

**Files:**
- Modify: `ios/NexaInsight/Classroom/ClassroomController.swift`
- Test: `ios/NexaInsightCoreTests/ClassroomControllerTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `FloorHolder` / `floorReducer` / `silenced(by:)`;现有 `Playback`(`pause()`/`play()`/`seek(_:)`/`currentMs`)、`ClassroomTransport`(`stopSpeaking()`/`beginListening()`/`endTurnAndRespond()`/`setTurnMode(_:)`/`requestResponse()`)。
- Produces:
  - `@Published var floor: FloorHolder`(视觉层消费)
  - `func grantFloor(to holder: FloorHolder, resumeAtMs: Int?)` — 私有交接:按 `silenced(by:)` 暂停播客/让老师闭嘴,player 时 `play()`,更新 `floor`。
  - `func pressQuickAsk()` / `func releaseQuickAsk()` — 长按插话入口(取代 `beginUserTurn`/`endUserTurn`)。
  - `func enterLive()` / `func exitLive()` — Live 入口。

**行为定义:**
- `pressQuickAsk()`:`transport.beginListening()`;freeze 在 cursor;`grantFloor(to: .user, resumeAtMs: nil)`;`onContextRefresh(frozen)`。
- `releaseQuickAsk()`:`transport.endTurnAndRespond()`;`grantFloor(to: .teacher, ...)`;记住这是插话场景(老师答完要续播)。
- `enterLive()`:`transport.setTurnMode(.continuous)`;`grantFloor(to: .idle, ...)`(播客暂停,等用户)。
- `exitLive()`:`grantFloor(to: .player, ...)` 续播 + `transport.setTurnMode(.pushToTalk)`(回到默认)。
- 老师答完事件(`teacherFinished`):插话场景 `resumePlayback: true`,Live 场景 `resumePlayback: false`。用一个私有 `inLive: Bool` 区分。

- [ ] **Step 1: Write the failing test**

```swift
func testPressQuickAskGrantsUserFloorAndPausesPlayback() {
    let (c, playback, transport, _) = make()
    playback.currentMs = 2100
    c.pressQuickAsk()
    XCTAssertEqual(c.floor, .user)
    XCTAssertTrue(playback.didPause)
    XCTAssertEqual(transport.beganListening, 1)
}

func testReleaseQuickAskGrantsTeacherFloorAndRequests() {
    let (c, _, transport, _) = make()
    c.pressQuickAsk()
    c.releaseQuickAsk()
    XCTAssertEqual(c.floor, .teacher)
    XCTAssertEqual(transport.endedTurns, 1)
}

func testEnterLivePausesAndGoesIdleContinuous() {
    let (c, playback, transport, _) = make()
    c.enterLive()
    XCTAssertEqual(c.floor, .idle)
    XCTAssertTrue(playback.didPause)
    XCTAssertEqual(transport.turnModes.last, .continuous)
}

func testLivePlaybackRequestGrantsPlayerFloorAndStopsTeacher() {
    let (c, playback, transport, _) = make()
    c.enterLive()
    c.runPlaybackTool(.resume_playback, [:])
    XCTAssertEqual(c.floor, .player)
    XCTAssertTrue(playback.didPlay)
    XCTAssertGreaterThan(transport.stoppedSpeaking, 0)
}

func testExitLiveResumesAndReturnsToPushToTalk() {
    let (c, playback, transport, _) = make()
    c.enterLive()
    c.exitLive()
    XCTAssertEqual(c.floor, .player)
    XCTAssertTrue(playback.didPlay)
    XCTAssertEqual(transport.turnModes.last, .pushToTalk)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && swift test --filter ClassroomControllerTests`
Expected: FAIL(`floor`/`pressQuickAsk`/`enterLive` 等未定义)

- [ ] **Step 3: Write minimal implementation**

在 `ClassroomController` 增加 `@Published var floor: FloorHolder = .player` 和 `private var inLive = false`,并新增:

```swift
private func grantFloor(to holder: FloorHolder, resumeAtMs: Int?) {
    let rule = silenced(by: holder)
    if rule.stopTeacher { transport.stopSpeaking() }
    if rule.pausePlayer { playback.pause() }
    if holder == .player {
        if let resumeAtMs { playback.seek(resumeAtMs) }
        frozenPositionMs = nil
        playback.play()
    }
    floor = holder
}

func pressQuickAsk() {
    inLive = false
    transport.beginListening()
    freeze(cursor(), reason: .speechStarted)
    onContextRefresh(frozenPositionMs ?? cursor())
    grantFloor(to: .user, resumeAtMs: nil)
}

func releaseQuickAsk() {
    state = classroomReducer(state, .discussionStarted)
    transport.endTurnAndRespond()
    grantFloor(to: .teacher, resumeAtMs: nil)
}

func enterLive() {
    inLive = true
    transport.setTurnMode(.continuous)
    freeze(cursor(), reason: .paused)
    grantFloor(to: .idle, resumeAtMs: nil)
}

func exitLive() {
    inLive = false
    transport.setTurnMode(.pushToTalk)
    grantFloor(to: .player, resumeAtMs: frozenPositionMs)
}
```

在 `runPlaybackTool` 的 `.resume_playback` 分支后,令 `grantFloor(to: .player, ...)`;`.pause_playback` 分支令 `grantFloor(to: .idle, ...)`。保留旧 `beginUserTurn`/`endUserTurn`/`switchToContinuous` 暂不删(Task 3 切换手势后删)。

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && swift test --filter ClassroomControllerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Classroom/ClassroomController.swift ios/NexaInsightCoreTests/ClassroomControllerTests.swift
git commit -m "Wire floor handoff into controller: quick-ask and live entries"
```

---

### Task 3: 手势层改为两个独立入口

**Files:**
- Modify: `ios/NexaInsight/Views/StudyView.swift`(`DiscussionDockContent`)
- Modify: `ios/NexaInsight/Classroom/ClassroomController.swift`(删除旧 `beginUserTurn`/`endUserTurn`/`switchToContinuous`)

**Interfaces:**
- Consumes: Task 2 的 `pressQuickAsk()`/`releaseQuickAsk()`/`enterLive()`/`exitLive()`/`floor`。
- Produces: 无新公共接口(视图内部)。

**行为定义:**
- `micControl` 承载**两个独立手势**:
  - `LongPressGesture(0.18)` sequenced `DragGesture(0)`:按下→haptic + `pressQuickAsk()`;松手→`releaseQuickAsk()`。删除上滑锁定/`willLock`/`lockThreshold`/`lockHint`。
  - `TapGesture()`:`enterLive()`,置 `live = true`。
- `live == true` 时:mic 变成被动指示器(令牌视觉),不再响应长按;显示退出按钮触发 `exitLive()` + `live = false`。
- 无 `locked` 概念,改为 `live` 布尔。

- [ ] **Step 1: 手动改写(无独立单测,手势靠真机)**

改写 `DiscussionDockContent`:去掉 `locked`/`talking`/`willLock`/`lockThreshold` 状态,改为 `@State private var live = false` 和 `@State private var talking = false`。`micControl` 同时挂长按手势(quick-ask)与 `.onTapGesture { controller.enterLive(); live = true }`,`live` 时禁用长按。退出按钮 `live ? exitLive+live=false : onEnd`。

```swift
private var micControl: some View {
    VoiceActivityIcon(phase: controller.state.phase, connected: connected)
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .scaleEffect(talking ? 1.12 : 1)
        .animation(.easeOut(duration: 0.14), value: talking)
        .gesture(live ? nil : quickAsk)
        .onTapGesture { if !live { controller.enterLive(); live = true } }
        .accessibilityLabel(live ? "Live discussion" : "Hold to talk, tap for live")
}

private var quickAsk: some Gesture {
    LongPressGesture(minimumDuration: 0.18)
        .sequenced(before: DragGesture(minimumDistance: 0))
        .onChanged { value in
            guard case .second(true, _) = value, !talking else { return }
            talking = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            controller.pressQuickAsk()
        }
        .onEnded { _ in
            guard talking else { return }
            talking = false
            controller.releaseQuickAsk()
        }
}
```

注意:`LongPressGesture` 与 `onTapGesture` 并存时,短点触发 tap(进 Live),长按触发 quick-ask。这是设计意图。删除 `ClassroomController` 里旧的 `beginUserTurn`/`endUserTurn`/`switchToContinuous` 及其测试。

- [ ] **Step 2: 更新旧测试**

删除 `ClassroomControllerTests` 里 `testBeginUserTurn...`/`testEndUserTurn...`/`testSwitchToContinuous...`(已被 Task 2 新测试取代)。

- [ ] **Step 3: 构建 + 全套测试**

Run: `cd ios && ./generate.sh && swift test 2>&1 | grep "Executed"`
Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'generic/platform=iOS Simulator' -derivedDataPath build build 2>&1 | grep -E "error:|BUILD" | grep -v appintents`
Expected: 测试全过;`** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/NexaInsight/Views/StudyView.swift ios/NexaInsight/Classroom/ClassroomController.swift ios/NexaInsightCoreTests/ClassroomControllerTests.swift
git commit -m "Replace slide-to-lock with two entries: long-press ask, tap live"
```

---

### Task 4: 视觉按令牌持有者渲染

**Files:**
- Modify: `ios/NexaInsight/Views/StudyView.swift`(`DiscussionDockContent` 的 mic 视觉与状态行)

**Interfaces:**
- Consumes: Task 2 的 `controller.floor: FloorHolder`。
- Produces: 无。

**行为定义:** mic 图标与状态行按 `controller.floor` 渲染唯一视觉:
- `.user`:图标放大 + 录音色(在听你)
- `.teacher`:声纹跳动(它在说)
- `.player`:安静(播客在放)
- `.idle`:待命(Live 等你 / 插话间隙)

复用现有 `VoiceActivityIcon`;若其入参是 `phase`,则加一个按 `floor` 决定的 `emphasis`(scale/tint)覆盖层即可,不改 `VoiceActivityIcon` 本身。

- [ ] **Step 1: 手动改写视觉**

在 `micControl` 上按 `controller.floor` 决定 `scaleEffect` 与 tint;状态行文案在 Live 下按 `floor` 给"在听你/它在说/播放中/等你说"。纯视觉,无逻辑分支进入 reducer。

- [ ] **Step 2: 构建 + 装机真机验证**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'id=00008150-000E458E0C00401C' -allowProvisioningUpdates build 2>&1 | grep -E "BUILD"`
Run: 装机 `xcrun devicectl device install app --device 00008150-000E458E0C00401C "<app>"`
Expected: `** BUILD SUCCEEDED **`;装机成功。

- [ ] **Step 3: Commit**

```bash
git add ios/NexaInsight/Views/StudyView.swift
git commit -m "Render dock visuals from the floor holder"
```

---

## 真机验证清单(无法单测)

装机后由用户验证:
1. **长按插话**:按住→播客暂停→说话→松手→老师立即答→答完播客续播。
2. **点击进 Live**:点一下→播客暂停、进入待命→张嘴即说、老师接话→说"继续播放"→播客续播且仍可插话→点退出→回正常听播客。
3. **单声道铁律**:任何时刻不出现播客与老师同时出声。
4. **回声消除(最高风险)**:Live 里播客播放时,播客声音不会被误判成"用户在说话"而自我打断。若抽风,启用兜底(降低 Live 播放时 VAD 灵敏度)。

## Self-Review

- **Spec 覆盖**:组件一(两入口)→Task 3;组件二(令牌)→Task 1+2;组件三(Live 内部)→Task 2 的 enter/exit/playback + 真机清单;组件四(视觉)→Task 4。全覆盖。
- **占位符**:无 TBD;每个 code step 有实际代码。
- **类型一致**:`FloorHolder`/`floorReducer`/`silenced(by:)`/`grantFloor(to:resumeAtMs:)`/`pressQuickAsk`/`releaseQuickAsk`/`enterLive`/`exitLive`/`floor` 在 Task 1-4 间引用一致。
- **回声消除风险**已在 spec 与真机清单双标注,含兜底。
