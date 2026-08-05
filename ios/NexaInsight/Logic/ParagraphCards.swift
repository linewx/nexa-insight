import Foundation

/// The cards attached to one paragraph, in the order they were made.
///
/// A paragraph can accumulate several: a word you looked up, then a question about
/// the grammar, then one about what the whole thing is arguing. They are different
/// kinds of answer, so they are different card shapes, but they belong to the same
/// line and collapse behind the same summary.
enum ParagraphCards {
    enum Card: Equatable, Identifiable {
        /// A vocabulary card, with a highlight in the text.
        case expression(LearningExpressionDTO)
        /// A free-form question and its answer. No highlight — the subject is the
        /// passage, not a phrase inside it.
        case note(id: Int, question: String, answer: String)

        var id: String {
            switch self {
            case .expression(let expression): "e\(expression.id)"
            case .note(let id, _, _): "n\(id)"
            }
        }

        /// Only what the learner made by hand can be deleted. Automatic extraction
        /// is replaced wholesale by a reprocess, so deleting one of those would only
        /// bring it back on the next sync.
        var isDeletable: Bool {
            switch self {
            case .expression(let expression): expression.source == "manual"
            case .note: true
            }
        }
    }

    /// Every paragraph's cards, grouped by sentence in one pass.
    ///
    /// Built once per transcript, not once per row. Calling `cards(sentenceId:…)`
    /// inside the row loop measured 31.6ms for 681 rows against 209 expressions —
    /// on its own nearly twice a 60fps frame budget, and by a wide margin the
    /// largest cost in reading mode. Every other candidate (segmenting a screenful,
    /// the active-sentence lookup, building this index) sits under 0.4ms.
    struct Index {
        private let bySentence: [Int: [Card]]

        init(
            expressions: [LearningExpressionDTO],
            notes: [(id: Int, sentenceId: Int, question: String, answer: String)]
        ) {
            var map: [Int: [Card]] = [:]
            // Expressions first, so a paragraph reads from the highlighted word in
            // the line down to the card explaining it.
            for expression in expressions {
                // A distinct expression can occur twice in one line; the card should
                // appear once.
                for sentenceId in Set(expression.occurrences.map(\.sentenceId)) {
                    map[sentenceId, default: []].append(.expression(expression))
                }
            }
            for note in notes {
                map[note.sentenceId, default: []].append(
                    .note(id: note.id, question: note.question, answer: note.answer))
            }
            bySentence = map
        }

        func cards(for sentenceId: Int) -> [Card] { bySentence[sentenceId] ?? [] }
        func hasCards(for sentenceId: Int) -> Bool { bySentence[sentenceId] != nil }
    }

    /// Cards for one sentence: its manual and automatic expressions, then its notes.
    ///
    /// Kept for tests and one-off lookups. Anything looping over rows must use
    /// `Index` — see the note there.
    static func cards(
        sentenceId: Int,
        expressions: [LearningExpressionDTO],
        notes: [(id: Int, sentenceId: Int, question: String, answer: String)]
    ) -> [Card] {
        Index(expressions: expressions, notes: notes).cards(for: sentenceId)
    }

    /// The collapsed label. Nil when there is nothing to show, so a paragraph with
    /// no cards gets no summary row at all — most paragraphs never will, and a row
    /// reading "0 cards" under every line is exactly the clutter to avoid.
    static func summary(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \u{5f20}\u{5361}\u{7247}"
    }
}
