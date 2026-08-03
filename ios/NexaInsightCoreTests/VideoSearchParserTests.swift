import XCTest
@testable import NexaInsightCore

final class VideoSearchParserTests: XCTestCase {
    private func page(_ renderersJSON: String) -> Data {
        Data("""
        <html><body><script>
        var ytInitialData = {"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":
        {"sectionListRenderer":{"contents":[{"itemSectionRenderer":
        {"contents":[\(renderersJSON)]}}]}}}}};</script></body></html>
        """.utf8)
    }

    // Shaped after the in-channel search response (the only site-wide-sibling
    // shape that could be measured), plus the owner fields that in-channel
    // results omit and site-wide results carry.
    private let videoRenderer = """
    {"videoRenderer":{
      "videoId":"y3cw_9ELpQw",
      "title":{"runs":[{"text":"Andrew Strominger: Black Holes"}]},
      "lengthText":{"simpleText":"2:19:34"},
      "publishedTimeText":{"simpleText":"3 years ago"},
      "viewCountText":{"simpleText":"3,028,760 views"},
      "descriptionSnippet":{"runs":[{"text":"Andrew Strominger is a "},{"text":"physicist"}]},
      "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/y3cw_9ELpQw/hqdefault.jpg"}]},
      "ownerText":{"runs":[{"text":"Lex Fridman","navigationEndpoint":{"browseEndpoint":
        {"browseId":"UCSHZKyawb77ixDdsGog4iWA"}}}]}
    }}
    """

    private func videos(_ outcome: ChannelVideoOutcome) -> [ChannelVideo] {
        guard case .parsed(let items) = outcome else {
            XCTFail("expected .parsed, got \(outcome)")
            return []
        }
        return items
    }

    func testParsesAllFields() {
        let items = videos(VideoSearchParser.parse(page(videoRenderer)))
        XCTAssertEqual(items.count, 1)
        let v = items[0]
        XCTAssertEqual(v.videoId, "y3cw_9ELpQw")
        XCTAssertEqual(v.title, "Andrew Strominger: Black Holes")
        XCTAssertEqual(v.durationText, "2:19:34")
        XCTAssertEqual(v.publishedText, "3 years ago")
        XCTAssertEqual(v.viewsText, "3,028,760 views")
        XCTAssertEqual(v.summary, "Andrew Strominger is a physicist")
    }

    // The whole reason this parser exists rather than reusing ChannelVideoParser:
    // without the owner fields there is no tappable channel name, and following a
    // channel becomes unreachable.
    func testExtractsOwnerChannelTitleAndId() {
        let items = videos(VideoSearchParser.parse(page(videoRenderer)))
        XCTAssertEqual(items[0].channelTitle, "Lex Fridman")
        XCTAssertEqual(items[0].channelId, "UCSHZKyawb77ixDdsGog4iWA")
    }

    func testReadsOwnerFromLongBylineText() {
        let renderer = """
        {"videoRenderer":{
          "videoId":"aaaaaaaaaaa",
          "title":{"simpleText":"Some video"},
          "longBylineText":{"runs":[{"text":"Veritasium","navigationEndpoint":{"browseEndpoint":
            {"browseId":"UCHnyfMqiRRG1u-2MsSQLbXA"}}}]}
        }}
        """
        let items = videos(VideoSearchParser.parse(page(renderer)))
        XCTAssertEqual(items[0].channelTitle, "Veritasium")
        XCTAssertEqual(items[0].channelId, "UCHnyfMqiRRG1u-2MsSQLbXA")
    }

    // A malformed browseId must not become a channelId, or the card would link to
    // a channel page that 404s. YouTubeChannelLogic already owns that rule.
    func testRejectsMalformedBrowseId() {
        let renderer = """
        {"videoRenderer":{
          "videoId":"aaaaaaaaaaa",
          "title":{"simpleText":"Some video"},
          "ownerText":{"runs":[{"text":"Someone","navigationEndpoint":{"browseEndpoint":
            {"browseId":"not-a-channel-id"}}}]}
        }}
        """
        let items = videos(VideoSearchParser.parse(page(renderer)))
        XCTAssertEqual(items[0].channelTitle, "Someone", "the name is still shown")
        XCTAssertNil(items[0].channelId, "but it must not be tappable")
    }

    func testOwnerAbsentLeavesBothNil() {
        let renderer = """
        {"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"Some video"}}}
        """
        let items = videos(VideoSearchParser.parse(page(renderer)))
        XCTAssertNil(items[0].channelTitle)
        XCTAssertNil(items[0].channelId)
    }

    // The renderer shape on this page could not be measured. In-channel search
    // serves videoRenderer while the channel videos page has already migrated to
    // lockupViewModel, so both are handled rather than betting on one and
    // shipping a page that silently shows nothing.
    func testParsesLockupViewModelShape() {
        let renderer = """
        {"lockupViewModel":{
          "contentId":"y3cw_9ELpQw",
          "contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
          "metadata":{"lockupMetadataViewModel":{"title":{"content":"Andrew Strominger: Black Holes"}}}
        }}
        """
        let items = videos(VideoSearchParser.parse(page(renderer)))
        XCTAssertEqual(items.count, 1, "a lockupViewModel page must not come back empty")
        XCTAssertEqual(items[0].videoId, "y3cw_9ELpQw")
        XCTAssertEqual(items[0].title, "Andrew Strominger: Black Holes")
    }

    func testTitleFromSimpleTextOrRuns() {
        let simple = """
        {"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"Simple title"}}}
        """
        XCTAssertEqual(videos(VideoSearchParser.parse(page(simple)))[0].title, "Simple title")

        let runs = """
        {"videoRenderer":{"videoId":"bbbbbbbbbbb","title":{"runs":[{"text":"Run "},{"text":"title"}]}}}
        """
        XCTAssertEqual(videos(VideoSearchParser.parse(page(runs)))[0].title, "Run title")
    }

    func testDuplicateVideoIdsCollapse() {
        let items = videos(VideoSearchParser.parse(page("\(videoRenderer),\(videoRenderer)")))
        XCTAssertEqual(items.count, 1)
    }

    func testRendererMissingVideoIdIsSkipped() {
        let renderer = """
        {"videoRenderer":{"title":{"simpleText":"No id here"}}}
        """
        XCTAssertTrue(videos(VideoSearchParser.parse(page(renderer))).isEmpty)
    }

    func testRendererMissingTitleIsSkipped() {
        let renderer = """
        {"videoRenderer":{"videoId":"aaaaaaaaaaa"}}
        """
        XCTAssertTrue(videos(VideoSearchParser.parse(page(renderer))).isEmpty)
    }

    // These two cases MUST stay distinct. Zero results means "nothing matched"
    // and shows a message; structureMissing means "YouTube changed" and points at
    // the paste-a-link fallback. Collapsing them would blame the user for a
    // YouTube-side change.
    func testEmptyResultSetIsParsedNotStructureMissing() {
        XCTAssertEqual(VideoSearchParser.parse(page("")), .parsed([]))
    }

    func testMissingYtInitialDataIsStructureMissing() {
        let html = Data("<html><body>consent interstitial, no data</body></html>".utf8)
        XCTAssertEqual(VideoSearchParser.parse(html), .structureMissing)
    }

    func testMalformedJSONIsStructureMissing() {
        let html = Data("<html><script>var ytInitialData = {not json;</script></html>".utf8)
        XCTAssertEqual(VideoSearchParser.parse(html), .structureMissing)
    }

    func testThumbnailProtocolRelativeURLIsMadeAbsolute() {
        let renderer = """
        {"videoRenderer":{"videoId":"aaaaaaaaaaa","title":{"simpleText":"T"},
          "thumbnail":{"thumbnails":[{"url":"//i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg"}]}}}
        """
        let items = videos(VideoSearchParser.parse(page(renderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString,
                       "https://i.ytimg.com/vi/aaaaaaaaaaa/hq.jpg")
    }

    func testRelevanceOrderIsPreserved() {
        let second = videoRenderer.replacingOccurrences(of: "y3cw_9ELpQw", with: "zzzzzzzzzzz")
        let items = videos(VideoSearchParser.parse(page("\(videoRenderer),\(second)")))
        XCTAssertEqual(items.map(\.videoId), ["y3cw_9ELpQw", "zzzzzzzzzzz"],
                       "YouTube's ranking is the answer; do not re-sort")
    }
}
