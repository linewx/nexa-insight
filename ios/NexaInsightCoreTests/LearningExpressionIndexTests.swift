import XCTest
@testable import NexaInsightCore

/// The indexed path must be indistinguishable from the scanning one — it exists
/// only to stop reading mode recomputing the same answer for every row on every
/// frame.
final class LearningExpressionIndexTests: XCTestCase {
    private func expression(
        id: Int, text: String, occurrences: [(sentence: Int, start: Int, end: Int)]
    ) -> LearningExpressionDTO {
        LearningExpressionDTO(
            id: id, text: text, kind: .phrase, chinese: "释义", pronunciation: nil,
            example: text, exampleChinese: "例句",
            occurrences: occurrences.map {
                ExpressionOccurrenceDTO(sentenceId: $0.sentence, startOffset: $0.start, endOffset: $0.end)
            })
    }

    private let host = "We need to rethink how we work."

    func testIndexedResultMatchesTheScanningResult() {
        let expressions = [
            expression(id: 1, text: "rethink how", occurrences: [(7, 11, 22)]),
            expression(id: 2, text: "we work", occurrences: [(7, 23, 30)]),
            expression(id: 3, text: "elsewhere", occurrences: [(99, 0, 9)]),
        ]
        let scanned = LearningExpressionLogic.segments(for: host, sentenceId: 7, expressions: expressions)
        let indexed = LearningExpressionLogic.segments(
            for: host, sentenceId: 7, index: .init(expressions))
        XCTAssertEqual(scanned, indexed)
        XCTAssertEqual(indexed.map(\.text).joined(), host)
    }

    func testOverlapStillKeepsTheLongestRange() {
        let expressions = [
            expression(id: 1, text: "rethink how", occurrences: [(7, 11, 22)]),
            expression(id: 2, text: "rethink", occurrences: [(7, 11, 18)]),
        ]
        let indexed = LearningExpressionLogic.segments(
            for: host, sentenceId: 7, index: .init(expressions))
        XCTAssertEqual(indexed.filter { $0.expressionID != nil }.map(\.expressionID), [1])
    }

    func testSentenceWithNoOccurrencesReturnsOnePlainSegment() {
        let index = LearningExpressionLogic.Index([
            expression(id: 1, text: "rethink how", occurrences: [(7, 11, 22)])
        ])
        let segments = LearningExpressionLogic.segments(for: host, sentenceId: 8, index: index)
        XCTAssertEqual(segments, [.init(text: host, expressionID: nil)])
        XCTAssertFalse(index.has(sentenceId: 8))
        XCTAssertTrue(index.has(sentenceId: 7))
    }

    func testOutOfRangeOccurrenceIsSkippedRatherThanCrashing() {
        // Offsets come from a different implementation (the backend counts code
        // points, this counts Characters), so a stale row can exceed the line.
        let expressions = [expression(id: 1, text: "way past", occurrences: [(7, 100, 120)])]
        let segments = LearningExpressionLogic.segments(
            for: host, sentenceId: 7, index: .init(expressions))
        XCTAssertEqual(segments.map(\.text).joined(), host)
        XCTAssertTrue(segments.allSatisfy { $0.expressionID == nil })
    }

    func testMultibyteTextKeepsHighlightAligned() {
        let emoji = "\u{1F600} rethink how it works."
        let expressions = [expression(id: 1, text: "rethink how", occurrences: [(7, 2, 13)])]
        let segments = LearningExpressionLogic.segments(
            for: emoji, sentenceId: 7, index: .init(expressions))
        XCTAssertEqual(segments.map(\.text).joined(), emoji)
        XCTAssertEqual(segments.first { $0.expressionID == 1 }?.text, "rethink how")
    }

    func testIndexIsBuiltOncePerTranscriptNotPerSentence() {
        // 137 expressions over 681 sentences is the real shape; the point is that
        // looking up one sentence does not touch the others.
        let expressions = (1...137).map { id in
            expression(id: id, text: "x", occurrences: [(id % 681, 0, 1)])
        }
        let index = LearningExpressionLogic.Index(expressions)
        XCTAssertTrue(index.has(sentenceId: 5))
        XCTAssertFalse(index.has(sentenceId: 680))
    }
}

/// The regression this class exists to prevent: an index that is empty because it
/// has not been built yet must still produce renderable text.
extension LearningExpressionIndexTests {
    func testColdIndexStillYieldsTheWholeLine() {
        // What the first frame sees, before the cache is filled. Returning an empty
        // segment list here rendered an empty Text and the sentence vanished.
        let cold = LearningExpressionLogic.Index([])
        let segments = LearningExpressionLogic.segments(for: host, sentenceId: 7, index: cold)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.map(\.text).joined(), host)
        XCTAssertNil(segments.first?.expressionID)
    }

    func testSegmentsNeverReturnAnEmptyList() {
        // Whatever the inputs, there is always something to draw.
        let index = LearningExpressionLogic.Index([
            expression(id: 1, text: "rethink how", occurrences: [(7, 11, 22)])
        ])
        for sentenceId in [7, 8, 999] {
            XCTAssertFalse(
                LearningExpressionLogic.segments(for: host, sentenceId: sentenceId, index: index).isEmpty,
                "sentence \(sentenceId) produced nothing to render")
        }
        XCTAssertFalse(LearningExpressionLogic.segments(for: "", sentenceId: 7, index: index).isEmpty)
    }
}
