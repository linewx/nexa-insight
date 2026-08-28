import XCTest
@testable import NexaInsightCore

private func s(_ id: Int, _ start: Int, _ en: String, _ zh: String) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: start + 900, speaker: nil, sourceText: en, chinese: zh)
}

@MainActor
final class StudyViewModelTests: XCTestCase {
    let lines = [s(0, 0, "Hello there", "你好"), s(1, 1000, "How are you", "你好吗"), s(2, 2000, "Goodbye now", "再见")]

    func testAFlickHidesTheLineEvenThoughTheFingerBarelyMoved() {
        // The bug you hit: the button never appeared at all. I measured FINGER travel, but a
        // flick moves a finger 150-250pt and momentum carries the content several screens — so a
        // 220pt finger threshold was never reached however far the transcript actually went.
        let vm = StudyViewModel()
        vm.onContentOffset(0)          // settled
        vm.onManualScroll(translation: 180)   // a flick: finger well under the old threshold
        vm.onContentOffset(-2000)      // momentum carried the content two screens
        XCTAssertFalse(vm.following, "the playing line is long gone, whatever the finger did")
    }

    func testASmallNudgeKeepsFollowing() {
        // The first complaint: the button appeared "even when the current line is right there in
        // view, just not centred", because ANY 12pt drag flipped following.
        let vm = StudyViewModel()
        vm.onContentOffset(0)
        vm.onManualScroll(translation: 40)
        vm.onContentOffset(-60)
        XCTAssertTrue(vm.following, "60pt is well under a screen — the line is still visible")

        vm.onContentOffset(-200)
        XCTAssertTrue(vm.following, "still inside the threshold")
    }

    func testAutoScrollDoesNotHideTheLine() {
        // Following the playing line moves the content by large amounts too. Treating that as
        // "reading elsewhere" would make the button appear while the transcript is tracking
        // playback perfectly — the offset alone cannot tell the two apart.
        let vm = StudyViewModel()
        for offset in stride(from: 0.0, through: -4000.0, by: -400.0) {
            vm.onContentOffset(offset)
        }
        XCTAssertTrue(vm.following, "no finger touched it, so nothing was read elsewhere")
    }

    func testSyncingResetsTheReferencePoint() {
        // Pressing the button must clear the anchor, or the next small nudge is measured against
        // a stale offset and hides the line immediately.
        let vm = StudyViewModel()
        vm.onContentOffset(0)
        vm.onManualScroll(translation: 200)
        vm.onContentOffset(-3000)
        XCTAssertFalse(vm.following)

        vm.syncNow()
        XCTAssertTrue(vm.following)
        vm.onContentOffset(-3000)      // the transcript is now HERE, and that is in sync
        vm.onManualScroll(translation: 20)
        vm.onContentOffset(-3050)      // a 50pt nudge from the new position
        XCTAssertTrue(vm.following, "measured from where it sits now, not where it used to")
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
        // `following` gates the auto-scroll AND the sync button's visibility. Nothing called
        // this method at first, so the flag stayed true forever and the button could never
        // render. It now takes BOTH signals: the drag says the movement is the learner's, the
        // offset says how far it went.
        let vm = StudyViewModel()
        XCTAssertTrue(vm.following)
        vm.onContentOffset(0)
        vm.onManualScroll()
        vm.onContentOffset(-1000)
        XCTAssertFalse(vm.following)
        vm.syncNow()
        XCTAssertTrue(vm.following)
    }

    func testScrollingAwayDoesNotResumeFollowingOnItsOwn() async throws {
        // No timer any more. Ten seconds is a normal amount of time to spend on a paragraph,
        // and the page yanking itself back mid-sentence is worse than a button you press.
        let vm = StudyViewModel()
        vm.onContentOffset(0)
        vm.onManualScroll()
        vm.onContentOffset(-1000)
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
