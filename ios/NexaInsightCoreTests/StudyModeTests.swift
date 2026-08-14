import XCTest
@testable import NexaInsightCore

final class StudyModeTests: XCTestCase {
    func testListeningKeepsThePlaybackControls() {
        XCTAssertTrue(StudyMode.listening.showsPlaybackControls)
    }

    // Reading still plays single sentences; what it drops is loop, speed, shadow and
    // previous/next, which are ear work. Asking a question is no longer part of this
    // distinction — reading asks by holding a paragraph, which is a gesture rather than
    // a control, so there is nothing for a flag to switch on.
    func testReadingDropsTheFullPlaybackSet() {
        XCTAssertFalse(StudyMode.reading.showsPlaybackControls)
    }

    func testToggleRoundTrips() {
        XCTAssertEqual(StudyMode.listening.toggled, .reading)
        XCTAssertEqual(StudyMode.reading.toggled, .listening)
        XCTAssertEqual(StudyMode.listening.toggled.toggled, .listening)
    }

    func testLabelNamesTheModeYouAreIn() {
        // Not the one you would switch to: a capsule reading 精读 while you are in
        // 精听 is the ambiguity this replaces.
        XCTAssertEqual(StudyMode.listening.label, "\u{7cbe}\u{542c}")
        XCTAssertEqual(StudyMode.reading.label, "\u{7cbe}\u{8bfb}")
    }

    func testModeIsPersistableAsAStableString() {
        // Stored in AppSettings, so the raw values must not drift.
        XCTAssertEqual(StudyMode.listening.rawValue, "listening")
        XCTAssertEqual(StudyMode.reading.rawValue, "reading")
        XCTAssertEqual(StudyMode(rawValue: "reading"), .reading)
        XCTAssertNil(StudyMode(rawValue: "skimming"))
    }
}
