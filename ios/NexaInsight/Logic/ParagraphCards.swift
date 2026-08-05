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

    /// Cards for one sentence: its manual and automatic expressions, then its notes.
    ///
    /// Expressions come first because they have a highlight in the line above, so
    /// reading order matches the eye's path from the marked word down to the card.
    static func cards(
        sentenceId: Int,
        expressions: [LearningExpressionDTO],
        notes: [(id: Int, sentenceId: Int, question: String, answer: String)]
    ) -> [Card] {
        let anchored = expressions
            .filter { $0.occurrences.contains { $0.sentenceId == sentenceId } }
            .map(Card.expression)
        let attached = notes
            .filter { $0.sentenceId == sentenceId }
            .map { Card.note(id: $0.id, question: $0.question, answer: $0.answer) }
        return anchored + attached
    }

    /// The collapsed label. Nil when there is nothing to show, so a paragraph with
    /// no cards gets no summary row at all — most paragraphs never will, and a row
    /// reading "0 cards" under every line is exactly the clutter to avoid.
    static func summary(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \u{5f20}\u{5361}\u{7247}"
    }
}
