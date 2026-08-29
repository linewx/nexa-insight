import XCTest
@testable import NexaInsightCore

// The shadowing sheet must not drive the transcript behind it.
//
// SegmentPlayback and PracticeRecorder both sit inside `#if os(iOS)`, so neither can be
// instantiated here — swift test runs on macOS. What is checkable is the wiring, and the wiring
// IS the bug in all three cases: which player the sheet uses, when the session is armed, and
// whether the main player is paused. A behavioural test would be better; a source-level test
// that catches the exact regression is better than none.
final class ShadowingIsolationTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func testThePracticeSheetDoesNotSeekTheMainPlayer() throws {
        // Tapping 听这句 used to call back into StudyView and seek the MAIN player, so asking to
        // hear one line moved the transcript underneath the sheet and left the outer paragraph
        // playing from there — "会一直播放", because nothing in the sheet owned the stop.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        XCTAssertTrue(practice.contains("segment.play(fromMs:"),
                      "listening plays on the sheet's own player")
        XCTAssertFalse(practice.contains("onPlayOriginal"),
                       "the callback that drove the main player is gone")

        // BOTH sheets, counted. Asserting the string merely appears passed with one call site
        // set to nil, because the other still had it — the same blind spot that let the card
        // sheet ship without the audio callback at all.
        let study = try source("NexaInsight/Views/StudyView.swift")
        XCTAssertEqual(
            study.components(separatedBy: "onSuspendMainPlayback: { player.pause() }").count - 1, 2,
            "every practice sheet pauses the main player while it is up")
    }

    func testBothPracticeSheetsGetTheAudioFile() throws {
        // Two sheets present PracticeView — a transcript sentence and a card example — and the
        // card one was constructed without the player callback at all, so its 听这句 fell back to
        // synthesised speech. Only one presentation per view survives in SwiftUI, which is how
        // differences between these two call sites keep going unnoticed.
        let study = try source("NexaInsight/Views/StudyView.swift")
        XCTAssertEqual(study.components(separatedBy: "audioFileURL: audioFileURL").count - 1, 2,
                       "both sheets pass the audio file")
        XCTAssertEqual(study.components(separatedBy: "onSuspendMainPlayback:").count - 1, 2,
                       "and both pause the main player")
    }

    func testTheAudioSessionIsArmedBeforeTheFirstPress() throws {
        // "录音非常不灵敏": beginTake called setActive(true), which blocks the main thread for
        // tens to hundreds of milliseconds. The finger was already down and the first syllable
        // already spoken before recording started, and the button stayed un-lit throughout, so
        // the press read as ignored.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        // A prepared RECORDER, not just an active session. Arming the session alone was my first
        // attempt and the delay stayed: AVAudioRecorder's initialiser opens the output file and
        // the first record() allocates buffers and starts the input hardware, and both ran inside
        // the press.
        XCTAssertTrue(practice.contains("recorder.prepare(to: nextRecordingURL())"),
                      "the sheet arms a real recorder on open")
        XCTAssertTrue(practice.contains("recorder.armedURL"),
                      "and the press uses the armed file, or the fast path is skipped")
        // Twice: once on open, once after a take. The scored and silent paths used to re-arm
        // separately; they now share one call, which is why this is 2 and not 3.
        XCTAssertEqual(
            practice.components(separatedBy: "recorder.prepare(to: nextRecordingURL())").count - 1, 2,
            "armed on open and re-armed after every take")

        let recorderSource = try source("NexaInsight/Shadowing/PracticeRecorder.swift")
        // Code only. The doc comment above `prepare` explains why prepareToRecord matters, so
        // matching raw source passed with the actual CALL deleted — the same comment-matching
        // slip as the LongPressGesture assertion below.
        let recorderCode = recorderSource.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(recorderCode.contains("recorder.prepareToRecord()"),
                      "the expensive file and buffer work happens before the press")
        // The press itself must still be a plain drag with no minimum, or a long-press delay
        // reintroduces the same lost syllable by a different route.
        XCTAssertTrue(practice.contains("DragGesture(minimumDistance: 0)"))
        // Checked against code only: the comment above that gesture explains why LongPressGesture
        // is wrong, and matching raw source flagged the explanation as the offence.
        let code = practice.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("LongPressGesture"),
                       "a long-press delay would lose the first syllable again")

        XCTAssertTrue(recorderSource.contains("func prepare(to url: URL)"))
    }

    func testASegmentPlayerStopsAtTheWindowEnd() throws {
        // The stop has to live with the player. It used to be an onChange watcher in StudyView,
        // which meant the sheet's playback depended on a view behind it still observing.
        let segment = try source("NexaInsight/Playback/SegmentPlayback.swift")
        XCTAssertTrue(segment.contains("ms >= pending.endMs"), "it bounds its own playback")
        XCTAssertTrue(segment.contains("func stop()"), "and can be silenced when a take begins")
        // It must NOT touch the audio session: the main player configured it, and re-activating
        // mid-sheet is what makes the first syllable disappear.
        XCTAssertFalse(segment.contains("setActive"),
                       "a second session activation would undo the recording fix")
    }

    func testTheSentenceBlockCannotPushTheButtonOffTheSheet() throws {
        // The text handed to this sheet is a transcript ROW, and rows are paragraphs: measured
        // across ep8's 761 rows, 123 characters on average, 289 at the longest, and 52% over 120.
        // At title3 serif semibold that set 40 words over six lines and the record button — the
        // only thing the sheet exists for — ended up at the bottom edge.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        let code = practice.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains(".title3, design: .serif, weight: .semibold"),
                       "heading type on a paragraph is what caused the overflow")
        XCTAssertTrue(code.contains(".callout, design: .serif"),
                      "reading size, serif retained")
        // The ceiling is what makes the button's position independent of paragraph length.
        XCTAssertTrue(code.contains("maxHeight: 168"))
        XCTAssertTrue(code.contains("ScrollView(.vertical, showsIndicators: false)"),
                      "a long paragraph scrolls inside the ceiling instead of displacing the button")
    }

    func testTheChineseIsShownAndCanBeHidden() throws {
        // Collapsing it by default saved three lines but made the practice worse: the translation
        // is how you check you understood the line before saying it. The height ceiling on the
        // text block is what keeps the button in place, so the lines are affordable.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        let code = practice.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("@State private var showChinese = true"))
        // Bidirectional. The toggle only ever assigned `true`, which was invisible while the
        // default was collapsed and became a one-way door the moment the default flipped.
        XCTAssertTrue(code.contains("showChinese.toggle()"),
                      "tapping must hide it again, not only reveal it")
        // The only `= true` left is the state declaration; a bare assignment inside the button
        // body would be the one-way door. Checked by looking at the button, not the whole file —
        // my first version matched the declaration itself and failed on correct code.
        if let button = code.range(of: "showChinese.toggle()") {
            let around = String(code[..<button.lowerBound].suffix(200))
            XCTAssertFalse(around.contains("showChinese = true"),
                           "the toggle is the only mutation in the button")
        }
    }

    func testLeavingTheSheetStopsItsPlayer() throws {
        // The segment player was added this round and missed in onDisappear, so leaving mid
        // sentence left it playing — and once the main player resumed, both were audible.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        let disappear = practice.range(of: ".onDisappear {")
        XCTAssertNotNil(disappear)
        let body = String(practice[disappear!.upperBound...].prefix(500))
        XCTAssertTrue(body.contains("segment.stop()"), "the sheet's own player stops on the way out")
        XCTAssertTrue(body.contains("recorder.stop()"))
        XCTAssertTrue(body.contains("speaker.stop()"))
    }

    func testReleasingTheButtonDoesNoExpensiveWork() throws {
        // Fixing the press moved the cost to the release: `prepare` builds an AVAudioRecorder and
        // primes the audio hardware, and calling it inline meant the finger lifted into that
        // work. The stutter moved rather than went away.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        guard let endTake = practice.range(of: "private func endTake() {") else {
            return XCTFail("endTake not found")
        }
        let body = String(practice[endTake.upperBound...].prefix(900))
        guard let prepare = body.range(of: "recorder.prepare(to: nextRecordingURL())") else {
            return XCTFail("re-arming is missing; the second press would be slow again")
        }
        // Whatever precedes the re-arm must have handed it to a Task, not run it inline.
        let before = String(body[..<prepare.lowerBound])
        XCTAssertTrue(before.contains("Task {"),
                      "re-arming happens off the release's run loop turn")
    }

    func testTheRecordButtonDoesNotMove() throws {
        // "按住之后按钮会飘，有了结果之后更加明显". Three separate movements read as one drift:
        //
        //   - the button shrank 88 -> 64 once a score existed, moving its own centre
        //   - the sheet's top padding shrank 24 -> 16 at the same moment, sliding everything up
        //   - the caption changes width (按住说话 / 松开结束 / 按住再说一遍, 4/4/6 characters)
        //
        // All three keyed off `score`, and the 0.2s animation on the container swept them
        // together — which is why it was worst on the second press.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        let code = practice.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("score == nil ? 88 : 64"),
                       "the button's size must not depend on whether a score exists")
        XCTAssertFalse(code.contains("size: score == nil ? 30 : 22"),
                       "nor the icon's")
        XCTAssertFalse(code.contains("padding(.top, score == nil"),
                       "nor the padding above it, which slid the whole column")
        // The caption's height is pinned, so changing its wording cannot move the button.
        XCTAssertTrue(code.contains(".frame(height: 18)"),
                      "the caption occupies the same height whatever it says")
    }

    func testTheHaloCannotAffectLayout() throws {
        // The halo scales with the live microphone level. Anything that pulses with your voice
        // must be decoration: if it participated in layout the stack would breathe.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        guard let halo = practice.range(of: "scaleEffect(isSpeaking ? 1 + CGFloat(currentLevel)") else {
            return XCTFail("the level-driven halo is gone; this test needs rewriting")
        }
        let after = String(practice[halo.upperBound...].prefix(400))
        XCTAssertTrue(after.contains("allowsHitTesting(false)"),
                      "the halo is decoration, and must not take the press either")
    }

    func testTheSegmentPlayerIsInTheBuild() throws {
        // Created on disk and not added to the target, which failed the build loudly this time —
        // but a file that compiles nowhere is a class of mistake worth pinning.
        let project = try source("NexaInsight.xcodeproj/project.pbxproj")
        XCTAssertTrue(project.contains("SegmentPlayback.swift in Sources"))
    }
}
