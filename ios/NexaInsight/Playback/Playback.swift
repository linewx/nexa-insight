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
}
