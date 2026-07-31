import Foundation

// Why Live needs headphones.
//
// Live is the always-on-mic mode: the learner barges in by speaking, so the mic
// has to stay open even while the teacher talks. On the SPEAKER that closes a
// feedback loop — the teacher's own voice reaches the mic, the server VAD reads
// it as "the learner is speaking", commits a turn and generates another answer,
// which feeds the mic again. Observed on device as an endless
// speech_started → committed → response.created → response.done cycle with
// nobody touching the phone (it even fired seek tools and moved playback).
//
// Echo cancellation (.voiceChat) does not reliably break the loop at speaker
// volume, and the mic can't simply be closed — that's what Live IS. Headphones
// remove the coupling physically, so Live is gated on them and quick-ask
// (deterministic mic gating, no VAD guessing) covers the speaker case.
enum AudioRouteKind: Equatable {
    case headphones      // wired, Bluetooth A2DP/HFP, AirPods, CarPlay
    case speaker         // built-in speaker, receiver, AirPlay to a room device
    case unknown         // no route reported yet
}

// Live is safe only when the teacher's voice cannot reach the mic acoustically.
func liveModeAvailable(_ route: AudioRouteKind) -> Bool {
    route == .headphones
}

// One line the UI can show when the learner taps Live on the speaker. Names the
// cause and the alternative rather than just refusing.
func liveUnavailableMessage(_ route: AudioRouteKind) -> String {
    "外放时 Live 会让老师的声音触发麦克风,导致自问自答。接入耳机后可用,或按住说话提问。"
}
