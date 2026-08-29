import XCTest
@testable import NexaInsightCore

final class StudyModeTests: XCTestCase {
    // 精听 is gone. It differed from 精读 only in which controls a sentence offered, which is a
    // distinction the learner had to remember rather than see, and the toolbar slot it occupied
    // now opens 洞察 — a page that replaces the hour rather than a second way to spend it.
    //
    // The transcript is always `.reading`, so this flag must be true everywhere. Leaving it as
    // `self == .listening` would have silently taken the dock, hold-to-talk, shadowing, looping
    // and speed with the mode — the practice, not just the switch.
    func testEveryModeKeepsThePlaybackControls() {
        XCTAssertTrue(StudyMode.reading.showsPlaybackControls,
                      "the only mode in use must keep replay, loop, shadow and speed")
        XCTAssertTrue(StudyMode.listening.showsPlaybackControls)
    }

    func testLabelNamesTheModeYouAreIn() {
        // Not the one you would switch to: a capsule reading 精读 while you are in 精听 was the
        // ambiguity this replaced, back when there were two.
        XCTAssertEqual(StudyMode.listening.label, "\u{7cbe}\u{542c}")
        XCTAssertEqual(StudyMode.reading.label, "\u{7cbe}\u{8bfb}")
    }

    func testModeIsPersistableAsAStableString() {
        // Still stored in AppSettings, so the raw values must not drift even though only one is
        // reachable now — an installed app may hold either string.
        XCTAssertEqual(StudyMode.listening.rawValue, "listening")
        XCTAssertEqual(StudyMode.reading.rawValue, "reading")
        XCTAssertEqual(StudyMode(rawValue: "reading"), .reading)
        XCTAssertNil(StudyMode(rawValue: "skimming"))
    }
}
