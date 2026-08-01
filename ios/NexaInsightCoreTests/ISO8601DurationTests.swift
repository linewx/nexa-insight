import XCTest
@testable import NexaInsightCore

final class ISO8601DurationTests: XCTestCase {
    // All four shapes came from live API responses. PT1M is the important one:
    // zero components are OMITTED, not sent as zero, so a fixed-format parse
    // would fail on nearly every video.
    func testParsesMeasuredShapes() {
        XCTAssertEqual(ISO8601Duration.seconds("PT3H46M18S"), 13578)
        XCTAssertEqual(ISO8601Duration.seconds("PT2H53M43S"), 10423)
        XCTAssertEqual(ISO8601Duration.seconds("PT1M"), 60)
        XCTAssertEqual(ISO8601Duration.seconds("PT42S"), 42)
    }

    func testParsesPartialComponentCombinations() {
        XCTAssertEqual(ISO8601Duration.seconds("PT1H"), 3600)
        XCTAssertEqual(ISO8601Duration.seconds("PT1H30S"), 3630, "minutes omitted entirely")
        XCTAssertEqual(ISO8601Duration.seconds("PT18M42S"), 1122)
    }

    func testRejectsNonDurations() {
        XCTAssertNil(ISO8601Duration.seconds(nil))
        XCTAssertNil(ISO8601Duration.seconds(""))
        XCTAssertNil(ISO8601Duration.seconds("3:46:18"), "that is the scraped display form")
        XCTAssertNil(ISO8601Duration.seconds("PT"), "no components")
        XCTAssertNil(ISO8601Duration.seconds("PT12"), "trailing digits with no unit")
        XCTAssertNil(ISO8601Duration.seconds("PTabc"))
    }

    // P0D shows up for some live/upcoming items. Treating it as a zero-second
    // video would show a "0:00" badge; unknown is the honest answer.
    func testLivePlaceholderIsUnknownNotZero() {
        XCTAssertNil(ISO8601Duration.seconds("P0D"))
        XCTAssertNil(ISO8601Duration.displayText("P0D"))
        XCTAssertFalse(ISO8601Duration.isShort("P0D"))
    }

    // Must match the scraped pages' format exactly, or cards from the two sources
    // would look different.
    func testDisplayTextMatchesTheScrapedFormat() {
        XCTAssertEqual(ISO8601Duration.displayText("PT3H46M18S"), "3:46:18")
        XCTAssertEqual(ISO8601Duration.displayText("PT18M42S"), "18:42")
        XCTAssertEqual(ISO8601Duration.displayText("PT42S"), "0:42")
        XCTAssertEqual(ISO8601Duration.displayText("PT1M"), "1:00")
        XCTAssertEqual(ISO8601Duration.displayText("PT1H5M3S"), "1:05:03", "zero-padded")
    }

    func testDisplayTextNilForUnparseable() {
        XCTAssertNil(ISO8601Duration.displayText(nil))
        XCTAssertNil(ISO8601Duration.displayText("PT0S"), "a zero-length video is unknown, not 0:00")
    }

    // 60s is YouTube's own ceiling. Verified against Veritasium: 6 of 50 uploads
    // were at or under it, including two at exactly PT1M.
    func testIsShortUsesTheSixtySecondCeiling() {
        XCTAssertTrue(ISO8601Duration.isShort("PT42S"))
        XCTAssertTrue(ISO8601Duration.isShort("PT1M"), "exactly 60s is a Short")
        XCTAssertFalse(ISO8601Duration.isShort("PT1M1S"))
        XCTAssertFalse(ISO8601Duration.isShort("PT3H46M18S"))
    }

    // Deliberate asymmetry, same as the scraped path: an unknown duration is kept.
    // A stray Short is noise; a dropped episode is unfindable.
    func testUnknownDurationIsNotAShort() {
        XCTAssertFalse(ISO8601Duration.isShort(nil))
        XCTAssertFalse(ISO8601Duration.isShort("garbage"))
    }
}
