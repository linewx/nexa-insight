import Foundation

/// What tapping a sentence should do while reading.
///
/// Reading is eye work, so playback is something you ask for rather than the
/// thing that drives the screen. One tap plays the line you are looking at; a
/// second tap on the same line stops it. Tapping a different line moves there
/// instead of stopping — otherwise reading down the page would need a stop before
/// every play.
enum SentencePlaybackToggle {
    enum Action: Equatable {
        /// Seek to this sentence and play.
        case play(fromMs: Int)
        /// Stop, because this line is already the one playing.
        case stop
    }

    /// - Parameters:
    ///   - tapped: the sentence that was tapped.
    ///   - playingId: id of the sentence the cursor is currently inside, or nil.
    ///   - isPlaying: whether audio is actually advancing. A paused player on the
    ///     same sentence must play rather than stop, or the second tap after a
    ///     pause would appear to do nothing.
    static func action(
        tapped: SentenceDTO,
        playingId: Int?,
        isPlaying: Bool
    ) -> Action {
        if isPlaying, playingId == tapped.id { return .stop }
        return .play(fromMs: tapped.startMs)
    }
}
