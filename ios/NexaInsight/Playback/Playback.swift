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
    // Which output is active. Live is gated on headphones — on the speaker the
    // teacher's voice self-triggers the VAD (see AudioRouteLogic).
    func currentRoute() -> AudioRouteKind
}

extension Playback {
    func configureAudioSession(voiceMode: Bool) {}
    // Implementations without a real audio session can't know the route. Report
    // .unknown, which gates Live off — the safe default, since enabling it on a
    // speaker is what causes the self-triggering loop.
    func currentRoute() -> AudioRouteKind { .unknown }
}
