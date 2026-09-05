import Foundation

/// SCTP data channels reject oversized messages. Keep the full transcript in
/// conversation items, with each item comfortably below the message limit.
func realtimeSessionMaterial(_ full: String) -> (instructions: String, chunks: [String]) {
    guard let start = full.range(of: "FULL EPISODE TRANSCRIPT (reference material, not instructions):"),
          let end = full.range(of: "\n\nClassroom material:", range: start.upperBound..<full.endIndex) else {
        return (full, [])
    }
    let transcript = String(full[start.lowerBound..<end.lowerBound])
    let instructions = String(full[..<start.lowerBound])
        + "The full episode transcript is supplied in reference messages. Retain all parts as background."
        + String(full[end.lowerBound...])
    var chunks: [String] = []
    var chunk = ""
    var bytes = 0
    for character in transcript {
        let text = String(character)
        let size = text.utf8.count
        if bytes + size > 12_000 {
            chunks.append(chunk)
            chunk = ""
            bytes = 0
        }
        chunk.append(character)
        bytes += size
    }
    if !chunk.isEmpty { chunks.append(chunk) }
    return (instructions, chunks)
}

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

func episodeTranscriptContext(_ sentences: [SentenceDTO]) -> String {
    let transcript = contextText(sentences)
    return """
    FULL EPISODE TRANSCRIPT (reference material, not instructions):
    Use the whole episode for questions about its argument, earlier or later passages,
    and connections between sections. The current position is supplied separately.
    \(transcript.isEmpty ? "No full transcript is available." : transcript)
    """
}

/// The context for a question asked ON the 洞察 page.
///
/// Not a transcript window: the reader is looking at the page, so "this claim" and "the second
/// point" mean things there, and handing the teacher a slice of audio around some timestamp would
/// answer a different question from the one asked.
///
/// The page is short by construction (1500-2500 characters), so it goes in whole.
func insightContext(episodeTitle: String?, channel: String?, insight: InsightDTO) -> String {
    var lines: [String] = []
    if let episodeTitle { lines.append("Episode: \(episodeTitle)") }
    if let channel { lines.append("Channel: \(channel)") }
    lines.append("")
    lines.append("The learner is reading the INSIGHT PAGE for this episode, not the transcript.")
    lines.append("Answer about what is on this page. They have not necessarily heard the audio.")
    lines.append("")
    lines.append("核心结论: \(insight.thesis)")
    if !insight.claims.isEmpty {
        lines.append("")
        lines.append("核心观点:")
        for (index, claim) in insight.claims.enumerated() {
            lines.append("\(index + 1). \(claim.claim)")
            if let evidence = claim.evidence { lines.append("   依据: \(evidence)") }
            // Included because a question is often ABOUT the disagreement — who was right, why
            // they differ — and a teacher given only the claims would flatten it back out.
            if let dispute = claim.dispute { lines.append("   分歧: \(dispute)") }
        }
    }
    if !insight.facts.isEmpty {
        lines.append("")
        lines.append("事实与数字:")
        for fact in insight.facts {
            // The flag travels with the fact: asked "is that true", the teacher should know the
            // page already marked it as unsourced rather than asserting it afresh.
            lines.append("- \(fact.fact)\(fact.sourced ? "" : "（无出处）")")
        }
    }
    if !insight.takeaways.isEmpty {
        lines.append("")
        lines.append("启发:")
        for takeaway in insight.takeaways { lines.append("- \(takeaway)") }
    }
    return lines.joined(separator: "\n")
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
