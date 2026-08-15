import XCTest
@testable import NexaInsightCore

final class ReadingAskTests: XCTestCase {
    private func ask() -> ReadingAsk { ReadingAsk(sentenceId: 42, atMs: 3000) }

    func testStartsRecordingAndEmpty() {
        let a = ask()
        XCTAssertEqual(a.phase, .recording)
        XCTAssertTrue(a.isEmpty)
        XCTAssertFalse(a.acceptsFollowUp, "a hold in progress is not a follow-up slot")
    }

    // The gap this type exists for. Release used to clear the waveform and leave
    // nothing in its place, so the seconds before an answer looked identical to idle.
    func testReleaseShowsWaitingRatherThanNothing() {
        var a = ask()
        a.released()
        XCTAssertEqual(a.phase, .waiting)
    }

    func testHeardThenAnsweredAccumulatesBothTurns() {
        var a = ask()
        a.released()
        a.heard("这个 that 指什么")
        XCTAssertEqual(a.phase, .answering)
        a.answered("指前面那个从句")
        XCTAssertEqual(a.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(a.turns.first?.text, "这个 that 指什么")
        XCTAssertFalse(a.isEmpty)
    }

    func testFinishedOpensAFollowUp() {
        var a = ask()
        a.released()
        a.heard("q")
        a.answered("a")
        a.finished()
        XCTAssertEqual(a.phase, .idle)
        XCTAssertTrue(a.acceptsFollowUp)
    }

    // A follow-up accumulates into the SAME conversation: a question chain is one
    // knowledge point, and splitting it per turn would shatter it into three.
    func testFollowUpKeepsAccumulatingInOneConversation() {
        var a = ask()
        a.released(); a.heard("q1"); a.answered("a1"); a.finished()
        a.held()
        XCTAssertEqual(a.phase, .recording)
        a.released(); a.heard("q2"); a.answered("a2"); a.finished()
        XCTAssertEqual(a.turns.count, 4)
        XCTAssertEqual(a.sentenceId, 42, "the anchor does not move")
    }

    // Only a turn that was UNDERWAY can end. Reporting one otherwise is how every hold
    // came to say "没听清" with nothing actually lost: a floor settling to .idle while a
    // fresh conversation held no turns yet looked identical to a turn that produced no
    // words.
    func testATurnThatNeverStartedCannotEnd() {
        var a = ask()
        XCTAssertEqual(a.phase, .recording)
        a.finished()
        XCTAssertEqual(a.phase, .recording, "still recording — nothing has ended")

        var settled = ask()
        settled.released(); settled.heard("q"); settled.answered("a"); settled.finished()
        XCTAssertEqual(settled.phase, .idle)
        settled.finished()
        XCTAssertEqual(settled.phase, .idle, "a settled conversation must not become misheard")
    }

    // A turn that ends with nothing transcribed says so. Silence with no explanation
    // is what makes a learner press again and again.
    func testTurnEndingWithNoWordsReportsMisheard() {
        var a = ask()
        a.released()
        a.finished()
        XCTAssertEqual(a.phase, .misheard)
        XCTAssertTrue(a.isEmpty)
        XCTAssertTrue(a.acceptsFollowUp, "the learner must be able to just say it again")
    }

    func testEmptyTranscriptsAreIgnored() {
        var a = ask()
        a.released()
        a.heard("   ")
        a.answered("\n")
        XCTAssertTrue(a.isEmpty)
    }

    func testAbandonedHoldIsNotAnError() {
        var a = ask()
        a.abandoned()
        XCTAssertEqual(a.phase, .idle)
        XCTAssertTrue(a.isEmpty)
    }

    // `onHoldEnd` fires on EVERY release — a scroll, a tap, a press too brief to pass
    // the threshold — so the caller must only release a hold that is actually recording.
    // Releasing a finished conversation would move it to `waiting` while the floor sat
    // at `.idle`, and the event that lands it back on `idle` would never arrive: the
    // panel would show "thinking" forever. This pins the property the guard relies on.
    func testOnlyARecordingHoldIsReleasable() {
        var a = ask()
        a.released(); a.heard("q"); a.answered("a"); a.finished()
        XCTAssertEqual(a.phase, .idle)
        XCTAssertNotEqual(a.phase, .recording, "a settled conversation must not look releasable")

        a.held()
        XCTAssertEqual(a.phase, .recording, "a real follow-up hold is releasable again")
    }

    func testFollowUpRefusedWhileATurnIsInFlight() {
        var a = ask()
        a.released()
        XCTAssertFalse(a.acceptsFollowUp, "waiting on the server is not a follow-up slot")
        a.heard("q")
        XCTAssertFalse(a.acceptsFollowUp, "mid-answer a press is an interrupt, not a new ask")
    }
}
