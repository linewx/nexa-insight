import XCTest
@testable import NexaInsightCore

final class IntensiveListeningLogicTests: XCTestCase {
    // Deliberately uneven lengths: a 1.2s line next to a 9s one is what makes
    // fixed-interval seeking wrong for this screen.
    private let sentences = [
        SentenceDTO(id: 1, episodeId: 1, chapterId: nil, position: 0, startMs: 0, endMs: 1_200,
                    speaker: nil, sourceText: "Yeah.", chinese: "是的。"),
        SentenceDTO(id: 2, episodeId: 1, chapterId: nil, position: 1, startMs: 1_200, endMs: 10_500,
                    speaker: nil, sourceText: "So the interesting thing about black holes is that they evaporate.",
                    chinese: "黑洞有趣的地方在于它们会蒸发。"),
        SentenceDTO(id: 3, episodeId: 1, chapterId: nil, position: 2, startMs: 10_500, endMs: 13_000,
                    speaker: nil, sourceText: "Right.", chinese: "对。"),
    ]

    // MARK: - Stepping

    func testStepsByIndexNotByTime() {
        let from = sentences[1]
        XCTAssertEqual(IntensiveListening.previousSentence(sentences, from: from)?.id, 1)
        XCTAssertEqual(IntensiveListening.nextSentence(sentences, from: from)?.id, 3)
    }

    // The ends must return nil rather than clamping, so the control can disable
    // instead of silently doing nothing when tapped.
    func testStoppsAtBothEnds() {
        XCTAssertNil(IntensiveListening.previousSentence(sentences, from: sentences[0]))
        XCTAssertNil(IntensiveListening.nextSentence(sentences, from: sentences[2]))
    }

    // Before playback starts there is no current sentence, so stepping should
    // enter the transcript rather than do nothing.
    func testNoCurrentSentenceStartsAtTheBeginning() {
        XCTAssertEqual(IntensiveListening.previousSentence(sentences, from: nil)?.id, 1)
        XCTAssertEqual(IntensiveListening.nextSentence(sentences, from: nil)?.id, 1)
    }

    func testEmptyTranscriptYieldsNothing() {
        XCTAssertNil(IntensiveListening.previousSentence([], from: nil))
        XCTAssertNil(IntensiveListening.nextSentence([], from: nil))
    }

    // A sentence from a filtered/stale list must not strand the controls.
    func testUnknownCurrentSentenceFallsBackToTheStart() {
        let orphan = SentenceDTO(id: 99, episodeId: 1, chapterId: nil, position: 9, startMs: 0, endMs: 1,
                                 speaker: nil, sourceText: "?", chinese: "?")
        XCTAssertEqual(IntensiveListening.nextSentence(sentences, from: orphan)?.id, 1)
    }

    // MARK: - Replay

    // Replay restarts the line, it does not jump back a fixed interval — with a
    // 1.2s sentence next to a 9.3s one, any constant offset lands in the wrong one.
    func testReplayTargetsTheSentenceStart() {
        XCTAssertEqual(IntensiveListening.replayTarget(sentences[1]), 1_200)
        XCTAssertNil(IntensiveListening.replayTarget(nil))
    }

    // MARK: - Speed

    func testSpeedBadgeHiddenAtNormalSpeed() {
        XCTAssertNil(IntensiveListening.speedBadge(1.0),
                     "the default state must add nothing to the screen")
    }

    func testSpeedBadgeShownWhenChanged() {
        XCTAssertEqual(IntensiveListening.speedBadge(0.75), "0.75×")
        XCTAssertEqual(IntensiveListening.speedBadge(1.25), "1.25×")
    }

    func testSpeedCyclesThroughListeningSpeeds() {
        XCTAssertEqual(IntensiveListening.cycledSpeed(after: 0.75), 1.0)
        XCTAssertEqual(IntensiveListening.cycledSpeed(after: 1.0), 1.25)
        XCTAssertEqual(IntensiveListening.cycledSpeed(after: 1.25), 0.75, "wraps around")
    }

    func testCyclingFromAnUnknownRateReturnsToNormal() {
        XCTAssertEqual(IntensiveListening.cycledSpeed(after: 1.9), 1.0)
    }

    func testSpeedsExcludeSkimmingRates() {
        XCTAssertFalse(IntensiveListening.speeds.contains(2.0),
                       "2× is for skimming, the opposite of intensive listening")
        XCTAssertTrue(IntensiveListening.speeds.contains(0.75))
    }

    // MARK: - Loop

    func testLoopStartsOff() {
        XCTAssertFalse(SentenceLoop.off.isActive)
        XCTAssertNil(SentenceLoop.off.rewindTarget(for: sentences[1], at: 10_499))
    }

    func testTogglingOnThenOffTheSameSentence() {
        let on = SentenceLoop.off.toggled(sentences[1])
        XCTAssertTrue(on.isLooping(sentences[1]))
        XCTAssertFalse(on.toggled(sentences[1]).isActive, "the same control turns it off")
    }

    // Only one sentence can loop, so tapping loop elsewhere moves it rather than
    // leaving two active.
    func testLoopMovesRatherThanAccumulating() {
        let moved = SentenceLoop.off.toggled(sentences[0]).toggled(sentences[2])
        XCTAssertFalse(moved.isLooping(sentences[0]))
        XCTAssertTrue(moved.isLooping(sentences[2]))
    }

    func testRewindsAtTheSentenceEnd() {
        let loop = SentenceLoop.off.toggled(sentences[1])
        XCTAssertNil(loop.rewindTarget(for: sentences[1], at: 5_000), "mid-sentence keeps playing")
        XCTAssertEqual(loop.rewindTarget(for: sentences[1], at: 10_450), 1_200,
                       "at the boundary it returns to this sentence's start")
    }

    // A loop left on sentence 2 must not yank playback when the learner has moved
    // to sentence 3.
    func testStaleLoopCannotHijackAnotherSentence() {
        let loop = SentenceLoop.off.toggled(sentences[1])
        XCTAssertNil(loop.rewindTarget(for: sentences[2], at: 12_999))
    }

    func testRewindTargetIgnoresNoSentence() {
        let loop = SentenceLoop.off.toggled(sentences[1])
        XCTAssertNil(loop.rewindTarget(for: SentenceDTO?.none, at: 10_450))
    }
}
