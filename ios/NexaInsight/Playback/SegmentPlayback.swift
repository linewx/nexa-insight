#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Combine
import Foundation

/// Plays one bounded stretch of an episode's audio, independently of the main player.
///
/// Shadowing used to ask StudyView to seek the MAIN player, which meant asking to hear one
/// sentence moved the transcript underneath the sheet and left it playing there — the outer
/// paragraph ran on, because it was the same player and the same position.
///
/// So this owns its own AVPlayer over the same file. It deliberately does NOT touch the audio
/// session: the main player already configured it, and re-activating a session mid-sheet is
/// what makes hold-to-talk swallow its first syllable.
@MainActor
final class SegmentPlayback: ObservableObject {
    @Published private(set) var isPlaying = false

    private let player: AVPlayer
    private var timeObserver: Any?
    /// Where to stop, and what to call when we get there.
    private var pending: (endMs: Int, done: () -> Void)?

    init(fileURL: URL) {
        player = AVPlayer(playerItem: AVPlayerItem(url: fileURL))
        // 0.05s, not the main player's 0.2s: a sentence is a couple of seconds long, and a
        // 200ms overshoot on a 260ms tail is audible as the next word starting.
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in self.tick(atMs: Int(time.seconds * 1000)) }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func play(fromMs startMs: Int, toMs endMs: Int, then done: @escaping () -> Void) {
        pending = (endMs, done)
        isPlaying = true
        player.seek(to: CMTime(value: CMTimeValue(max(0, startMs)), timescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.player.play() }
        }
    }

    /// Stops without running the completion — used when the sheet closes or a take begins.
    func stop() {
        pending = nil
        isPlaying = false
        player.pause()
    }

    private func tick(atMs ms: Int) {
        guard let pending, ms >= pending.endMs else { return }
        self.pending = nil
        isPlaying = false
        player.pause()
        pending.done()
    }
}
#endif
