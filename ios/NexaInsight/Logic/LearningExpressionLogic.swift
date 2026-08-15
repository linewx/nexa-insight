import Foundation

enum LearningExpressionLogic {
    struct Segment: Equatable, Identifiable {
        let text: String
        let expressionID: Int?
        var id: String { "\(expressionID.map(String.init) ?? "plain")-\(text)" }
    }

    /// Scheme for per-expression links.
    ///
    /// No longer embedded in the transcript: an interactive `Text` is what an
    /// episode with expressions paid on every row of every frame, and the card
    /// stack under each paragraph reaches the same cards. Kept because the URL
    /// round-trip is still the way an expression id travels when one is needed.
    static let expressionURLScheme = "nexa-expression"

    static func expressionURL(_ expressionID: Int) -> URL? {
        URL(string: "\(expressionURLScheme)://\(expressionID)")
    }

    /// The expression a tapped link refers to, or nil when the URL is not ours
    /// (a real http link in the transcript must still open normally).
    static func expressionID(fromURL url: URL) -> Int? {
        guard url.scheme == expressionURLScheme else { return nil }
        guard let host = url.host, let id = Int(host) else { return nil }
        return id
    }

    /// The transcript sentence as one attributed run-set: highlighted expressions
    /// carry emphasis, everything else is plain.
    static func attributedSentence(
        segments: [Segment],
        highlight: (inout AttributedSubstring) -> Void = { _ in }
    ) -> AttributedString {
        var output = AttributedString()
        for segment in segments {
            let piece = AttributedString(segment.text)
            let start = output.endIndex
            output.append(piece)
            if segment.expressionID != nil {
                // The subscript is passed STRAIGHT to the callback. Assigning the slice to
                // a variable first and mutating that writes to a copy and is silently
                // lost — verified both ways in isolation. The original code did exactly
                // that, on a local `piece` thrown away a line later: the callback ran, the
                // colour was set, nothing kept it. Highlights had not rendered since,
                // while every test passed, because they only checked WHICH text the
                // callback was handed and never whether the styling stuck.
                highlight(&output[start..<output.endIndex])
            }
        }
        return output
    }


    /// Occurrences grouped by the sentence they belong to.
    ///
    /// Built once per transcript instead of per row. Reading mode was scanning
    /// EVERY expression's EVERY occurrence for EVERY visible row on EVERY redraw —
    /// on a 681-sentence episode with 137 expressions that is tens of thousands of
    /// comparisons per frame, which is what made scrolling stutter.
    struct Index {
        fileprivate let bySentence: [Int: [(expressionID: Int, start: Int, end: Int)]]

        init(_ expressions: [LearningExpressionDTO]) {
            var map: [Int: [(expressionID: Int, start: Int, end: Int)]] = [:]
            for expression in expressions {
                for occurrence in expression.occurrences where occurrence.startOffset < occurrence.endOffset {
                    guard occurrence.startOffset >= 0 else { continue }
                    map[occurrence.sentenceId, default: []].append(
                        (expression.id, occurrence.startOffset, occurrence.endOffset))
                }
            }
            // Sorted here rather than per row: same order the unindexed path used,
            // longest-wins on a tie.
            bySentence = map.mapValues { matches in
                matches.sorted {
                    $0.start == $1.start ? ($0.end - $0.start) > ($1.end - $1.start) : $0.start < $1.start
                }
            }
        }

        func has(sentenceId: Int) -> Bool { bySentence[sentenceId] != nil }
    }

    /// Indexed variant. Same result as the scanning version, without the per-row
    /// scan over every expression.
    static func segments(for source: String, sentenceId: Int, index: Index) -> [Segment] {
        guard let candidates = index.bySentence[sentenceId] else {
            return [Segment(text: source, expressionID: nil)]
        }
        let characters = Array(source)
        var accepted: [(expressionID: Int, start: Int, end: Int)] = []
        var cursor = 0
        for match in candidates where match.start >= cursor && match.end <= characters.count {
            accepted.append(match)
            cursor = match.end
        }
        guard !accepted.isEmpty else { return [Segment(text: source, expressionID: nil)] }

        // Slicing an Array<Character> rather than dropFirst/prefix on the String:
        // those walk from the start every time, making the cost quadratic in the
        // number of highlights.
        var output: [Segment] = []
        cursor = 0
        for match in accepted {
            if cursor < match.start {
                output.append(Segment(text: String(characters[cursor..<match.start]), expressionID: nil))
            }
            output.append(Segment(text: String(characters[match.start..<match.end]), expressionID: match.expressionID))
            cursor = match.end
        }
        if cursor < characters.count {
            output.append(Segment(text: String(characters[cursor...]), expressionID: nil))
        }
        return output
    }

    static func segments(for source: String, sentenceId: Int, expressions: [LearningExpressionDTO]) -> [Segment] {
        struct Match {
            let expressionID: Int
            let start: Int
            let end: Int
        }

        let characterCount = source.count
        var matches: [Match] = []
        for expression in expressions {
            for occurrence in expression.occurrences {
                guard occurrence.sentenceId == sentenceId,
                      0 <= occurrence.startOffset,
                      occurrence.startOffset < occurrence.endOffset,
                      occurrence.endOffset <= characterCount else { continue }
                matches.append(Match(expressionID: expression.id, start: occurrence.startOffset, end: occurrence.endOffset))
            }
        }
        matches.sort {
            $0.start == $1.start ? ($0.end - $0.start) > ($1.end - $1.start) : $0.start < $1.start
        }

        var accepted: [Match] = []
        var cursor = 0
        for match in matches where match.start >= cursor {
            accepted.append(match)
            cursor = match.end
        }
        guard !accepted.isEmpty else { return [Segment(text: source, expressionID: nil)] }

        var output: [Segment] = []
        cursor = 0
        for match in accepted {
            if cursor < match.start {
                output.append(Segment(text: String(source.dropFirst(cursor).prefix(match.start - cursor)), expressionID: nil))
            }
            output.append(Segment(text: String(source.dropFirst(match.start).prefix(match.end - match.start)), expressionID: match.expressionID))
            cursor = match.end
        }
        if cursor < characterCount {
            output.append(Segment(text: String(source.dropFirst(cursor)), expressionID: nil))
        }
        return output
    }
}
