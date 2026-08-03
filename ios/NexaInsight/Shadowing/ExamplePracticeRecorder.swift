#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation

final class ExamplePracticeRecorder {
    private var recorder: AVAudioRecorder?

    func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
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
        recorder.record()
        self.recorder = recorder
    }

    func stop() { recorder?.stop(); recorder = nil }
}
#endif
