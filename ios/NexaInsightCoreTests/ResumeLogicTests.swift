import XCTest
@testable import NexaInsightCore

final class ResumeLogicTests: XCTestCase {
    // The measured length of a real episode: 3h46m18s. Resume matters in
    // proportion to duration, so the fixtures use a real one.
    private let long = 13_578_000
    private let short = 1_122_000   // 18:42

    // MARK: - Where to resume

    func testResumesWhereYouLeftOff() {
        XCTAssertEqual(Resume.startPosition(savedMs: 4_804_000, durationMs: long), 4_804_000)
    }

    func testNothingSavedStartsAtTheBeginning() {
        XCTAssertNil(Resume.startPosition(savedMs: nil, durationMs: long))
    }

    // A few seconds in usually means the wrong episode was opened; resuming at
    // 0:03 reads as a bug rather than as memory.
    func testAFewSecondsInIsTreatedAsNotStarted() {
        XCTAssertNil(Resume.startPosition(savedMs: 3_000, durationMs: long))
        XCTAssertNil(Resume.startPosition(savedMs: Resume.minimumMs - 1, durationMs: long))
        XCTAssertEqual(Resume.startPosition(savedMs: Resume.minimumMs, durationMs: long), Resume.minimumMs)
    }

    // Resuming at 99% drops you in the outro with no explanation, so a finished
    // episode starts over.
    func testFinishedEpisodeStartsOver() {
        XCTAssertNil(Resume.startPosition(savedMs: Int(Double(long) * 0.99), durationMs: long))
        XCTAssertNil(Resume.startPosition(savedMs: long, durationMs: long))
    }

    func testJustBeforeTheEndStillResumes() {
        let almost = Int(Double(long) * 0.9)
        XCTAssertEqual(Resume.startPosition(savedMs: almost, durationMs: long), almost)
    }

    // Duration is optional on EpisodeDTO, so the saved position has to survive
    // without it rather than being discarded.
    func testUnknownDurationStillResumes() {
        XCTAssertEqual(Resume.startPosition(savedMs: 60_000, durationMs: nil), 60_000)
        XCTAssertEqual(Resume.startPosition(savedMs: 60_000, durationMs: 0), 60_000)
    }

    // MARK: - When to write

    // Saving on every tick would be a SwiftData write several times a second for
    // the length of the session.
    func testThrottlesWritesToMeaningfulJumps() {
        XCTAssertFalse(Resume.shouldPersist(newMs: 61_000, lastSavedMs: 60_000))
        XCTAssertTrue(Resume.shouldPersist(newMs: 66_000, lastSavedMs: 60_000))
    }

    // Seeking backwards has to persist too, or closing after a rewind would
    // restore the later position.
    func testSeekingBackwardsPersists() {
        XCTAssertTrue(Resume.shouldPersist(newMs: 30_000, lastSavedMs: 600_000))
    }

    func testFirstWriteWaitsForTheMinimum() {
        XCTAssertFalse(Resume.shouldPersist(newMs: 4_000, lastSavedMs: nil))
        XCTAssertTrue(Resume.shouldPersist(newMs: Resume.minimumMs, lastSavedMs: nil))
    }

    // MARK: - Row display

    func testProgressFractionForAPartlyHeardEpisode() {
        let fraction = Resume.progressFraction(savedMs: long / 2, durationMs: long)
        XCTAssertEqual(fraction ?? 0, 0.5, accuracy: 0.001)
    }

    // An untouched episode gets no bar, rather than an empty one implying it was
    // started.
    func testNoBarWhenUntouchedOrFinished() {
        XCTAssertNil(Resume.progressFraction(savedMs: nil, durationMs: long))
        XCTAssertNil(Resume.progressFraction(savedMs: 2_000, durationMs: long))
        XCTAssertNil(Resume.progressFraction(savedMs: long, durationMs: long))
    }

    func testNoBarWithoutADuration() {
        XCTAssertNil(Resume.progressFraction(savedMs: 60_000, durationMs: nil))
    }

    // Remaining time is what decides whether to start now, so both halves show.
    func testProgressTextShowsPositionAndTotal() {
        XCTAssertEqual(
            Resume.progressText(savedMs: 4_804_000, durationMs: long),
            "1:20:04 / 3:46:18")
    }

    func testProgressTextAbsentWhenThereIsNoProgress() {
        XCTAssertNil(Resume.progressText(savedMs: nil, durationMs: long))
        XCTAssertNil(Resume.progressText(savedMs: long, durationMs: long))
    }

    // Hours appear only when the content has them.
    func testClockOmitsHoursForShortContent() {
        XCTAssertEqual(Resume.clockText(short), "18:42")
        XCTAssertEqual(Resume.clockText(45_000), "0:45")
        XCTAssertEqual(Resume.clockText(long), "3:46:18")
    }

    func testClockHandlesZeroAndNegative() {
        XCTAssertEqual(Resume.clockText(0), "0:00")
        XCTAssertEqual(Resume.clockText(-5_000), "0:00")
    }
}
