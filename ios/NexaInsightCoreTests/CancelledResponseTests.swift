import XCTest
@testable import NexaInsightCore

final class CancelledResponseTests: XCTestCase {
    func testOldCancelledResponseDoesNotClearNewActiveResponse() {
        var lifecycle = ResponseLifecycle()
        lifecycle.started("old")
        XCTAssertEqual(lifecycle.cancel(), "old")
        lifecycle.started("new")
        XCTAssertTrue(lifecycle.finished("old"))
        XCTAssertEqual(lifecycle.activeID, "new")
        XCTAssertFalse(lifecycle.finished("new"))
        XCTAssertNil(lifecycle.activeID)
    }

    func testNewResponseCanFinishBeforeCancelledResponse() {
        var lifecycle = ResponseLifecycle()
        lifecycle.started("old")
        _ = lifecycle.cancel()
        lifecycle.started("new")
        XCTAssertFalse(lifecycle.finished("new"))
        XCTAssertTrue(lifecycle.finished("old"))
    }

    func testATurnNobodyIsWaitingForDoesNotEndTheTurn() {
        // Observed on device: pressQuickAsk at 95800ms, then response.cancel, then the
        // cancelled turn's response.done four events later — closing out the hold that had
        // just begun. The UI said "Live 等你开口" while the controller had been told the
        // teacher finished, so nothing answered.
        let forwarded = CancelledResponse.forwarded([.responseDone], wasCancelled: true)
        XCTAssertTrue(forwarded.isEmpty)
    }

    func testANormalResponseStillEndsTheTurn() {
        // The earlier bug was nothing handing the floor back, leaving the podcast dead. This
        // must not regress into that.
        let forwarded = CancelledResponse.forwarded([.responseDone], wasCancelled: false)
        XCTAssertEqual(forwarded.count, 1)
        guard case .responseDone = forwarded[0] else { return XCTFail("expected responseDone") }
    }

    func testAToolCallOnACancelledFrameIsStillDelivered() {
        // Tool calls ride on response.done. A note the teacher saved a moment before the
        // cancel must still be written — dropping the frame wholesale loses it silently,
        // which is worse than the bug being fixed.
        let events: [RealtimeEvent] = [
            .toolCall(name: .save_note,
                      args: ToolArguments(numbers: [:], texts: ["text": "hedge fund"]),
                      callId: "c1"),
            .responseDone,
        ]
        let forwarded = CancelledResponse.forwarded(events, wasCancelled: true)
        XCTAssertEqual(forwarded.count, 1)
        guard case let .toolCall(name, _, _) = forwarded[0] else { return XCTFail() }
        XCTAssertEqual(name, .save_note)
    }

    func testEverythingElsePassesThroughUntouched() {
        let events: [RealtimeEvent] = [.speechStarted, .responseCreated]
        XCTAssertEqual(CancelledResponse.forwarded(events, wasCancelled: true).count, 2)
    }
}
