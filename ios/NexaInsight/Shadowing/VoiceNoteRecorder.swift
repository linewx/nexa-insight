#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation
import Observation

/// Captures a spoken note and reports live levels for the waveform.
///
/// Same 16 kHz mono PCM as `ExamplePracticeRecorder`, because that is what the
/// omni model accepts as `input_audio` — the recording goes to the model as
/// audio, with no transcription step. One less layer to mistranslate, and no need
/// for a speech-recognition entitlement the app does not otherwise have.
@Observable
final class VoiceNoteRecorder {
    private(set) var samples: [Float] = []
    private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var url: URL?

    var carriesSpeech: Bool { VoiceLevelMeter.carriesSpeech(samples) }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // .playAndRecord rather than .record: the episode may still be playing, and
        // .record would silence it mid-question.
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try session.setActive(true)

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let recorder = try AVAudioRecorder(url: target, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        self.recorder = recorder
        self.url = target
        samples = []
        isRecording = true

        // 10 Hz: fast enough that the bars track the voice, slow enough to stay off
        // the main thread's critical path while the transcript scrolls.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            self.samples = VoiceLevelMeter.appending(
                recorder.averagePower(forChannel: 0), to: self.samples)
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    /// Stops and hands back the file, or nil when nothing usable was captured.
    ///
    /// A tap that registers as a long-press for a few milliseconds, or a muted
    /// mic, yields floor-level samples only. Returning nil there avoids spending a
    /// request to be told nothing was heard.
    @discardableResult
    func stop() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false

        let captured = url
        url = nil
        guard let captured, carriesSpeech else {
            if let captured { try? FileManager.default.removeItem(at: captured) }
            return nil
        }
        return captured
    }

    /// Abandons the take — used when the gesture is cancelled rather than released.
    func cancel() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        samples = []
    }
}
#endif
