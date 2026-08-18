import XCTest
@testable import NexaInsightCore

final class ProcessingStageTests: XCTestCase {
    /// Every stage name the backend actually sends. It drifted once already: `audio` and
    /// `learning` were missing, fell through to `default`, and surfaced to the learner as
    /// "Audio" and "Learning" — the raw enum, mid-import, on the stage that takes longest.
    private let backendStages = [
        "metadata", "audio", "transcription", "translation", "indexing", "learning", "complete",
    ]

    func testEveryBackendStageHasAWrittenName() {
        for stage in backendStages {
            let title = processingStageTitle(stage)
            XCTAssertNotEqual(title, stage.capitalized,
                              "\(stage) is falling through to the raw name")
            XCTAssertFalse(title.isEmpty, stage)
        }
    }

    func testTheLongestStageSaysWhatItIsDoing() {
        // 65% of an import's wall clock. "Learning" reads like the app is learning something.
        XCTAssertEqual(processingStageTitle("learning"), "Finding expressions")
    }

    func testIndexingIsTheChapterStep() {
        XCTAssertEqual(normalizedProcessingStage("indexing"), "chapters")
        XCTAssertEqual(processingStageTitle("indexing"), "Generating chapters")
    }

    func testAnUnknownStageStillReadsAsSomething() {
        // A stage added to the backend and not here must degrade, not blank out. Swift's
        // `capitalized` treats `_` as a word separator, hence the second capital.
        XCTAssertEqual(processingStageTitle("brand_new_step"), "Brand_New_Step")
        XCTAssertEqual(processingStageTitle(""), "Processing")
    }
}
