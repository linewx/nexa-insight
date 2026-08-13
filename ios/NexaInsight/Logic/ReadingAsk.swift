import Foundation

/// One conversation about one paragraph, in reading mode.
///
/// The controller's `transcript` is the whole episode's, in order, with no notion of
/// which paragraph a turn was about. Reading needs the other cut: the turns belonging
/// to THIS paragraph and THIS sitting, so they can be drawn under that paragraph and
/// handed to the extractor as one unit when the conversation ends.
///
/// Pure state, no transport: the phase transitions are where the silent gap lived
/// (release cleared the waveform and nothing replaced it until a card appeared), so
/// they are worth testing without a network.
struct ReadingAsk: Equatable {
    /// What the learner can see happening. `waiting` is the one the old flow had no
    /// representation for at all — the seconds between the finger lifting and an
    /// answer arriving, during which the screen went back to looking idle.
    enum Phase: Equatable {
        /// Finger down, mic open.
        case recording
        /// Finger up, the question is with the server, nothing to show yet.
        case waiting
        /// The answer is arriving, and audio is playing.
        case answering
        /// A turn finished. The conversation stays open for a follow-up.
        case idle
        /// The server took a turn but no words came back from it.
        case misheard
    }

    /// The paragraph this conversation is about. Every turn is drawn under it, and the
    /// extractor anchors whatever it keeps to this line.
    let sentenceId: Int
    /// That paragraph's start, used to centre the teacher's context window.
    let atMs: Int
    private(set) var phase: Phase = .recording
    private(set) var turns: [TutorTurn] = []

    init(sentenceId: Int, atMs: Int) {
        self.sentenceId = sentenceId
        self.atMs = atMs
    }

    /// Whether anything has been said and answered yet. A conversation that never got
    /// past `recording` — a mis-hold, a slip of the thumb — has nothing to sediment
    /// and nothing to draw.
    var isEmpty: Bool { turns.isEmpty }

    /// Whether a follow-up can start right now. Not during a turn: pressing while the
    /// teacher is still answering is an interrupt, which the controller handles by
    /// taking the floor, and the session should not also start a second conversation.
    var acceptsFollowUp: Bool { phase == .idle || phase == .misheard }

    // MARK: - Transitions

    mutating func held() { phase = .recording }

    /// The finger lifted and something was actually said. From here the learner is
    /// waiting on the server, which is a state worth showing.
    mutating func released() { phase = .waiting }

    /// What the learner said, as the server heard it. Shown verbatim: when the model
    /// mishears, an answer to the wrong question is indistinguishable from a wrong
    /// answer unless you can see which happened.
    mutating func heard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(TutorTurn(role: .user, text: trimmed))
        phase = .answering
    }

    /// The teacher's reply.
    mutating func answered(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(TutorTurn(role: .assistant, text: trimmed))
        phase = .answering
    }

    /// The turn is over. Lands on `idle` so a follow-up is possible, unless nothing
    /// was heard at all — then say so, because silence with no explanation is the
    /// failure mode that makes a learner press again and again.
    mutating func finished() {
        phase = turns.isEmpty ? .misheard : .idle
    }

    /// The hold produced no turn (too brief, or nothing said). Not an error worth a
    /// dialog; the conversation simply never started.
    mutating func abandoned() { phase = .idle }
}
