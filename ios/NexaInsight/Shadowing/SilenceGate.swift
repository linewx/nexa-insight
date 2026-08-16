import Foundation

/// Decides when a take is finished, so the learner never has to press stop.
///
/// Pressing stop was one of four taps a single score used to cost, and it is the one that
/// competes with speaking: you cannot say a sentence naturally while watching for a button.
/// The mic opens on its own after the model sentence plays, and this ends the take.
///
/// Deliberately pure — no AVFoundation, no timers. `observe` is fed one power sample at a
/// time and answers with what the recorder should do, which is what makes the thresholds
/// testable without a microphone.
struct SilenceGate {
    /// dBFS below which a sample counts as silence. AVAudioRecorder reports 0 dB as full
    /// scale and -160 as silence; a quiet room sits near -50, and speech peaks above -25.
    static let silenceThreshold: Float = -40

    /// How long the quiet has to last. Shorter than this and the gate fires inside the
    /// natural pause between clauses — "I have you here for two nights" has one after
    /// "here" — cutting the take off mid-sentence.
    static let silenceDuration: TimeInterval = 1.2

    /// Give up waiting for speech that never comes. Without this a take opened by mistake
    /// records until the view goes away.
    static let noSpeechTimeout: TimeInterval = 6

    /// Stop a rambling take rather than send a minute of audio for scoring.
    static let maxDuration: TimeInterval = 30

    enum Decision: Equatable {
        /// Keep recording.
        case keepGoing
        /// The learner spoke and has stopped: score this.
        case finished
        /// Nothing was ever said. There is nothing to score, so this is not a take.
        case nothingSaid
    }

    private var heardSpeech = false
    private var quietSince: TimeInterval?

    /// - Parameters:
    ///   - power: average power in dBFS for the latest sample.
    ///   - elapsed: seconds since recording started.
    mutating func observe(power: Float, elapsed: TimeInterval) -> Decision {
        if elapsed >= Self.maxDuration {
            // Anything at all was said, so it is worth scoring even if they did not stop.
            return heardSpeech ? .finished : .nothingSaid
        }
        if power > Self.silenceThreshold {
            heardSpeech = true
            quietSince = nil
            return .keepGoing
        }
        guard heardSpeech else {
            return elapsed >= Self.noSpeechTimeout ? .nothingSaid : .keepGoing
        }
        // Speech has happened and this sample is quiet: start or continue the countdown.
        let start = quietSince ?? elapsed
        quietSince = start
        return elapsed - start >= Self.silenceDuration ? .finished : .keepGoing
    }
}
