import XCTest
@testable import NexaInsightCore

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
        vm.onManualScroll(currentOffset: 300, targetOffset: 160)
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
