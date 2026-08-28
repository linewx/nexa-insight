import XCTest
@testable import NexaInsightCore

private func s(_ id: Int, _ start: Int, _ en: String, _ zh: String) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: start + 900, speaker: nil, sourceText: en, chinese: zh)
}

@MainActor
final class StudyViewModelTests: XCTestCase {
    let lines = [s(0, 0, "Hello there", "你好"), s(1, 1000, "How are you", "你好吗"), s(2, 2000, "Goodbye now", "再见")]

    func testASmallNudgeKeepsFollowing() {
        // The complaint: the button appeared "even when the current line is right there in view,
        // just not centred". The trigger was `following = false` on ANY 12pt vertical drag, so
        // nudging the page offered to scroll back to a line already on screen.
        let vm = StudyViewModel()
        vm.onManualScroll(translation: 40)
        XCTAssertTrue(vm.following, "40pt is under a row — the playing line has not moved off screen")
        vm.onManualScroll(translation: 120)
        XCTAssertTrue(vm.following, "still within about a row and a half")

        vm.onManualScroll(translation: StudyViewModel.driftThreshold)
        XCTAssertFalse(vm.following, "far enough that the line really is gone")
    }

    func testDragTranslationIsCumulativeNotIncremental() {
        // SwiftUI reports a gesture's TOTAL translation on every change, so summing the values
        // would count the same movement repeatedly and trip the threshold inside one flick.
        let vm = StudyViewModel()
        for step in stride(from: 20.0, through: 100.0, by: 20.0) {
            vm.onManualScroll(translation: step)
        }
        XCTAssertTrue(vm.following, "100pt of actual movement, reported five times, is still 100pt")
    }

    func testSeparateNudgesDoNotAccumulate() {
        // Three small drags that each leave the line visible must not add up to a hidden line.
        let vm = StudyViewModel()
        for _ in 0..<3 {
            vm.onManualScroll(translation: 100)
            vm.onScrollEnded()
        }
        XCTAssertTrue(vm.following, "each gesture is measured on its own")
    }

    func testDriftResetsAfterSyncing() {
        // Pressing the button must clear the accumulated drift, or the next small nudge inherits
        // it and hides the line immediately.
        let vm = StudyViewModel()
        vm.onManualScroll(translation: StudyViewModel.driftThreshold)
        XCTAssertFalse(vm.following)
        vm.syncNow()
        vm.onManualScroll(translation: 30)
        XCTAssertTrue(vm.following, "a 30pt nudge after syncing is still a nudge")
    }

    func testCurrentSentenceFallsBackToFirst() {
        let vm = StudyViewModel()
        XCTAssertEqual(vm.currentSentence(sentences: lines, cursorMs: -50)?.id, 0)
        XCTAssertEqual(vm.currentSentence(sentences: lines, cursorMs: 1500)?.id, 1)
    }

    // A line becomes current exactly at its startMs — no lead/offset. Tapping a
    // line seeks to its startMs, so highlight must land on that same line, not
    // the next one.
    func testCurrentSentenceIsExactAtStart() {
        let vm = StudyViewModel()
        XCTAssertEqual(vm.currentSentence(sentences: lines, cursorMs: 1000)?.id, 1)
        XCTAssertEqual(vm.currentSentence(sentences: lines, cursorMs: 999)?.id, 0)
    }

    func testManualScrollLeavesFollowThenSyncRestores() {
        // `following` gates the auto-scroll AND the visibility of "Back to current". Nothing
        // called this method, so the flag stayed true forever and that button — which existed,
        // wired to an action, laid out above the dock — could never render.
        let vm = StudyViewModel()
        XCTAssertTrue(vm.following)
        vm.onManualScroll()
        XCTAssertFalse(vm.following)
        vm.syncNow()
        XCTAssertTrue(vm.following)
    }

    func testScrollingAwayDoesNotResumeFollowingOnItsOwn() async throws {
        // No timer any more. Ten seconds is a normal amount of time to spend on a paragraph,
        // and the page yanking itself back mid-sentence is worse than a button you press.
        let vm = StudyViewModel()
        vm.onManualScroll()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(vm.following, "following resumes only when asked")
    }

    func testTapSeeksAndPlaysAndResumesFollowing() {
        let vm = StudyViewModel()
        let player = FakePlayback()
        vm.onManualScroll()
        vm.tap(sentence: lines[2], playback: player)
        XCTAssertEqual(player.seeks, [2000])
        XCTAssertTrue(player.didPlay)
        // Tapping a line is a request to be AT that line, so the button must not linger.
        XCTAssertTrue(vm.following)
    }
}
