import CoreGraphics
import Foundation

func activeSentence(_ sentences: [SentenceDTO], _ currentMs: Int) -> SentenceDTO? {
    var active: SentenceDTO?
    for item in sentences {
        if item.startMs <= currentMs { active = item } else { break }
    }
    return active
}

func subtitleWindow(_ sentences: [SentenceDTO], _ currentMs: Int, radius: Int = 2) -> [SentenceDTO] {
    if sentences.isEmpty { return [] }
    var precedingIndex = -1
    for (index, item) in sentences.enumerated() where item.startMs <= currentMs {
        precedingIndex = index
    }
    let index = max(0, precedingIndex)
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
