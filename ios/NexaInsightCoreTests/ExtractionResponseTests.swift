import XCTest
@testable import NexaInsightCore

/// Each case here is a way the model actually misbehaves — the same ones the
/// backend validates for, since on-demand notes must not be worse than pipeline
/// ones.
final class ExtractionResponseTests: XCTestCase {
    private let host = "We need to rethink how we work."

    private func payload(_ body: String) -> String {
        "{\"expressions\":[\(body)]}"
    }

    func testParsesAWellFormedExpression() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"rethink how","type":"syntax","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}\u{5982}\u{4f55}",
             "pronunciation":"riːˈθɪŋk","example":"We need to rethink how we work.",
             "example_chinese":"\u{6211}\u{4eec}\u{9700}\u{8981}\u{91cd}\u{65b0}\u{601d}\u{8003}\u{3002}",
             "why_hard":"\u{4ece}\u{53e5}\u{7ed3}\u{6784}\u{5bb9}\u{6613}\u{8bfb}\u{9519}\u{3002}","formality":"neutral"}
            """), host: host)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "rethink how")
        XCTAssertEqual(result[0].type, .syntax)
        XCTAssertEqual(result[0].pronunciation, "riːˈθɪŋk")
        XCTAssertNotNil(result[0].whyHard)
    }

    func testStripsCodeFencesTheModelAddsAnyway() throws {
        let fenced = "```json\n" + payload("""
            {"text":"rethink how","type":"idiom","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}"}
            """) + "\n```"
        XCTAssertEqual(try ExtractionResponse.parse(fenced, host: host).count, 1)
    }

    func testDropsAnExpressionAbsentFromTheSentence() {
        // Nothing to anchor: a note on words that are not there would float, or
        // worse, highlight something unrelated.
        XCTAssertThrowsError(try ExtractionResponse.parse(payload("""
            {"text":"thanks so much","type":"phrase","chinese":"\u{591a}\u{8c22}"}
            """), host: host)) { error in
            XCTAssertEqual(error as? ExtractionParseError, .noUsableExpression)
        }
    }

    func testRejectsAWholeSentenceQuotedAsAnExpression() {
        XCTAssertThrowsError(try ExtractionResponse.parse(payload("""
            {"text":"We need to rethink how we work","type":"phrase","chinese":"\u{6574}\u{53e5}"}
            """), host: host))
    }

    func testKeepsALongPatternBecauseTheFrameIsThePoint() throws {
        let frameHost = "I can't change the market, but I can change my product."
        let result = try ExtractionResponse.parse(payload("""
            {"text":"I can't change {X}, but I can change {Y}","type":"pattern",
             "chinese":"\u{6211}\u{6539}\u{4e0d}\u{4e86}X，\u{4f46}\u{6539}\u{5f97}\u{4e86}Y",
             "when_to_use":"\u{8c08}\u{53ef}\u{63a7}\u{4e0e}\u{4e0d}\u{53ef}\u{63a7}\u{65f6}\u{3002}"}
            """), host: frameHost)
        // Over six words and its braces appear nowhere in the transcript, yet it
        // must survive: the frame is the transferable part. It simply gets no
        // highlight, the same trade the pipeline makes.
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].type, .pattern)
        XCTAssertNotNil(result[0].whenToUse)
    }

    func testPatternWithoutSlotsIsDemotedToPhrase() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"rethink how","type":"pattern","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}"}
            """), host: host)
        XCTAssertEqual(result[0].type, .phrase)
    }

    func testEnglishInAChineseOnlyFieldIsDroppedRatherThanShown() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"rethink how","type":"syntax","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}",
             "why_hard":"The subordinate clause is hard to parse."}
            """), host: host)
        XCTAssertNil(result[0].whyHard, "an English why_hard is worse than none")
    }

    func testUnknownTypeFallsBackRatherThanFailing() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"rethink how","type":"phrasal verb (YC term)","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}"}
            """), host: host)
        XCTAssertEqual(result[0].type, .phrase)
    }

    func testInventedKeysAreIgnored() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"rethink how","type":"idiom","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}",
             "confidence":0.9,"difficulty":"B2","start_offset":3,"end_offset":9}
            """), host: host)
        XCTAssertEqual(result.count, 1)
    }

    func testSlashWrappedIPAIsUnwrapped() {
        XCTAssertEqual(ExtractionResponse.cleanedPronunciation("/həˈloʊ/"), "həˈloʊ")
        XCTAssertNil(ExtractionResponse.cleanedPronunciation("//"))
        XCTAssertNil(ExtractionResponse.cleanedPronunciation(nil))
    }

    func testMissingExampleFallsBackToTheSentenceItself() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"rethink how","type":"idiom","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}"}
            """), host: host)
        XCTAssertEqual(result[0].example, host)
    }

    func testEmptyExpressionsArrayMeansNothingWorthNoting() {
        XCTAssertThrowsError(try ExtractionResponse.parse("{\"expressions\":[]}", host: host)) { error in
            XCTAssertEqual(error as? ExtractionParseError, .noUsableExpression)
        }
    }

    func testNonJSONIsReportedAsSuch() {
        XCTAssertThrowsError(try ExtractionResponse.parse("I'm sorry, I can't help with that.", host: host)) { error in
            XCTAssertEqual(error as? ExtractionParseError, .notJSON)
        }
    }

    // MARK: - Spoken questions, where the target line has to be inferred

    private var lines: [String] {
        [
            "They both signed up to it.",
            "What they wrote is not what shipped.",
            "We need to rethink how we work.",
        ]
    }

    func testPicksTheLineTheExpressionActuallyOccursIn() throws {
        // The model said line 0; the words are in line 1. The text wins, because a
        // reported index was wrong often enough in the pipeline to drop 37 of 45
        // valid expressions when trusted.
        let result = try ExtractionResponse.parse(payload("""
            {"text":"what they wrote","type":"syntax","chinese":"\u{4ed6}\u{4eec}\u{5199}\u{7684}",
             "sentence_position":0}
            """), candidates: lines)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].sentencePosition, 1)
    }

    func testKeepsAnExpressionFromAnyOfferedLine() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"rethink how","type":"idiom","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}","sentence_position":2}
            """), candidates: lines)
        XCTAssertEqual(result[0].sentencePosition, 2)
    }

    func testDropsAnExpressionInNoneOfTheOfferedLines() {
        XCTAssertThrowsError(try ExtractionResponse.parse(payload("""
            {"text":"link in the description","type":"phrase","chinese":"\u{7b80}\u{4ecb}\u{6807}\u{6ce8}"}
            """), candidates: lines))
    }

    func testOutOfRangePositionFallsBackToSearchingEveryLine() throws {
        // 99 is not a line. Ignoring the index rather than failing keeps the note.
        let result = try ExtractionResponse.parse(payload("""
            {"text":"signed up to it","type":"phrase","chinese":"\u{90fd}\u{540c}\u{610f}\u{4e86}","sentence_position":99}
            """), candidates: lines)
        XCTAssertEqual(result[0].sentencePosition, 0)
    }

    func testStringPositionIsAccepted() throws {
        // The model returns "1" instead of 1 often enough to handle here.
        let result = try ExtractionResponse.parse(payload("""
            {"text":"what they wrote","type":"syntax","chinese":"\u{4ed6}\u{4eec}\u{5199}\u{7684}",
             "sentence_position":"1"}
            """), candidates: lines)
        XCTAssertEqual(result[0].sentencePosition, 1)
    }

    func testGeneralQuestionWithNoPositionKeepsTheNoteUnanchored() throws {
        // "How do what-clauses work" is not about any one line. A slot pattern has
        // no literal occurrence either, so it survives with no position rather than
        // being pinned to a guess.
        let result = try ExtractionResponse.parse(payload("""
            {"text":"what {clause} is not what {result}","type":"pattern",
             "chinese":"\u{6240}\u{5199}\u{975e}\u{6240}\u{505a}",
             "when_to_use":"\u{5bf9}\u{6bd4}\u{8ba1}\u{5212}\u{4e0e}\u{7ed3}\u{679c}\u{65f6}\u{3002}"}
            """), candidates: lines)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].sentencePosition)
    }

    func testExampleFallsBackToTheLineTheExpressionWasFoundIn() throws {
        let result = try ExtractionResponse.parse(payload("""
            {"text":"what they wrote","type":"syntax","chinese":"\u{4ed6}\u{4eec}\u{5199}\u{7684}"}
            """), candidates: lines)
        XCTAssertEqual(result[0].example, "What they wrote is not what shipped.")
    }

    func testChineseDetectionAcceptsMixedTextButRejectsPlainEnglish() {
        XCTAssertTrue(ExtractionResponse.isChinese("\u{8fd9}\u{91cc} clause \u{5f88}\u{96be}"))
        XCTAssertFalse(ExtractionResponse.isChinese("hard to parse"))
        XCTAssertFalse(ExtractionResponse.isChinese("   "))
    }
}
