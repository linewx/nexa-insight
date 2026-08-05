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

/// The index exists for one measured reason: grouping cards per row cost 31.6ms
/// for a 681-sentence transcript against 209 expressions — the only thing in
/// reading mode over a 60fps frame budget, and 800× the indexed cost. These pin it
/// against the per-row version it replaced.
final class ParagraphCardIndexTests: XCTestCase {
    private func expression(
        id: Int, text: String, sentenceIds: [Int], source: String = "manual"
    ) -> LearningExpressionDTO {
        LearningExpressionDTO(
            id: id, text: text, kind: .phrase, chinese: "释义", pronunciation: nil,
            example: text, exampleChinese: "例句", source: source,
            occurrences: sentenceIds.map {
                ExpressionOccurrenceDTO(sentenceId: $0, startOffset: 0, endOffset: 2)
            })
    }

    private func note(
        _ id: Int, sentenceId: Int
    ) -> (id: Int, sentenceId: Int, question: String, answer: String) {
        (id: id, sentenceId: sentenceId, question: "q\(id)", answer: "a\(id)")
    }

    func testIndexedResultMatchesThePerRowVersion() {
        let expressions = [
            expression(id: 1, text: "Hi", sentenceIds: [10]),
            expression(id: 2, text: "Bye", sentenceIds: [11]),
        ]
        let notes = [note(-1, sentenceId: 10), note(-2, sentenceId: 11)]
        let index = ParagraphCards.Index(expressions: expressions, notes: notes)

        for sentenceId in [10, 11, 12] {
            XCTAssertEqual(
                index.cards(for: sentenceId),
                ParagraphCards.cards(sentenceId: sentenceId, expressions: expressions, notes: notes),
                "diverged on sentence \(sentenceId)")
        }
    }

    func testExpressionsStillComeBeforeNotes() {
        let index = ParagraphCards.Index(
            expressions: [expression(id: 1, text: "Hi", sentenceIds: [10])],
            notes: [note(-1, sentenceId: 10)])
        let cards = index.cards(for: 10)

        XCTAssertEqual(cards.count, 2)
        guard case .expression = cards[0] else { return XCTFail("expression must lead") }
        guard case .note = cards[1] else { return XCTFail("note must follow") }
    }

    func testAnExpressionOccurringTwiceInOneLineYieldsOneCard() {
        // Two occurrences, one card: the highlight appears twice in the text, but a
        // duplicated card underneath is noise.
        let index = ParagraphCards.Index(
            expressions: [expression(id: 1, text: "Hi", sentenceIds: [10, 10])], notes: [])
        XCTAssertEqual(index.cards(for: 10).count, 1)
    }

    func testAnExpressionSpanningTwoLinesAppearsUnderBoth() {
        let index = ParagraphCards.Index(
            expressions: [expression(id: 1, text: "Hi", sentenceIds: [10, 11])], notes: [])
        XCTAssertEqual(index.cards(for: 10).count, 1)
        XCTAssertEqual(index.cards(for: 11).count, 1)
    }

    func testParagraphsWithoutCardsReportSoWithoutAllocating() {
        // What the summary row keys off: most paragraphs never carry a card, and the
        // row must not appear under them.
        let index = ParagraphCards.Index(
            expressions: [expression(id: 1, text: "Hi", sentenceIds: [10])], notes: [])
        XCTAssertTrue(index.hasCards(for: 10))
        XCTAssertFalse(index.hasCards(for: 11))
        XCTAssertTrue(index.cards(for: 11).isEmpty)
    }

    func testEmptyIndexIsSafeToQuery() {
        // The first frame, before the cache is filled.
        let cold = ParagraphCards.Index(expressions: [], notes: [])
        XCTAssertTrue(cold.cards(for: 10).isEmpty)
        XCTAssertFalse(cold.hasCards(for: 10))
    }
}
