import XCTest
@testable import NexaInsightCore

/// The card template is chosen by `type`, so an unknown value must still decode:
/// one unrecognised string used to fail the whole bundle.
final class ExpressionTypeTests: XCTestCase {
    private func decode(_ json: String) throws -> LearningExpressionDTO {
        try BackendClient.jsonDecoder.decode(LearningExpressionDTO.self, from: json.data(using: .utf8)!)
    }

    private func payload(type: String, extra: String = "") -> String {
        """
        {"id": 1, "text": "kind of", "kind": "phrase", "type": "\(type)",
         "chinese": "有点儿", "pronunciation": null,
         "example": "I kind of like it.", "example_chinese": "我有点喜欢。",
         "occurrences": []\(extra.isEmpty ? "" : ", \(extra)")}
        """
    }

    func testDecodesEveryKnownType() throws {
        for name in ["reduction", "ellipsis", "syntax", "idiom", "reference",
                     "phrase", "pattern", "collocation", "word", "chunk"] {
            let decoded = try decode(payload(type: name))
            XCTAssertEqual(decoded.type.rawValue, name, "expected \(name) to decode")
        }
    }

    func testUnknownTypeFallsBackInsteadOfThrowing() throws {
        XCTAssertEqual(try decode(payload(type: "something-new")).type, .phrase)
    }

    func testMissingTypeFallsBackForOlderBackends() throws {
        let json = """
        {"id": 1, "text": "kind of", "kind": "phrase", "chinese": "有点儿",
         "pronunciation": null, "example": "e", "example_chinese": "例", "occurrences": []}
        """
        XCTAssertEqual(try decode(json).type, .phrase)
    }

    func testDecodesNativeComprehensionFields() throws {
        let decoded = try decode(payload(
            type: "reduction",
            extra: """
            "heard_as": "kinda", "restored": "kind of", "why_hard": "弱读脱落。", "formality": "spoken"
            """))

        XCTAssertEqual(decoded.heardAs, "kinda")
        XCTAssertEqual(decoded.restored, "kind of")
        XCTAssertEqual(decoded.whyHard, "弱读脱落。")
        XCTAssertEqual(decoded.formality, "spoken")
    }

    func testDecodesTeachingProductionFields() throws {
        let decoded = try decode(payload(
            type: "collocation",
            extra: """
            "when_to_use": "描述反复想某事。", "common_mistake": "think too much about"
            """))

        XCTAssertEqual(decoded.whenToUse, "描述反复想某事。")
        XCTAssertEqual(decoded.commonMistake, "think too much about")
    }

    func testTypeGroupsIntoTheRightStudyGoal() {
        // Native types answer "why did I miss that"; teaching types "what do I say".
        for type in [LearningExpressionType.reduction, .ellipsis, .syntax] {
            XCTAssertTrue(type.explainsComprehension, "\(type) should explain comprehension")
        }
        for type in [LearningExpressionType.phrase, .pattern, .collocation] {
            XCTAssertFalse(type.explainsComprehension, "\(type) should be a production item")
        }
    }
}

final class ExpressionCardCopyTests: XCTestCase {
    func testEveryTypeHasADistinctChineseLabel() {
        let labels = LearningExpressionType.allCases.map(ExpressionCardCopy.typeLabel)
        XCTAssertEqual(labels.count, LearningExpressionType.allCases.count)
        XCTAssertEqual(Set(labels).count, labels.count, "labels must not collide")
        XCTAssertFalse(labels.contains { $0.isEmpty })
    }

    func testComprehensionTypesReadAsComprehensionProblems() {
        XCTAssertEqual(ExpressionCardCopy.typeLabel(.reduction), "连读弱读")
        XCTAssertEqual(ExpressionCardCopy.typeLabel(.reference), "背景知识")
    }
}
