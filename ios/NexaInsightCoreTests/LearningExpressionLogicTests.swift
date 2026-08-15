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

    func testAttributedSentenceStylesOnlyTheExpression() {
        let segments = LearningExpressionLogic.segments(
            for: "We need to rethink how we work.", sentenceId: 7, expressions: [expression])
        // The highlight callback marks the run; here it records which text it was
        // handed, which is what the view uses to apply colour and weight.
        var styled: [String] = []
        let attributed = LearningExpressionLogic.attributedSentence(segments: segments) { run in
            styled.append(String(run.characters))
        }

        XCTAssertEqual(String(attributed.characters), "We need to rethink how we work.")
        XCTAssertEqual(styled, ["rethink how"])
    }

    // The callback's mutations have to reach the RETURNED string, not just a copy of
    // the run. The old test only recorded which text was handed over, which is why a
    // highlight that set colour and then lost it passed for weeks: cards appeared under
    // the right lines, and the words in them were never blue.
    func testTheHighlightStylingSurvivesIntoTheResult() {
        let segments = LearningExpressionLogic.segments(
            for: "We need to rethink how we work.", sentenceId: 7, expressions: [expression])
        // A Foundation attribute rather than a SwiftUI one: the test target does not link
        // SwiftUI, and the mechanism under test — whether the callback's writes reach the
        // returned string — is identical either way.
        let attributed = LearningExpressionLogic.attributedSentence(segments: segments) { run in
            run.inlinePresentationIntent = .stronglyEmphasized
        }

        let marked = attributed.runs
            .filter { $0.attributes.inlinePresentationIntent != nil }
            .map { String(attributed[$0.range].characters) }
        XCTAssertEqual(marked, ["rethink how"], "the styling must be on the returned string")
    }

    func testNoLinksAreEmbeddedInTheTranscript() {
        // A link makes SwiftUI treat the Text as interactive, and that is what an
        // episode with expressions paid on every row of every frame — the difference
        // between a transcript with highlights scrolling badly and one without
        // scrolling fine. The card stack reaches the same cards.
        let segments = LearningExpressionLogic.segments(
            for: "We need to rethink how we work.", sentenceId: 7, expressions: [expression])
        let attributed = LearningExpressionLogic.attributedSentence(segments: segments)

        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
    }

    func testAttributedSentenceWithoutExpressionsIsUntouched() {
        var styled: [String] = []
        let segments = LearningExpressionLogic.segments(for: "Nothing notable here.", sentenceId: 7, expressions: [])
        let attributed = LearningExpressionLogic.attributedSentence(segments: segments) { run in
            styled.append(String(run.characters))
        }

        XCTAssertEqual(String(attributed.characters), "Nothing notable here.")
        XCTAssertTrue(styled.isEmpty)
        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
    }

    func testOverlappingExpressionsKeepTheLongestRange() {
        let word = LearningExpressionDTO(id: 2, text: "rethink", kind: .word, chinese: "重新思考", pronunciation: nil, example: "Rethink it.", exampleChinese: "重新想想。", occurrences: [ExpressionOccurrenceDTO(sentenceId: 7, startOffset: 11, endOffset: 18)])
        let segments = LearningExpressionLogic.segments(for: "We need to rethink how we work.", sentenceId: 7, expressions: [word, expression])
        XCTAssertEqual(segments.filter { $0.expressionID != nil }.map(\.expressionID), [1])
    }
}
