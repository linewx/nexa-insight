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

/// The lookup became a binary search because it runs on every 200ms position tick
/// and drives a transcript redraw. These pin it against the linear behaviour it
/// replaced — an off-by-one here highlights the wrong line for a whole sentence.
final class ActiveSentenceBinarySearchTests: XCTestCase {
    private func line(_ id: Int, startMs: Int) -> SentenceDTO {
        SentenceDTO(
            id: id, episodeId: 1, chapterId: nil, position: id, startMs: startMs,
            endMs: startMs + 1000, speaker: nil, sourceText: "s\(id)", chinese: "句\(id)")
    }

    /// What the code did before: walk until a sentence starts after the cursor.
    private func linear(_ sentences: [SentenceDTO], _ ms: Int) -> SentenceDTO? {
        var active: SentenceDTO?
        for item in sentences {
            if item.startMs <= ms { active = item } else { break }
        }
        return active
    }

    func testMatchesTheLinearScanAtEveryBoundary() {
        let sentences = (0..<50).map { line($0, startMs: $0 * 1000) }
        // Every exact start, every ms either side, plus outside both ends.
        var probes = [-1, 0, 49_999, 50_000, 1_000_000]
        for i in 0..<50 {
            probes.append(contentsOf: [i * 1000 - 1, i * 1000, i * 1000 + 1])
        }
        for ms in probes {
            XCTAssertEqual(
                activeSentence(sentences, ms)?.id, linear(sentences, ms)?.id,
                "diverged at \(ms)ms")
        }
    }

    func testReturnsNilBeforeTheFirstSentenceStarts() {
        let sentences = [line(1, startMs: 5_000), line(2, startMs: 9_000)]
        XCTAssertNil(activeSentenceIndex(sentences, 4_999))
        XCTAssertEqual(activeSentenceIndex(sentences, 5_000), 0)
    }

    func testHoldsTheLastSentencePastTheEnd() {
        let sentences = [line(1, startMs: 0), line(2, startMs: 1_000)]
        XCTAssertEqual(activeSentence(sentences, 999_999)?.id, 2)
    }

    func testEmptyTranscriptIsHandled() {
        XCTAssertNil(activeSentenceIndex([], 0))
        XCTAssertNil(activeSentence([], 0))
        XCTAssertEqual(subtitleWindow([], 0), [])
    }

    func testWindowStaysCenteredAndClampedAtBothEnds() {
        let sentences = (0..<10).map { line($0, startMs: $0 * 1000) }
        XCTAssertEqual(subtitleWindow(sentences, 5_000, radius: 2).map(\.id), [3, 4, 5, 6, 7])
        // Clamped at the start rather than wrapping or going negative.
        XCTAssertEqual(subtitleWindow(sentences, 0, radius: 2).map(\.id), [0, 1, 2])
        XCTAssertEqual(subtitleWindow(sentences, 9_000, radius: 2).map(\.id), [7, 8, 9])
    }

    func testRepeatedStartTimesPickTheLastOne() {
        // Two sentences sharing a start is malformed but has occurred; the linear
        // scan kept the later one, so the search must too.
        let sentences = [line(1, startMs: 0), line(2, startMs: 1_000), line(3, startMs: 1_000)]
        XCTAssertEqual(activeSentence(sentences, 1_000)?.id, linear(sentences, 1_000)?.id)
    }
}
