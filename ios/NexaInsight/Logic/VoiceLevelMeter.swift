import Foundation

/// Turns AVAudioRecorder's decibel readings into the bar heights the waveform
/// draws.
///
/// Separated from the recorder because this is the part with judgement in it:
/// `averagePower(forChannel:)` returns dBFS, which is logarithmic, unbounded
/// below, and clusters ordinary speech in the top few dB. Fed straight to a bar
/// height it looks dead — every bar near full, then silence. The mapping has to
/// spread the range a learner actually speaks in.
enum VoiceLevelMeter {
    /// Quietest level treated as sound. Below this is room noise, not speech, so
    /// it maps to the floor rather than stretching the scale.
    static let silenceFloor: Float = -50

    /// Number of bars retained. Roughly two seconds at 10 samples/second — enough
    /// to read as movement without becoming a scrolling chart.
    static let barCount = 24

    /// Normalises one dBFS reading to 0...1.
    ///
    /// The square root is what makes it look alive: a linear map of -50...0 leaves
    /// conversational speech (-15 to -5 dB) bunched in the top fifth, so the bars
    /// barely differ. The curve lifts the quiet end without letting silence float
    /// off the floor.
    static func normalized(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        guard decibels > silenceFloor else { return 0 }
        let clamped = min(decibels, 0)
        let linear = (clamped - silenceFloor) / -silenceFloor
        return min(1, max(0, linear.squareRoot()))
    }

    /// Appends a reading, keeping only the most recent `barCount`.
    static func appending(_ decibels: Float, to samples: [Float]) -> [Float] {
        var next = samples
        next.append(normalized(decibels))
        if next.count > barCount { next.removeFirst(next.count - barCount) }
        return next
    }

    /// Normalised level a sample must reach to count as speech.
    ///
    /// Set against the curve above, not by eye: `normalized` is square-rooted, so
    /// a quiet room at -48 dB already arrives as 0.20 and a linear-looking
    /// threshold like 0.15 would call silence speech. 0.5 sits at about -37 dB —
    /// below anything spoken toward the phone, above room noise.
    static let speechThreshold: Float = 0.5

    /// Whether the take carries any speech at all.
    ///
    /// A hold released instantly, or held with the mic muted, produces only floor
    /// samples. Sending that spends a request to be told nothing was heard, so it
    /// is refused locally instead.
    static func carriesSpeech(_ samples: [Float]) -> Bool {
        samples.contains { $0 > speechThreshold }
    }
}
