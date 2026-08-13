import Foundation

/// One expression the model returned for a single sentence, before it becomes a
/// stored note.
///
/// Parsing lives apart from the network call because this is where the model
/// misbehaves in ways worth pinning down in tests: it wraps JSON in fences, it
/// invents keys, it answers in English where Chinese was demanded, and it returns
/// a `pattern` with no slots. The backend learned each of these the hard way and
/// validates them; on-demand extraction has to do the same or notes made offline
/// would be worse than the ones made in the pipeline.
struct ExtractedExpression: Equatable {
    var text: String
    var type: LearningExpressionType
    var chinese: String
    var pronunciation: String?
    var example: String
    var exampleChinese: String
    var heardAs: String?
    var restored: String?
    var whyHard: String?
    var whenToUse: String?
    var commonMistake: String?
    var formality: String?
    /// Which of the offered lines the model decided the question was about. Nil
    /// when the question was not about any of them, in which case the note is kept
    /// without an anchor rather than pinned to a guess.
    var sentencePosition: Int?
}

enum ExtractionParseError: LocalizedError, Equatable {
    case notJSON
    case noUsableExpression

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "\u{62bd}\u{53d6}\u{7ed3}\u{679c}\u{683c}\u{5f0f}\u{65e0}\u{6548}\u{ff0c}\u{8bf7}\u{91cd}\u{8bd5}\u{3002}"
        case .noUsableExpression:
            return "\u{8fd9}\u{53e5}\u{6ca1}\u{6709}\u{503c}\u{5f97}\u{5355}\u{72ec}\u{8bb0}\u{7684}\u{8868}\u{8fbe}\u{3002}"
        }
    }
}

enum ExtractionResponse {
    /// Strips the fences the model adds despite being asked for bare JSON.
    static func unfenced(_ text: String) -> String {
        text.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a string is meaningfully Chinese.
    ///
    /// The prompt demands Chinese for the explanation fields and the model ignores
    /// it often enough that the backend measures the ratio rather than trusting it
    /// — an English sentence in `why_hard` is worse than none, because it is the
    /// field the learner reads first.
    static func isChinese(_ text: String) -> Bool {
        let stripped = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard !stripped.isEmpty else { return false }
        let han = stripped.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        return Double(han.count) / Double(stripped.count) >= 0.3
    }

    /// IPA sometimes arrives wrapped in slashes even though the prompt forbids it,
    /// and the card adds its own, which produced "//həˈloʊ//".
    static func cleanedPronunciation(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\t"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// - Parameter host: the sentence the note is for. Used to keep only
    ///   expressions that actually occur in it, which is the same rule the
    ///   pipeline applies — an invented expression gets dropped rather than
    ///   highlighted in the wrong place.
    static func parse(_ raw: String, host: String) throws -> [ExtractedExpression] {
        try parse(raw, candidates: [host])
    }

    /// Routes one reply to either a vocabulary card or a kept answer.
    ///
    /// - Parameter candidates: the lines offered to the model, in the order they
    ///   were numbered. A spoken question does not say which line it is about, so
    ///   several are sent and `sentence_position` indexes into this list. An
    ///   expression is kept if it occurs in ANY of them — the model's chosen index
    ///   is a hint, not the authority, exactly as in the batch pipeline.
    static func parse(_ raw: String, candidates: [String]) throws -> [ExtractedExpression] {
        let cleaned = unfenced(raw)
        guard let data = cleaned.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ExtractionParseError.notJSON }

        let items = root["expressions"] as? [[String: Any]] ?? []
        let parsed = items.compactMap { item -> ExtractedExpression? in
            let reported = (item["sentence_position"] as? Int)
                ?? (item["sentence_position"] as? String).flatMap(Int.init)
            // Look in the reported line first, then everywhere else. The model's
            // index was unreliable enough in the pipeline to drop 37 of 45 valid
            // expressions when trusted outright.
            let ordered: [(offset: Int, text: String)] = {
                let all = Array(candidates.enumerated()).map { (offset: $0.offset, text: $0.element) }
                guard let reported, candidates.indices.contains(reported) else { return all }
                return [all[reported]] + all.filter { $0.offset != reported }
            }()
            let located = ordered.first { ExpressionLocator.locate(
                (item["text"] as? String) ?? "", in: $0.text) != nil }
            let host = located?.text ?? candidates.first ?? ""

            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  // At most 6 words, unless it is a slot pattern whose frame is the
                  // point. Same cap as the batch prompt: a quoted whole sentence
                  // teaches nothing transferable.
                  text.split(whereSeparator: \.isWhitespace).count <= 6 || text.contains("{"),
                  // Must really be in the line, so there is something to anchor to
                  // — except for a slot pattern, whose braces are placeholders and
                  // by definition never appear literally in the transcript.
                  // Dropping those lost every pattern, the one type whose whole
                  // value is being reusable. They are kept and simply go
                  // un-highlighted, which is what the pipeline does too: the row
                  // survives, the occurrence is skipped.
                  text.contains("{") || ExpressionLocator.locate(text, in: host) != nil
            else { return nil }

            let rawType = (item["type"] as? String)?.lowercased() ?? ""
            var type = LearningExpressionType(rawValue: rawType) ?? .phrase
            // A pattern without slots is not reusable, so it is demoted rather
            // than shown as a frame the learner cannot fill.
            if type == .pattern, !text.contains("{") { type = .phrase }

            let chinese = (item["chinese"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !chinese.isEmpty else { return nil }

            func chineseField(_ key: String) -> String? {
                guard let value = (item[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty, isChinese(value) else { return nil }
                return value
            }
            func plainField(_ key: String) -> String? {
                guard let value = (item[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty else { return nil }
                return value
            }

            return ExtractedExpression(
                text: text,
                type: type,
                chinese: chinese,
                pronunciation: cleanedPronunciation(item["pronunciation"] as? String),
                // Falling back to the host sentence keeps the card's example
                // truthful when the model paraphrases instead of quoting.
                example: plainField("example") ?? host,
                exampleChinese: plainField("example_chinese") ?? "",
                heardAs: plainField("heard_as"),
                restored: plainField("restored"),
                whyHard: chineseField("why_hard"),
                whenToUse: chineseField("when_to_use"),
                commonMistake: plainField("common_mistake"),
                formality: plainField("formality"),
                // Where the text was actually found, not where the model said it
                // was. When only the model's claim exists (a slot pattern, which
                // never occurs literally), fall back to that.
                sentencePosition: located?.offset ?? reported)
        }

        guard !parsed.isEmpty else { throw ExtractionParseError.noUsableExpression }
        return parsed
    }
}
