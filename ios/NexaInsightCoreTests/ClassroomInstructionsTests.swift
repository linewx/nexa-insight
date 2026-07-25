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
}
