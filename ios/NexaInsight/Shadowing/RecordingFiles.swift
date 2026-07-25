import Foundation

enum RecordingFiles {
    static func directory(episodeId: Int) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("recordings/\(episodeId)", isDirectory: true)
    }
    static func recordingURL(episodeId: Int, sentenceId: Int) -> (url: URL, relative: String) {
        let name = "\(sentenceId)-\(UUID().uuidString).m4a"
        let dir = directory(episodeId: episodeId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent(name), "recordings/\(episodeId)/\(name)")
    }
}

// Recorder abstraction so ShadowingViewModel's logic is testable offline.
// The concrete AVAudioRecorder implementation is iOS-only and lives in the
// Xcode app target (it needs AVAudioSession).
protocol ShadowingRecording: AnyObject {
    func start(to url: URL) throws
    @discardableResult func stop() -> URL?
}
