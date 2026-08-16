import Foundation

/// Where the model audio for a practice subject comes from.
///
/// Synthesis was the wrong default. `AVSpeechSynthesisVoice(language: "en-US")` resolves to
/// `super-compact.Samantha` — Apple's most heavily compressed offline voice, quality tier
/// `default`, with zero premium or enhanced voices installed on this machine. Shadowing a
/// robot teaches the wrong intonation, which is worse than teaching none.
///
/// A transcript sentence has real speech behind it, so it plays that. What stopped this
/// earlier was segment length: the hotel vlog averages 11.5s per segment and runs to 33s. But
/// a segment carries its own `startMs`/`endMs`, so playback can be bounded to exactly the
/// sentence rather than the paragraph around it — the same trick `SentenceLoop` already uses.
enum ModelAudio: Equatable {
    /// Play the episode's own audio between these bounds.
    case original(startMs: Int, endMs: Int)
    /// Synthesise. A card example or pattern is not spoken anywhere in the episode — the
    /// example is written, and a pattern is a frame nobody said verbatim.
    case synthesised

    /// Padding either side of the segment bounds.
    ///
    /// Transcript timings clip the first consonant and the final syllable often enough to
    /// matter when the whole point is hearing the sentence exactly. Asymmetric because the
    /// tail is where a trailing "-s" or "-ed" lives, and those are what a Chinese learner is
    /// most likely to drop.
    static let leadInMs = 120
    static let tailMs = 260

    /// Bounds to actually seek and stop at, clamped so padding cannot run past the file.
    var playbackWindow: (start: Int, end: Int)? {
        guard case .original(let startMs, let endMs) = self else { return nil }
        return (max(0, startMs - Self.leadInMs), endMs + Self.tailMs)
    }

    /// Whether playback has run past the sentence and should stop.
    ///
    /// Stopping is what keeps a 33-second paragraph from playing when the learner asked for
    /// one line of it.
    func hasReachedEnd(at positionMs: Int) -> Bool {
        guard let window = playbackWindow else { return false }
        return positionMs >= window.end
    }
}
