import XCTest
@testable import NexaInsightCore

final class ChannelVideoParserTests: XCTestCase {
    private func page(_ renderersJSON: String) -> Data {
        Data("""
        <html><body><script>
        var ytInitialData = {"contents":{"twoColumnBrowseResultsRenderer":{"tabs":
        [{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":
        {"contents":[\(renderersJSON)]}}]}}}}]}}};</script></body></html>
        """.utf8)
    }

    // Trimmed from a real in-channel search response. Note: title is under
    // `runs`, and the thumbnail URL is already absolute — both differ from the
    // channel-search page that ChannelSearchParser handles.
    private let fullRenderer = """
    {"videoRenderer":{
      "videoId":"y3cw_9ELpQw",
      "title":{"runs":[{"text":"Andrew Strominger: Black Holes"}]},
      "lengthText":{"simpleText":"2:19:34"},
      "publishedTimeText":{"simpleText":"3 years ago"},
      "viewCountText":{"simpleText":"3,028,760 views"},
      "descriptionSnippet":{"runs":[{"text":"Andrew Strominger is a "},{"text":"theoretical physicist"},{"text":" at Harvard."}]},
      "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/y3cw_9ELpQw/hqdefault.jpg","width":168,"height":94}]}
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
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items.count, 1)
        let v = items[0]
        XCTAssertEqual(v.videoId, "y3cw_9ELpQw")
        XCTAssertEqual(v.title, "Andrew Strominger: Black Holes")
        XCTAssertEqual(v.durationText, "2:19:34")
        XCTAssertEqual(v.publishedText, "3 years ago")
        XCTAssertEqual(v.viewsText, "3,028,760 views")
        XCTAssertEqual(v.id, "y3cw_9ELpQw")
    }

    // Regression lock: title here is `runs`, not `simpleText`. Copying
    // ChannelSearchParser's simpleText reader would silently drop every title.
    func testTitleComesFromRunsNotSimpleText() {
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].title, "Andrew Strominger: Black Holes")
    }

    func testDescriptionRunsAreJoined() {
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].summary, "Andrew Strominger is a theoretical physicist at Harvard.")
    }

    // Regression lock: these thumbnails are ALREADY absolute (0/30 were
    // protocol-relative), unlike the channel-search page where 20/20 were
    // `//...`. Prefixing unconditionally would corrupt the URL.
    func testAbsoluteThumbnailIsNotDoublePrefixed() {
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString,
                       "https://i.ytimg.com/vi/y3cw_9ELpQw/hqdefault.jpg")
    }

    func testProtocolRelativeThumbnailStillGetsPrefixed() {
        let renderer = """
        {"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"T"}]},
        "thumbnail":{"thumbnails":[{"url":"//i.ytimg.com/vi/abcdefghijk/hq.jpg"}]}}}
        """
        let items = videos(ChannelVideoParser.parse(page(renderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString,
                       "https://i.ytimg.com/vi/abcdefghijk/hq.jpg")
    }

    // 4 of 30 measured results had no descriptionSnippet.
    func testMissingOptionalFieldsDegradeGracefully() {
        let renderer = """
        {"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Bare"}]}}}
        """
        let items = videos(ChannelVideoParser.parse(page(renderer)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Bare")
        XCTAssertNil(items[0].summary)
        XCTAssertNil(items[0].durationText)
        XCTAssertNil(items[0].viewsText)
        XCTAssertNil(items[0].thumbnailURL)
    }

    func testSkipsRenderersMissingVideoIdOrTitle() {
        let renderer = """
        {"videoRenderer":{"title":{"runs":[{"text":"No id"}]}}},
        {"videoRenderer":{"videoId":"abcdefghijk"}},
        \(fullRenderer)
        """
        let items = videos(ChannelVideoParser.parse(page(renderer)))
        XCTAssertEqual(items.map(\.videoId), ["y3cw_9ELpQw"])
    }

    func testDeduplicatesByVideoId() {
        let items = videos(ChannelVideoParser.parse(page("\(fullRenderer),\(fullRenderer)")))
        XCTAssertEqual(items.count, 1)
    }

    func testPreservesResultOrder() {
        let second = fullRenderer.replacingOccurrences(of: "y3cw_9ELpQw", with: "HUkBz-cdB-k")
        let items = videos(ChannelVideoParser.parse(page("\(fullRenderer),\(second)")))
        XCTAssertEqual(items.map(\.videoId), ["y3cw_9ELpQw", "HUkBz-cdB-k"],
                       "relevance order from YouTube must be preserved")
    }

    // Measured: a no-match query returns 200 with ytInitialData present and zero
    // renderers. That is a real answer, not a failure.
    func testZeroResultsIsParsedNotStructureMissing() {
        guard case .parsed(let items) = ChannelVideoParser.parse(page("")) else {
            return XCTFail("zero results must be .parsed")
        }
        XCTAssertTrue(items.isEmpty)
    }

    func testMissingYtInitialDataReportsStructureMissing() {
        guard case .structureMissing = ChannelVideoParser.parse(Data("<html>nope</html>".utf8)) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testMalformedJSONReportsStructureMissing() {
        let html = Data("<script>var ytInitialData = {\"broken\":;</script>".utf8)
        guard case .structureMissing = ChannelVideoParser.parse(html) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testEmptyDataReportsStructureMissing() {
        guard case .structureMissing = ChannelVideoParser.parse(Data()) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testFindsRenderersAtArbitraryDepth() {
        let deep = Data("""
        <script>var ytInitialData = {"a":{"b":[{"c":{"d":[\(fullRenderer)]}}]}};</script>
        """.utf8)
        XCTAssertEqual(videos(ChannelVideoParser.parse(deep)).count, 1)
    }
}
