import Foundation

enum LearningExpressionLogic {
    struct Segment: Equatable, Identifiable {
        let text: String
        let expressionID: Int?
        var id: String { "\\(expressionID.map(String.init) ?? \"plain\")-\\(text)" }
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
