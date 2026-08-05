import CoreGraphics
import Foundation

/// Index of the last sentence that has started by `currentMs`, or nil before the
/// first one.
///
/// Binary search, because this runs on every position tick — the player publishes
/// every 200ms — and it decides which row is highlighted, so it drives a redraw of
/// the transcript five times a second. A linear pass over 681 sentences there is
/// the difference between a smooth scroll and a stuttering one.
///
/// Relies on `sentences` being ordered by `startMs`, which is how the pipeline
/// writes them and how `position` is assigned.
func activeSentenceIndex(_ sentences: [SentenceDTO], _ currentMs: Int) -> Int? {
    var low = 0
    var high = sentences.count - 1
    var found: Int?
    while low <= high {
        let mid = (low + high) / 2
        if sentences[mid].startMs <= currentMs {
            found = mid
            low = mid + 1
        } else {
            high = mid - 1
        }
    }
    return found
}

func activeSentence(_ sentences: [SentenceDTO], _ currentMs: Int) -> SentenceDTO? {
    activeSentenceIndex(sentences, currentMs).map { sentences[$0] }
}

func subtitleWindow(_ sentences: [SentenceDTO], _ currentMs: Int, radius: Int = 2) -> [SentenceDTO] {
    if sentences.isEmpty { return [] }
    // The old version had no early exit at all: it walked every sentence to find
    // the last match, on every tick.
    let index = activeSentenceIndex(sentences, currentMs) ?? 0
    let lower = max(0, index - radius)
    let upper = min(sentences.count - 1, index + radius)
    return Array(sentences[lower...upper])
}

func sentenceLoopBoundary(_ sentence: SentenceDTO, _ currentMs: Int) -> Int? {
    currentMs >= sentence.endMs - 100 ? sentence.startMs : nil
}

func formatTime(_ ms: Int) -> String {
    let seconds = ms / 1000
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

func scrollOffsetToCenter(viewportHeight: CGFloat, rowOffsetTop: CGFloat, rowHeight: CGFloat) -> CGFloat {
    max(0, (rowOffsetTop - (viewportHeight - rowHeight) / 2).rounded())
}

func isManualScrollAway(currentScrollTop: CGFloat, targetScrollTop: CGFloat, tolerancePx: CGFloat) -> Bool {
    abs(currentScrollTop - targetScrollTop) > tolerancePx
}
