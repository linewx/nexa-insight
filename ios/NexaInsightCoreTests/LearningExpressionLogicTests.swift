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

    func testOverlappingExpressionsKeepTheLongestRange() {
        let word = LearningExpressionDTO(id: 2, text: "rethink", kind: .word, chinese: "重新思考", pronunciation: nil, example: "Rethink it.", exampleChinese: "重新想想。", occurrences: [ExpressionOccurrenceDTO(sentenceId: 7, startOffset: 11, endOffset: 18)])
        let segments = LearningExpressionLogic.segments(for: "We need to rethink how we work.", sentenceId: 7, expressions: [word, expression])
        XCTAssertEqual(segments.filter { $0.expressionID != nil }.map(\.expressionID), [1])
    }
}
