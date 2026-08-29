import AVFoundation
import XCTest
@testable import NexaInsightCore

// Leaving the study page must stop the audio.
//
// The player is a @StateObject owned by StudyView, so re-entering the episode builds a
// SECOND one. An AVPlayer keeps playing for as long as something retains it — and its own
// item retains it — so the first player stayed audible while the controls drove the new
// instance. Play, pause and seek all appeared to do nothing.
final class PlaybackTeardownTests: XCTestCase {
    // LocalAudioPlayback is wrapped in `#if canImport(AVFoundation) && os(iOS)` and
    // `swift test` runs on macOS, so the class is not in this target and cannot be
    // driven here — which is exactly why the teardown bug had no test. What IS checkable
    // is that the view stops the audio on the way out, and that is the fix that matters:
    // deinit timing is SwiftUI's to decide.

    func testTheViewPausesRatherThanRelyingOnDeinit() {
        // deinit does pause too, but SwiftUI decides WHEN a @StateObject is released and it
        // may not happen before the learner reopens the episode. The explicit pause in
        // onDisappear is what makes the behaviour deterministic; this asserts the call is
        // actually there, since a passing player-level test says nothing about the view.
        let source = try! String(contentsOfFile: "NexaInsight/Views/StudyView.swift", encoding: .utf8)
        let onDisappear = source.range(of: ".onDisappear {")
        XCTAssertNotNil(onDisappear)
        let tail = String(source[onDisappear!.upperBound...].prefix(1200))
        XCTAssertTrue(tail.contains("player.pause()"),
                      "onDisappear must stop the audio, not leave it to deinit")
    }
}
