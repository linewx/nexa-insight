import XCTest
@testable import NexaInsightCore

final class ExtractionPromptTests: XCTestCase {
    func testNativeMaterialAsksForTheListeningTypes() {
        let prompt = ExtractionPrompt.instruction(materialKind: "native", request: nil)
        XCTAssertTrue(prompt.contains("reduction"))
        XCTAssertTrue(prompt.contains("ellipsis"))
        // Teaching-only types must not leak in: they ask for something the learner
        // is not trying to do with native-speed material.
        XCTAssertFalse(prompt.contains("collocation"))
    }

    func testTeachingMaterialAsksForTheSpeakingTypes() {
        let prompt = ExtractionPrompt.instruction(materialKind: "teaching", request: nil)
        XCTAssertTrue(prompt.contains("collocation"))
        XCTAssertTrue(prompt.contains("when_to_use"))
        XCTAssertFalse(prompt.contains("reduction"))
    }

    func testUnknownMaterialKindFallsBackToNative() {
        // Episodes imported before material classification carry no kind, and the
        // backend defaults them to native too.
        let prompt = ExtractionPrompt.instruction(materialKind: "", request: nil)
        XCTAssertTrue(prompt.contains("reduction"))
    }

    func testRejectListIsAlwaysPresent() {
        // The load-bearing part: without it the model returned "welcome back" and
        // "thanks so much" on every source.
        for kind in ["native", "teaching"] {
            let prompt = ExtractionPrompt.instruction(materialKind: kind, request: nil)
            XCTAssertTrue(prompt.contains("REJECT"), "missing reject rules for \(kind)")
            XCTAssertTrue(prompt.contains("welcome back"))
            XCTAssertTrue(prompt.contains("at most 6 words"))
        }
    }

    func testLearnerRequestIsAppendedAndMarkedAsOverriding() {
        let prompt = ExtractionPrompt.instruction(materialKind: "native", request: "\u{53ea}\u{8bb2}\u{65f6}\u{6001}")
        XCTAssertTrue(prompt.contains("\u{53ea}\u{8bb2}\u{65f6}\u{6001}"))
        XCTAssertTrue(prompt.contains("overrides"))
        // Last, so it is the most recent instruction the model reads — and after
        // the reject list, which it is explicitly told not to override.
        XCTAssertTrue(prompt.hasSuffix("field format."), "ends with: \(prompt.suffix(40))")
        let requestIndex = prompt.range(of: "specifically asked")?.lowerBound
        let rejectIndex = prompt.range(of: "REJECT")?.lowerBound
        XCTAssertNotNil(requestIndex)
        XCTAssertNotNil(rejectIndex)
        XCTAssertTrue(rejectIndex! < requestIndex!)
    }

    func testBlankRequestIsIgnoredRatherThanSentAsAnEmptyDemand() {
        let blank = ExtractionPrompt.instruction(materialKind: "native", request: "   ")
        let none = ExtractionPrompt.instruction(materialKind: "native", request: nil)
        XCTAssertEqual(blank, none)
        XCTAssertFalse(blank.contains("specifically asked"))
    }

    func testSingleSentenceExtractionMayReturnNothing() {
        // The batch prompt caps items per 40 sentences; for one line the risk is
        // the opposite — inventing something to avoid an empty answer.
        let prompt = ExtractionPrompt.instruction(materialKind: "native", request: nil)
        XCTAssertTrue(prompt.contains("empty array"))
    }

    func testOffsetsAreNeverRequested() {
        // Model-reported offsets were wrong ~97% of the time; the device anchors by
        // text instead, so asking for them would only invite trusting them.
        let prompt = ExtractionPrompt.instruction(materialKind: "teaching", request: nil)
        XCTAssertTrue(prompt.contains("Do NOT return character offsets"))
    }
}
