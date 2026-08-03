import Foundation

// Sentence-level controls for intensive listening.
//
// The player already had precise seeking and a 0.5–2.0 rate, but neither reached
// the screen — so the highest-frequency action in intensive listening (missed
// that, play it again) meant dragging a scrubber across a four-hour file.
//
// These are pure functions so the whole interaction is testable offline; the view
// only decides where to draw them.
enum IntensiveListening {
    // Stepping is by INDEX, not by timestamp arithmetic. Sentence boundaries are
    // not uniform, so "back 5 seconds" lands mid-sentence — the one thing a
    // learner replaying a line does not want.
    static func previousSentence(_ sentences: [SentenceDTO], from current: SentenceDTO?) -> SentenceDTO? {
        guard let current, let index = sentences.firstIndex(where: { $0.id == current.id }) else {
            return sentences.first
        }
        return index > 0 ? sentences[index - 1] : nil
    }

    static func nextSentence(_ sentences: [SentenceDTO], from current: SentenceDTO?) -> SentenceDTO? {
        guard let current, let index = sentences.firstIndex(where: { $0.id == current.id }) else {
            return sentences.first
        }
        return index + 1 < sentences.count ? sentences[index + 1] : nil
    }

    // Replaying the current line restarts THIS sentence rather than nudging back a
    // fixed interval, for the same reason stepping is index-based.
    static func replayTarget(_ sentence: SentenceDTO?) -> Int? {
        sentence?.startMs
    }

    // The speeds actually useful for listening practice, not a continuous slider.
    // A learner wants "slower than native" or "native"; 2.0 is for skimming, which
    // is the opposite of this screen's purpose.
    static let speeds: [Double] = [0.75, 1.0, 1.25]

    // Shown next to the play control ONLY when it is not 1.0, so the default state
    // adds nothing to the screen.
    static func speedBadge(_ rate: Double) -> String? {
        guard abs(rate - 1.0) > 0.01 else { return nil }
        // Trailing zeros dropped: "0.75×" and "1.25×", never "1.250×".
        let text = String(format: "%g", rate)
        return "\(text)×"
    }

    static func cycledSpeed(after rate: Double) -> Double {
        guard let index = speeds.firstIndex(where: { abs($0 - rate) < 0.01 }) else { return 1.0 }
        return speeds[(index + 1) % speeds.count]
    }
}

// Which sentence is looping, if any.
//
// Deliberately a value type holding the sentence id rather than a Bool on the row:
// only one sentence can loop at a time, and storing it centrally makes that
// impossible to violate.
struct SentenceLoop: Equatable {
    private(set) var sentenceId: Int?

    static let off = SentenceLoop(sentenceId: nil)

    var isActive: Bool { sentenceId != nil }

    func isLooping(_ sentence: SentenceDTO) -> Bool { sentenceId == sentence.id }

    // Tapping loop on the sentence already looping turns it off; on any other
    // sentence it moves there. One control, no separate stop button.
    func toggled(_ sentence: SentenceDTO) -> SentenceLoop {
        SentenceLoop(sentenceId: sentenceId == sentence.id ? nil : sentence.id)
    }

    // Where playback should jump back to, or nil to keep playing.
    //
    // Returns nil when the loop is off or points at a different sentence, so a
    // stale loop cannot hijack playback after the learner moves on.
    func rewindTarget(for sentence: SentenceDTO?, at currentMs: Int) -> Int? {
        guard let sentence, isLooping(sentence) else { return nil }
        return sentenceLoopBoundary(sentence, currentMs)
    }
}
