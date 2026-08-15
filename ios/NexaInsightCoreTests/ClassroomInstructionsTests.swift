import XCTest
@testable import NexaInsightCore

final class ClassroomInstructionsTests: XCTestCase {
    func testStableInstructionsStripsBakedContext() {
        let full = "STYLE AND RULES\n\nClassroom material:\nEpisode: X\nmap..."
        XCTAssertEqual(stableInstructions(full), "STYLE AND RULES")
    }

    func testComposeAttachesSingleAuthoritativeWindow() {
        let full = "PREFIX\n\nCurrent podcast context:\nOLD WINDOW"
        let composed = composeInstructions(full, freshContext: "NEW WINDOW")
        XCTAssertTrue(composed.hasPrefix("PREFIX"))
        XCTAssertTrue(composed.contains("NEW WINDOW"))
        XCTAssertFalse(composed.contains("OLD WINDOW"))
        XCTAssertTrue(composed.contains("ONLY current context"))
    }

    func testRealtimeToolsAdvertiseOmniDirectSet() {
        let names = realtimePlaybackTools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["resume_playback", "pause_playback", "previous_sentence", "next_sentence", "seek_to_timestamp"])
    }

    func testBaseInstructionsAppendMaterial() {
        let text = baseClassroomInstructions(material: "MATERIAL_XYZ")
        XCTAssertTrue(text.contains("MATERIAL_XYZ"))
    }

    // Reading asked "what is worth studying here" and got "好，我们来梳理一下…" with the
    // content deferred to a turn that never came. The learner held that paragraph
    // because they are stuck on it now, and a turn spent on preamble also leaves the
    // exchange with nothing to sediment.
    func testReadingIsToldToAnswerInTheSameTurn() {
        let composed = composeInstructions("PREFIX", freshContext: "WINDOW", scene: .reading)
        XCTAssertTrue(composed.contains("READING MODE"))
        XCTAssertTrue(composed.contains("THIS turn"))
        XCTAssertTrue(composed.contains("do not defer content"))
    }

    // Listening keeps the Socratic framing: thinking aloud while the podcast plays is
    // exactly where engaging before explaining is right.
    func testListeningScenesAreLeftAlone() {
        for scene in [ClassroomScene.selfStudy, .live] {
            let composed = composeInstructions("PREFIX", freshContext: "WINDOW", scene: scene)
            XCTAssertFalse(composed.contains("READING MODE"), "leaked into \(scene)")
        }
    }

    // The default has to stay the listening one: `updateContext` is called from paths
    // that predate scenes, and a wrong default would silently reshape 精听.
    func testDefaultSceneIsSelfStudy() {
        XCTAssertEqual(composeInstructions("P", freshContext: "W"),
                       composeInstructions("P", freshContext: "W", scene: .selfStudy))
    }

    // The reading guidance is appended, not substituted: the material window and the
    // "only current context" rule must survive it.
    func testReadingKeepsTheAuthoritativeWindow() {
        let composed = composeInstructions(
            "PREFIX\n\nCurrent podcast context:\nOLD", freshContext: "NEW", scene: .reading)
        XCTAssertTrue(composed.contains("NEW"))
        XCTAssertFalse(composed.contains("OLD"))
        XCTAssertTrue(composed.contains("ONLY current context"))
    }
}
