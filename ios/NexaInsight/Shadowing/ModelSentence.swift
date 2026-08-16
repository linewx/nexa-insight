#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation

/// Says the sentence the learner is about to shadow.
///
/// Neither practice screen could play anything, which left "跟读" meaning "read this text
/// aloud and hope" — shadowing without a model to shadow. On-device synthesis rather than the
/// episode audio, because a transcript segment averages 11.5 seconds on the hotel vlog and
/// runs to 33: that is a paragraph, not a sentence to repeat. It also covers card examples and
/// patterns, which have no audio anywhere.
final class ModelSentence: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?

    /// Slightly under the default. Shadowing at native pace teaches nothing to someone who
    /// cannot say the sentence yet, and 0.45 still sounds like speech rather than a slur.
    static let rate: Float = 0.45

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// - Parameter completion: called on the main queue when the sentence ends, which is what
    ///   opens the mic. Also called if speaking cannot start, so the flow never stalls in
    ///   `.listening` with no way forward.
    func say(_ text: String, completion: @escaping () -> Void) {
        // A pattern is written with a blank ("I have you here for ___ nights"), and the
        // synthesizer reads underscores aloud as "underscore". Spoken as a short pause, the
        // frame sounds like the sentence it is.
        let spoken = text.replacingOccurrences(
            of: "_+", with: "...", options: .regularExpression
        )
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion()
            return
        }
        onFinish = completion
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.rate = Self.rate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        // Recording follows immediately, so the session must already allow both.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        onFinish = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension ModelSentence: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finish = onFinish
        onFinish = nil
        DispatchQueue.main.async { finish?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Cancelled means the learner moved on. Do NOT call the completion: it would open the
        // mic for a take nobody asked for.
        onFinish = nil
    }
}
#endif
