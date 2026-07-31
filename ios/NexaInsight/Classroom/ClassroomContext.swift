import Foundation

// Renders the transcript window. `currentId` marks the line the learner is
// actually looking at (the highlighted one). Without that marker the window is
// 13 undifferentiated lines and "explain THIS sentence" makes the teacher guess
// — it would usually pick a neighbour instead of the highlighted line.
func contextText(_ window: [SentenceDTO], currentId: Int? = nil) -> String {
    window.map { item in
        let seconds = String(format: "%.1f", Double(item.startMs) / 1000.0)
        let line = "[\(seconds)s] \(item.speaker ?? "Speaker"): \(item.sourceText) / \(item.chinese)"
        return item.id == currentId ? "\(line)    <<< CURRENT LINE" : line
    }.joined(separator: "\n")
}

func classroomContext(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO], atMs: Int, radius: Int = 6) -> String {
    let sortedChapters = chapters.sorted { $0.startMs < $1.startMs }
    var current = sortedChapters.first { $0.startMs <= atMs && atMs < $0.endMs }
    if current == nil { current = sortedChapters.last { $0.startMs <= atMs } ?? sortedChapters.first }
    let window = subtitleWindow(sentences, atMs, radius: radius)
    // Same selection rule the on-screen highlight uses (activeSentence), so the
    // marked line is exactly the line the learner sees highlighted.
    let currentLine = activeSentence(sentences, atMs) ?? sentences.first
    let transcript = contextText(window, currentId: currentLine?.id)
    let outline = sortedChapters.map { item in
        let minutes = String(format: "%.1f", Double(item.startMs) / 60000.0)
        return "- [\(minutes)m] \(item.title): \(item.summary)"
    }.joined(separator: "\n")
    let outlineText = outline.isEmpty ? "- No chapter outline is available yet." : outline
    let currentTopic = current.map { "\($0.title): \($0.summary)" }
        ?? "No chapter is available; rely on the transcript window."
    let transcriptText = transcript.isEmpty ? "No nearby transcript is available." : transcript
    let currentLineText = currentLine.map {
        "[\(String(format: "%.1f", Double($0.startMs) / 1000.0))s] \($0.sourceText) / \($0.chinese)"
    } ?? "Unknown."
    return """
    Episode: \(episodeTitle ?? "Untitled") · \(channel ?? "Unknown channel")

    Episode map:
    \(outlineText)

    Current chapter:
    \(currentTopic)

    THE CURRENT LINE (what "this sentence" / "这句" / "当前这段" refers to — the
    line the learner sees highlighted right now; never resolve it to a neighbour):
    \(currentLineText)

    Current transcript window (surrounding context; the current line is marked):
    \(transcriptText)
    """
}
