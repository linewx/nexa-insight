import XCTest
@testable import NexaInsightCore

final class PracticeFlowTests: XCTestCase {
    func testOneTapCarriesTheLearnerFromListeningToAScore() {
        // The whole point: four taps became one. Nothing in this sequence is a tap except
        // `begin()`.
        var flow = PracticeFlow()
        XCTAssertEqual(flow.stage, .idle)

        flow.begin()
        XCTAssertEqual(flow.stage, .listening, "the sentence plays first — shadowing needs a model")

        flow.sentenceFinished()
        XCTAssertEqual(flow.stage, .speaking(level: 0), "the mic opens by itself")

        flow.heard(level: 0.4)
        XCTAssertEqual(flow.stage, .speaking(level: 0.4))

        flow.takeFinished(recording: URL(fileURLWithPath: "/tmp/take.m4a"))
        XCTAssertEqual(flow.stage, .scoring, "silence ended the take, not a button")

        flow.scored()
        XCTAssertEqual(flow.stage, .scored)
    }

    func testSilenceIsReportedRatherThanScored() {
        // An empty recording sent for evaluation comes back as a low score for a take the
        // learner never made, which reads as "you spoke badly".
        var flow = PracticeFlow()
        flow.begin()
        flow.sentenceFinished()
        flow.takeFinished(recording: nil)
        XCTAssertEqual(flow.stage, .failed("没听到声音，再试一次"))
    }

    func testTheMicDoesNotOpenWhileTheSentenceIsNotPlaying() {
        // A playback callback can arrive after the learner has already restarted. Reopening
        // the mic then would record over a take that is already running.
        var flow = PracticeFlow()
        flow.begin()
        flow.sentenceFinished()
        flow.heard(level: 0.5)

        flow.sentenceFinished()  // late callback from the previous playback
        XCTAssertEqual(flow.stage, .speaking(level: 0.5), "the running take is untouched")
    }

    func testLevelsAreIgnoredOutsideATake() {
        var flow = PracticeFlow()
        flow.begin()
        flow.heard(level: 0.9)
        XCTAssertEqual(flow.stage, .listening, "metering during playback must not start a take")
    }

    func testReplayIsRefusedWhileATakeIsRunning() {
        var flow = PracticeFlow()
        flow.begin()
        flow.sentenceFinished()
        XCTAssertFalse(flow.replay(), "replaying mid-take would cut the learner off")
        XCTAssertEqual(flow.stage, .speaking(level: 0))
    }

    func testReplayIsAllowedOnceAScoreIsShowing() {
        var flow = PracticeFlow()
        flow.begin()
        flow.sentenceFinished()
        flow.takeFinished(recording: URL(fileURLWithPath: "/tmp/take.m4a"))
        flow.scored()

        XCTAssertTrue(flow.replay())
        XCTAssertEqual(flow.stage, .listening)
    }

    func testRetryAfterAFailureStartsFromTheSentenceAgain() {
        var flow = PracticeFlow()
        flow.begin()
        flow.sentenceFinished()
        flow.takeFinished(recording: nil)

        flow.begin()
        XCTAssertEqual(flow.stage, .listening, "再试一次 replays the model, it does not just reopen the mic")
    }

    func testBusyCoversExactlyTheStagesThatMustNotBeInterrupted() {
        var flow = PracticeFlow()
        XCTAssertFalse(flow.isBusy)
        flow.begin()
        XCTAssertTrue(flow.isBusy, "listening")
        flow.sentenceFinished()
        XCTAssertTrue(flow.isBusy, "speaking")
        flow.takeFinished(recording: URL(fileURLWithPath: "/tmp/take.m4a"))
        XCTAssertTrue(flow.isBusy, "scoring")
        flow.scored()
        XCTAssertFalse(flow.isBusy)
        flow.failed("x")
        XCTAssertFalse(flow.isBusy)
    }
}
