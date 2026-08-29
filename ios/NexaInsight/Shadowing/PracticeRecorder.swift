#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation

/// One recorder for both practice entries, which stops itself.
///
/// Replaces ExamplePracticeRecorder and ShadowingRecorder — they differed only in whether
/// `stop()` returned the URL. Neither metered, so neither could end a take on its own, and
/// pressing stop was the tap that competes with speaking: you cannot say a sentence naturally
/// while watching for a button.
///
/// The thresholds live in `SilenceGate`, which is pure and tested. This class does the parts
/// that need a microphone: metering on a timer and closing the file.
final class PracticeRecorder {
    /// 20 Hz. Fast enough that the 1.2s silence window is measured to within a sample, slow
    /// enough to be free.
    private static let meterInterval: TimeInterval = 0.05

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var gate = SilenceGate()
    private var startedAt: Date?
    private var url: URL?

    /// Called on the main queue when the take ends by itself. `nil` means nothing was said,
    /// so there is no recording worth scoring.
    var onFinished: ((URL?) -> Void)?

    /// Live level in 0...1, for the waveform. Published through a callback rather than
    /// @Published so this file stays free of Combine and testable by inspection.
    var onLevel: ((Float) -> Void)?

    /// Puts the audio session into recording mode ahead of the first press.
    ///
    /// `setActive(true)` blocks on the main thread for tens to hundreds of milliseconds, and
    /// doing it inside the press meant the finger was already down — and the first syllable
    /// already spoken — before recording began. The button also stayed un-lit for that whole
    /// time, so the press read as ignored.
    ///
    /// Called when the practice sheet opens. The cost is that the sheet holds the session in
    /// `.playAndRecord` while it is up, which is what it needs anyway to alternate between
    /// hearing the line and speaking it.
    func prepareSession() {
        let session = AVAudioSession.sharedInstance()
        // Best-effort: a failure here only means the press pays the cost as before.
        try? session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try? session.setActive(true)
    }

    func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        // Idempotent, and nearly free once `prepareSession` has run — AVAudioSession returns
        // immediately when the category and active state already match.
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        // Without this, averagePower returns 0 forever and every take looks like speech.
        recorder.isMeteringEnabled = true
        recorder.record()
        self.recorder = recorder
        self.url = url
        self.gate = SilenceGate()
        self.startedAt = Date()
        let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        // .common, or the timer stops the moment a scroll begins.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Ends the take early — the learner tapped 再试一次, or the view went away.
    @discardableResult
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        startedAt = nil
        let finished = url
        url = nil
        return finished
    }

    private func sample() {
        guard let recorder, let startedAt else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        onLevel?(Self.level(fromPower: power))
        switch gate.observe(power: power, elapsed: Date().timeIntervalSince(startedAt)) {
        case .keepGoing:
            return
        case .finished:
            onFinished?(stop())
        case .nothingSaid:
            // Discard the file: an empty recording sent for scoring comes back as a low
            // score for a take the learner never made.
            let discarded = stop()
            if let discarded { try? FileManager.default.removeItem(at: discarded) }
            onFinished?(nil)
        }
    }

    /// dBFS to a 0...1 bar height. -50 and quieter reads as empty; 0 is full scale.
    static func level(fromPower power: Float) -> Float {
        let floor: Float = -50
        guard power > floor else { return 0 }
        return min(1, (power - floor) / -floor)
    }
}
#endif
