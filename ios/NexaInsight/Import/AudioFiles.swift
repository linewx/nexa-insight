import Foundation

enum AudioFiles {
    static var audioDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("audio", isDirectory: true)
    }
    static func audioURL(forEpisode id: Int) -> URL {
        audioDirectory.appendingPathComponent("\(id).mp3")
    }
    static func relativePath(forEpisode id: Int) -> String { "audio/\(id).mp3" }
}
