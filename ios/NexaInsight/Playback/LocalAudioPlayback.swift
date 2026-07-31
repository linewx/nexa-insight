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
        configureAudioSession(voiceMode: false)
    }

    // Voice mode is required whenever the realtime classroom holds the mic:
    // `.playback` forbids recording outright, and without `.voiceChat`'s echo
    // cancellation the podcast leaking from the speaker into the mic keeps
    // tripping the model's VAD — the source would pause at random instead of
    // when the learner speaks. It costs some fidelity (voice-tuned processing),
    // so the session switches back to `.playback` when the class ends.
    func configureAudioSession(voiceMode: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if voiceMode {
                // `.voiceChat` already implies Bluetooth HFP routing, so there is
                // no need for an explicitly deprecated option to get headsets.
                //
                // `.defaultToSpeaker` must NOT be set unconditionally: it forces
                // output to the BUILT-IN SPEAKER even when headphones/AirPods are
                // connected, so currentRoute() then reports .builtInSpeaker and the
                // headphone gate blocks Live for a learner who is wearing them. It
                // only exists to keep `.playAndRecord` off the earpiece when there
                // is nothing plugged in, so apply it only in that case.
                let onHeadphones = Self.headphonesAttached(session)
                let options: AVAudioSession.CategoryOptions = onHeadphones ? [] : [.defaultToSpeaker]
                try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
            } else {
                try session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
            }
            try session.setActive(true)
        } catch {
            // A failed switch leaves the previous category in place; playback
            // keeps working, so this is not worth surfacing to the learner.
        }
    }

    // Which kind of output is active. Live is gated on headphones because on the
    // speaker the teacher's voice reaches the mic and self-triggers the VAD — see
    // AudioRouteLogic. AirPlay counts as a speaker: it's a room device, so the
    // coupling is the same (or worse, with latency).
    // Whether headphones are physically attached, independent of where audio is
    // currently being ROUTED. This must not read currentRoute.outputs: while
    // `.defaultToSpeaker` is in effect that reports the built-in speaker even with
    // AirPods connected, which is the circular reasoning that blocked Live. The
    // available inputs list still shows the headset, so ask that instead.
    private static func headphonesAttached(_ session: AVAudioSession) -> Bool {
        let headphonePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio, .carAudio,
        ]
        if session.currentRoute.outputs.contains(where: { headphonePorts.contains($0.portType) }) {
            return true
        }
        // A wired headset / AirPods also expose a matching INPUT port, which stays
        // visible regardless of the output override.
        let headsetInputs: Set<AVAudioSession.Port> = [.headsetMic, .bluetoothHFP, .usbAudio]
        return (session.availableInputs ?? []).contains { headsetInputs.contains($0.portType) }
    }

    func currentRoute() -> AudioRouteKind {
        let session = AVAudioSession.sharedInstance()
        // Ask about attachment, not the active output override — see
        // headphonesAttached. Reading outputs alone made Live unavailable while
        // wearing AirPods, because voice mode had forced output to the speaker.
        if Self.headphonesAttached(session) {
            NexaLog.log("ROUTE headphones attached -> .headphones (Live allowed)")
            return .headphones
        }
        let outputs = session.currentRoute.outputs
        guard let port = outputs.first?.portType else {
            NexaLog.log("ROUTE none reported -> .unknown (Live blocked)")
            return .unknown
        }
        switch port {
        case .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
             .usbAudio, .carAudio:
            NexaLog.log("ROUTE \(port.rawValue) -> .headphones (Live allowed)")
            return .headphones
        default:
            NexaLog.log("ROUTE \(port.rawValue) -> .speaker (Live blocked)")
            return .speaker
        }
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
