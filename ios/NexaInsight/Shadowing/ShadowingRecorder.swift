#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Foundation

final class ShadowingRecorder: ShadowingRecording {
    private var recorder: AVAudioRecorder?

    func start(to url: URL) throws {
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker])
        try AVAudioSession.sharedInstance().setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()
        self.recorder = recorder
    }

    @discardableResult
    func stop() -> URL? {
        let url = recorder?.url
        recorder?.stop()
        recorder = nil
        return url
    }
}
#endif
