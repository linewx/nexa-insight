import Foundation

/// Finds where an expression really sits inside its sentence.
///
/// A Swift port of the backend's `locate_expression`. The model reports
/// start/end offsets by counting characters itself and is wrong about 97% of the
/// time — plausibly wrong, so a range check passes and the highlight lands on
/// unrelated words ("Thanks so much" highlighting "Okay, Patrick"). Searching for
/// the text is the only way to be right, and returning nil when it is absent
/// means an invented expression gets no highlight rather than a misleading one.
///
/// This exists in two languages because on-demand extraction runs on the device
/// while batch extraction runs in the pipeline. The behaviour must stay
/// identical, so the tests mirror the Python cases — including the one that
/// motivated the lookaround.
enum ExpressionLocator {
    /// Character offsets into `host`, or nil when the expression is not there.
    ///
    /// Matching ignores case and treats any run of whitespace as equivalent,
    /// because transcripts carry double spaces the model silently normalizes.
    /// Each word may also carry a suffix, so the lemma "work out" still finds
    /// "worked out" — the form actually spoken. The leading boundary keeps that
    /// from reaching inside a longer word, which would otherwise let "work out"
    /// match "network outside".
    static func locate(_ text: String, in host: String) -> Range<Int>? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, !host.isEmpty else { return nil }

        let pattern = "(?<!\\w)" + words
            .map { NSRegularExpression.escapedPattern(for: String($0)) + "\\w*" }
            .joined(separator: "\\s+")

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(host.startIndex..<host.endIndex, in: host)
        guard let match = regex.firstMatch(in: host, options: [], range: range) else { return nil }

        // Offsets are reported in Characters, not UTF-16 units, because that is
        // what the transcript highlighting indexes by — an emoji earlier in the
        // line would otherwise shift every following highlight.
        guard let matched = Range(match.range, in: host) else { return nil }
        let start = host.distance(from: host.startIndex, to: matched.lowerBound)
        let end = host.distance(from: host.startIndex, to: matched.upperBound)
        return start..<end
    }
}
