import Foundation

enum LearningExpressionLogic {
    struct Segment: Equatable, Identifiable {
        let text: String
        let expressionID: Int?
        var id: String { "\(expressionID.map(String.init) ?? "plain")-\(text)" }
    }

    /// Scheme for the per-expression links embedded in the transcript's
    /// AttributedString. Tapping a highlighted run opens one of these, which the
    /// view intercepts via `OpenURLAction` instead of letting the system handle
    /// it — that is what lets a single native `Text` carry many tap targets, so
    /// wrapping stays SwiftUI's job rather than a hand-rolled Layout's.
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
    /// carry a link plus emphasis, everything else is plain.
    static func attributedSentence(
        segments: [Segment],
        highlight: (inout AttributedSubstring) -> Void = { _ in }
    ) -> AttributedString {
        var output = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            if let expressionID = segment.expressionID, let url = expressionURL(expressionID) {
                piece.link = url
                var whole = piece[piece.startIndex..<piece.endIndex]
                highlight(&whole)
            }
            output.append(piece)
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
