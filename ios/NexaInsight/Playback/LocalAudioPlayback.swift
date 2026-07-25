#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import Combine
import Foundation

@MainActor
final class LocalAudioPlayback: ObservableObject, Playback {
    private let player: AVPlayer
    private let fileURL: URL
    private var timeObserver: Any?
    private var playbackRate: Double = 1
    @Published private(set) var currentMsPublished: Int = 0
    @Published private(set) var isReadyPublished: Bool = false
    @Published private(set) var statePublished: PlaybackState = .unstarted
    @Published private(set) var errorMessage: String?

    var currentMs: Int { currentMsPublished }
    var isReady: Bool { isReadyPublished }
    var playbackState: PlaybackState { statePublished }
    var hasLocalFile: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    init(fileURL: URL, initialPositionMs: Int = 0) {
        self.fileURL = fileURL
        player = AVPlayer()
        if !hasLocalFile {
            errorMessage = "Audio is not downloaded on this device yet. Re-add or refresh this source after backend processing finishes."
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: fileURL))
        }
        activateAudioSession()
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentMsPublished = max(0, Int(time.seconds * 1000))
            }
        }
        Task { @MainActor in
            await prepareCurrentItem(initialPositionMs: initialPositionMs)
        }
    }

    deinit { if let timeObserver { player.removeTimeObserver(timeObserver) } }

    func seek(_ ms: Int) {
        let next = max(0, ms)
        currentMsPublished = next
        player.seek(to: CMTime(value: CMTimeValue(next), timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() { player.pause(); statePublished = .paused }

    func play() {
        guard errorMessage == nil else { return }
        guard hasLocalFile else {
            errorMessage = "Audio file is missing locally. Re-add or refresh this source to download audio."
            statePublished = .paused
            return
        }
        if player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(url: fileURL))
        }
        activateAudioSession()
        if let item = player.currentItem, item.status == .failed {
            errorMessage = item.error?.localizedDescription ?? "Audio could not be played."
            statePublished = .paused
            return
        }
        player.playImmediately(atRate: Float(playbackRate))
        statePublished = .playing
    }

    func reloadFromDisk() {
        guard hasLocalFile else {
            errorMessage = "Audio file is missing locally. Re-add or refresh this source to download audio."
            isReadyPublished = false
            statePublished = .paused
            return
        }
        let position = currentMsPublished
        player.replaceCurrentItem(with: AVPlayerItem(url: fileURL))
        errorMessage = nil
        isReadyPublished = false
        statePublished = .paused
        Task { @MainActor in
            await prepareCurrentItem(initialPositionMs: position)
        }
    }

    func speed(_ rate: Double) {
        playbackRate = max(0.5, min(2, rate))
        if statePublished == .playing {
            player.rate = Float(playbackRate)
        }
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func prepareCurrentItem(initialPositionMs: Int) async {
        guard let item = player.currentItem else { return }
        do {
            _ = try await item.asset.load(.duration)
        } catch {
            errorMessage = "Audio could not be loaded."
            statePublished = .paused
            return
        }
        isReadyPublished = true
        if initialPositionMs > 0 { seek(initialPositionMs) }
    }
}
#endif
