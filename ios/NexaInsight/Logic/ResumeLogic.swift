import Foundation

// Where to resume an episode, and how to describe that on a list row.
//
// Nothing persisted a playback position before this, so leaving a 3h46m episode
// at 1:20:00 and coming back started it at 0:00. That made the longest content —
// exactly what this app is for — the most punishing to return to.
enum Resume {
    // Treated as "not started". A few seconds in usually means the learner opened
    // the wrong episode, and resuming at 0:03 reads as a bug rather than a memory.
    static let minimumMs = 10_000

    // How close to the end counts as finished. Resuming at 99% would drop you into
    // the outro with no way to tell why, so a finished episode restarts.
    static let completionFraction = 0.98

    // The position to open at. nil means start from the beginning.
    static func startPosition(savedMs: Int?, durationMs: Int?) -> Int? {
        guard let savedMs, savedMs >= minimumMs else { return nil }
        guard let durationMs, durationMs > 0 else { return savedMs }
        return isFinished(savedMs: savedMs, durationMs: durationMs) ? nil : savedMs
    }

    static func isFinished(savedMs: Int, durationMs: Int) -> Bool {
        guard durationMs > 0 else { return false }
        return Double(savedMs) / Double(durationMs) >= completionFraction
    }

    // Whether a position is worth writing. Saving on every tick would mean a
    // SwiftData write several times a second for the whole session.
    static func shouldPersist(newMs: Int, lastSavedMs: Int?, minimumDeltaMs: Int = 5_000) -> Bool {
        guard let lastSavedMs else { return newMs >= minimumMs }
        return abs(newMs - lastSavedMs) >= minimumDeltaMs
    }

    // Fraction for a progress bar on a list row, or nil when there is nothing
    // worth showing — an untouched episode gets no bar rather than an empty one.
    static func progressFraction(savedMs: Int?, durationMs: Int?) -> Double? {
        guard let savedMs, savedMs >= minimumMs,
              let durationMs, durationMs > 0,
              !isFinished(savedMs: savedMs, durationMs: durationMs)
        else { return nil }
        return min(1, Double(savedMs) / Double(durationMs))
    }

    // "1:20:04 / 3:46:18" — the remaining time is what decides whether to start
    // now, so both halves are shown rather than a bare percentage.
    static func progressText(savedMs: Int?, durationMs: Int?) -> String? {
        guard progressFraction(savedMs: savedMs, durationMs: durationMs) != nil,
              let savedMs, let durationMs
        else { return nil }
        return "\(clockText(savedMs)) / \(clockText(durationMs))"
    }

    // Hours appear only when the content has them, so a 20-minute video reads
    // "18:42" rather than "0:18:42".
    static func clockText(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
