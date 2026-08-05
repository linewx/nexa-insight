import XCTest
@testable import NexaInsightCore

final class LearningExpressionLogicTests: XCTestCase {
    private let expression = LearningExpressionDTO(
        id: 1, text: "rethink how", kind: .pattern, chinese: "重新思考如何", pronunciation: nil,
        example: "We need to rethink how we work.", exampleChinese: "我们需要重新思考如何工作。",
        occurrences: [ExpressionOccurrenceDTO(sentenceId: 7, startOffset: 11, endOffset: 22)]
    )

    func testSegmentsPreserveTextAndMarkExpressionRange() {
        let segments = LearningExpressionLogic.segments(for: "We need to rethink how we work.", sentenceId: 7, expressions: [expression])
        XCTAssertEqual(segments.map(\.text).joined(), "We need to rethink how we work.")
        XCTAssertEqual(segments.filter { $0.expressionID == 1 }.map(\.text), ["rethink how"])
    }

    func testSegmentIDInterpolatesRatherThanEmittingBackslashes() {
        let segment = LearningExpressionLogic.Segment(text: "rethink how", expressionID: 1)
        XCTAssertEqual(segment.id, "1-rethink how")
        let plain = LearningExpressionLogic.Segment(text: "we work.", expressionID: nil)
        XCTAssertEqual(plain.id, "plain-we work.")
    }

    func testExpressionURLRoundTrips() {
        let url = LearningExpressionLogic.expressionURL(42)
        XCTAssertNotNil(url)
        XCTAssertEqual(LearningExpressionLogic.expressionID(fromURL: url!), 42)
    }

    func testForeignURLsAreNotMistakenForExpressions() {
        // A real link in a transcript must still open in the browser.
        XCTAssertNil(LearningExpressionLogic.expressionID(fromURL: URL(string: "https://example.com/7")!))
        XCTAssertNil(LearningExpressionLogic.expressionID(fromURL: URL(string: "nexa-expression://notanumber")!))
    }

    func testAttributedSentencePreservesTextAndLinksOnlyExpressions() {
        let segments = LearningExpressionLogic.segments(
            for: "We need to rethink how we work.", sentenceId: 7, expressions: [expression])
        let attributed = LearningExpressionLogic.attributedSentence(segments: segments)

        XCTAssertEqual(String(attributed.characters), "We need to rethink how we work.")

        var linked: [String] = []
        for run in attributed.runs where run.link != nil {
            linked.append(String(attributed[run.range].characters))
            XCTAssertEqual(LearningExpressionLogic.expressionID(fromURL: run.link!), 1)
        }
        XCTAssertEqual(linked, ["rethink how"])
    }

    func testAttributedSentenceWithoutExpressionsCarriesNoLinks() {
        let segments = LearningExpressionLogic.segments(for: "Nothing notable here.", sentenceId: 7, expressions: [])
        let attributed = LearningExpressionLogic.attributedSentence(segments: segments)

        XCTAssertEqual(String(attributed.characters), "Nothing notable here.")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
    }

    func testOverlappingExpressionsKeepTheLongestRange() {
        let word = LearningExpressionDTO(id: 2, text: "rethink", kind: .word, chinese: "重新思考", pronunciation: nil, example: "Rethink it.", exampleChinese: "重新想想。", occurrences: [ExpressionOccurrenceDTO(sentenceId: 7, startOffset: 11, endOffset: 18)])
        let segments = LearningExpressionLogic.segments(for: "We need to rethink how we work.", sentenceId: 7, expressions: [word, expression])
        XCTAssertEqual(segments.filter { $0.expressionID != nil }.map(\.expressionID), [1])
    }
}
