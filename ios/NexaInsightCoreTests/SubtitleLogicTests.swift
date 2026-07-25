import XCTest
@testable import NexaInsightCore

private func s(_ id: Int, _ start: Int, _ end: Int) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: end, speaker: nil, sourceText: "e\(id)", chinese: "c\(id)")
}

final class SubtitleLogicTests: XCTestCase {
    let lines = [s(0, 0, 1200), s(1, 1000, 2200), s(2, 2000, 3200), s(3, 3000, 4200)]

    func testActiveSentenceIsLastStartedNotContaining() {
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
