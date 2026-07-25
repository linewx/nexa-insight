# iOS Voice Classroom Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the live 1:1 voice classroom to the iOS app — a WebRTC session direct to Qwen Omni-Realtime (using the on-device DashScope key, no backend), driven by the exact interaction orchestration ported from `nexa_insight`'s `useClassroomTeacher.ts` + `QwenClassroom.ts`.

**Architecture:** The Omni-direct single-model path only (the live web app's `OMNI_DIRECT = true`): Qwen Omni hears the learner, reasons, replies by voice, and calls playback tools itself. The legacy qwen-max HTTP teacher-brain is NOT ported. An iOS WebRTC peer connection exchanges SDP directly with DashScope; a data channel carries realtime events and tool calls; the playback tools drive the `LocalAudioPlayback` from Plan 2 through the shared `Playback` protocol. The classroom orchestration is split into a pure, unit-tested `ClassroomController` (all the decision logic from `useClassroomTeacher`) plus thin transport/AV shells.

**Tech Stack:** Swift, WebRTC (the `stasel/WebRTC` or `webrtc-sdk/Specs` Swift package binary), AVFoundation, plus everything from Plan 2 (`ClassroomLogic`, `Playback`, `EpisodeStore`, `KeychainStore`).

This is Plan 3 of 3. It requires Plan 2's `ClassroomLogic` (state machine, `matchDirectCommand`, `playbackTargetPosition`, `playbackNotice`, `isActionableTranscript`), the `Playback` protocol + `LocalAudioPlayback`, `EpisodeStore` (local sentences/chapters), and `KeychainStore` (DashScope key + workspace id).

## Global Constraints

- Omni-direct path ONLY. Do not port the qwen-max HTTP `classTeacherTurn` brain or the `OMNI_DIRECT = false` branch.
- The DashScope API key and workspace id come from the Keychain (`SecretKey.dashscopeKey`, `.dashscopeWorkspaceId`); they are sent directly to DashScope, never to the user's own backend (there is no backend in the classroom path).
- Interaction behavior MUST replicate `useClassroomTeacher.ts` + `QwenClassroom.ts` exactly. All decision logic lives in the pure `ClassroomController` and is unit-tested; only WebRTC/AV transport is device-validated.
- The classroom context (episode map + current chapter + transcript window) is computed ON-DEVICE from the local `EpisodeStore`, porting `repositories.py::classroom_context` — NOT fetched from any backend.
- Voice-first invariants (from Plan 2's spec guiding principle) are preserved: speaking freezes the cursor; only an explicit resume releases playback; a playback command carries no spoken monologue; exactly one authoritative fresh context window; position-moving tools refresh context.
- Playback positions are integer milliseconds.
- Realtime session config mirrors `QwenClassroom.connect`: modalities text+audio, voice `Ethan`, pcm in/out, input transcription model `qwen3-asr-flash-realtime`, semantic VAD (threshold 0.5, silence 800ms, `create_response: true`), and the Omni-direct playback tools advertised.
- FIDELITY SUBTLETY (verified against the original during implementation): `sendText`/`handleLearnerTranscript` gates on `isActionableTranscript` BEFORE `matchDirectCommand`, and `isActionableTranscript` deliberately REJECTS short spoken fillers including "继续", "暂停", "停一下", "好的", "嗯". So typing "继续" as text is intentionally a no-op — playback control for those short phrases comes from the realtime model hearing the audio and calling the tool, not the text fast-path. Do NOT "fix" this by reordering the gate or whitelisting "继续" in the text path. Test the no-monologue direct path with "resume" (whitelisted) instead.

---

### Task 1: On-device classroom context (port of `classroom_context`)

**Files:**
- Create: `ios/NexaInsight/Classroom/ClassroomContext.swift`
- Create: `ios/NexaInsightTests/ClassroomContextTests.swift`

**Interfaces:**
- Consumes: `SentenceDTO`, `ChapterDTO` (Plan 2 Task 2), `subtitleWindow` (Plan 2 Task 3).
- Produces free functions porting `repositories.py::classroom_context` + `sentence_window` + `context_text` behavior to the local data:
  - `func contextText(_ window: [SentenceDTO]) -> String` — one line per sentence `"[<s>s] <speaker>: <source_text> / <chinese>"`, seconds one decimal (mirrors `context_text`).
  - `func classroomContext(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO], atMs: Int, radius: Int = 6) -> String` — builds the "Episode / Episode map / Current chapter / Current transcript window" block exactly like the Python. Current chapter = the one whose `[startMs, endMs)` contains `atMs`, else the last one starting at/before `atMs`, else the first (mirrors the Python fallback).
- The sentence window uses `subtitleWindow(sentences, atMs, radius:)` from Plan 2 (same last-started anchoring the backend's `sentence_window` used via `position.between`).

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/ClassroomContextTests.swift`**

```swift
import XCTest
@testable import NexaInsight

private func s(_ id: Int, _ start: Int, _ end: Int, _ en: String, _ zh: String) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: end, speaker: "Host", sourceText: en, chinese: zh)
}

final class ClassroomContextTests: XCTestCase {
    func testContextTextFormat() {
        let line = contextText([s(0, 1500, 3000, "Hello", "你好")])
        XCTAssertEqual(line, "[1.5s] Host: Hello / 你好")
    }

    func testClassroomContextIncludesMapChapterWindow() {
        let chapters = [
            ChapterDTO(id: 1, title: "Intro", summary: "opening", startMs: 0, endMs: 2000),
            ChapterDTO(id: 2, title: "Core", summary: "the meat", startMs: 2000, endMs: 6000),
        ]
        let sentences = [s(0, 0, 1000, "A", "甲"), s(1, 2500, 3500, "B", "乙"), s(2, 4000, 5000, "C", "丙")]
        let text = classroomContext(episodeTitle: "T", channel: "C", chapters: chapters, sentences: sentences, atMs: 2600, radius: 1)
        XCTAssertTrue(text.contains("Episode: T · C"))
        XCTAssertTrue(text.contains("Episode map:"))
        XCTAssertTrue(text.contains("Intro"))
        XCTAssertTrue(text.contains("Current chapter:\nCore: the meat"))
        XCTAssertTrue(text.contains("Current transcript window:"))
        XCTAssertTrue(text.contains("B / 乙"))
    }

    func testChapterFallbackWhenBetweenChapters() {
        let chapters = [ChapterDTO(id: 1, title: "Only", summary: "s", startMs: 0, endMs: 1000)]
        let text = classroomContext(episodeTitle: nil, channel: nil, chapters: chapters, sentences: [s(0, 0, 500, "A", "甲")], atMs: 5000, radius: 1)
        XCTAssertTrue(text.contains("Only"))          // falls back to last chapter starting before atMs
        XCTAssertTrue(text.contains("Untitled"))       // nil title
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `classroomContext` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Classroom/ClassroomContext.swift`**

```swift
import Foundation

func contextText(_ window: [SentenceDTO]) -> String {
    window.map { item in
        let seconds = String(format: "%.1f", Double(item.startMs) / 1000.0)
        return "[\(seconds)s] \(item.speaker ?? "Speaker"): \(item.sourceText) / \(item.chinese)"
    }.joined(separator: "\n")
}

func classroomContext(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO], atMs: Int, radius: Int = 6) -> String {
    let sortedChapters = chapters.sorted { $0.startMs < $1.startMs }
    var current = sortedChapters.first { $0.startMs <= atMs && atMs < $0.endMs }
    if current == nil { current = sortedChapters.last { $0.startMs <= atMs } ?? sortedChapters.first }
    let window = subtitleWindow(sentences, atMs, radius: radius)
    let transcript = contextText(window)
    let outline = sortedChapters.map { item in
        let minutes = String(format: "%.1f", Double(item.startMs) / 60000.0)
        return "- [\(minutes)m] \(item.title): \(item.summary)"
    }.joined(separator: "\n")
    let outlineText = outline.isEmpty ? "- No chapter outline is available yet." : outline
    let currentTopic = current.map { "\($0.title): \($0.summary)" }
        ?? "No chapter is available; rely on the transcript window."
    let transcriptText = transcript.isEmpty ? "No nearby transcript is available." : transcript
    return """
    Episode: \(episodeTitle ?? "Untitled") · \(channel ?? "Unknown channel")

    Episode map:
    \(outlineText)

    Current chapter:
    \(currentTopic)

    Current transcript window:
    \(transcriptText)
    """
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Classroom/ClassroomContext.swift ios/NexaInsightTests/ClassroomContextTests.swift
git commit -m "feat(ios): on-device classroom context (port of classroom_context)"
```

---

### Task 2: Instruction composition and realtime config (port of `classroomConfig.ts`)

**Files:**
- Create: `ios/NexaInsight/Classroom/ClassroomInstructions.swift`
- Create: `ios/NexaInsightTests/ClassroomInstructionsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (ported from `classroomConfig.ts` + the `TEACHER_STYLE`/class instructions the backend baked into the session):
  - `let teacherStyle: String` — the Socratic-teacher base prompt (copied from `tutor.py::TEACHER_STYLE`).
  - `let omniDirectInstructions: String` — the appended Omni-direct block (copied from `classroomConfig.ts::OMNI_DIRECT_INSTRUCTIONS`).
  - `func baseClassroomInstructions(material: String) -> String` — the full "you own playback / disambiguation rules / classroom material" instruction the backend `create_class_session` built, with the initial material appended (this is the `instructionsRef` seed).
  - `func stableInstructions(_ full: String) -> String` — strips the baked-in context block at the marker (port of `stableInstructions`, same regex markers).
  - `func composeInstructions(_ full: String, freshContext: String) -> String` — stable prefix + exactly one authoritative CURRENT context block (port of `composeInstructions`).
  - `let realtimePlaybackTools: [[String: Any]]` — the tool list advertised in `session.update` (port of `REALTIME_PLAYBACK_TOOLS`: resume/pause/previous/next/seek_to_timestamp with the same params).

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/ClassroomInstructionsTests.swift`**

```swift
import XCTest
@testable import NexaInsight

final class ClassroomInstructionsTests: XCTestCase {
    func testStableInstructionsStripsBakedContext() {
        let full = "STYLE AND RULES\n\nClassroom material:\nEpisode: X\nmap..."
        XCTAssertEqual(stableInstructions(full), "STYLE AND RULES")
    }

    func testComposeAttachesSingleAuthoritativeWindow() {
        let full = "PREFIX\n\nCurrent podcast context:\nOLD WINDOW"
        let composed = composeInstructions(full, freshContext: "NEW WINDOW")
        XCTAssertTrue(composed.hasPrefix("PREFIX"))
        XCTAssertTrue(composed.contains("NEW WINDOW"))
        XCTAssertFalse(composed.contains("OLD WINDOW"))
        XCTAssertTrue(composed.contains("ONLY current context"))
    }

    func testRealtimeToolsAdvertiseOmniDirectSet() {
        let names = realtimePlaybackTools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["resume_playback", "pause_playback", "previous_sentence", "next_sentence", "seek_to_timestamp"])
    }

    func testBaseInstructionsAppendMaterial() {
        let text = baseClassroomInstructions(material: "MATERIAL_XYZ")
        XCTAssertTrue(text.contains("MATERIAL_XYZ"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — symbols undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Classroom/ClassroomInstructions.swift`**

Copy the prompt text verbatim from the originals. The disambiguation rules block is the exact text the backend passed in `create_class_session` (see `app.py` and `tutor.py::classroom_reply` system message) — copy it word-for-word so behavior matches.

```swift
import Foundation

let teacherStyle = """
You are a Socratic source language teacher discussing a world-class podcast. \
Always reply in source language unless the learner explicitly asks for Chinese. Engage with the \
learner's idea before language feedback. Ask a thoughtful follow-up. After each learner \
turn, provide no more than three corrections, choosing only issues that affect clarity \
or naturalness. Never invent facts beyond the supplied transcript context.
"""

let omniDirectInstructions = [
    "You hear the learner's real voice, so you may comment on pronunciation, intonation, and fluency when they ask (e.g. '我发音怎么样', 'how's my accent') — give concrete, specific notes, not just praise.",
    "You control the podcast player with the provided tools. Call resume_playback / pause_playback / previous_sentence / next_sentence / seek_to_timestamp when the learner asks, in any language. Do NOT narrate the action; just call the tool.",
    "The learner controls the pace: do not resume playback on your own unless the learner asks. When they interrupt or speak, stop talking and listen.",
].joined(separator: " ")

// The playback-ownership + disambiguation rules the backend baked into the class
// session instructions. Copied verbatim from app.py create_class_session so the
// on-device Omni model behaves identically.
private let playbackDisambiguationRules = """
The student controls the podcast. Accept playback commands in source language or Chinese. Use the registered tools instead of merely describing actions. For absolute requests such as 'go to 10 minutes', '10:30', '第10分钟', or '跳到十分钟', call seek_to_timestamp with total seconds from the episode start; use seek_relative only for relative requests such as 'forward 30 seconds'. Give at most two high-impact micro-corrections after each learner turn. When finish_discussion is requested, briefly review the learner's argument, language accuracy, and reusable advanced expressions before resuming. The supplied classroom material has an episode map, current chapter, and transcript window. Use all three when relevant. You may add general background knowledge, but explicitly distinguish it from what the speakers said. If the learner's transcription is ambiguous or incomplete, ask one brief clarification instead of guessing.
"""

func baseClassroomInstructions(material: String) -> String {
    "\(teacherStyle)\n\(playbackDisambiguationRules)\n\nClassroom material:\n\(material)"
}

// Port of classroomConfig.ts BAKED_CONTEXT_MARKER + stableInstructions.
private let bakedContextMarker = try! NSRegularExpression(
    pattern: "\\n+(?:Classroom material|Current podcast context|Updated playback context|CURRENT podcast position)[^\\n:]*:")

func stableInstructions(_ full: String) -> String {
    let range = NSRange(full.startIndex..., in: full)
    guard let match = bakedContextMarker.firstMatch(in: full, range: range),
          let r = Range(match.range, in: full) else {
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(full[full.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

func composeInstructions(_ full: String, freshContext: String) -> String {
    "\(stableInstructions(full))\n\nCURRENT podcast position (this is the ONLY current context; ignore any earlier transcript window):\n\(freshContext)"
}

let realtimePlaybackTools: [[String: Any]] = [
    ["type": "function", "name": "resume_playback", "description": "Resume/continue playing the podcast.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "pause_playback", "description": "Pause the podcast.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "previous_sentence", "description": "Go to the previous transcript sentence.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "next_sentence", "description": "Go to the next transcript sentence.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "seek_to_timestamp", "description": "Jump to an absolute position in the episode.",
     "parameters": ["type": "object", "properties": ["seconds": ["type": "number", "description": "Seconds from the episode start."]], "required": ["seconds"]]],
]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all four ClassroomInstructionsTests)

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Classroom/ClassroomInstructions.swift ios/NexaInsightTests/ClassroomInstructionsTests.swift
git commit -m "feat(ios): classroom instructions + realtime config (port of classroomConfig.ts)"
```

---

### Task 3: ClassroomController — pure orchestration (port of `useClassroomTeacher`)

**Files:**
- Create: `ios/NexaInsight/Classroom/ClassroomController.swift`
- Create: `ios/NexaInsightTests/ClassroomControllerTests.swift`

**Interfaces:**
- Consumes: `Playback` protocol (Plan 2 Task 7), `ClassroomLogic` (Plan 2 Task 4: `classroomReducer`, `matchDirectCommand`, `playbackTargetPosition`, `playbackNotice`, `isActionableTranscript`, `ClassroomState`, `PlaybackTool`), `activeSentence` (Plan 2 Task 3), `SentenceDTO`.
- Produces `@MainActor final class ClassroomController: ObservableObject` — all the DECISION logic of `useClassroomTeacher.ts`, with side effects behind injected closures so it is fully unit-testable without WebRTC/AV:
  - Init: `init(sentences: [SentenceDTO], playback: Playback, transport: ClassroomTransport, onNotice: @escaping (String) -> Void, onContextRefresh: @escaping (Int) -> Void)`. `ClassroomTransport` is a protocol (Task 4) with `stopSpeaking()`, `sendToolResult(callId:output:)`, `updateContext(_:)`, `speak(_:)`, `requestResponse()`; a `FakeTransport` in the test target records calls.
  - Published state: `@Published var state: ClassroomState`, `@Published var transcript: [TutorTurn]`, `@Published var frozenPositionMs: Int?`.
  - `func cursor() -> Int` — `classroomCursorPosition(playback.currentMs, frozenPositionMs, 0)`.
  - `func freeze(_ positionMs: Int, reason: FreezeReason)` — set frozen, `playback.pause()`, reduce with `.speechStarted`/`.paused` (ports `freeze`).
  - `func resume()` — clear frozen, `transport.stopSpeaking()`, `playback.play()`, reduce `.resumed`, notice "Podcast playing" (ports `resume`).
  - `func runPlaybackTool(_ name: PlaybackTool, _ args: [String: Double])` — the exact `runPlaybackTool` logic: stop speaking; compute target via `playbackTargetPosition` over `activeSentence`-derived index and `sentenceStarts`; resume/finish → resume; pause → pause+freeze; set speed → speed; position-movers → seek then resume; emit `playbackNotice`; for movers call `onContextRefresh(target)` (ports the "refresh model context to new spot" rule).
  - `func handleRealtimeEvent(_ event: RealtimeEvent)` — the Omni-direct branch of `handleEvent`: on `.speechStarted` freeze at cursor + `onContextRefresh`; on `.inputTranscriptionCompleted(text)` append a user turn; on `.responseAudioTranscriptDone(text)` append an assistant turn + reduce `.teacherStarted`; on `.responseDone` reduce `.teacherFinished`; on `.toolCall(name,args,callId)` run the tool and `transport.sendToolResult(callId, {ok:true})`.
  - `func sendText(_ message: String)` — the text path: if `isActionableTranscript` is false, ignore; if `matchDirectCommand` matches, append user turn + run tool; otherwise this is discussion — in the Omni-direct model the spoken model drives the reply, so text discussion is injected as a conversation item and `transport.requestResponse()` is called (ports `sendText` → `handleLearnerTranscript` for the direct path).
  - `enum FreezeReason { case paused, speechStarted }`, `enum RealtimeEvent { case speechStarted, inputTranscriptionCompleted(String), responseAudioTranscriptDone(String), responseDone, toolCall(name: PlaybackTool, args: [String: Double], callId: String?) }`.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/ClassroomControllerTests.swift`**

```swift
import XCTest
@testable import NexaInsight

final class FakeTransport: ClassroomTransport {
    private(set) var stoppedSpeaking = 0
    private(set) var toolResults: [(String?, Bool)] = []
    private(set) var contextUpdates: [String] = []
    private(set) var spoken: [String] = []
    private(set) var responseRequests = 0
    func stopSpeaking() { stoppedSpeaking += 1 }
    func sendToolResult(callId: String?, ok: Bool) { toolResults.append((callId, ok)) }
    func updateContext(_ context: String) { contextUpdates.append(context) }
    func speak(_ text: String) { spoken.append(text) }
    func requestResponse() { responseRequests += 1 }
}

private func s(_ id: Int, _ start: Int) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: start + 900, speaker: nil, sourceText: "e\(id)", chinese: "c\(id)")
}

@MainActor
final class ClassroomControllerTests: XCTestCase {
    func make() -> (ClassroomController, FakePlayback, FakeTransport, Box) {
        let playback = FakePlayback()
        let transport = FakeTransport()
        let box = Box()
        let controller = ClassroomController(
            sentences: [s(0, 0), s(1, 1000), s(2, 2000), s(3, 3000)],
            playback: playback, transport: transport,
            onNotice: { box.notices.append($0) },
            onContextRefresh: { box.refreshes.append($0) })
        return (controller, playback, transport, box)
    }
    final class Box { var notices: [String] = []; var refreshes: [Int] = [] }

    func testSpeechStartedFreezesAndRefreshes() {
        let (c, playback, _, box) = make()
        playback.currentMs = 2100
        c.handleRealtimeEvent(.speechStarted)
        XCTAssertEqual(c.frozenPositionMs, 2100)
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(box.refreshes, [2100])
    }

    func testResumeToolPlaysAndClearsFrozen() {
        let (c, playback, transport, box) = make()
        c.freeze(2000, reason: .paused)
        c.runPlaybackTool(.resume_playback, [:])
        XCTAssertNil(c.frozenPositionMs)
        XCTAssertTrue(playback.didPlay)
        XCTAssertGreaterThan(transport.stoppedSpeaking, 0)
        XCTAssertEqual(box.notices.last, "Podcast playing")
    }

    func testSeekToolSeeksResumesAndRefreshesContext() {
        let (c, playback, _, box) = make()
        c.runPlaybackTool(.seek_to_timestamp, ["seconds": 3])
        XCTAssertEqual(playback.seeks.last, 3000)
        XCTAssertTrue(playback.didPlay)               // position-movers resume after seeking
        XCTAssertEqual(box.refreshes.last, 3000)      // context refreshed to new spot
    }

    func testNextSentenceUsesActiveIndex() {
        let (c, playback, _, _) = make()
        playback.currentMs = 1050                     // active sentence index 1
        c.runPlaybackTool(.next_sentence, [:])
        XCTAssertEqual(playback.seeks.last, 2000)     // start of sentence index 2
    }

    func testToolCallEventRunsToolAndAcks() {
        let (c, playback, transport, _) = make()
        c.handleRealtimeEvent(.toolCall(name: .pause_playback, args: [:], callId: "abc"))
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(transport.toolResults.last?.0, "abc")
        XCTAssertEqual(transport.toolResults.last?.1, true)
    }

    func testTextDirectCommandRunsToolNoDiscussion() {
        let (c, playback, transport, _) = make()
        c.sendText("继续")
        XCTAssertTrue(playback.didPlay)               // resume ran
        XCTAssertEqual(transport.spoken.count, 0)     // no monologue on a playback command
    }

    func testTextDiscussionInjectsAndRequestsResponse() {
        let (c, _, transport, _) = make()
        c.sendText("what do you think about the host's argument here")
        XCTAssertEqual(transport.responseRequests, 1) // discussion drives a model response
    }

    func testEmptyOrFillerTextIgnored() {
        let (c, _, transport, _) = make()
        c.sendText("嗯")
        XCTAssertEqual(transport.responseRequests, 0)
        XCTAssertEqual(c.transcript.count, 0)
    }

    func testInputTranscriptAndAssistantTranscriptAppendTurns() {
        let (c, _, _, _) = make()
        c.handleRealtimeEvent(.inputTranscriptionCompleted("hello teacher"))
        c.handleRealtimeEvent(.responseAudioTranscriptDone("hello learner"))
        XCTAssertEqual(c.transcript.map(\.role), [.user, .assistant])
    }
}
```

Note: `FakePlayback` is the test double defined in Plan 2 Task 7's `PlaybackTests.swift`. Ensure it remains in the test target so this suite reuses it (it already conforms to `Playback`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `ClassroomController` / `ClassroomTransport` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Classroom/ClassroomController.swift`**

```swift
import Foundation

protocol ClassroomTransport: AnyObject {
    func stopSpeaking()
    func sendToolResult(callId: String?, ok: Bool)
    func updateContext(_ context: String)
    func speak(_ text: String)
    func requestResponse()
}

enum FreezeReason { case paused, speechStarted }

enum RealtimeEvent {
    case speechStarted
    case inputTranscriptionCompleted(String)
    case responseAudioTranscriptDone(String)
    case responseDone
    case toolCall(name: PlaybackTool, args: [String: Double], callId: String?)
}

@MainActor
final class ClassroomController: ObservableObject {
    @Published var state = ClassroomState(phase: .idle, pausedAtMs: nil)
    @Published var transcript: [TutorTurn] = []
    @Published var frozenPositionMs: Int?

    private let sentences: [SentenceDTO]
    private let playback: Playback
    private let transport: ClassroomTransport
    private let onNotice: (String) -> Void
    private let onContextRefresh: (Int) -> Void

    // Position-moving tools jump the podcast, so the model's context must refresh
    // to the new spot (ports the PLAYS_AUDIO / moved sets from useClassroomTeacher).
    private static let movers: Set<PlaybackTool> = [.seek_to_timestamp, .seek_relative, .previous_sentence, .next_sentence, .repeat_current_sentence]

    init(sentences: [SentenceDTO], playback: Playback, transport: ClassroomTransport,
         onNotice: @escaping (String) -> Void, onContextRefresh: @escaping (Int) -> Void) {
        self.sentences = sentences; self.playback = playback; self.transport = transport
        self.onNotice = onNotice; self.onContextRefresh = onContextRefresh
        self.state = ClassroomState(phase: .connected, pausedAtMs: nil)
    }

    func cursor() -> Int { classroomCursorPosition(playback.currentMs, frozenPositionMs, 0) }

    func freeze(_ positionMs: Int, reason: FreezeReason) {
        let frozen = max(0, positionMs)
        frozenPositionMs = frozen
        playback.pause()
        state = classroomReducer(state, reason == .speechStarted ? .speechStarted(atMs: frozen) : .paused(atMs: frozen))
    }

    func resume() {
        frozenPositionMs = nil
        transport.stopSpeaking()
        playback.play()
        state = classroomReducer(state, .resumed)
        onNotice("Podcast playing")
    }

    func runPlaybackTool(_ name: PlaybackTool, _ args: [String: Double]) {
        transport.stopSpeaking()
        let positionMs = cursor()
        let at = activeSentence(sentences, positionMs) ?? sentences.first
        let index = max(0, sentences.firstIndex(where: { $0.id == at?.id }) ?? 0)
        let starts = sentences.map(\.startMs)
        let target = playbackTargetPosition(name, args, positionMs, index, starts)
        switch name {
        case .resume_playback, .finish_discussion:
            resume()
        case .pause_playback:
            playback.pause()
            freeze(target, reason: .paused)
        case .set_playback_speed:
            playback.speed(args["rate"] ?? 1)
        case .exit_class:
            break
        default:
            playback.seek(target)
            resume()
        }
        onNotice(playbackNotice(name, target))
        if Self.movers.contains(name) { onContextRefresh(target) }
    }

    func handleRealtimeEvent(_ event: RealtimeEvent) {
        switch event {
        case .speechStarted:
            freeze(cursor(), reason: .speechStarted)
            onContextRefresh(frozenPositionMs ?? cursor())
        case let .inputTranscriptionCompleted(text) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
            transcript.append(TutorTurn(role: .user, text: text))
        case .inputTranscriptionCompleted:
            break
        case let .responseAudioTranscriptDone(text):
            transcript.append(TutorTurn(role: .assistant, text: text))
            state = classroomReducer(state, .teacherStarted)
        case .responseDone:
            state = classroomReducer(state, .teacherFinished)
        case let .toolCall(name, args, callId):
            runPlaybackTool(name, args)
            transport.sendToolResult(callId: callId, ok: true)
        }
    }

    func sendText(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActionableTranscript(trimmed) else { return }
        if let direct = matchDirectCommand(trimmed) {
            transcript.append(TutorTurn(role: .user, text: trimmed))
            runPlaybackTool(direct.name, direct.args)
            return
        }
        // Discussion on the Omni-direct path: freeze if needed, inject the learner
        // turn, and let the spoken model respond.
        if frozenPositionMs == nil { freeze(cursor(), reason: .paused) }
        state = classroomReducer(state, .discussionStarted)
        transcript.append(TutorTurn(role: .user, text: trimmed))
        transport.speak("")            // placeholder no-op kept for parity; real injection is the conversation item in the transport
        transport.requestResponse()
    }
}
```

Note on `sendText` discussion path: the web `sendText` for the Omni-direct model routes the typed text into the same realtime conversation as spoken input. The transport (Task 4) exposes the actual "inject user text item" via `speak`/conversation-item creation; here the controller's contract is "append the turn and request a model response". The `transport.speak("")` line is a parity placeholder — replace with the transport's `injectUserText(trimmed)` method when wiring Task 4, and update this call. Keep `requestResponse()` as the observable behavior the test asserts.

Correction for the test to pass deterministically: the controller must NOT call `transport.speak("")` (the test asserts `spoken.count == 0` only on the direct-command path, but the discussion test asserts `responseRequests == 1`). Implement the discussion branch as:

```swift
        if frozenPositionMs == nil { freeze(cursor(), reason: .paused) }
        state = classroomReducer(state, .discussionStarted)
        transcript.append(TutorTurn(role: .user, text: trimmed))
        transport.injectUserText(trimmed)
        transport.requestResponse()
```

and add `func injectUserText(_ text: String)` to the `ClassroomTransport` protocol (with `FakeTransport` recording it, not counting as `spoken`). This keeps `spoken` reserved for teacher TTS and makes both text assertions hold.

- [ ] **Step 4: Update the protocol and FakeTransport for `injectUserText`**

Add to `ClassroomTransport`: `func injectUserText(_ text: String)`. In `FakeTransport`, record it in a new `injectedTexts: [String]` array (do NOT add to `spoken`). Remove the `transport.speak("")` placeholder from `sendText`.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all ClassroomControllerTests)

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Classroom/ClassroomController.swift ios/NexaInsightTests/ClassroomControllerTests.swift
git commit -m "feat(ios): pure ClassroomController orchestration (port of useClassroomTeacher)"
```

---

### Task 4: QwenRealtimeTransport — WebRTC + data-channel to DashScope

**Files:**
- Modify: `ios/project.yml` (add the WebRTC Swift package dependency)
- Create: `ios/NexaInsight/Classroom/RealtimeEventParser.swift`
- Create: `ios/NexaInsight/Classroom/QwenRealtimeTransport.swift`
- Create: `ios/NexaInsightTests/RealtimeEventParserTests.swift`

**Interfaces:**
- Consumes: `ClassroomTransport` (Task 3), `RealtimeEvent` (Task 3), `PlaybackTool` (Plan 2 Task 4), Keychain (Plan 2 Task 5).
- Produces:
  - `enum RealtimeEventParser { static func parse(_ json: [String: Any]) -> RealtimeEvent? }` — the PURE translation of a Qwen data-channel event JSON into a `RealtimeEvent` (ports the `handle`/`handleEvent` type dispatch + `response.done` → `function_call` extraction + `safeJson` arg tolerance). This is the unit-tested core; the live socket just feeds it.
  - `@MainActor final class QwenRealtimeTransport: NSObject, ClassroomTransport` — owns an `RTCPeerConnection`, the mic track, the `oai-events` data channel, and the remote audio track. Methods:
    - `func connect(instructions: String, apiKey: String, workspaceId: String, region: String, model: String, onEvent: @escaping (RealtimeEvent) -> Void) async throws` — creates the offer, POSTs SDP directly to `https://{workspaceId}.{region}.maas.aliyuncs.com/api/v1/webrtc/realtime?model={model}` with `Authorization: Bearer {apiKey}` and `Content-Type: application/sdp` (this is the endpoint the backend `QwenRealtimeProvider.endpoint` used — now called from the device), sets the remote answer, and on channel open sends the `session.update` from Task 2's config.
    - `stopSpeaking()` → send `response.cancel` + `output_audio_buffer.clear` (ports `stopSpeaking`).
    - `sendToolResult(callId:ok:)` → send `conversation.item.create` with `function_call_output` (ports `sendToolResult`).
    - `updateContext(_:)` → send `session.update` with `composeInstructions` + inject the `[SYSTEM] ... ONLY current context` user item (ports `updateContext`).
    - `injectUserText(_:)` → send a `conversation.item.create` user message with the text.
    - `speak(_:)` → send the "Read this teacher answer aloud" user item + `response.create` (ports `speak`; used only if a text teacher reply must be voiced — on the pure Omni-direct path the model speaks on its own, so this is retained for parity but rarely used).
    - `requestResponse()` → send `response.create`.
  - The transport parses each inbound data-channel message via `RealtimeEventParser.parse` and forwards non-nil events to `onEvent`.

- [ ] **Step 1: Add the WebRTC dependency to `ios/project.yml`**

Under the `NexaInsight` target, add a Swift package dependency on the prebuilt WebRTC binary. Append to `project.yml`:

```yaml
packages:
  WebRTC:
    url: https://github.com/stasel/WebRTC.git
    from: "120.0.0"
targets:
  NexaInsight:
    dependencies:
      - package: WebRTC
```

(Merge these into the existing `targets.NexaInsight` block rather than duplicating it; `xcodegen` merges package dependencies. If `stasel/WebRTC` is unavailable, use `webrtc-sdk/Specs` — the `RTCPeerConnection` API used here is identical.)

- [ ] **Step 2: Write the failing test `ios/NexaInsightTests/RealtimeEventParserTests.swift`**

```swift
import XCTest
@testable import NexaInsight

final class RealtimeEventParserTests: XCTestCase {
    func testSpeechStarted() {
        let e = RealtimeEventParser.parse(["type": "input_audio_buffer.speech_started"])
        guard case .speechStarted = e else { return XCTFail("expected speechStarted") }
    }

    func testInputTranscriptionCompleted() {
        let e = RealtimeEventParser.parse([
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "hello teacher"])
        guard case let .inputTranscriptionCompleted(text) = e else { return XCTFail() }
        XCTAssertEqual(text, "hello teacher")
    }

    func testResponseAudioTranscriptDone() {
        let e = RealtimeEventParser.parse(["type": "response.audio_transcript.done", "transcript": "hi"])
        guard case let .responseAudioTranscriptDone(text) = e else { return XCTFail() }
        XCTAssertEqual(text, "hi")
    }

    func testResponseDoneWithFunctionCallEmitsToolCall() {
        let e = RealtimeEventParser.parse([
            "type": "response.done",
            "response": ["output": [[
                "type": "function_call", "name": "seek_to_timestamp",
                "arguments": "{\"seconds\": 12}", "call_id": "c1"]]]])
        guard case let .toolCall(name, args, callId) = e else { return XCTFail() }
        XCTAssertEqual(name, .seek_to_timestamp)
        XCTAssertEqual(args["seconds"], 12)
        XCTAssertEqual(callId, "c1")
    }

    func testResponseDoneWithoutToolCallIsResponseDone() {
        let e = RealtimeEventParser.parse(["type": "response.done", "response": ["output": []]])
        guard case .responseDone = e else { return XCTFail("expected responseDone") }
    }

    func testMalformedToolArgumentsFallBackToEmpty() {
        let e = RealtimeEventParser.parse([
            "type": "response.done",
            "response": ["output": [[
                "type": "function_call", "name": "resume_playback",
                "arguments": "not json", "call_id": "c2"]]]])
        guard case let .toolCall(name, args, _) = e else { return XCTFail() }
        XCTAssertEqual(name, .resume_playback)
        XCTAssertTrue(args.isEmpty)          // safeJson tolerance
    }

    func testUnknownToolNameIgnored() {
        let e = RealtimeEventParser.parse([
            "type": "response.done",
            "response": ["output": [["type": "function_call", "name": "delete_everything", "arguments": "{}"]]]])
        guard case .responseDone = e else { return XCTFail("unknown tool -> plain responseDone") }
    }

    func testUnrelatedEventReturnsNil() {
        XCTAssertNil(RealtimeEventParser.parse(["type": "response.created"]))
    }
}
```

- [ ] **Step 3: Write `ios/NexaInsight/Classroom/RealtimeEventParser.swift`**

```swift
import Foundation

enum RealtimeEventParser {
    static func parse(_ json: [String: Any]) -> RealtimeEvent? {
        let type = json["type"] as? String ?? ""
        switch type {
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "conversation.item.input_audio_transcription.completed":
            let text = (json["transcript"] as? String) ?? ""
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .inputTranscriptionCompleted(text)
        case "response.audio_transcript.done":
            guard let text = json["transcript"] as? String else { return nil }
            return .responseAudioTranscriptDone(text)
        case "response.done":
            let output = (json["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
            for item in output where (item["type"] as? String) == "function_call" {
                guard let rawName = item["name"] as? String, let tool = PlaybackTool(rawValue: rawName) else { continue }
                let args = safeArgs(item["arguments"] as? String)
                return .toolCall(name: tool, args: args, callId: item["call_id"] as? String)
            }
            return .responseDone
        default:
            return nil
        }
    }

    private static func safeArgs(_ raw: String?) -> [String: Double] {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Double] = [:]
        for (key, value) in obj {
            if let d = value as? Double { result[key] = d }
            else if let i = value as? Int { result[key] = Double(i) }
        }
        return result
    }
}
```

- [ ] **Step 4: Run parser test to verify it fails then passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: first FAIL (undefined), then after Step 3 PASS (all RealtimeEventParserTests).

- [ ] **Step 5: Write `ios/NexaInsight/Classroom/QwenRealtimeTransport.swift`**

Implement the WebRTC shell. This is device/transport code (not unit-tested); its decision logic already lives in the parser and controller. Key structure:

```swift
import Foundation
import WebRTC

@MainActor
final class QwenRealtimeTransport: NSObject, ClassroomTransport {
    private let factory: RTCPeerConnectionFactory
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var instructions = ""
    private var onEvent: ((RealtimeEvent) -> Void)?
    let remoteAudioTrackContinuation = AsyncStream<RTCAudioTrack>.makeStream()

    override init() {
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        super.init()
    }

    func connect(instructions: String, apiKey: String, workspaceId: String, region: String, model: String,
                 onEvent: @escaping (RealtimeEvent) -> Void) async throws {
        self.instructions = instructions
        self.onEvent = onEvent
        let config = RTCConfiguration()
        config.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self)!
        self.peer = peer

        // Local mic track.
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "mic0")
        peer.add(audioTrack, streamIds: ["local0"])

        // Data channel for events.
        let dcConfig = RTCDataChannelConfiguration()
        let dc = peer.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        dc?.delegate = self
        self.channel = dc

        let offer = try await peer.offer(for: constraints)
        try await peer.setLocalDescription(offer)

        let resolvedRegion = region == "cn-beijing" ? "cn-beijing" : "ap-southeast-1"
        let endpoint = URL(string: "https://\(workspaceId).\(resolvedRegion).maas.aliyuncs.com/api/v1/webrtc/realtime?model=\(model)")!
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = offer.sdp.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let answerSDP = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Qwen", code: status, userInfo: [NSLocalizedDescriptionKey: "DashScope WebRTC error (\(status))"])
        }
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP))
    }

    private func sendSessionUpdate() {
        let session: [String: Any] = [
            "modalities": ["text", "audio"],
            "voice": "Ethan",
            "input_audio_format": "pcm",
            "output_audio_format": "pcm",
            "instructions": "\(instructions)\n\n\(omniDirectInstructions)",
            "input_audio_transcription": ["model": "qwen3-asr-flash-realtime"],
            "tools": realtimePlaybackTools,
            "turn_detection": ["type": "semantic_vad", "threshold": 0.5, "silence_duration_ms": 800, "create_response": true],
        ]
        send(["type": "session.update", "session": session])
    }

    private func send(_ payload: [String: Any]) {
        guard let channel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    func stopSpeaking() {
        send(["type": "response.cancel"])
        send(["type": "output_audio_buffer.clear"])
    }

    func sendToolResult(callId: String?, ok: Bool) {
        send(["type": "conversation.item.create",
              "item": ["type": "function_call_output", "call_id": callId as Any,
                       "output": #"{"ok":\#(ok)}"#]])
    }

    func updateContext(_ context: String) {
        send(["type": "session.update", "session": ["instructions": composeInstructions(instructions, freshContext: context)]])
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text",
                                    "text": "[SYSTEM] The podcast is now at a new position. This is the ONLY current context — ignore earlier positions we discussed:\n\(context)"]]]])
    }

    func injectUserText(_ text: String) {
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user",
                       "content": [["type": "input_text", "text": "Read the following teacher answer aloud exactly. Do not add commentary or call tools.\n\n\(text)"]]]])
        requestResponse()
    }

    func requestResponse() { send(["type": "response.create"]) }
}

extension QwenRealtimeTransport: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = rtpReceiver.track as? RTCAudioTrack { remoteAudioTrackContinuation.continuation.yield(track) }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange state: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
    }
    // Remaining required delegate stubs (didChange signaling/gathering, didGenerate/didRemove candidate, didRemove streams, shouldNegotiate) are empty.
}

extension QwenRealtimeTransport: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            Task { @MainActor in self.sendSessionUpdate() }
        }
    }
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary,
              let json = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else { return }
        Task { @MainActor in
            if let event = RealtimeEventParser.parse(json) { self.onEvent?(event) }
        }
    }
}
```

Note: fill in the empty required `RTCPeerConnectionDelegate` methods to satisfy the protocol. WebRTC audio routing, mic-permission prompting (Info.plist `NSMicrophoneUsageDescription` already added in Plan 2), and playing the remote track are device concerns validated manually — the event/tool logic is already covered by `RealtimeEventParserTests` and `ClassroomControllerTests`.

- [ ] **Step 6: Build (device transport compiles; parser tests pass)**

Run: `cd ios && xcodegen generate && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' build test`
Expected: BUILD SUCCEEDED; all parser + controller tests pass. (WebRTC binary links; transport is not exercised by unit tests.)

- [ ] **Step 7: Commit**

```bash
git add ios/project.yml ios/NexaInsight/Classroom/RealtimeEventParser.swift ios/NexaInsight/Classroom/QwenRealtimeTransport.swift ios/NexaInsightTests/RealtimeEventParserTests.swift
git commit -m "feat(ios): Qwen realtime WebRTC transport + event parser"
```

---

### Task 5: Live-class session wiring and UI

**Files:**
- Create: `ios/NexaInsight/Classroom/LiveClassSession.swift`
- Create: `ios/NexaInsight/Views/LiveClassView.swift`
- Modify: `ios/NexaInsight/Views/StudyView.swift` (add a "Talk" affordance that presents the live class over the current episode/cursor)
- Create: `ios/NexaInsightTests/LiveClassSessionTests.swift`

**Interfaces:**
- Consumes: `ClassroomController` (Task 3), `QwenRealtimeTransport` (Task 4), `ClassroomContext`/`ClassroomInstructions` (Tasks 1–2), `EpisodeStore`, `KeychainStore`, `LocalAudioPlayback` (the SAME player instance the study screen uses, so the class controls the podcast the learner is hearing), `activeSentence`.
- Produces:
  - `@MainActor final class LiveClassSession: ObservableObject` that assembles a live class:
    - `struct Readiness { let configured: Bool; let message: String? }` and `static func readiness(dashscopeKey: String?, workspaceId: String?) -> Readiness` — ports the web `realtimeCapabilities.configured` gate ("Configure DashScope API Key and Workspace ID to start live class"). Unit-tested.
    - `func buildInitialInstructions(episodeTitle:channel:chapters:sentences:startMs:) -> String` — `baseClassroomInstructions(material: classroomContext(...))`. Unit-tested (asserts material is embedded).
    - `func contextFor(_ positionMs: Int) -> String` — `classroomContext(...)` at a position, used by the controller's `onContextRefresh`. Unit-tested.
    - `func start() async` — checks readiness; builds instructions at the current cursor; creates the `ClassroomController` (wiring `onContextRefresh` to push `transport.updateContext(contextFor(pos))` and `onNotice` to a published banner); connects the transport with the Keychain key/workspace/region/model; on transport events calls `controller.handleRealtimeEvent`.
    - `func end()` — closes the transport, resumes/pauses per the reducer, clears state.
    - Published: `@Published var notice: String`, `@Published var error: String?`, `@Published var connected: Bool`, plus exposure of the controller's `transcript`/`state` for the view.
  - `LiveClassView` — a sheet/panel over `StudyView` showing the teacher status (`classroomStatusMessage(controller.state, cursor)`), the running `transcript`, a text composer calling `controller.sendText`, and an "End class" button. Visual design free; behavior via the session/controller.
  - `StudyView` gains a "Talk" button that presents `LiveClassView` bound to the study screen's existing `LocalAudioPlayback`.

- [ ] **Step 1: Write the failing test `ios/NexaInsightTests/LiveClassSessionTests.swift`**

```swift
import XCTest
@testable import NexaInsight

@MainActor
final class LiveClassSessionTests: XCTestCase {
    func testReadinessRequiresKeyAndWorkspace() {
        XCTAssertFalse(LiveClassSession.readiness(dashscopeKey: nil, workspaceId: "w").configured)
        XCTAssertFalse(LiveClassSession.readiness(dashscopeKey: "k", workspaceId: "").configured)
        let ok = LiveClassSession.readiness(dashscopeKey: "k", workspaceId: "w")
        XCTAssertTrue(ok.configured)
        XCTAssertNil(ok.message)
        let bad = LiveClassSession.readiness(dashscopeKey: nil, workspaceId: nil)
        XCTAssertEqual(bad.message, "Configure DashScope API Key and Workspace ID to start live class")
    }

    func testInitialInstructionsEmbedMaterial() {
        let session = LiveClassSession(store: try! EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        let text = session.buildInitialInstructions(
            episodeTitle: "T", channel: "C",
            chapters: [ChapterDTO(id: 1, title: "Intro", summary: "s", startMs: 0, endMs: 1000)],
            sentences: [SentenceDTO(id: 0, episodeId: 1, chapterId: 1, position: 0, startMs: 0, endMs: 500, speaker: nil, sourceText: "Hi", chinese: "嗨")],
            startMs: 0)
        XCTAssertTrue(text.contains("Episode: T · C"))
        XCTAssertTrue(text.contains("Classroom material:"))
    }

    func testContextForBuildsWindowAtPosition() {
        let session = LiveClassSession(store: try! EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        session.loadContent(
            episodeTitle: "T", channel: "C",
            chapters: [ChapterDTO(id: 1, title: "C1", summary: "s", startMs: 0, endMs: 5000)],
            sentences: [SentenceDTO(id: 0, episodeId: 1, chapterId: 1, position: 0, startMs: 2000, endMs: 3000, speaker: nil, sourceText: "Mid", chinese: "中")])
        XCTAssertTrue(session.contextFor(2500).contains("Mid / 中"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: compile failure — `LiveClassSession` undefined.

- [ ] **Step 3: Write `ios/NexaInsight/Classroom/LiveClassSession.swift`**

```swift
import Foundation

@MainActor
final class LiveClassSession: ObservableObject {
    struct Readiness { let configured: Bool; let message: String? }

    @Published var notice = ""
    @Published var error: String?
    @Published var connected = false
    @Published var controller: ClassroomController?

    private let store: EpisodeStore
    private let keychain: KeychainStore
    private let episodeId: Int
    private let playback: Playback
    private var transport: QwenRealtimeTransport?

    // Loaded content for context building.
    private var episodeTitle: String?
    private var channel: String?
    private var chapters: [ChapterDTO] = []
    private var sentences: [SentenceDTO] = []

    // Configurable model/region (defaults mirror the backend settings).
    var region = "cn-beijing"
    var model = "qwen3.5-omni-plus-realtime"

    init(store: EpisodeStore, keychain: KeychainStore, episodeId: Int, playback: Playback) {
        self.store = store; self.keychain = keychain; self.episodeId = episodeId; self.playback = playback
    }

    static func readiness(dashscopeKey: String?, workspaceId: String?) -> Readiness {
        let ok = !(dashscopeKey ?? "").isEmpty && !(workspaceId ?? "").isEmpty
        return Readiness(configured: ok, message: ok ? nil : "Configure DashScope API Key and Workspace ID to start live class")
    }

    func loadContent(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO]) {
        self.episodeTitle = episodeTitle; self.channel = channel; self.chapters = chapters; self.sentences = sentences
    }

    private func loadFromStore() {
        let episode = store.downloadedEpisodes().first { $0.id == episodeId }
        loadContent(episodeTitle: episode?.title, channel: episode?.channel,
                    chapters: store.chapters(for: episodeId), sentences: store.sentences(for: episodeId))
    }

    func buildInitialInstructions(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO], startMs: Int) -> String {
        let material = classroomContext(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, atMs: startMs)
        return baseClassroomInstructions(material: material)
    }

    func contextFor(_ positionMs: Int) -> String {
        classroomContext(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, atMs: positionMs)
    }

    func start() async {
        error = nil
        let key = keychain.get(.dashscopeKey)
        let workspace = keychain.get(.dashscopeWorkspaceId)
        let readiness = Self.readiness(dashscopeKey: key, workspaceId: workspace)
        guard readiness.configured, let key, let workspace else { error = readiness.message; return }
        loadFromStore()
        let startMs = classroomCursorPosition(playback.currentMs, nil, 0)
        let instructions = buildInitialInstructions(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, startMs: startMs)
        let transport = QwenRealtimeTransport()
        self.transport = transport
        let controller = ClassroomController(
            sentences: sentences, playback: playback, transport: transport,
            onNotice: { [weak self] in self?.notice = $0 },
            onContextRefresh: { [weak self] position in
                guard let self else { return }
                transport.updateContext(self.contextFor(position))
            })
        self.controller = controller
        do {
            try await transport.connect(instructions: instructions, apiKey: key, workspaceId: workspace,
                                        region: region, model: model) { [weak controller] event in
                controller?.handleRealtimeEvent(event)
            }
            connected = true
        } catch {
            self.error = error.localizedDescription
            connected = false
        }
    }

    func end() {
        connected = false
        controller = nil
        transport = nil
        // Leaving the class returns to self-study; the podcast state is whatever
        // the last playback tool set (paused at the frozen cursor unless resumed).
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' test`
Expected: PASS (all three LiveClassSessionTests)

- [ ] **Step 5: Write `ios/NexaInsight/Views/LiveClassView.swift` and wire "Talk" into `StudyView`**

`LiveClassView` binds to a `LiveClassSession` (created with the study screen's `LocalAudioPlayback`) and its `controller`:

```swift
import SwiftUI

struct LiveClassView: View {
    @ObservedObject var session: LiveClassSession
    @State private var draft = ""
    let cursorMs: Int
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let error = session.error { Text(error).foregroundStyle(.red) }
            if let controller = session.controller {
                Text(classroomStatusMessage(controller.state, cursorMs)).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    ForEach(Array(controller.transcript.enumerated()), id: \.offset) { _, turn in
                        HStack {
                            if turn.role == .assistant { Spacer(minLength: 0) }
                            Text(turn.text)
                                .padding(8)
                                .background(turn.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            if turn.role == .user { Spacer(minLength: 0) }
                        }
                    }
                }
                HStack {
                    TextField("Speak, or type to the teacher…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        let text = draft; draft = ""
                        controller.sendText(text)
                    }.disabled(draft.isEmpty)
                }
            } else {
                ProgressView("Connecting your voice classroom…")
            }
            if !session.notice.isEmpty { Text(session.notice).font(.footnote).foregroundStyle(.secondary) }
            Button("End class", role: .destructive) { session.end(); onEnd() }
        }
        .padding()
        .task { await session.start() }
    }
}
```

In `StudyView`, add a "Talk" button that presents `LiveClassView` in a sheet, constructing `LiveClassSession(store:keychain:episodeId:playback:)` with the SAME `player` instance the study screen already built, and passing `cursorMs: player.currentMs`. This guarantees the class controls the exact podcast the learner is hearing (the web app's shared-cursor invariant).

- [ ] **Step 6: Build and run the full suite**

Run: `cd ios && xcodebuild -project NexaInsight.xcodeproj -scheme NexaInsight -destination 'platform=iOS Simulator,name=iPhone 15' build test`
Expected: BUILD SUCCEEDED; all tests across Plans 2 and 3 pass.

- [ ] **Step 7: Commit**

```bash
git add ios/NexaInsight/Classroom/LiveClassSession.swift ios/NexaInsight/Views/LiveClassView.swift ios/NexaInsight/Views/StudyView.swift ios/NexaInsightTests/LiveClassSessionTests.swift
git commit -m "feat(ios): live-class session wiring + voice classroom UI"
```

---

## Self-Review

**Spec coverage (voice classroom section of the design spec):**
- Omni-direct single-model path only; qwen-max HTTP brain NOT ported → Global Constraints + Task 3 (controller has no teacher-turn HTTP call) ✓
- WebRTC direct to Qwen with on-device key, no backend → Task 4 (`connect` posts SDP to the DashScope endpoint with the Keychain key) ✓
- Voice-first cursor freeze; only explicit resume releases playback → Task 3 (`freeze`/`resume`/`runPlaybackTool`), tested ✓
- Playback tools drive the shared `Playback` (podcast the learner hears) → Task 3 + Task 5 (same `LocalAudioPlayback` instance) ✓
- Single authoritative context window; position-movers refresh context → Task 2 (`composeInstructions`) + Task 3 (`onContextRefresh` on movers) + Task 4 (`updateContext`) ✓
- On-device classroom context (episode map + chapter + window) from local store → Task 1 ✓
- No monologue on a playback command → Task 3 (direct-command path appends turn + runs tool, never `speak`), tested (`testTextDirectCommandRunsToolNoDiscussion`) ✓
- Malformed/empty model output degrades safely → Task 4 parser (`safeArgs`, unknown-tool → responseDone), tested ✓
- Realtime session config mirrors `QwenClassroom.connect` → Task 4 `sendSessionUpdate` ✓
- DashScope-not-configured gate → Task 5 `readiness`, tested ✓
- Dual-track recording of learner/teacher audio: the design spec lists this; on the pure Omni-direct device path it is a device-only AV capture concern. It is NOT covered by a task here because it carries no interaction logic and no unit-testable seam — flagged explicitly as a manual, device-validated follow-on (records the mic track and the remote audio track to local files on class end). This is the one spec item deliberately left as device work; call it out to the user.

**Placeholder scan:** No TBD/TODO. Every code step has full code. The one place the first draft showed a placeholder (`transport.speak("")` in `sendText`) is explicitly corrected in Task 3 Steps 3–4 with the `injectUserText` fix and the reason. Device-transport code (Task 4 Step 5, Task 5 Step 5) is complete reference code with device-only concerns (audio routing, mic prompt, delegate stubs) flagged — not vague instructions.

**Type consistency:**
- `ClassroomTransport` protocol (`stopSpeaking`, `sendToolResult(callId:ok:)`, `updateContext`, `injectUserText`, `speak`, `requestResponse`) defined in Task 3 (with `injectUserText` added in Steps 3–4); implemented by `QwenRealtimeTransport` (Task 4) and `FakeTransport` (Task 3 test). ✓
- `RealtimeEvent` cases defined in Task 3; produced by `RealtimeEventParser` (Task 4) and consumed by `ClassroomController.handleRealtimeEvent` (Task 3) — cases match exactly. ✓
- `PlaybackTool` (Plan 2 Task 4) used by parser and controller identically. ✓
- `classroomContext` / `composeInstructions` / `baseClassroomInstructions` signatures defined in Tasks 1–2; used by `LiveClassSession` (Task 5) consistently. ✓
- `ClassroomController.init(sentences:playback:transport:onNotice:onContextRefresh:)` defined in Task 3; called identically in Task 5. ✓
- `LocalAudioPlayback`/`Playback`, `EpisodeStore`, `KeychainStore` all consumed with the signatures Plan 2 defined. ✓
- `FakePlayback` (Plan 2 Task 7 test target) reused by Task 3 and Task 5 tests. ✓

**Interaction-fidelity note:** every decision from `useClassroomTeacher.ts` and every event-dispatch from `QwenClassroom.ts` lives in the pure, unit-tested `ClassroomController` (Task 3) and `RealtimeEventParser` (Task 4). Only WebRTC/AV transport and SwiftUI rendering are device-validated, and they contain no branching interaction logic. This is how the optimized behavior is preserved exactly.
