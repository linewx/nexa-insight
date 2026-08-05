import XCTest
@testable import NexaInsightCore

final class ParagraphCardsTests: XCTestCase {
    private func expression(
        id: Int, text: String, sentenceId: Int, source: String = "manual"
    ) -> LearningExpressionDTO {
        LearningExpressionDTO(
            id: id, text: text, kind: .phrase, chinese: "释义", pronunciation: nil,
            example: text, exampleChinese: "例句", source: source,
            occurrences: [ExpressionOccurrenceDTO(sentenceId: sentenceId, startOffset: 0, endOffset: 2)])
    }

    private func note(
        _ id: Int, sentenceId: Int, question: String = "q", answer: String = "a"
    ) -> (id: Int, sentenceId: Int, question: String, answer: String) {
        (id: id, sentenceId: sentenceId, question: question, answer: answer)
    }

    func testOneParagraphGathersBothKinds() {
        let cards = ParagraphCards.cards(
            sentenceId: 10,
            expressions: [expression(id: 1, text: "Hi", sentenceId: 10)],
            notes: [note(-1, sentenceId: 10)])

        XCTAssertEqual(cards.count, 2)
        // Expressions first: the eye comes down from the highlighted word.
        guard case .expression = cards[0] else { return XCTFail("expected the expression first") }
        guard case .note = cards[1] else { return XCTFail("expected the note second") }
    }

    func testCardsFromOtherParagraphsAreExcluded() {
        let cards = ParagraphCards.cards(
            sentenceId: 10,
            expressions: [expression(id: 1, text: "Hi", sentenceId: 11)],
            notes: [note(-1, sentenceId: 11)])
        XCTAssertTrue(cards.isEmpty)
    }

    func testSeveralNotesOnOneParagraphAreAllKept() {
        let cards = ParagraphCards.cards(
            sentenceId: 10, expressions: [],
            notes: [note(-1, sentenceId: 10, question: "first"),
                    note(-2, sentenceId: 10, question: "second"),
                    note(-3, sentenceId: 10, question: "third")])
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(Set(cards.map(\.id)).count, 3, "ids must stay distinct")
    }

    func testIDsDoNotCollideBetweenTheTwoKinds() {
        // Both number from their own sequence, so an expression id 1 and a note id 1
        // would clash without the prefix — and ForEach would drop one silently.
        let cards = ParagraphCards.cards(
            sentenceId: 10,
            expressions: [expression(id: 1, text: "Hi", sentenceId: 10)],
            notes: [note(1, sentenceId: 10)])
        XCTAssertEqual(Set(cards.map(\.id)).count, 2)
    }

    func testManualCardsAreDeletableAndAutomaticOnesAreNot() {
        let manual = ParagraphCards.Card.expression(
            expression(id: 1, text: "Hi", sentenceId: 10, source: "manual"))
        let auto = ParagraphCards.Card.expression(
            expression(id: 2, text: "Bye", sentenceId: 10, source: "auto"))

        XCTAssertTrue(manual.isDeletable)
        // A reprocess replaces automatic rows, so deleting one would not stick.
        XCTAssertFalse(auto.isDeletable)
        XCTAssertTrue(ParagraphCards.Card.note(id: -1, question: "q", answer: "a").isDeletable)
    }

    func testSummaryIsAbsentWhenThereIsNothingToShow() {
        // No row under the vast majority of paragraphs, which never carry a card.
        XCTAssertNil(ParagraphCards.summary(count: 0))
        XCTAssertEqual(ParagraphCards.summary(count: 1), "1 \u{5f20}\u{5361}\u{7247}")
        XCTAssertEqual(ParagraphCards.summary(count: 3), "3 \u{5f20}\u{5361}\u{7247}")
    }

    func testAutomaticAndManualExpressionsBothAppear() {
        // Reading shows what extraction found as well as what you asked for.
        let cards = ParagraphCards.cards(
            sentenceId: 10,
            expressions: [expression(id: 1, text: "Hi", sentenceId: 10, source: "auto"),
                          expression(id: 2, text: "there", sentenceId: 10, source: "manual")],
            notes: [])
        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.filter(\.isDeletable).count, 1)
    }
}
