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
        // Twice more in endTake — both the scored and the silent outcome — because a take
        // consumes the armed recorder and 按住再说一遍 is the common case here.
        XCTAssertGreaterThanOrEqual(
            practice.components(separatedBy: "recorder.prepare(to: nextRecordingURL())").count - 1, 3,
            "re-armed after a take, on both the scored and the silent path")

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

    func testTheChineseIsCollapsedByDefault() throws {
        // Shadowing means reading the English. The Chinese confirms understanding, and shown
        // always it cost another three lines on a paragraph before the button came into view.
        let practice = try source("NexaInsight/Views/PracticeView.swift")
        let code = practice.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("@State private var showChinese = false"),
                      "hidden until asked for")
        XCTAssertTrue(code.contains("if showChinese {"))
        XCTAssertTrue(code.contains("showChinese = true"), "and there is a way to ask")
    }

    func testTheSegmentPlayerIsInTheBuild() throws {
        // Created on disk and not added to the target, which failed the build loudly this time —
        // but a file that compiles nowhere is a class of mistake worth pinning.
        let project = try source("NexaInsight.xcodeproj/project.pbxproj")
        XCTAssertTrue(project.contains("SegmentPlayback.swift in Sources"))
    }
}
