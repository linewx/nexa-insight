import Foundation

/// The whole practice interaction, as one state machine.
///
/// One tap used to cost four: open, record, stop, evaluate. Each was a decision the learner
/// had to make about the tool rather than about English, and stopping competes directly with
/// speaking. This drives listen → speak → score without asking anything in between.
///
/// Pure and synchronous, so every transition is testable without a microphone, a network or a
/// view. The view owns playback and recording; this owns what happens next.
struct PracticeFlow {
    enum Stage: Equatable {
        /// Nothing has happened yet. Only reachable before the first tap.
        case idle
        /// The model sentence is playing. The mic is closed — recording here would capture
        /// the phone's own speaker.
        case listening
        /// Mic open, waiting for the learner. `level` drives the waveform.
        case speaking(level: Float)
        /// Take finished, being scored.
        case scoring
        /// A score is showing.
        case scored
        /// Nothing was said, or scoring failed. Carries what to tell the learner.
        case failed(String)
    }

    private(set) var stage: Stage = .idle

    /// True while the learner should not be interrupted by UI changes.
    var isBusy: Bool {
        switch stage {
        case .listening, .speaking, .scoring: true
        case .idle, .scored, .failed: false
        }
    }

    /// 听一遍 — play the model sentence.
    mutating func begin() {
        stage = .listening
    }

    /// Playback ended. The mic does NOT open on its own: auto-advancing into a recording felt
    /// like being rushed, and the learner may want to hear the sentence twice before trying.
    mutating func listenFinished() {
        // Only from .listening. A late callback from a previous playback must not disturb a
        // take that has already started.
        guard stage == .listening else { return }
        stage = .idle
    }

    /// 说一遍 — the learner starts a take deliberately.
    mutating func startTake() {
        stage = .speaking(level: 0)
    }

    mutating func heard(level: Float) {
        guard case .speaking = stage else { return }
        stage = .speaking(level: level)
    }

    /// The take ended on its own. `recording == nil` means silence: there is nothing to score.
    mutating func takeFinished(recording: URL?) {
        guard case .speaking = stage else { return }
        guard recording != nil else {
            stage = .failed("没听到声音，再试一次")
            return
        }
        stage = .scoring
    }

    mutating func scored() {
        stage = .scored
    }

    mutating func failed(_ message: String) {
        stage = .failed(message)
    }

    /// 再听一遍 — replay without recording. Allowed only when nothing is in flight, so it
    /// cannot cut off a take in progress.
    mutating func replay() -> Bool {
        guard !isBusy else { return false }
        stage = .listening
        return true
    }
}
