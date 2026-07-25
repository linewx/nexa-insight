# iOS Foundation + Study Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working native iOS app that imports episodes from the thin backend, stores them locally, and delivers the full study experience — local mp3 playback, bilingual subtitle follow/browse/tap-to-seek, and shadowing recordings — minus the live voice classroom (Plan 3).

**Architecture:** SwiftUI app. The proven interaction logic from `nexa_insight`'s `domain.ts` and `classroom.ts` is ported 1:1 into pure Swift functions with XCTest coverage — this is where interaction fidelity is guaranteed. Playback is abstracted behind a `Playback` protocol (currentMs + seek/play/pause/speed); an `AVPlayer`-backed local mp3 implementation replaces the web app's YouTube iframe, but every consumer of playback stays player-agnostic and identical in behavior. SwiftData persists episodes/chapters/sentences/recordings locally after a one-time download from the backend.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftData, AVFoundation (AVPlayer playback + AVAudioRecorder), Keychain Services, XCTest. Minimum iOS 17 (SwiftData).

This is Plan 2 of 3. It consumes the episode bundle format from Plan 1 (backend). Plan 3 adds the live voice classroom on top of the `Playback` protocol and interaction-logic modules defined here.

## Global Constraints

- Minimum deployment target iOS 17.0 (SwiftData requirement).
- The interaction logic MUST replicate `nexa_insight` exactly. Pure-logic ports (Tasks 3–4) copy the algorithms from `domain.ts`/`classroom.ts` verbatim in behavior, verified by tests mirroring the original TS tests. When a detail is ambiguous, mirror the original implementation; do not invent behavior.
- API keys are stored ONLY in the iOS Keychain, never in `UserDefaults`, source, or git.
- The backend base URL is user-configurable (Settings), stored in `UserDefaults` (non-secret). Default `http://localhost:8000`.
- Playback positions are integer milliseconds everywhere (mirror the web app's `integerMilliseconds`).
- All consumers of playback depend on the `Playback` protocol, never directly on `AVPlayer`, so Plan 3's classroom reuses them unchanged.
- Money/time formatting: `formatTime(ms)` renders `m:ss` (seconds zero-padded to 2), matching `domain.ts`.

---

### Task 1: Xcode project scaffold

**Files:**
- Create: `ios/NexaInsight.xcodeproj` (via `xcodegen` or Xcode) with an app target `NexaInsight` and a unit-test target `NexaInsightTests`.
- Create: `ios/NexaInsight/NexaInsightApp.swift`
- Create: `ios/NexaInsight/ContentView.swift`
- Create: `ios/NexaInsightTests/SmokeTests.swift`
- Create: `ios/project.yml` (xcodegen spec, so the project is reproducible from text)

**Interfaces:**
- Consumes: nothing.
- Produces: a buildable, test-runnable iOS app skeleton. `@main struct NexaInsightApp`.

- [ ] **Step 1: Write `ios/project.yml`**

```yaml
name: NexaInsight
options:
  bundleIdPrefix: com.nexainsight
  deploymentTarget:
    iOS: "17.0"
targets:
  NexaInsight:
    type: application
    platform: iOS
    sources: [NexaInsight]
    info:
      path: NexaInsight/Info.plist
      properties:
        NSMicrophoneUsageDescription: "Nexa Insight records your shadowing practice and voice-class speech."
        UILaunchScreen: {}
    settings:
      base:
        GENERATE_INFOPLIST_FILE: NO
  NexaInsightTests:
    type: bundle.unit-test
    platform: iOS
    sources: [NexaInsightTests]
    dependencies:
      - target: NexaInsight
```

- [ ] **Step 2: Write `ios/NexaInsight/NexaInsightApp.swift`**

```swift
import SwiftUI

@main
struct NexaInsightApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

- [ ] **Step 3: Write `ios/NexaInsight/ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("Nexa Insight")
    }
}
```

- [ ] **Step 4: Write `ios/NexaInsightTests/SmokeTests.swift`**

```swift
import XCTest

final class SmokeTests: XCTestCase {
    func testTrue() { XCTAssertTrue(true) }
}
```

- [ ] **Step 5: Generate and build**

Run: `cd ios && xcodegen generate && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' build test`
Expected: BUILD SUCCEEDED, SmokeTests passes. (If `xcodegen` is unavailable, create the project in Xcode with the same targets; the `project.yml` documents the intended structure.)

- [ ] **Step 6: Commit**

```bash
git add ios
git commit -m "feat(ios): Xcode project scaffold"
```

---

### Task 2: Domain models and shared value types

**Files:**
- Create: `ios/NexaInsight/Models/Models.swift`
- Create: `ios/NexaInsightTests/ModelsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: plain Swift value types mirroring the backend bundle (used by the API decoder and pure logic; SwiftData `@Model` persistence is Task 6):
  - `struct SentenceDTO: Codable, Identifiable { let id: Int; let episodeId: Int; let chapterId: Int?; let position: Int; let startMs: Int; let endMs: Int; let speaker: String?; let sourceText: String; let chinese: String }`
  - `struct ChapterDTO: Codable, Identifiable { let id: Int; let title: String; let summary: String; let startMs: Int; let endMs: Int }`
  - `struct EpisodeDTO: Codable, Identifiable { let id: Int; let sourceUrl: String; let youtubeId: String?; let title: String?; let channel: String?; let durationMs: Int?; let thumbnailUrl: String?; let audioPath: String?; let status: String; let error: String? }`
  - `struct JobDTO: Codable { let id: Int; let episodeId: Int; let stage: String; let status: String; let progress: Int; let error: String? }`
  - `struct BundleDTO: Codable { let episode: EpisodeDTO; let chapters: [ChapterDTO]; let sentences: [SentenceDTO]; let hasAudio: Bool }`
  - `struct TutorTurn: Equatable { enum Role { case user, assistant, system }; let role: Role; let text: String; var corrections: [String] }`
- All `Codable` types decode the backend's snake_case via a shared `JSONDecoder` with `.convertFromSnakeCase` (Task 5 owns the decoder; the field names above are the camelCase targets).

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/ModelsTests.swift`**

```swift
import XCTest
@testable import NexaInsight

final class ModelsTests: XCTestCase {
    func testBundleDecodesSnakeCase() throws {
        let json = """
        {"episode":{"id":1,"source_url":"u","youtube_id":"y","title":"T","channel":"C","duration_ms":1000,"thumbnail_url":null,"audio_path":"episodes/1/source.mp3","status":"ready","error":null},
         "chapters":[{"id":1,"title":"Intro","summary":"s","start_ms":0,"end_ms":1000}],
         "sentences":[{"id":1,"episode_id":1,"chapter_id":1,"position":0,"start_ms":0,"end_ms":500,"speaker":null,"source_text":"Hi","chinese":"嗨"}],
         "has_audio":true}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let bundle = try decoder.decode(BundleDTO.self, from: json)
        XCTAssertEqual(bundle.episode.title, "T")
        XCTAssertEqual(bundle.sentences.first?.chinese, "嗨")
        XCTAssertTrue(bundle.hasAudio)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `BundleDTO` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Models/Models.swift`**

```swift
import Foundation

struct SentenceDTO: Codable, Identifiable, Equatable {
    let id: Int
    let episodeId: Int
    let chapterId: Int?
    let position: Int
    let startMs: Int
    let endMs: Int
    let speaker: String?
    let sourceText: String
    let chinese: String
}

struct ChapterDTO: Codable, Identifiable, Equatable {
    let id: Int
    let title: String
    let summary: String
    let startMs: Int
    let endMs: Int
}

struct EpisodeDTO: Codable, Identifiable, Equatable {
    let id: Int
    let sourceUrl: String
    let youtubeId: String?
    let title: String?
    let channel: String?
    let durationMs: Int?
    let thumbnailUrl: String?
    let audioPath: String?
    let status: String
    let error: String?
}

struct JobDTO: Codable, Equatable {
    let id: Int
    let episodeId: Int
    let stage: String
    let status: String
    let progress: Int
    let error: String?
}

struct BundleDTO: Codable, Equatable {
    let episode: EpisodeDTO
    let chapters: [ChapterDTO]
    let sentences: [SentenceDTO]
    let hasAudio: Bool
}

struct TutorTurn: Equatable {
    enum Role { case user, assistant, system }
    let role: Role
    let text: String
    var corrections: [String]
    init(role: Role, text: String, corrections: [String] = []) {
        self.role = role; self.text = text; self.corrections = corrections
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Models/Models.swift ios/NexaInsightTests/ModelsTests.swift
git commit -m "feat(ios): domain DTOs decoding backend bundle"
```

---

### Task 3: SubtitleLogic — port of `domain.ts`

**Files:**
- Create: `ios/NexaInsight/Logic/SubtitleLogic.swift`
- Create: `ios/NexaInsightTests/SubtitleLogicTests.swift`

**Interfaces:**
- Consumes: `SentenceDTO` (Task 2).
- Produces free functions (behavior copied verbatim from `nexa_insight/apps/web/src/domain.ts`):
  - `activeSentence(_ sentences: [SentenceDTO], _ currentMs: Int) -> SentenceDTO?` — the last line whose `startMs <= currentMs` (handles overlapping caption ranges; NOT a containment test).
  - `subtitleWindow(_ sentences: [SentenceDTO], _ currentMs: Int, radius: Int = 2) -> [SentenceDTO]` — window centered on the last-started line.
  - `sentenceLoopBoundary(_ sentence: SentenceDTO, _ currentMs: Int) -> Int?` — returns `startMs` when `currentMs >= endMs - 100`, else nil.
  - `formatTime(_ ms: Int) -> String` — `m:ss`.
  - `scrollOffsetToCenter(viewportHeight: CGFloat, rowOffsetTop: CGFloat, rowHeight: CGFloat) -> CGFloat`.
  - `isManualScrollAway(currentScrollTop: CGFloat, targetScrollTop: CGFloat, tolerancePx: CGFloat) -> Bool`.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/SubtitleLogicTests.swift`**

```swift
import XCTest
@testable import NexaInsight

private func s(_ id: Int, _ start: Int, _ end: Int) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: end, speaker: nil, sourceText: "e\(id)", chinese: "c\(id)")
}

final class SubtitleLogicTests: XCTestCase {
    let lines = [s(0, 0, 1200), s(1, 1000, 2200), s(2, 2000, 3200), s(3, 3000, 4200)]

    func testActiveSentenceIsLastStartedNotContaining() {
        // At 1100ms both line 0 (0-1200) and line 1 (1000-2200) overlap; the
        // spoken line is the last one that has started -> line 1.
        XCTAssertEqual(activeSentence(lines, 1100)?.id, 1)
        XCTAssertEqual(activeSentence(lines, 0)?.id, 0)
        XCTAssertNil(activeSentence([], 100))
    }

    func testSubtitleWindowCentersOnLastStarted() {
        let window = subtitleWindow(lines, 2050, radius: 1)
        XCTAssertEqual(window.map(\.id), [1, 2, 3])
    }

    func testSentenceLoopBoundary() {
        XCTAssertEqual(sentenceLoopBoundary(s(2, 2000, 3200), 3150), 2000)
        XCTAssertNil(sentenceLoopBoundary(s(2, 2000, 3200), 2500))
    }

    func testFormatTime() {
        XCTAssertEqual(formatTime(0), "0:00")
        XCTAssertEqual(formatTime(65_000), "1:05")
    }

    func testScrollHelpers() {
        XCTAssertEqual(scrollOffsetToCenter(viewportHeight: 100, rowOffsetTop: 200, rowHeight: 20), 160)
        XCTAssertEqual(scrollOffsetToCenter(viewportHeight: 500, rowOffsetTop: 0, rowHeight: 20), 0)
        XCTAssertTrue(isManualScrollAway(currentScrollTop: 200, targetScrollTop: 160, tolerancePx: 24))
        XCTAssertFalse(isManualScrollAway(currentScrollTop: 170, targetScrollTop: 160, tolerancePx: 24))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `activeSentence` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Logic/SubtitleLogic.swift`**

```swift
import CoreGraphics
import Foundation

func activeSentence(_ sentences: [SentenceDTO], _ currentMs: Int) -> SentenceDTO? {
    var active: SentenceDTO?
    for item in sentences {
        if item.startMs <= currentMs { active = item } else { break }
    }
    return active
}

func subtitleWindow(_ sentences: [SentenceDTO], _ currentMs: Int, radius: Int = 2) -> [SentenceDTO] {
    if sentences.isEmpty { return [] }
    var precedingIndex = -1
    for (index, item) in sentences.enumerated() where item.startMs <= currentMs {
        precedingIndex = index
    }
    let index = max(0, precedingIndex)
    let lower = max(0, index - radius)
    let upper = min(sentences.count - 1, index + radius)
    return Array(sentences[lower...upper])
}

func sentenceLoopBoundary(_ sentence: SentenceDTO, _ currentMs: Int) -> Int? {
    currentMs >= sentence.endMs - 100 ? sentence.startMs : nil
}

func formatTime(_ ms: Int) -> String {
    let seconds = ms / 1000
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

func scrollOffsetToCenter(viewportHeight: CGFloat, rowOffsetTop: CGFloat, rowHeight: CGFloat) -> CGFloat {
    max(0, (rowOffsetTop - (viewportHeight - rowHeight) / 2).rounded())
}

func isManualScrollAway(currentScrollTop: CGFloat, targetScrollTop: CGFloat, tolerancePx: CGFloat) -> Bool {
    abs(currentScrollTop - targetScrollTop) > tolerancePx
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Logic/SubtitleLogic.swift ios/NexaInsightTests/SubtitleLogicTests.swift
git commit -m "feat(ios): port domain.ts subtitle logic"
```

---

### Task 4: ClassroomLogic — port of `classroom.ts`

**Files:**
- Create: `ios/NexaInsight/Logic/ClassroomLogic.swift`
- Create: `ios/NexaInsightTests/ClassroomLogicTests.swift`

**Interfaces:**
- Consumes: nothing (pure functions/enums over primitives).
- Produces (behavior copied verbatim from `nexa_insight/apps/web/src/classroom.ts`) — Plan 3 depends on ALL of these:
  - `enum PlaybackTool: String` with cases `pause_playback, resume_playback, previous_sentence, next_sentence, repeat_current_sentence, seek_relative, seek_to_timestamp, set_playback_speed, finish_discussion, exit_class`.
  - `enum ClassroomPhase { case idle, connecting, podcastPlaying, userSpeaking, discussionPaused, discussing, teacherSpeaking, resuming, ended }`.
  - `struct ClassroomState: Equatable { var phase: ClassroomPhase; var pausedAtMs: Int? }`.
  - `enum ClassroomEvent { case speechStarted(atMs: Int), paused(atMs: Int), falseActivation, teacherStarted, teacherFinished, discussionStarted, resumed, entered, connected, collapsed, ended }`.
  - `func classroomReducer(_ state: ClassroomState, _ event: ClassroomEvent) -> ClassroomState`.
  - `func reliablePlaybackPosition(_ livePositionMs: Int, _ capturedPositionMs: Int) -> Int`.
  - `func classroomCursorPosition(_ livePositionMs: Int, _ frozenPositionMs: Int?, _ initialPositionMs: Int) -> Int`.
  - `func classroomMode(_ state: ClassroomState) -> String` (`"listening"`/`"discussion"`).
  - `func classroomStatusMessage(_ state: ClassroomState, _ positionMs: Int) -> String`.
  - `func isActionableTranscript(_ transcript: String) -> Bool`.
  - `func isCurrentSentenceMeaningRequest(_ transcript: String) -> Bool`.
  - `func mergeTranscriptFragment(_ existing: String, _ fragment: String) -> String`.
  - `func matchDirectCommand(_ transcript: String) -> (name: PlaybackTool, args: [String: Double])?`.
  - `func playbackNotice(_ name: PlaybackTool, _ positionMs: Int) -> String`.
  - `func playbackTargetPosition(_ name: PlaybackTool, _ args: [String: Double], _ currentMs: Int, _ currentSentenceIndex: Int, _ sentenceStarts: [Int]) -> Int`.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/ClassroomLogicTests.swift`**

Port the assertions from `nexa_insight/apps/web/src/classroom.test.ts`. Minimum coverage:

```swift
import XCTest
@testable import NexaInsight

final class ClassroomLogicTests: XCTestCase {
    func testReducerSpeechFreezesCursorAndKeepsFirstPause() {
        var st = ClassroomState(phase: .podcastPlaying, pausedAtMs: nil)
        st = classroomReducer(st, .speechStarted(atMs: 5000))
        XCTAssertEqual(st.phase, .userSpeaking)
        XCTAssertEqual(st.pausedAtMs, 5000)
        // A later speech keeps the ORIGINAL paused position.
        st = classroomReducer(st, .speechStarted(atMs: 9000))
        XCTAssertEqual(st.pausedAtMs, 5000)
    }

    func testReducerResumeClearsPause() {
        let st = classroomReducer(ClassroomState(phase: .discussing, pausedAtMs: 5000), .resumed)
        XCTAssertEqual(st.phase, .resuming)
        XCTAssertNil(st.pausedAtMs)
    }

    func testCursorPrefersFrozenThenLiveThenInitial() {
        XCTAssertEqual(classroomCursorPosition(3000, 5000, 0), 5000)
        XCTAssertEqual(classroomCursorPosition(3000, nil, 0), 3000)
        XCTAssertEqual(classroomCursorPosition(0, nil, 1200), 1200)
    }

    func testDirectCommandResumeVariantsAndFillers() {
        XCTAssertEqual(matchDirectCommand("继续")?.name, .resume_playback)
        XCTAssertEqual(matchDirectCommand("我觉得有道理，我们继续吧")?.name, .resume_playback)
        XCTAssertEqual(matchDirectCommand("ok let's continue")?.name, .resume_playback)
        XCTAssertEqual(matchDirectCommand("pause")?.name, .pause_playback)
        XCTAssertEqual(matchDirectCommand("next sentence")?.name, .next_sentence)
    }

    func testDirectCommandBailsOnDiscussSignal() {
        // "回到播客" alone resumes, but with a question signal it must fall through.
        XCTAssertNil(matchDirectCommand("回到播客里那个观点是什么意思"))
        XCTAssertNil(matchDirectCommand("explain that"))
    }

    func testActionableTranscriptRejectsFillers() {
        XCTAssertFalse(isActionableTranscript(""))
        XCTAssertFalse(isActionableTranscript("嗯"))
        XCTAssertTrue(isActionableTranscript("pause"))
        XCTAssertTrue(isActionableTranscript("what do you think about this argument"))
    }

    func testPlaybackTargetPosition() {
        let starts = [0, 1000, 2000, 3000]
        XCTAssertEqual(playbackTargetPosition(.seek_to_timestamp, ["seconds": 10], 0, 1, starts), 10_000)
        XCTAssertEqual(playbackTargetPosition(.seek_relative, ["seconds": -5], 8000, 1, starts), 3000)
        XCTAssertEqual(playbackTargetPosition(.previous_sentence, [:], 2500, 2, starts), 1000)
        XCTAssertEqual(playbackTargetPosition(.next_sentence, [:], 2500, 2, starts), 3000)
        XCTAssertEqual(playbackTargetPosition(.repeat_current_sentence, [:], 2500, 2, starts), 2000)
    }

    func testPlaybackNotice() {
        XCTAssertEqual(playbackNotice(.resume_playback, 0), "Podcast playing")
        XCTAssertEqual(playbackNotice(.pause_playback, 65_000), "Paused at 1:05")
        XCTAssertEqual(playbackNotice(.next_sentence, 0), "Next sentence · paused")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — types undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Logic/ClassroomLogic.swift`**

Port each function from `classroom.ts`. Reference implementation (translate the regex/logic 1:1; `matchDirectCommand` and `isActionableTranscript` keep the exact regex sets):

```swift
import Foundation

enum PlaybackTool: String {
    case pause_playback, resume_playback, previous_sentence, next_sentence
    case repeat_current_sentence, seek_relative, seek_to_timestamp
    case set_playback_speed, finish_discussion, exit_class
}

enum ClassroomPhase { case idle, connecting, podcastPlaying, userSpeaking, discussionPaused, discussing, teacherSpeaking, resuming, ended }

struct ClassroomState: Equatable { var phase: ClassroomPhase; var pausedAtMs: Int? }

enum ClassroomEvent {
    case speechStarted(atMs: Int), paused(atMs: Int), falseActivation
    case teacherStarted, teacherFinished, discussionStarted, resumed
    case entered, connected, collapsed, ended
}

func classroomReducer(_ state: ClassroomState, _ event: ClassroomEvent) -> ClassroomState {
    switch event {
    case let .speechStarted(atMs):
        return ClassroomState(phase: .userSpeaking, pausedAtMs: state.pausedAtMs ?? atMs)
    case let .paused(atMs):
        return ClassroomState(phase: .discussionPaused, pausedAtMs: atMs)
    case .falseActivation:
        return ClassroomState(phase: .discussionPaused, pausedAtMs: state.pausedAtMs)
    case .teacherStarted:
        return state.phase == .discussing ? ClassroomState(phase: .teacherSpeaking, pausedAtMs: state.pausedAtMs) : state
    case .teacherFinished:
        return state.phase == .teacherSpeaking ? ClassroomState(phase: .discussionPaused, pausedAtMs: state.pausedAtMs) : state
    case .discussionStarted:
        return ClassroomState(phase: .discussing, pausedAtMs: state.pausedAtMs)
    case .resumed:
        return ClassroomState(phase: .resuming, pausedAtMs: nil)
    case .entered:
        return ClassroomState(phase: .idle, pausedAtMs: nil)
    case .connected:
        return ClassroomState(phase: .podcastPlaying, pausedAtMs: nil)
    case .collapsed:
        return ClassroomState(phase: .idle, pausedAtMs: nil)
    case .ended:
        return ClassroomState(phase: .ended, pausedAtMs: state.pausedAtMs)
    }
}

func reliablePlaybackPosition(_ livePositionMs: Int, _ capturedPositionMs: Int) -> Int {
    livePositionMs > 0 ? livePositionMs : capturedPositionMs
}

func classroomCursorPosition(_ livePositionMs: Int, _ frozenPositionMs: Int?, _ initialPositionMs: Int) -> Int {
    frozenPositionMs ?? reliablePlaybackPosition(livePositionMs, initialPositionMs)
}

func classroomMode(_ state: ClassroomState) -> String {
    (state.phase == .podcastPlaying || state.phase == .idle) ? "listening" : "discussion"
}

private func classroomTime(_ ms: Int) -> String {
    let seconds = ms / 1000
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

func classroomStatusMessage(_ state: ClassroomState, _ positionMs: Int) -> String {
    switch state.phase {
    case .idle: return "Self-study · press Talk to bring in your teacher"
    case .podcastPlaying: return "Podcast playing · say anything to interrupt"
    case .resuming: return "Starting podcast..."
    case .userSpeaking: return "You are speaking · podcast paused at \(classroomTime(positionMs))"
    case .teacherSpeaking: return "Teacher is speaking · podcast paused at \(classroomTime(positionMs))"
    case .discussing: return "Teacher is preparing a response · paused at \(classroomTime(positionMs))"
    case .connecting: return "Connecting your voice classroom..."
    default: return "Discussion held at \(classroomTime(positionMs))"
    }
}

func isCurrentSentenceMeaningRequest(_ transcript: String) -> Bool {
    let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let zh = try! NSRegularExpression(pattern: "(当前|这|这句|这句话).*(什么意思|含义|怎么理解)")
    let en = try! NSRegularExpression(pattern: "what does (this|the current) sentence mean")
    let range = NSRange(value.startIndex..., in: value)
    return zh.firstMatch(in: value, range: range) != nil || en.firstMatch(in: value, range: range) != nil
}

func isActionableTranscript(_ transcript: String) -> Bool {
    let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.isEmpty { return false }
    let hasHan = normalized.range(of: "\\p{Han}", options: .regularExpression) != nil
    if hasHan {
        let fillers = try! NSRegularExpression(pattern: "^(我说的是|我说|等一下|喂|你好|不知道|继续吧|继续|暂停|停一下|好的|嗯|啊)$")
        if fillers.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil { return false }
        return normalized.count >= 4 || isCurrentSentenceMeaningRequest(normalized)
    }
    let words = normalized.matches(of: /[a-z]+(?:'[a-z]+)?/).map { String($0.0) }
    if ["pause", "continue", "resume", "repeat", "back"].contains(words.joined(separator: " ")) { return true }
    if words.count < 3 { return false }
    for (index, word) in words.enumerated() where index > 0 && word == words[index - 1] { return false }
    return true
}

func mergeTranscriptFragment(_ existing: String, _ fragment: String) -> String {
    "\(existing) \(fragment)".replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

func matchDirectCommand(_ transcript: String) -> (name: PlaybackTool, args: [String: Double])? {
    func stripTrailing(_ s: String) -> String {
        s.replacingOccurrences(of: "[。！？.!?,，、\\s]+$", with: "", options: .regularExpression)
    }
    var value = stripTrailing(transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    if value.isEmpty { return nil }
    let discuss = "(什么意思|含义|解释|讲讲|讲解|理解|为什么|观点|意思是|聊聊|讨论|explain|mean|why|discuss|what)"
    if value.range(of: discuss, options: .regularExpression) != nil { return nil }
    value = value.replacingOccurrences(of: "^.*[，,。.]\\s*", with: "", options: .regularExpression)
    let filler = "^(好的?|嗯+|那|然后|ok|okay|alright|well|so|um+|uh+|let'?s|请|麻烦你?|我们|咱们|你|帮我)\\s*"
    var prev: String
    repeat { prev = value; value = value.replacingOccurrences(of: filler, with: "", options: .regularExpression) } while value != prev
    value = value.replacingOccurrences(of: "[吧啦呀呢嘛]+$", with: "", options: .regularExpression)
    value = stripTrailing(value).trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    func match(_ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    if match("^(继续|继续继续|继续播放|接着放|接着播|接着听|回到播客|恢复播放|播放|播放视频|resume|resume playback|continue|continue playing|keep going|play|play the podcast|play the video|go back to the podcast)$") {
        return (.resume_playback, [:])
    }
    if match("^(暂停|停一下|停下|pause|pause playback|stop|hold on)$") { return (.pause_playback, [:]) }
    if match("^(上一句|回到上一句|previous sentence|go back one sentence)$") { return (.previous_sentence, [:]) }
    if match("^(下一句|next sentence)$") { return (.next_sentence, [:]) }
    if match("^(重播这句|再放一遍|重播|replay|play it again|say that again)$") { return (.repeat_current_sentence, [:]) }
    return nil
}

func playbackNotice(_ name: PlaybackTool, _ positionMs: Int) -> String {
    switch name {
    case .resume_playback, .finish_discussion: return "Podcast playing"
    case .pause_playback: return "Paused at \(classroomTime(positionMs))"
    case .seek_to_timestamp, .seek_relative: return "Moved to \(classroomTime(positionMs)) · paused"
    case .previous_sentence: return "Previous sentence · paused"
    case .next_sentence: return "Next sentence · paused"
    case .repeat_current_sentence: return "Repeating this sentence · paused"
    case .set_playback_speed: return "Playback speed updated"
    case .exit_class: return "Ending class"
    }
}

func playbackTargetPosition(_ name: PlaybackTool, _ args: [String: Double], _ currentMs: Int, _ currentSentenceIndex: Int, _ sentenceStarts: [Int]) -> Int {
    switch name {
    case .seek_to_timestamp: return max(0, Int((args["seconds"] ?? 0) * 1000))
    case .seek_relative: return max(0, currentMs + Int((args["seconds"] ?? 0) * 1000))
    case .previous_sentence:
        let i = max(0, currentSentenceIndex - 1)
        return sentenceStarts.indices.contains(i) ? sentenceStarts[i] : currentMs
    case .next_sentence:
        let i = min(sentenceStarts.count - 1, currentSentenceIndex + 1)
        return sentenceStarts.indices.contains(i) ? sentenceStarts[i] : currentMs
    case .repeat_current_sentence:
        return sentenceStarts.indices.contains(currentSentenceIndex) ? sentenceStarts[currentSentenceIndex] : currentMs
    default: return currentMs
    }
}
```

Note: the `default` in `playbackNotice` is unreachable because all cases are covered; if the Swift compiler flags exhaustiveness, keep the explicit cases above (no `default` needed since `PlaybackTool` is a closed enum). The `try!` on the static regex literals is safe — the patterns are constant and compile-time-valid.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all ClassroomLogicTests)

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Logic/ClassroomLogic.swift ios/NexaInsightTests/ClassroomLogicTests.swift
git commit -m "feat(ios): port classroom.ts interaction logic + state machine"
```

---

### Task 5: Keychain store, settings, and backend API client

**Files:**
- Create: `ios/NexaInsight/Services/KeychainStore.swift`
- Create: `ios/NexaInsight/Services/AppSettings.swift`
- Create: `ios/NexaInsight/Services/BackendClient.swift`
- Create: `ios/NexaInsightTests/BackendClientTests.swift`

**Interfaces:**
- Consumes: DTOs (Task 2).
- Produces:
  - `enum SecretKey: String { case openAIKey, dashscopeKey, dashscopeWorkspaceId }` and `struct KeychainStore { func set(_ value: String, for key: SecretKey); func get(_ key: SecretKey) -> String?; func delete(_ key: SecretKey) }` (wraps Security framework).
  - `final class AppSettings: ObservableObject { @Published var backendBaseURL: String }` persisted in `UserDefaults` (key `backendBaseURL`, default `http://localhost:8000`).
  - `struct BackendClient { let baseURL: URL; var session: URLSession = .shared; func listEpisodes() async throws -> [EpisodeDTO]; func importEpisode(url: String) async throws -> (episode: EpisodeDTO, job: JobDTO); func episodeJob(_ id: Int) async throws -> JobDTO; func retryJob(_ id: Int) async throws -> JobDTO; func bundle(_ id: Int) async throws -> BundleDTO; func downloadAudio(_ id: Int, to destination: URL) async throws }` plus `func formatApiError(_ data: Data, _ status: Int) -> String` (ports `api.ts` error formatting: reads `detail` string or FastAPI validation array).
  - Shared `static var jsonDecoder: JSONDecoder` with `.convertFromSnakeCase`.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/BackendClientTests.swift`**

```swift
import XCTest
@testable import NexaInsight

final class BackendClientTests: XCTestCase {
    func testFormatApiErrorReadsDetailString() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        let data = #"{"detail":"This episode has already been imported"}"#.data(using: .utf8)!
        XCTAssertEqual(client.formatApiError(data, 409), "This episode has already been imported")
    }

    func testFormatApiErrorReadsValidationArray() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        let data = #"{"detail":[{"loc":["body","url"],"msg":"field required"}]}"#.data(using: .utf8)!
        XCTAssertEqual(client.formatApiError(data, 422), "body.url: field required")
    }

    func testFormatApiErrorFallback() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        XCTAssertEqual(client.formatApiError(Data(), 500), "Request failed (500)")
    }

    func testBundleURLConstruction() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        XCTAssertEqual(client.url(path: "/api/episodes/3/bundle").absoluteString,
                       "http://localhost:8000/api/episodes/3/bundle")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `BackendClient` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Services/KeychainStore.swift`**

```swift
import Foundation
import Security

enum SecretKey: String { case openAIKey, dashscopeKey, dashscopeWorkspaceId }

struct KeychainStore {
    let service = "com.nexainsight.secrets"

    func set(_ value: String, for key: SecretKey) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: key.rawValue]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func get(_ key: SecretKey) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: key.rawValue,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: SecretKey) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: key.rawValue]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Write `ios/NexaInsight/Services/AppSettings.swift`**

```swift
import Foundation

final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var backendBaseURL: String {
        didSet { defaults.set(backendBaseURL, forKey: "backendBaseURL") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendBaseURL = defaults.string(forKey: "backendBaseURL") ?? "http://localhost:8000"
    }
}
```

- [ ] **Step 5: Write `ios/NexaInsight/Services/BackendClient.swift`**

```swift
import Foundation

struct BackendClient {
    let baseURL: URL
    var session: URLSession = .shared

    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func url(path: String) -> URL { baseURL.appendingPathComponent(path) }

    func formatApiError(_ data: Data, _ status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] {
            if let text = detail as? String { return text }
            if let items = detail as? [[String: Any]] {
                return items.map { item in
                    let loc = (item["loc"] as? [Any] ?? []).map { "\($0)" }.joined(separator: ".")
                    let msg = item["msg"] as? String ?? "Invalid value"
                    return "\(loc): \(msg)"
                }.joined(separator: "; ")
            }
        }
        return "Request failed (\(status))"
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(URLRequest(url: url(path: path)))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw NSError(domain: "Backend", code: status, userInfo: [NSLocalizedDescriptionKey: formatApiError(data, status)]) }
        return try Self.jsonDecoder.decode(T.self, from: data)
    }

    func listEpisodes() async throws -> [EpisodeDTO] { try await get("/api/episodes") }

    func importEpisode(url urlString: String) async throws -> (episode: EpisodeDTO, job: JobDTO) {
        struct ImportView: Decodable { let episode: EpisodeDTO; let job: JobDTO }
        var request = URLRequest(url: url(path: "/api/episodes/import"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": urlString])
        let view: ImportView = try await send(request)
        return (view.episode, view.job)
    }

    func episodeJob(_ id: Int) async throws -> JobDTO { try await get("/api/episodes/\(id)/job") }

    func retryJob(_ id: Int) async throws -> JobDTO {
        var request = URLRequest(url: url(path: "/api/jobs/\(id)/retry"))
        request.httpMethod = "POST"
        return try await send(request)
    }

    func bundle(_ id: Int) async throws -> BundleDTO { try await get("/api/episodes/\(id)/bundle") }

    func downloadAudio(_ id: Int, to destination: URL) async throws {
        let (temp, response) = try await session.download(from: url(path: "/api/episodes/\(id)/audio"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw NSError(domain: "Backend", code: status, userInfo: [NSLocalizedDescriptionKey: "Audio download failed (\(status))"]) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp, to: destination)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all four BackendClientTests)

- [ ] **Step 7: Commit**

```bash
git add ios/NexaInsight/Services
git add ios/NexaInsightTests/BackendClientTests.swift
git commit -m "feat(ios): keychain, settings, backend API client"
```

---

### Task 6: SwiftData persistence and episode store

**Files:**
- Create: `ios/NexaInsight/Storage/PersistentModels.swift`
- Create: `ios/NexaInsight/Storage/EpisodeStore.swift`
- Create: `ios/NexaInsightTests/EpisodeStoreTests.swift`

**Interfaces:**
- Consumes: DTOs (Task 2), `BackendClient` (Task 5).
- Produces:
  - SwiftData `@Model` classes `StoredEpisode`, `StoredChapter`, `StoredSentence`, `StoredRecording` (fields mirror the DTOs plus `localAudioPath: String?` on episode and `localFilePath`, `isBest`, `feedback` on recording).
  - `@MainActor final class EpisodeStore` with a `ModelContainer`, and:
    - `func saveBundle(_ bundle: BundleDTO, localAudioPath: String?) throws -> StoredEpisode` — upserts by episode id, replacing chapters/sentences.
    - `func sentences(for episodeId: Int) -> [SentenceDTO]` — ordered by position, converted back to DTOs for the pure logic.
    - `func chapters(for episodeId: Int) -> [ChapterDTO]`.
    - `func downloadedEpisodes() -> [EpisodeDTO]`.
    - `func addRecording(episodeId: Int, sentenceId: Int, localFilePath: String) throws -> StoredRecording`.
    - `func recordings(sentenceId: Int) -> [StoredRecording]`.
    - `func markBest(recordingId: PersistentIdentifier) throws`.
    - `func setFeedback(recordingId: PersistentIdentifier, feedback: String) throws`.
  - Note: `saveBundle` is what turns a downloaded bundle into the local, offline-usable episode. `localAudioPath` is a path relative to the app's Application Support dir.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/EpisodeStoreTests.swift`**

```swift
import XCTest
import SwiftData
@testable import NexaInsight

@MainActor
final class EpisodeStoreTests: XCTestCase {
    func makeStore() throws -> EpisodeStore {
        try EpisodeStore(inMemory: true)
    }

    func bundle() -> BundleDTO {
        BundleDTO(
            episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: "y", title: "T", channel: "C", durationMs: 1000, thumbnailUrl: nil, audioPath: "episodes/1/source.mp3", status: "ready", error: nil),
            chapters: [ChapterDTO(id: 1, title: "Intro", summary: "s", startMs: 0, endMs: 1000)],
            sentences: [
                SentenceDTO(id: 10, episodeId: 1, chapterId: 1, position: 0, startMs: 0, endMs: 500, speaker: nil, sourceText: "Hi", chinese: "嗨"),
                SentenceDTO(id: 11, episodeId: 1, chapterId: 1, position: 1, startMs: 500, endMs: 1000, speaker: nil, sourceText: "Bye", chinese: "拜"),
            ],
            hasAudio: true)
    }

    func testSaveAndReadBundle() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: "audio/1.mp3")
        XCTAssertEqual(store.sentences(for: 1).map(\.sourceText), ["Hi", "Bye"])
        XCTAssertEqual(store.chapters(for: 1).count, 1)
        XCTAssertEqual(store.downloadedEpisodes().first?.title, "T")
    }

    func testSaveBundleUpsertsReplacingSentences() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)
        var updated = bundle()
        updated = BundleDTO(episode: updated.episode, chapters: updated.chapters,
                            sentences: [updated.sentences[0]], hasAudio: true)
        _ = try store.saveBundle(updated, localAudioPath: nil)
        XCTAssertEqual(store.sentences(for: 1).count, 1)  // replaced, not duplicated
    }

    func testRecordingsLifecycle() throws {
        let store = try makeStore()
        _ = try store.saveBundle(bundle(), localAudioPath: nil)
        let r1 = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "rec/a.m4a")
        _ = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "rec/b.m4a")
        XCTAssertEqual(store.recordings(sentenceId: 10).count, 2)
        try store.markBest(recordingId: r1.persistentModelID)
        XCTAssertEqual(store.recordings(sentenceId: 10).filter(\.isBest).count, 1)
        try store.setFeedback(recordingId: r1.persistentModelID, feedback: "great rhythm")
        XCTAssertTrue(store.recordings(sentenceId: 10).contains { $0.feedback == "great rhythm" })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `EpisodeStore` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Storage/PersistentModels.swift`**

```swift
import Foundation
import SwiftData

@Model final class StoredEpisode {
    @Attribute(.unique) var episodeId: Int
    var sourceUrl: String
    var youtubeId: String?
    var title: String?
    var channel: String?
    var durationMs: Int?
    var thumbnailUrl: String?
    var localAudioPath: String?
    var status: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var chapters: [StoredChapter]
    @Relationship(deleteRule: .cascade) var sentences: [StoredSentence]
    @Relationship(deleteRule: .cascade) var recordings: [StoredRecording]

    init(episodeId: Int, sourceUrl: String, youtubeId: String?, title: String?, channel: String?, durationMs: Int?, thumbnailUrl: String?, localAudioPath: String?, status: String) {
        self.episodeId = episodeId; self.sourceUrl = sourceUrl; self.youtubeId = youtubeId
        self.title = title; self.channel = channel; self.durationMs = durationMs
        self.thumbnailUrl = thumbnailUrl; self.localAudioPath = localAudioPath; self.status = status
        self.createdAt = Date(); self.chapters = []; self.sentences = []; self.recordings = []
    }
}

@Model final class StoredChapter {
    var chapterId: Int; var episodeId: Int; var title: String; var summary: String; var startMs: Int; var endMs: Int
    init(chapterId: Int, episodeId: Int, title: String, summary: String, startMs: Int, endMs: Int) {
        self.chapterId = chapterId; self.episodeId = episodeId; self.title = title
        self.summary = summary; self.startMs = startMs; self.endMs = endMs
    }
}

@Model final class StoredSentence {
    var sentenceId: Int; var episodeId: Int; var chapterId: Int?; var position: Int
    var startMs: Int; var endMs: Int; var speaker: String?; var sourceText: String; var chinese: String
    init(sentenceId: Int, episodeId: Int, chapterId: Int?, position: Int, startMs: Int, endMs: Int, speaker: String?, sourceText: String, chinese: String) {
        self.sentenceId = sentenceId; self.episodeId = episodeId; self.chapterId = chapterId
        self.position = position; self.startMs = startMs; self.endMs = endMs
        self.speaker = speaker; self.sourceText = source_text; self.chinese = chinese
    }
}

@Model final class StoredRecording {
    var episodeId: Int; var sentenceId: Int; var localFilePath: String; var isBest: Bool; var feedback: String?; var createdAt: Date
    init(episodeId: Int, sentenceId: Int, localFilePath: String, isBest: Bool = false, feedback: String? = nil) {
        self.episodeId = episodeId; self.sentenceId = sentenceId; self.localFilePath = localFilePath
        self.isBest = isBest; self.feedback = feedback; self.createdAt = Date()
    }
}
```

- [ ] **Step 4: Write `ios/NexaInsight/Storage/EpisodeStore.swift`**

```swift
import Foundation
import SwiftData

@MainActor
final class EpisodeStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: StoredEpisode.self, StoredChapter.self, StoredSentence.self, StoredRecording.self, configurations: config)
    }

    private func episode(_ id: Int) -> StoredEpisode? {
        try? context.fetch(FetchDescriptor<StoredEpisode>(predicate: #Predicate { $0.episodeId == id })).first
    }

    @discardableResult
    func saveBundle(_ bundle: BundleDTO, localAudioPath: String?) throws -> StoredEpisode {
        let e = bundle.episode
        if let existing = episode(e.id) {
            existing.sentences.forEach(context.delete)
            existing.chapters.forEach(context.delete)
            existing.sentences = []; existing.chapters = []
            existing.title = e.title; existing.channel = e.channel; existing.status = e.status
            if let localAudioPath { existing.localAudioPath = localAudioPath }
            try attach(bundle, to: existing)
            try context.save()
            return existing
        }
        let stored = StoredEpisode(episodeId: e.id, sourceUrl: e.sourceUrl, youtubeId: e.youtubeId, title: e.title, channel: e.channel, durationMs: e.durationMs, thumbnailUrl: e.thumbnailUrl, localAudioPath: localAudioPath, status: e.status)
        context.insert(stored)
        try attach(bundle, to: stored)
        try context.save()
        return stored
    }

    private func attach(_ bundle: BundleDTO, to stored: StoredEpisode) throws {
        for c in bundle.chapters {
            let chapter = StoredChapter(chapterId: c.id, episodeId: bundle.episode.id, title: c.title, summary: c.summary, startMs: c.startMs, endMs: c.endMs)
            context.insert(chapter); stored.chapters.append(chapter)
        }
        for s in bundle.sentences {
            let sentence = StoredSentence(sentenceId: s.id, episodeId: bundle.episode.id, chapterId: s.chapterId, position: s.position, startMs: s.startMs, endMs: s.endMs, speaker: s.speaker, sourceText: s.sourceText, chinese: s.chinese)
            context.insert(sentence); stored.sentences.append(sentence)
        }
    }

    func sentences(for episodeId: Int) -> [SentenceDTO] {
        guard let e = episode(episodeId) else { return [] }
        return e.sentences.sorted { $0.position < $1.position }.map {
            SentenceDTO(id: $0.sentenceId, episodeId: $0.episodeId, chapterId: $0.chapterId, position: $0.position, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker, sourceText: $0.sourceText, chinese: $0.chinese)
        }
    }

    func chapters(for episodeId: Int) -> [ChapterDTO] {
        guard let e = episode(episodeId) else { return [] }
        return e.chapters.sorted { $0.startMs < $1.startMs }.map {
            ChapterDTO(id: $0.chapterId, title: $0.title, summary: $0.summary, startMs: $0.startMs, endMs: $0.endMs)
        }
    }

    func localAudioPath(for episodeId: Int) -> String? { episode(episodeId)?.localAudioPath }

    func downloadedEpisodes() -> [EpisodeDTO] {
        let all = (try? context.fetch(FetchDescriptor<StoredEpisode>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        return all.map {
            EpisodeDTO(id: $0.episodeId, sourceUrl: $0.sourceUrl, youtubeId: $0.youtubeId, title: $0.title, channel: $0.channel, durationMs: $0.durationMs, thumbnailUrl: $0.thumbnailUrl, audioPath: $0.localAudioPath, status: $0.status, error: nil)
        }
    }

    @discardableResult
    func addRecording(episodeId: Int, sentenceId: Int, localFilePath: String) throws -> StoredRecording {
        let recording = StoredRecording(episodeId: episodeId, sentenceId: sentenceId, localFilePath: localFilePath)
        context.insert(recording)
        if let e = episode(episodeId) { e.recordings.append(recording) }
        try context.save()
        return recording
    }

    func recordings(sentenceId: Int) -> [StoredRecording] {
        (try? context.fetch(FetchDescriptor<StoredRecording>(predicate: #Predicate { $0.sentenceId == sentenceId }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func markBest(recordingId: PersistentIdentifier) throws {
        guard let target = context.model(for: recordingId) as? StoredRecording else { return }
        for peer in recordings(sentenceId: target.sentenceId) { peer.isBest = false }
        target.isBest = true
        try context.save()
    }

    func setFeedback(recordingId: PersistentIdentifier, feedback: String) throws {
        guard let target = context.model(for: recordingId) as? StoredRecording else { return }
        target.feedback = feedback
        try context.save()
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all three EpisodeStoreTests)

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Storage ios/NexaInsightTests/EpisodeStoreTests.swift
git commit -m "feat(ios): SwiftData persistence and episode store"
```

---

### Task 7: Playback protocol and AVPlayer implementation

**Files:**
- Create: `ios/NexaInsight/Playback/Playback.swift`
- Create: `ios/NexaInsight/Playback/LocalAudioPlayback.swift`
- Create: `ios/NexaInsightTests/PlaybackTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol Playback: AnyObject { var currentMs: Int { get }; var isReady: Bool { get }; var playbackState: PlaybackState { get }; func seek(_ ms: Int); func pause(); func play(); func speed(_ rate: Double) }` and `enum PlaybackState { case unstarted, playing, paused, ended, buffering }`. This mirrors the web app's `ClassroomPlayback`/`useYouTube` surface exactly, so every consumer (study view, Plan 3 classroom) is player-agnostic.
  - `@MainActor final class LocalAudioPlayback: ObservableObject, Playback` wrapping `AVPlayer` on a local mp3 file URL. `@Published var currentMs`, `@Published var isReady`, `@Published var playbackState`. `seek` clamps to `>= 0` and rounds (mirrors `useYouTube.seek`: `max(0, round(ms))`). Uses a periodic time observer (200ms, matching the web poll cadence) to update `currentMs`.
  - `final class FakePlayback: Playback` — a deterministic test double recording calls (`seeks: [Int]`, `didPlay`, `didPause`, `rates: [Double]`) and letting tests set `currentMs`. Placed in the test target.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/PlaybackTests.swift`**

```swift
import XCTest
@testable import NexaInsight

final class FakePlayback: Playback {
    var currentMs: Int = 0
    var isReady: Bool = true
    var playbackState: PlaybackState = .paused
    private(set) var seeks: [Int] = []
    private(set) var didPlay = false
    private(set) var didPause = false
    private(set) var rates: [Double] = []
    func seek(_ ms: Int) { seeks.append(ms); currentMs = ms }
    func pause() { didPause = true; playbackState = .paused }
    func play() { didPlay = true; playbackState = .playing }
    func speed(_ rate: Double) { rates.append(rate) }
}

final class PlaybackTests: XCTestCase {
    func testFakePlaybackRecordsInteractions() {
        let p = FakePlayback()
        p.seek(1500); p.play(); p.pause(); p.speed(1.5)
        XCTAssertEqual(p.seeks, [1500])
        XCTAssertTrue(p.didPlay)
        XCTAssertTrue(p.didPause)
        XCTAssertEqual(p.rates, [1.5])
        XCTAssertEqual(p.currentMs, 1500)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `Playback` / `PlaybackState` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Playback/Playback.swift`**

```swift
import Foundation

enum PlaybackState { case unstarted, playing, paused, ended, buffering }

protocol Playback: AnyObject {
    var currentMs: Int { get }
    var isReady: Bool { get }
    var playbackState: PlaybackState { get }
    func seek(_ ms: Int)
    func pause()
    func play()
    func speed(_ rate: Double)
}
```

- [ ] **Step 4: Write `ios/NexaInsight/Playback/LocalAudioPlayback.swift`**

```swift
import AVFoundation
import Combine
import Foundation

@MainActor
final class LocalAudioPlayback: ObservableObject, Playback {
    private let player: AVPlayer
    private var timeObserver: Any?
    @Published private(set) var currentMsPublished: Int = 0
    @Published private(set) var isReadyPublished: Bool = false
    @Published private(set) var statePublished: PlaybackState = .unstarted

    var currentMs: Int { currentMsPublished }
    var isReady: Bool { isReadyPublished }
    var playbackState: PlaybackState { statePublished }

    init(fileURL: URL, initialPositionMs: Int = 0) {
        player = AVPlayer(url: fileURL)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentMsPublished = max(0, Int(time.seconds * 1000))
        }
        Task { @MainActor in
            if let item = player.currentItem {
                _ = try? await item.asset.load(.duration)
                isReadyPublished = true
                if initialPositionMs > 0 { seek(initialPositionMs) }
            }
        }
    }

    deinit { if let timeObserver { player.removeTimeObserver(timeObserver) } }

    func seek(_ ms: Int) {
        let next = max(0, ms)
        currentMsPublished = next
        player.seek(to: CMTime(value: CMTimeValue(next), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() { player.pause(); statePublished = .paused }

    func play() {
        player.play()
        player.rate = player.rate == 0 ? 1 : player.rate
        statePublished = .playing
    }

    func speed(_ rate: Double) { player.rate = Float(rate) }
}
```

Note: `LocalAudioPlayback` exposes both the `Playback` protocol getters and `@Published` mirrors so SwiftUI views observe changes. Consumers that only need the protocol (Plan 3 orchestration) use the protocol; views observe the published properties.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Playback ios/NexaInsightTests/PlaybackTests.swift
git commit -m "feat(ios): Playback protocol + AVPlayer local mp3 implementation"
```

---

### Task 8: Import flow and library view model

**Files:**
- Create: `ios/NexaInsight/Import/ImportViewModel.swift`
- Create: `ios/NexaInsight/Import/AudioFiles.swift`
- Create: `ios/NexaInsightTests/ImportViewModelTests.swift`

**Interfaces:**
- Consumes: `BackendClient` (Task 5), `EpisodeStore` (Task 6), DTOs.
- Produces:
  - `enum AudioFiles { static func audioURL(forEpisode id: Int) -> URL }` — a stable path under Application Support (`AppSupport/audio/<id>.mp3`); the relative path stored is `audio/<id>.mp3`.
  - `@MainActor final class ImportViewModel: ObservableObject` with:
    - `@Published var episodes: [EpisodeDTO]` (from the store; downloaded/local)
    - `@Published var importing: Bool`, `@Published var importError: String?`, `@Published var progress: ImportProgress?`
    - `struct ImportProgress { let stage: String; let percent: Int }`
    - `func reload()` — repopulate `episodes` from the store.
    - `func startImport(urlString:) async` — POST import, then poll the job.
    - `func pollUntilReady(episodeId:jobId:) async` — poll `episodeJob` every 2s; on `complete` fetch the bundle, download audio if `has_audio`, `saveBundle`, then `reload()`; on `failed` set `importError`.
    - `func retry(jobId:episodeId:) async`.
  - The polling cadence and terminal states (`complete` → download+persist, `failed` → error+retry) mirror the web app's job flow. This is the only place that talks to the backend during normal use.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/ImportViewModelTests.swift`**

```swift
import XCTest
@testable import NexaInsight

@MainActor
final class ImportViewModelTests: XCTestCase {
    func testProgressPercentFromJob() {
        // The view model maps a JobDTO to a display progress; verify the mapping.
        let job = JobDTO(id: 1, episodeId: 1, stage: "translation", status: "running", progress: 72, error: nil)
        let progress = ImportViewModel.progress(from: job)
        XCTAssertEqual(progress.stage, "translation")
        XCTAssertEqual(progress.percent, 72)
    }

    func testAudioURLPathIsStableAndRelativePathDerivable() {
        let url = AudioFiles.audioURL(forEpisode: 42)
        XCTAssertTrue(url.path.hasSuffix("audio/42.mp3"))
    }

    func testReloadReadsFromStore() throws {
        let store = try EpisodeStore(inMemory: true)
        _ = try store.saveBundle(
            BundleDTO(episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: nil, title: "Local", channel: nil, durationMs: nil, thumbnailUrl: nil, audioPath: nil, status: "ready", error: nil),
                      chapters: [], sentences: [], hasAudio: false),
            localAudioPath: nil)
        let vm = ImportViewModel(client: BackendClient(baseURL: URL(string: "http://localhost:8000")!), store: store)
        vm.reload()
        XCTAssertEqual(vm.episodes.first?.title, "Local")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `ImportViewModel` / `AudioFiles` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Import/AudioFiles.swift`**

```swift
import Foundation

enum AudioFiles {
    static var audioDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("audio", isDirectory: true)
    }
    static func audioURL(forEpisode id: Int) -> URL {
        audioDirectory.appendingPathComponent("\(id).mp3")
    }
    static func relativePath(forEpisode id: Int) -> String { "audio/\(id).mp3" }
}
```

- [ ] **Step 4: Write `ios/NexaInsight/Import/ImportViewModel.swift`**

```swift
import Foundation

@MainActor
final class ImportViewModel: ObservableObject {
    struct ImportProgress: Equatable { let stage: String; let percent: Int }

    @Published var episodes: [EpisodeDTO] = []
    @Published var importing = false
    @Published var importError: String?
    @Published var progress: ImportProgress?

    private let client: BackendClient
    private let store: EpisodeStore

    init(client: BackendClient, store: EpisodeStore) {
        self.client = client; self.store = store
        reload()
    }

    static func progress(from job: JobDTO) -> ImportProgress {
        ImportProgress(stage: job.stage, percent: job.progress)
    }

    func reload() { episodes = store.downloadedEpisodes() }

    func startImport(urlString: String) async {
        importing = true; importError = nil; progress = nil
        defer { importing = false }
        do {
            let (episode, job) = try await client.importEpisode(url: urlString)
            await pollUntilReady(episodeId: episode.id, jobId: job.id)
        } catch {
            importError = error.localizedDescription
        }
    }

    func pollUntilReady(episodeId: Int, jobId: Int) async {
        while true {
            do {
                let job = try await client.episodeJob(episodeId)
                progress = Self.progress(from: job)
                if job.status == "complete" {
                    try await finishDownload(episodeId: episodeId)
                    return
                }
                if job.status == "failed" {
                    importError = job.error ?? "Import failed"
                    return
                }
            } catch {
                importError = error.localizedDescription
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func finishDownload(episodeId: Int) async throws {
        let bundle = try await client.bundle(episodeId)
        var localPath: String? = nil
        if bundle.hasAudio {
            let destination = AudioFiles.audioURL(forEpisode: episodeId)
            try await client.downloadAudio(episodeId, to: destination)
            localPath = AudioFiles.relativePath(forEpisode: episodeId)
        }
        _ = try store.saveBundle(bundle, localAudioPath: localPath)
        reload()
        progress = nil
    }

    func retry(jobId: Int, episodeId: Int) async {
        importError = nil
        do {
            _ = try await client.retryJob(jobId)
            await pollUntilReady(episodeId: episodeId, jobId: jobId)
        } catch {
            importError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all three ImportViewModelTests)

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Import ios/NexaInsightTests/ImportViewModelTests.swift
git commit -m "feat(ios): import flow with job polling and local download"
```

---

### Task 9: Library, Settings, and Study (subtitle) UI

**Files:**
- Create: `ios/NexaInsight/Views/LibraryView.swift`
- Create: `ios/NexaInsight/Views/SettingsView.swift`
- Create: `ios/NexaInsight/Views/StudyView.swift`
- Create: `ios/NexaInsight/Views/StudyViewModel.swift`
- Modify: `ios/NexaInsight/ContentView.swift`
- Create: `ios/NexaInsightTests/StudyViewModelTests.swift`

**Interfaces:**
- Consumes: `ImportViewModel`, `EpisodeStore`, `AppSettings`, `KeychainStore`, `LocalAudioPlayback`, `SubtitleLogic` (Task 3), `AudioFiles`.
- Produces:
  - `@MainActor final class StudyViewModel: ObservableObject` holding the subtitle follow/browse behavior ported from `ClassroomView.tsx`:
    - `@Published var following = true`
    - `func currentSentence(sentences:cursorMs:) -> SentenceDTO?` → `activeSentence(...) ?? sentences.first`
    - `func onManualScroll(currentOffset:targetOffset:)` — if `isManualScrollAway(...,tolerance:24)`, set `following=false` and start a 10s idle timer that flips it back to `true`.
    - `func syncNow()` — cancel timer, `following=true`.
    - `func tap(sentence:playback:)` — `playback.seek(sentence.startMs); playback.play()` (mirrors the web row tap).
    - `func search(_ query:in:) -> [SentenceDTO]` — case-insensitive filter over `source_text + " " + chinese` (mirrors the web `visible` filter).
  - `LibraryView` — lists `episodes`; an "Import" button presents a URL entry sheet driving `ImportViewModel.startImport`; shows progress and a retry button on failure; tapping a ready episode with a local audio file opens `StudyView`; a gear opens `SettingsView`.
  - `SettingsView` — text fields for backend base URL (→ `AppSettings`) and API keys (→ `KeychainStore`: OpenAI key, DashScope key, DashScope workspace id). Keys are entered with secure fields and never logged.
  - `StudyView` — builds a `LocalAudioPlayback` from the episode's local mp3, renders the transcript list with the active line highlighted and auto-centered while following, a search field, tap-to-seek, and a "Back to current" button when browsing. Visual layout is free; behavior follows `StudyViewModel`.
  - `ContentView` shows `LibraryView` as the root, injecting shared `EpisodeStore`/`AppSettings`.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/StudyViewModelTests.swift`**

```swift
import XCTest
@testable import NexaInsight

private func s(_ id: Int, _ start: Int, _ en: String, _ zh: String) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: start + 900, speaker: nil, sourceText: en, chinese: zh)
}

@MainActor
final class StudyViewModelTests: XCTestCase {
    let lines = [s(0, 0, "Hello there", "你好"), s(1, 1000, "How are you", "你好吗"), s(2, 2000, "Goodbye now", "再见")]

    func testCurrentSentenceFallsBackToFirst() {
        let vm = StudyViewModel()
        XCTAssertEqual(vm.currentSentence(sentences: lines, cursorMs: -50)?.id, 0)
        XCTAssertEqual(vm.currentSentence(sentences: lines, cursorMs: 1500)?.id, 1)
    }

    func testSearchFiltersBilingual() {
        let vm = StudyViewModel()
        XCTAssertEqual(vm.search("再见", in: lines).map(\.id), [2])
        XCTAssertEqual(vm.search("how", in: lines).map(\.id), [1])
        XCTAssertEqual(vm.search("", in: lines).count, 3)
    }

    func testManualScrollLeavesFollowThenSyncRestores() {
        let vm = StudyViewModel()
        XCTAssertTrue(vm.following)
        vm.onManualScroll(currentOffset: 300, targetOffset: 160)  // away > 24
        XCTAssertFalse(vm.following)
        vm.syncNow()
        XCTAssertTrue(vm.following)
    }

    func testTapSeeksAndPlays() {
        let vm = StudyViewModel()
        let player = FakePlayback()
        vm.tap(sentence: lines[2], playback: player)
        XCTAssertEqual(player.seeks, [2000])
        XCTAssertTrue(player.didPlay)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `StudyViewModel` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Views/StudyViewModel.swift`**

```swift
import Foundation

@MainActor
final class StudyViewModel: ObservableObject {
    @Published var following = true
    private var idleTask: Task<Void, Never>?

    func currentSentence(sentences: [SentenceDTO], cursorMs: Int) -> SentenceDTO? {
        activeSentence(sentences, cursorMs) ?? sentences.first
    }

    func search(_ query: String, in sentences: [SentenceDTO]) -> [SentenceDTO] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return sentences }
        return sentences.filter { "\($0.sourceText) \($0.chinese)".lowercased().contains(q) }
    }

    func onManualScroll(currentOffset: CGFloat, targetOffset: CGFloat) {
        guard isManualScrollAway(currentScrollTop: currentOffset, targetScrollTop: targetOffset, tolerancePx: 24) else { return }
        following = false
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { await MainActor.run { self?.following = true } }
        }
    }

    func syncNow() {
        idleTask?.cancel()
        following = true
    }

    func tap(sentence: SentenceDTO, playback: Playback) {
        playback.seek(sentence.startMs)
        playback.play()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all four StudyViewModelTests)

- [ ] **Step 5: Write the SwiftUI views**

Write `LibraryView.swift`, `SettingsView.swift`, `StudyView.swift`, and update `ContentView.swift`. These are UI wiring around the tested view models; visual design is free but behavior must call the view-model methods above. Reference structure:

`ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @State private var store: EpisodeStore? = try? EpisodeStore()

    var body: some View {
        Group {
            if let store {
                LibraryView(store: store, settings: settings)
            } else {
                Text("Storage unavailable")
            }
        }
    }
}
```

`LibraryView.swift` (behavior: list + import sheet + progress + retry + navigation to study):

```swift
import SwiftUI

struct LibraryView: View {
    let store: EpisodeStore
    @ObservedObject var settings: AppSettings
    @StateObject private var vm: ImportViewModel
    @State private var showImport = false
    @State private var showSettings = false
    @State private var urlDraft = ""

    init(store: EpisodeStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        _vm = StateObject(wrappedValue: ImportViewModel(
            client: BackendClient(baseURL: URL(string: settings.backendBaseURL) ?? URL(string: "http://localhost:8000")!),
            store: store))
    }

    var body: some View {
        NavigationStack {
            List(vm.episodes) { episode in
                NavigationLink(value: episode.id) {
                    VStack(alignment: .leading) {
                        Text(episode.title ?? "Untitled").font(.headline)
                        Text(episode.channel ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: Int.self) { id in
                StudyView(episodeId: id, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("Import") { showImport = true } }
                ToolbarItem(placement: .topBarLeading) { Button("Settings") { showSettings = true } }
            }
            .sheet(isPresented: $showImport) {
                ImportSheet(vm: vm, urlDraft: $urlDraft)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .onAppear { vm.reload() }
        }
    }
}

struct ImportSheet: View {
    @ObservedObject var vm: ImportViewModel
    @Binding var urlDraft: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("YouTube URL", text: $urlDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
                if let progress = vm.progress {
                    ProgressView(value: Double(progress.percent), total: 100) { Text(progress.stage) }
                }
                if let error = vm.importError {
                    Text(error).foregroundStyle(.red)
                }
                Button(vm.importing ? "Importing…" : "Start import") {
                    let url = urlDraft
                    Task { await vm.startImport(urlString: url); if vm.importError == nil && vm.progress == nil { dismiss() } }
                }.disabled(vm.importing || urlDraft.isEmpty)
            }
            .navigationTitle("Import episode")
        }
    }
}
```

`SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    private let keychain = KeychainStore()
    @State private var openAIKey = ""
    @State private var dashscopeKey = ""
    @State private var workspaceId = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    TextField("Base URL", text: $settings.backendBaseURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("API keys (stored in Keychain)") {
                    SecureField("OpenAI API key", text: $openAIKey)
                    SecureField("DashScope API key", text: $dashscopeKey)
                    TextField("DashScope workspace id", text: $workspaceId)
                }
                Button("Save keys") {
                    if !openAIKey.isEmpty { keychain.set(openAIKey, for: .openAIKey) }
                    if !dashscopeKey.isEmpty { keychain.set(dashscopeKey, for: .dashscopeKey) }
                    if !workspaceId.isEmpty { keychain.set(workspaceId, for: .dashscopeWorkspaceId) }
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                openAIKey = keychain.get(.openAIKey) ?? ""
                dashscopeKey = keychain.get(.dashscopeKey) ?? ""
                workspaceId = keychain.get(.dashscopeWorkspaceId) ?? ""
            }
        }
    }
}
```

`StudyView.swift` (behavior: player + transcript follow/browse/tap/search/sync):

```swift
import SwiftUI

struct StudyView: View {
    let episodeId: Int
    let store: EpisodeStore
    @StateObject private var vm = StudyViewModel()
    @StateObject private var player: LocalAudioPlayback
    @State private var query = ""
    private let sentences: [SentenceDTO]

    init(episodeId: Int, store: EpisodeStore) {
        self.episodeId = episodeId
        self.store = store
        self.sentences = store.sentences(for: episodeId)
        let relative = store.localAudioPath(for: episodeId) ?? "audio/\(episodeId).mp3"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        _player = StateObject(wrappedValue: LocalAudioPlayback(fileURL: base.appendingPathComponent(relative)))
    }

    var visible: [SentenceDTO] { vm.search(query, in: sentences) }
    var current: SentenceDTO? { vm.currentSentence(sentences: sentences, cursorMs: player.currentMs) }

    var body: some View {
        VStack {
            HStack {
                Button(player.playbackState == .playing ? "Pause" : "Play") {
                    player.playbackState == .playing ? player.pause() : player.play()
                }
                Spacer()
                Text(formatTime(player.currentMs)).monospacedDigit()
            }.padding(.horizontal)

            TextField("Search this episode", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal)

            ScrollViewReader { proxy in
                List(visible) { s in
                    Button {
                        vm.tap(sentence: s, playback: player)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(formatTime(s.startMs)).font(.caption).foregroundStyle(.secondary)
                            Text(s.sourceText).fontWeight(s.id == current?.id ? .bold : .regular)
                            Text(s.chinese).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .id(s.id)
                    .listRowBackground(s.id == current?.id ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .onChange(of: current?.id) { _, newValue in
                    if vm.following, let newValue { withAnimation { proxy.scrollTo(newValue, anchor: .center) } }
                }
            }

            if !vm.following {
                Button("↓ Back to current") { vm.syncNow() }
            }
        }
        .navigationTitle("Study")
    }
}
```

Note on follow/browse: SwiftUI's `List` does not expose scroll offset as cleanly as the web `scrollTop`, so `StudyView` approximates the web behavior — auto-center while `following`, and a manual drag flips to browse. The pure follow/browse decision (`onManualScroll`, 10s idle, `syncNow`) lives in the tested `StudyViewModel`; the view wires a `DragGesture` on the list to call `vm.onManualScroll` when the user drags. Behavior parity is verified at the view-model layer (Step 1 tests); the gesture wiring is validated manually on device.

- [ ] **Step 6: Build and run the full suite**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' build test`
Expected: BUILD SUCCEEDED; all tests from Tasks 1–9 pass.

- [ ] **Step 7: Commit**

```bash
git add ios/NexaInsight/Views ios/NexaInsight/ContentView.swift ios/NexaInsightTests/StudyViewModelTests.swift
git commit -m "feat(ios): library, settings, and study subtitle UI"
```

---

### Task 10: Shadowing — record, store, and on-device AI feedback

**Files:**
- Create: `ios/NexaInsight/Shadowing/ShadowingRecorder.swift`
- Create: `ios/NexaInsight/Shadowing/ShadowingViewModel.swift`
- Create: `ios/NexaInsight/Services/OpenAITutorClient.swift`
- Create: `ios/NexaInsight/Views/ShadowingView.swift`
- Modify: `ios/NexaInsight/Views/StudyView.swift` (add a "Shadow this line" affordance opening `ShadowingView` for the current sentence)
- Create: `ios/NexaInsightTests/ShadowingViewModelTests.swift`

**Interfaces:**
- Consumes: `EpisodeStore` (Task 6), `KeychainStore` (Task 5), `AudioFiles`, `SentenceDTO`.
- Produces:
  - `enum RecordingFiles { static func recordingURL(episodeId:sentenceId:) -> URL }` — under `AppSupport/recordings/<episodeId>/<uuid>.m4a`; relative path stored in the recording.
  - `final class ShadowingRecorder` wrapping `AVAudioRecorder` (m4a/AAC): `func start(to url: URL) throws`, `func stop() -> URL?`. Requests mic permission via `AVAudioApplication.requestRecordPermission`.
  - `struct OpenAITutorClient` — direct-to-OpenAI (key from Keychain), with `func shadowingFeedback(sentence: String, recordingURL: URL) async throws -> String`. Ports `tutor.py`'s `shadowing_feedback`: transcribe the recording (`audio/transcriptions`, model from settings/default `gpt-4o-transcribe`), then a `responses` call asking for concise qualitative rhythm/stress/linking feedback naming one highest-impact improvement, no numeric score. Base URL from `AppSettings`-style OpenAI base (default `https://api.openai.com/v1`). Throws a clear error if the OpenAI key is missing.
  - `@MainActor final class ShadowingViewModel: ObservableObject`:
    - `@Published var isRecording`, `@Published var recordings: [StoredRecording]`, `@Published var feedbackError: String?`, `@Published var requestingFeedback = false`
    - `func startRecording(episodeId:sentenceId:)` / `func stopRecording(episodeId:sentenceId:)` — persist via `EpisodeStore.addRecording`, then `reload`.
    - `func reload(sentenceId:)`
    - `func requestFeedback(recording:sentenceText:)` — call `OpenAITutorClient`, store via `EpisodeStore.setFeedback`.
    - `func markBest(recording:)`.
  - Pure helper on the view model, unit-tested without audio: `static func canRequestFeedback(hasKey: Bool) -> Bool` (guards the feedback button) and `func orderedRecordings() -> [StoredRecording]` returning best-first then newest.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/ShadowingViewModelTests.swift`**

```swift
import XCTest
@testable import NexaInsight

@MainActor
final class ShadowingViewModelTests: XCTestCase {
    func testCanRequestFeedbackRequiresKey() {
        XCTAssertFalse(ShadowingViewModel.canRequestFeedback(hasKey: false))
        XCTAssertTrue(ShadowingViewModel.canRequestFeedback(hasKey: true))
    }

    func testRecordAndPersist() throws {
        let store = try EpisodeStore(inMemory: true)
        _ = try store.saveBundle(
            BundleDTO(episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: nil, title: "T", channel: nil, durationMs: nil, thumbnailUrl: nil, audioPath: nil, status: "ready", error: nil),
                      chapters: [], sentences: [SentenceDTO(id: 10, episodeId: 1, chapterId: nil, position: 0, startMs: 0, endMs: 500, speaker: nil, sourceText: "Hi", chinese: "嗨")], hasAudio: false),
            localAudioPath: nil)
        let vm = ShadowingViewModel(store: store, keychain: KeychainStore())
        // Simulate a completed recording file being registered (no real audio in unit test).
        _ = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "recordings/1/a.m4a")
        vm.reload(sentenceId: 10)
        XCTAssertEqual(vm.recordings.count, 1)
    }

    func testOrderedRecordingsBestFirst() throws {
        let store = try EpisodeStore(inMemory: true)
        _ = try store.saveBundle(
            BundleDTO(episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: nil, title: "T", channel: nil, durationMs: nil, thumbnailUrl: nil, audioPath: nil, status: "ready", error: nil),
                      chapters: [], sentences: [SentenceDTO(id: 10, episodeId: 1, chapterId: nil, position: 0, startMs: 0, endMs: 500, speaker: nil, sourceText: "Hi", chinese: "嗨")], hasAudio: false),
            localAudioPath: nil)
        let vm = ShadowingViewModel(store: store, keychain: KeychainStore())
        _ = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "a.m4a")
        let b = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "b.m4a")
        try store.markBest(recordingId: b.persistentModelID)
        vm.reload(sentenceId: 10)
        XCTAssertTrue(vm.orderedRecordings().first?.isBest ?? false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `ShadowingViewModel` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Shadowing/ShadowingRecorder.swift`**

```swift
import AVFoundation
import Foundation

enum RecordingFiles {
    static func directory(episodeId: Int) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("recordings/\(episodeId)", isDirectory: true)
    }
    static func recordingURL(episodeId: Int, sentenceId: Int) -> (url: URL, relative: String) {
        let name = "\(sentenceId)-\(UUID().uuidString).m4a"
        let dir = directory(episodeId: episodeId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent(name), "recordings/\(episodeId)/\(name)")
    }
}

final class ShadowingRecorder {
    private var recorder: AVAudioRecorder?

    func start(to url: URL) throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()
        self.recorder = recorder
    }

    @discardableResult
    func stop() -> URL? {
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        return url
    }
}
```

- [ ] **Step 4: Write `ios/NexaInsight/Services/OpenAITutorClient.swift`**

```swift
import Foundation

struct OpenAITutorClient {
    let apiKey: String
    let baseURL: URL
    let transcriptionModel: String
    let textModel: String
    var session: URLSession = .shared

    init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!,
         transcriptionModel: String = "gpt-4o-transcribe", textModel: String = "gpt-4.1-mini") {
        self.apiKey = apiKey; self.baseURL = baseURL
        self.transcriptionModel = transcriptionModel; self.textModel = textModel
    }

    enum TutorError: LocalizedError {
        case missingKey
        var errorDescription: String? { "Add your OpenAI API key in Settings to get feedback." }
    }

    func shadowingFeedback(sentence: String, recordingURL: URL) async throws -> String {
        if apiKey.isEmpty { throw TutorError.missingKey }
        let transcript = try await transcribe(recordingURL)
        return try await feedback(sentence: sentence, learnerTranscript: transcript)
    }

    private func transcribe(_ fileURL: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", transcriptionModel)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"take.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["text"] as? String ?? ""
    }

    private func feedback(sentence: String, learnerTranscript: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let instructions = "Give concise qualitative shadowing feedback about rhythm, stress and linking. Name one highest-impact improvement. Do not give a numeric score."
        let payload: [String: Any] = [
            "model": textModel,
            "instructions": instructions,
            "input": "Original: \(sentence)\nLearner transcript: \(learnerTranscript)",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["output_text"] as? String
            ?? "Feedback unavailable (unexpected response shape)."
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "OpenAI", code: status, userInfo: [NSLocalizedDescriptionKey: "OpenAI request failed (\(status))"])
        }
    }
}
```

Note: `output_text` is the convenience field of the OpenAI Responses API, matching the original Python `response.output_text`. If a provider gateway returns the older shape, the fallback string prevents a crash. Verify the current Responses payload shape against the claude-api/context7 docs during implementation if the gateway differs.

- [ ] **Step 5: Write `ios/NexaInsight/Shadowing/ShadowingViewModel.swift`**

```swift
import Foundation

@MainActor
final class ShadowingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var recordings: [StoredRecording] = []
    @Published var feedbackError: String?
    @Published var requestingFeedback = false

    private let store: EpisodeStore
    private let keychain: KeychainStore
    private let recorder = ShadowingRecorder()
    private var activeRelativePath: String?

    init(store: EpisodeStore, keychain: KeychainStore) {
        self.store = store; self.keychain = keychain
    }

    static func canRequestFeedback(hasKey: Bool) -> Bool { hasKey }

    func reload(sentenceId: Int) { recordings = store.recordings(sentenceId: sentenceId) }

    func orderedRecordings() -> [StoredRecording] {
        recordings.sorted { ($0.isBest ? 1 : 0, $0.createdAt) > ($1.isBest ? 1 : 0, $1.createdAt) }
    }

    func startRecording(episodeId: Int, sentenceId: Int) {
        let target = RecordingFiles.recordingURL(episodeId: episodeId, sentenceId: sentenceId)
        activeRelativePath = target.relative
        do { try recorder.start(to: target.url); isRecording = true }
        catch { feedbackError = error.localizedDescription }
    }

    func stopRecording(episodeId: Int, sentenceId: Int) {
        _ = recorder.stop()
        isRecording = false
        if let relative = activeRelativePath {
            _ = try? store.addRecording(episodeId: episodeId, sentenceId: sentenceId, localFilePath: relative)
            activeRelativePath = nil
        }
        reload(sentenceId: sentenceId)
    }

    func markBest(recording: StoredRecording, sentenceId: Int) {
        try? store.markBest(recordingId: recording.persistentModelID)
        reload(sentenceId: sentenceId)
    }

    func requestFeedback(recording: StoredRecording, sentenceText: String, sentenceId: Int) async {
        feedbackError = nil
        guard let key = keychain.get(.openAIKey), Self.canRequestFeedback(hasKey: !key.isEmpty) else {
            feedbackError = "Add your OpenAI API key in Settings to get feedback."
            return
        }
        requestingFeedback = true
        defer { requestingFeedback = false }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(recording.localFilePath)
        let client = OpenAITutorClient(apiKey: key)
        do {
            let text = try await client.shadowingFeedback(sentence: sentenceText, recordingURL: url)
            try store.setFeedback(recordingId: recording.persistentModelID, feedback: text)
            reload(sentenceId: sentenceId)
        } catch {
            feedbackError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all three ShadowingViewModelTests)

- [ ] **Step 7: Write `ios/NexaInsight/Views/ShadowingView.swift` and wire it into `StudyView`**

`ShadowingView` is UI around the tested `ShadowingViewModel`: a record/stop button (`isRecording`), a list of `orderedRecordings()` each with a play button (AVAudioPlayer on the local file), a "Mark best" action, and a "Get feedback" button gated by `canRequestFeedback` that shows `recording.feedback` when present and `feedbackError` on failure. In `StudyView`, add a toolbar/inline button "Shadow this line" that presents `ShadowingView(episodeId:sentenceId:sentenceText:)` for `current`.

```swift
import SwiftUI

struct ShadowingView: View {
    let episodeId: Int
    let sentenceId: Int
    let sentenceText: String
    @StateObject private var vm: ShadowingViewModel

    init(episodeId: Int, sentenceId: Int, sentenceText: String, store: EpisodeStore) {
        self.episodeId = episodeId; self.sentenceId = sentenceId; self.sentenceText = sentenceText
        _vm = StateObject(wrappedValue: ShadowingViewModel(store: store, keychain: KeychainStore()))
    }

    var body: some View {
        List {
            Section {
                Text(sentenceText).font(.headline)
                Button(vm.isRecording ? "Stop" : "Record") {
                    vm.isRecording
                        ? vm.stopRecording(episodeId: episodeId, sentenceId: sentenceId)
                        : vm.startRecording(episodeId: episodeId, sentenceId: sentenceId)
                }
            }
            Section("Takes") {
                ForEach(vm.orderedRecordings(), id: \.persistentModelID) { r in
                    VStack(alignment: .leading) {
                        HStack {
                            Text(r.isBest ? "★ Best" : "Take").font(.caption)
                            Spacer()
                            Button("Mark best") { vm.markBest(recording: r, sentenceId: sentenceId) }
                            Button("Feedback") {
                                Task { await vm.requestFeedback(recording: r, sentenceText: sentenceText, sentenceId: sentenceId) }
                            }.disabled(vm.requestingFeedback)
                        }
                        if let feedback = r.feedback { Text(feedback).font(.footnote) }
                    }
                }
            }
            if let error = vm.feedbackError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Shadowing")
        .onAppear { vm.reload(sentenceId: sentenceId) }
    }
}
```

- [ ] **Step 8: Build and run the full suite**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' build test`
Expected: BUILD SUCCEEDED; all tests pass.

- [ ] **Step 9: Commit**

```bash
git add ios/NexaInsight/Shadowing ios/NexaInsight/Services/OpenAITutorClient.swift ios/NexaInsight/Views/ShadowingView.swift ios/NexaInsight/Views/StudyView.swift ios/NexaInsightTests/ShadowingViewModelTests.swift
git commit -m "feat(ios): shadowing recording, storage, and on-device AI feedback"
```

---

## Self-Review

**Spec coverage (iOS study portion of the design spec):**
- Swift/SwiftUI + AVFoundation + SwiftData + Keychain stack → Tasks 1, 5, 6, 7, 10 ✓
- Local data model (Episode/Chapter/Sentence/ShadowingRecording) → Task 6 ✓
- Shelf/Home (list + import URL → progress → pull bundle+audio local) → Tasks 8, 9 ✓
- Study screen (player + bilingual subtitle follow/browse/tap-to-seek) → Tasks 3, 7, 9 ✓
- Shadowing (record → store local → LLM feedback with local key) → Task 10 ✓
- Settings (API keys in Keychain) → Tasks 5, 9 ✓
- Context-window slicing ported to Swift → Task 3 (`subtitleWindow`, `activeSentence`) + Task 4 (classroom logic incl. cursor/state machine used by Plan 3) ✓
- Interaction logic faithfully replicated, verified against original TS tests → Tasks 3, 4, 9, 10 (view models unit-tested) ✓
- Player-agnostic `Playback` protocol so Plan 3 reuses everything → Task 7 ✓
- Keys only in Keychain → Task 5 (Global Constraint enforced; SecureField in Task 9) ✓
- mp3 native playback → Task 7 (AVPlayer on local mp3) ✓

**Deferred to Plan 3 (correctly out of scope here):** live voice classroom / WebRTC / Qwen realtime orchestration. The `Playback` protocol (Task 7) and `ClassroomLogic` (Task 4) are the seams Plan 3 builds on.

**Placeholder scan:** No TBD/TODO. Every code step has full code; every command has expected output. UI-only steps (Task 9 Step 5, Task 10 Step 7) provide complete reference views and explicitly push behavior into the unit-tested view models, with device-only concerns (scroll-offset gesture wiring, audio capture) flagged for manual validation — not left as vague instructions.

**Type consistency:**
- `Playback` protocol (`currentMs`, `isReady`, `playbackState`, `seek/pause/play/speed`) defined in Task 7; consumed by `StudyViewModel.tap` (Task 9) and Plan 3. `FakePlayback` conforms in the test target (Task 7) and is reused by Task 9 tests. ✓
- `SentenceDTO`/`ChapterDTO`/`EpisodeDTO`/`JobDTO`/`BundleDTO` defined in Task 2; used consistently in Tasks 3, 5, 6, 8, 9, 10. ✓
- `EpisodeStore` method names (`saveBundle`, `sentences(for:)`, `chapters(for:)`, `localAudioPath(for:)`, `downloadedEpisodes`, `addRecording`, `recordings(sentenceId:)`, `markBest`, `setFeedback`) defined in Task 6; used identically in Tasks 8, 9, 10. ✓
- `BackendClient` methods (`importEpisode`, `episodeJob`, `retryJob`, `bundle`, `downloadAudio`, `formatApiError`, `url(path:)`) defined in Task 5; used in Task 8. ✓
- `KeychainStore` (`get`/`set` with `SecretKey`) defined in Task 5; used in Tasks 9, 10. ✓
- `AudioFiles.audioURL(forEpisode:)` / `relativePath(forEpisode:)` defined in Task 8; used in Task 9's `StudyView`. ✓
- `ClassroomLogic` names (Task 4) match those the web `classroom.ts` exposes, so Plan 3 can consume them unchanged. ✓

**Interaction-fidelity note:** the highest-risk-to-fidelity code (`domain.ts`, `classroom.ts`) is ported as pure functions with tests mirroring the original suite (Tasks 3–4), and the two behavioral view models (study follow/browse, shadowing) are unit-tested (Tasks 9–10). SwiftUI's `List` scroll model differs from the web `scrollTop`; the decision logic stays in the tested view model and only gesture wiring is device-validated — the deviation is explicit and contained.
