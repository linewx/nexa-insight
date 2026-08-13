import XCTest
@testable import NexaInsightCore

final class KnowledgePointExtractorTests: XCTestCase {
    private let lines = ["He kind of wanted to bail on the whole thing.", "Bye now"]

    // MARK: - Keeping nothing

    // The point of the whole type. Most talk about a paragraph leaves nothing durable,
    // and the old path had no way to say so — every question became a card, so the
    // stack filled with "I asked about this once".
    func testAnEmptyPointsArrayIsANormalResult() {
        let points = KnowledgePointExtractor.points(#"{"points":[]}"#, candidates: lines)
        XCTAssertTrue(points.isEmpty)
    }

    // Unparseable output yields nothing rather than throwing. The learner already heard
    // and read the answer; there is nothing to apologise for. This is the deliberate
    // difference from outcome(_:candidates:), whose noUsableExpression was a failure
    // dialog for what was often a correct judgement.
    func testGarbageYieldsNothingRatherThanAnError() {
        XCTAssertTrue(KnowledgePointExtractor.points("not json at all", candidates: lines).isEmpty)
        XCTAssertTrue(KnowledgePointExtractor.points("", candidates: lines).isEmpty)
        XCTAssertTrue(KnowledgePointExtractor.points(#"{"wrong":"shape"}"#, candidates: lines).isEmpty)
    }

    func testAQuestionCardWithNoAnswerIsDropped() {
        let raw = #"{"points":[{"kind":"question","question":"这是什么意思","answer":"  "}]}"#
        XCTAssertTrue(KnowledgePointExtractor.points(raw, candidates: lines).isEmpty)
    }

    // MARK: - Question points

    func testQuestionPointKeepsWhatWasAskedAndConcluded() {
        let raw = """
            {"points":[{"kind":"question","question":"bail on 在这里是什么意思",
            "answer":"放弃、退出某件事。"}]}
            """
        let points = KnowledgePointExtractor.points(raw, candidates: lines)
        XCTAssertEqual(points, [.question(question: "bail on 在这里是什么意思", answer: "放弃、退出某件事。")])
    }

    // Same fallback as QuestionIntent: an unknown kind becomes a question card rather
    // than being discarded. An answer shown as a note is useful; an answer thrown away
    // is not.
    func testUnknownKindFallsBackToAQuestionCard() {
        let raw = #"{"points":[{"kind":"wat","question":"q","answer":"a"}]}"#
        XCTAssertEqual(KnowledgePointExtractor.points(raw, candidates: lines),
                       [.question(question: "q", answer: "a")])
    }

    // MARK: - Vocabulary points

    // The question travels with the card. The old vocabulary path passed request: nil,
    // so a card found a week later gave no hint why it had been wanted.
    func testVocabularyPointCarriesTheQuestion() {
        let raw = """
            {"points":[{"kind":"vocabulary","text":"kind of","type":"phrase",
            "chinese":"有点儿","example":"He kind of wanted to bail.",
            "example_chinese":"他有点想放弃。","question":"kind of 怎么用"}]}
            """
        let points = KnowledgePointExtractor.points(raw, candidates: lines)
        guard case let .vocabulary(expression, question) = points.first else {
            return XCTFail("expected a vocabulary point, got \(points)")
        }
        XCTAssertEqual(expression.text, "kind of")
        XCTAssertEqual(expression.chinese, "有点儿")
        XCTAssertEqual(question, "kind of 怎么用")
    }

    // Validation is reused rather than reimplemented, so the rules learned the hard way
    // still hold here: a whole sentence quoted back is not a reusable expression.
    func testVocabularyPointStillObeysTheSixWordCap() {
        let raw = """
            {"points":[{"kind":"vocabulary",
            "text":"He kind of wanted to bail on the whole thing",
            "type":"phrase","chinese":"他有点想放弃","example":"x","example_chinese":"y"}]}
            """
        XCTAssertTrue(KnowledgePointExtractor.points(raw, candidates: lines).isEmpty)
    }

    func testVocabularyPointMustOccurInTheParagraph() {
        let raw = """
            {"points":[{"kind":"vocabulary","text":"utterly invented","type":"phrase",
            "chinese":"编造的","example":"x","example_chinese":"y"}]}
            """
        XCTAssertTrue(KnowledgePointExtractor.points(raw, candidates: lines).isEmpty)
    }

    // One bad point must not take the good ones with it.
    func testAnInvalidPointDropsItselfNotTheConversation() {
        let raw = """
            {"points":[
            {"kind":"vocabulary","text":"nowhere near this text","type":"phrase",
            "chinese":"无","example":"x","example_chinese":"y"},
            {"kind":"question","question":"q","answer":"a"}]}
            """
        XCTAssertEqual(KnowledgePointExtractor.points(raw, candidates: lines),
                       [.question(question: "q", answer: "a")])
    }

    func testFencedJSONIsTolerated() {
        let raw = """
            ```json
            {"points":[{"kind":"question","question":"q","answer":"a"}]}
            ```
            """
        XCTAssertEqual(KnowledgePointExtractor.points(raw, candidates: lines),
                       [.question(question: "q", answer: "a")])
    }

    // MARK: - Conversation rendering

    // Roles are labelled because who said what changes the meaning entirely. Given an
    // unlabelled blob a model will happily keep the learner's own wrong guess as the
    // conclusion.
    func testConversationTextLabelsWhoSpoke() {
        let text = KnowledgePointExtractor.conversationText([
            TutorTurn(role: .user, text: "这个 that 指什么"),
            TutorTurn(role: .assistant, text: "指前面那个从句"),
        ])
        XCTAssertEqual(text, "LEARNER: 这个 that 指什么\nTEACHER: 指前面那个从句")
    }

    func testSystemTurnsAreNotPartOfWhatWasDiscussed() {
        let text = KnowledgePointExtractor.conversationText([
            TutorTurn(role: .system, text: "context refreshed"),
            TutorTurn(role: .user, text: "q"),
        ])
        XCTAssertEqual(text, "LEARNER: q")
    }
}
