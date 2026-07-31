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
}
