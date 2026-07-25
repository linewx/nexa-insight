import Foundation

enum PlaybackState { case unstarted, playing, paused, ended, buffering }

@MainActor
protocol Playback: AnyObject {
    var currentMs: Int { get }
    var isReady: Bool { get }
    var playbackState: PlaybackState { get }
    func seek(_ ms: Int)
    func pause()
    func play()
    func speed(_ rate: Double)
    // The live classroom needs the mic while the source keeps playing, which
    // only a voice-mode audio session allows. Implementations without a real
    // audio session ignore it.
    func configureAudioSession(voiceMode: Bool)
}

extension Playback {
    func configureAudioSession(voiceMode: Bool) {}
}
