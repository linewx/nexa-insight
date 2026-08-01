import Foundation

// Parses the ISO 8601 durations the YouTube Data API returns ("PT3H46M18S").
//
// Measured shapes from live responses: PT3H46M18S, PT2H53M43S, PT1M, PT42S.
// Note PT1M — a component that is zero is OMITTED, not sent as zero, so a
// fixed-format parse would fail on most videos.
//
// This replaces nothing: the scraped pages give pre-formatted display strings
// ("2:19:34") in the viewer's locale, while the API gives a machine duration we
// format ourselves. That is why formatting lives here rather than in the parser.
enum ISO8601Duration {
    // Returns nil for anything that is not a parseable duration. P0D appears for
    // some live/upcoming items (not seen in the two channels measured, but
    // documented), and is treated as unknown rather than as a zero-length video.
    static func seconds(_ text: String?) -> Int? {
        guard let text, text.hasPrefix("PT") else { return nil }

        var total = 0
        var digits = ""
        var sawComponent = false

        for character in text.dropFirst(2) {
            if character.isNumber {
                digits.append(character)
                continue
            }
            guard let value = Int(digits) else { return nil }
            switch character {
            case "H": total += value * 3600
            case "M": total += value * 60
            case "S": total += value
            default: return nil   // days/weeks in a video duration means we
                                  // misread the string; refuse rather than guess
            }
            digits = ""
            sawComponent = true
        }
        // Trailing digits with no unit ("PT12") is malformed.
        guard digits.isEmpty, sawComponent else { return nil }
        return total
    }

    // "3:46:18" / "18:42" / "0:45" — the same shape the scraped pages produce, so
    // cards look identical whichever source they came from.
    static func displayText(_ text: String?) -> String? {
        guard let total = seconds(text), total > 0 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    // YouTube's own Shorts ceiling. Unknown durations are NOT shorts: dropping a
    // real episode is worse than letting one short clip through, and the caller
    // cannot tell the difference after the fact.
    static func isShort(_ text: String?, maxSeconds: Int = 60) -> Bool {
        guard let total = seconds(text), total > 0 else { return false }
        return total <= maxSeconds
    }
}
