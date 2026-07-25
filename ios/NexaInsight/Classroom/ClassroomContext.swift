import Foundation

func contextText(_ window: [SentenceDTO]) -> String {
    window.map { item in
        let seconds = String(format: "%.1f", Double(item.startMs) / 1000.0)
        return "[\(seconds)s] \(item.speaker ?? "Speaker"): \(item.sourceText) / \(item.chinese)"
    }.joined(separator: "\n")
}

func classroomContext(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO], atMs: Int, radius: Int = 6) -> String {
    let sortedChapters = chapters.sorted { $0.startMs < $1.startMs }
    var current = sortedChapters.first { $0.startMs <= atMs && atMs < $0.endMs }
    if current == nil { current = sortedChapters.last { $0.startMs <= atMs } ?? sortedChapters.first }
    let window = subtitleWindow(sentences, atMs, radius: radius)
    let transcript = contextText(window)
    let outline = sortedChapters.map { item in
        let minutes = String(format: "%.1f", Double(item.startMs) / 60000.0)
        return "- [\(minutes)m] \(item.title): \(item.summary)"
    }.joined(separator: "\n")
    let outlineText = outline.isEmpty ? "- No chapter outline is available yet." : outline
    let currentTopic = current.map { "\($0.title): \($0.summary)" }
        ?? "No chapter is available; rely on the transcript window."
    let transcriptText = transcript.isEmpty ? "No nearby transcript is available." : transcript
    return """
    Episode: \(episodeTitle ?? "Untitled") · \(channel ?? "Unknown channel")

    Episode map:
    \(outlineText)

    Current chapter:
    \(currentTopic)

    Current transcript window:
    \(transcriptText)
    """
}
