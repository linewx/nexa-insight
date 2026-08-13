import XCTest
@testable import NexaInsightCore

final class ExtractionPromptTests: XCTestCase {
    func testNativeMaterialAsksForTheListeningTypes() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "native")
        XCTAssertTrue(prompt.contains("reduction"))
        XCTAssertTrue(prompt.contains("ellipsis"))
        // Teaching-only types must not leak in: they ask for something the learner
        // is not trying to do with native-speed material.
        XCTAssertFalse(prompt.contains("collocation"))
    }

    func testTeachingMaterialAsksForTheSpeakingTypes() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "teaching")
        XCTAssertTrue(prompt.contains("collocation"))
        XCTAssertFalse(prompt.contains("reduction"))
    }

    func testUnknownMaterialKindFallsBackToNative() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "")
        XCTAssertTrue(prompt.contains("reduction"))
    }

    // The load-bearing part of every extraction prompt. Without it the first version
    // returned greetings and literal domain nouns on every source.
    func testRejectListIsAlwaysPresent() {
        for kind in ["native", "teaching", "nonsense"] {
            let prompt = ExtractionPrompt.conversationRules(materialKind: kind)
            XCTAssertTrue(prompt.contains("REJECT"), "missing for \(kind)")
            XCTAssertTrue(prompt.contains("welcome back"), "missing for \(kind)")
        }
    }

    // The instruction this whole path exists for. A conversation that taught nothing
    // durable must be allowed to leave nothing behind — every question becoming a card
    // is what filled the stack with noise.
    func testKeepingNothingIsExplicitlyPermitted() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "native")
        XCTAssertTrue(prompt.contains("KEEP NOTHING"))
        XCTAssertTrue(prompt.contains("not a failure"))
        XCTAssertTrue(prompt.contains("empty"))
    }

    // A follow-up chain about one thing is one card. Recording per turn would shatter
    // a single understanding into three partial cards.
    func testFollowUpChainIsAskedForAsOneCard() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "native")
        XCTAssertTrue(prompt.contains("ONE card"))
    }

    // Both shapes must be described, or the model picks one and every question about
    // meaning comes back as a failed vocabulary extraction — the original bug.
    func testBothCardShapesAreOffered() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "native")
        XCTAssertTrue(prompt.contains("\"kind\":\"vocabulary\""))
        XCTAssertTrue(prompt.contains("\"kind\":\"question\""))
        XCTAssertTrue(prompt.contains("\"points\""))
    }

    // The vocabulary shape has to actually list its fields. It once said "the fields
    // specified below" and then never specified them, so the parser's required fields
    // were never asked for.
    func testVocabularyFieldsAreSpelledOut() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "native")
        for field in ["chinese", "example_chinese", "pronunciation", "formality"] {
            XCTAssertTrue(prompt.contains(field), "missing \(field)")
        }
    }

    // Batch extraction wraps items in "expressions", this path in "points". The shared
    // fields block must not name either, or it contradicts its caller.
    func testTheSharedFieldsBlockDoesNotNameAWrappingKey() {
        XCTAssertFalse(ExtractionPrompt.fields.contains("expressions"))
    }

    // Offsets from the model were wrong ~97% of the time in the pipeline, so they are
    // computed from the text instead and must never be requested.
    func testOffsetsAreNeverRequested() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "native")
        XCTAssertTrue(prompt.contains("Do NOT return character offsets"))
    }

    // An answer read a week later cannot lean on the conversation that produced it.
    func testAnswersMustStandAloneLater() {
        let prompt = ExtractionPrompt.conversationRules(materialKind: "native")
        XCTAssertTrue(prompt.contains("read cold"))
        XCTAssertTrue(prompt.contains("as mentioned above"))
    }
}
