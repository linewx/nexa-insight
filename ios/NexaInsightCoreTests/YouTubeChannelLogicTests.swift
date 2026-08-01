import XCTest
@testable import NexaInsightCore

final class YouTubeChannelLogicTests: XCTestCase {
    func testChannelIdFromDirectChannelURL() {
        XCTAssertEqual(
            YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA"),
            "UCSHZKyawb77ixDdsGog4iWA")
    }

    func testChannelIdFromDirectURLToleratesTrailingPathAndQuery() {
        XCTAssertEqual(
            YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA/videos?view=0"),
            "UCSHZKyawb77ixDdsGog4iWA")
    }

    func testChannelIdFromHandleURLReturnsNil() {
        // A handle URL carries no id; the caller must fetch the page and use
        // channelId(fromHTML:) instead.
        XCTAssertNil(YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/@lexfridman"))
    }

    func testChannelIdFromDirectURLRejectsMalformedId() {
        XCTAssertNil(YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/channel/UCtooshort"))
    }

    func testChannelIdFromHTMLUsesCanonicalLink() {
        let html = """
        <link rel="canonical" href="https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA">
        """
        XCTAssertEqual(YouTubeChannelLogic.channelId(fromHTML: html), "UCSHZKyawb77ixDdsGog4iWA")
    }

    // Regression lock. Verified against two live channel pages: a naive
    // "channelId":"(UC...)" regex extracts a RECOMMENDED VIDEO's author id,
    // which appears earlier in the HTML than the page's own canonical link.
    // For @lexfridman that wrong id was UCJIfeSCssxSC_Dhc5s7woww.
    func testChannelIdFromHTMLIgnoresEarlierChannelIdKeys() {
        let html = """
        {"channelId":"UCJIfeSCssxSC_Dhc5s7woww","title":"a recommended video"}
        <link rel="canonical" href="https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA">
        """
        XCTAssertEqual(YouTubeChannelLogic.channelId(fromHTML: html), "UCSHZKyawb77ixDdsGog4iWA")
    }

    func testChannelIdFromHTMLReturnsNilWhenNoCanonicalChannelLink() {
        XCTAssertNil(YouTubeChannelLogic.channelId(fromHTML: "<html><body>nothing here</body></html>"))
    }

    func testFeedURLFormat() {
        XCTAssertEqual(
            YouTubeChannelLogic.feedURL(channelId: "UCSHZKyawb77ixDdsGog4iWA")?.absoluteString,
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCSHZKyawb77ixDdsGog4iWA")
    }

    func testFeedURLRejectsMalformedChannelId() {
        XCTAssertNil(YouTubeChannelLogic.feedURL(channelId: "not-a-channel"))
    }

    func testIsShortsLink() {
        XCTAssertTrue(YouTubeChannelLogic.isShortsLink("https://www.youtube.com/shorts/3HQkVfZ4DNY"))
        XCTAssertFalse(YouTubeChannelLogic.isShortsLink("https://www.youtube.com/watch?v=XyXBwO5jYpw"))
    }

    func testDurationSecondsParsesHoursMinutesSeconds() {
        XCTAssertEqual(YouTubeChannelLogic.durationSeconds("2:19:34"), 8374)
        XCTAssertEqual(YouTubeChannelLogic.durationSeconds("18:42"), 1122)
        XCTAssertEqual(YouTubeChannelLogic.durationSeconds("0:45"), 45)
        XCTAssertEqual(YouTubeChannelLogic.durationSeconds("4:18:22"), 15502)
    }

    func testDurationSecondsRejectsNonDurations() {
        XCTAssertNil(YouTubeChannelLogic.durationSeconds(nil))
        XCTAssertNil(YouTubeChannelLogic.durationSeconds(""))
        XCTAssertNil(YouTubeChannelLogic.durationSeconds("LIVE"))
        XCTAssertNil(YouTubeChannelLogic.durationSeconds("45"), "a bare number has no unit")
        XCTAssertNil(YouTubeChannelLogic.durationSeconds("1:2:3:4"))
        XCTAssertNil(YouTubeChannelLogic.durationSeconds("ab:cd"))
    }

    // Site-wide search results carry a duration but no link, the reverse of the
    // RSS path — so Shorts have to be identified by length there. 60s is
    // YouTube's own ceiling.
    func testIsShortDurationUsesTheSixtySecondCeiling() {
        XCTAssertTrue(YouTubeChannelLogic.isShortDuration("0:45"))
        XCTAssertTrue(YouTubeChannelLogic.isShortDuration("1:00"))
        XCTAssertFalse(YouTubeChannelLogic.isShortDuration("1:01"))
        XCTAssertFalse(YouTubeChannelLogic.isShortDuration("18:42"))
        XCTAssertFalse(YouTubeChannelLogic.isShortDuration("2:19:34"))
    }

    // Deliberate asymmetry: an unrecognized duration is kept. A stray Short is
    // noise, but a dropped 4-hour episode is unfindable — the user searched for it.
    func testUnparseableDurationIsNotTreatedAsAShort() {
        XCTAssertFalse(YouTubeChannelLogic.isShortDuration(nil))
        XCTAssertFalse(YouTubeChannelLogic.isShortDuration("LIVE"))
        XCTAssertFalse(YouTubeChannelLogic.isShortDuration("unknown"))
    }
}
