import Foundation

/// Something worth keeping from a finished reading conversation.
///
/// Two shapes because there are two kinds of thing learned, and they already have
/// homes: a vocabulary point becomes a highlighted expression card, a question point
/// becomes a Q&A card. No new card type — the paragraph card stack draws both.
enum KnowledgePoint: Equatable {
    /// A word or phrase to learn, plus what the learner asked about it.
    ///
    /// The question travels WITH it. The old vocabulary path passed `request: nil` and
    /// discarded the question outright, so a card you found a week later gave no hint
    /// why you had wanted it.
    case vocabulary(ExtractedExpression, question: String)
    /// Anything else worth remembering, as the exchange settled it.
    case question(question: String, answer: String)
}

/// Decides what a finished reading conversation leaves behind — possibly nothing.
///
/// Reads the transcribed turns rather than the audio: the realtime session already
/// transcribed both sides, so there is no second chance to mishear here.
///
/// The parsing reuses `ExtractionResponse.parse` for vocabulary points by rewrapping
/// them in the shape it expects. That function carries validation learned the hard
/// way — the six-word cap, text must really occur in the line, patterns kept but
/// un-highlighted, a slotless pattern demoted to a phrase — and reimplementing it
/// here would mean relearning all of it.
enum KnowledgePointExtractor {
    /// The conversation as the model should see it, oldest turn first.
    ///
    /// Roles are labelled because who said what changes the meaning entirely: the
    /// learner's line is the question, the teacher's is the answer, and a model given
    /// an unlabelled blob will happily keep the learner's own guess as the conclusion.
    static func conversationText(_ turns: [TutorTurn]) -> String {
        turns.compactMap { turn in
            switch turn.role {
            case .user: "LEARNER: \(turn.text)"
            case .assistant: "TEACHER: \(turn.text)"
            // System turns are plumbing (context refreshes, notices) and are not part
            // of what was discussed.
            case .system: nil
            }
        }.joined(separator: "\n")
    }

    /// What to keep, from the model's reply.
    ///
    /// - Returns: the points worth keeping. **An empty array is a normal result**, not
    ///   an error: most exchanges about a paragraph leave nothing durable behind, and
    ///   the alternative — a card per question — is what filled the stack with noise.
    ///   Unparseable output also yields empty rather than throwing: the learner already
    ///   heard and read the answer, so there is nothing to apologise for and nothing
    ///   worth a dialog. This is the deliberate difference from `outcome(_:candidates:)`,
    ///   whose `noUsableExpression` was surfaced as a failure.
    static func points(_ raw: String, candidates: [String]) -> [KnowledgePoint] {
        let cleaned = ExtractionResponse.unfenced(raw)
        guard let data = cleaned.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["points"] as? [[String: Any]]
        else { return [] }

        return items.compactMap { item in
            let question = text(item["question"])
            switch (item["kind"] as? String)?.lowercased() {
            case "vocabulary":
                // Rewrapped into the shape `parse` reads, so its whole validation
                // chain applies unchanged. One item at a time: a point that fails
                // validation should drop itself, not the rest of the conversation.
                guard let wrapped = try? JSONSerialization.data(withJSONObject: ["expressions": [item]]),
                      let json = String(data: wrapped, encoding: .utf8),
                      let parsed = try? ExtractionResponse.parse(json, candidates: candidates),
                      let expression = parsed.first
                else { return nil }
                return .vocabulary(expression, question: question)
            default:
                // Anything not explicitly vocabulary is treated as a question card, the
                // same way QuestionIntent falls back to comprehension: an answer shown
                // as a note is useful, an answer thrown away is not.
                let answer = text(item["answer"])
                guard !answer.isEmpty else { return nil }
                return .question(question: question, answer: answer)
            }
        }
    }

    private static func text(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
