import XCTest
@testable import NexaInsightCore

final class ChannelSearchParserTests: XCTestCase {
    // Shaped exactly like a real response: the renderer is nested inside
    // itemSectionRenderer contents, description arrives as multiple runs, and
    // the thumbnail URL is protocol-relative.
    private func page(_ renderersJSON: String) -> Data {
        Data("""
        <html><body><script>
        var ytInitialData = {"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":
        {"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[\(renderersJSON)]}}]}}}}};</script>
        </body></html>
        """.utf8)
    }

    private let fullRenderer = """
    {"channelRenderer":{
      "channelId":"UCSHZKyawb77ixDdsGog4iWA",
      "title":{"simpleText":"Philosophy Tube"},
      "subscriberCountText":{"simpleText":"@PhilosophyTube"},
      "videoCountText":{"simpleText":"1.67M subscribers"},
      "descriptionSnippet":{"runs":[{"text":"I'm giving away a "},{"text":"philosophy","bold":true},{"text":" degree for free."}]},
      "thumbnail":{"thumbnails":[{"url":"//yt3.googleusercontent.com/ytc/abc=s88","width":88,"height":88}]}
    }}
    """

    private func results(_ outcome: ChannelSearchOutcome) -> [ChannelSearchResult] {
        guard case .parsed(let items) = outcome else {
            XCTFail("expected .parsed, got \(outcome)")
            return []
        }
        return items
    }

    func testParsesAllFields() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].channelId, "UCSHZKyawb77ixDdsGog4iWA")
        XCTAssertEqual(items[0].title, "Philosophy Tube")
        XCTAssertEqual(items[0].id, "UCSHZKyawb77ixDdsGog4iWA")
    }

    // Regression lock #1. Verified against live results: the response key
    // `subscriberCountText` carries the @handle and `videoCountText` carries the
    // subscriber count. Reading by name puts a handle where a count belongs.
    func testFieldNamesAreMislabeledInTheResponse() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].handle, "@PhilosophyTube",
                       "handle must come from subscriberCountText")
        XCTAssertEqual(items[0].subscriberText, "1.67M subscribers",
                       "subscriberText must come from videoCountText")
    }

    // Regression lock #2. All 20 live thumbnails were protocol-relative; without
    // a scheme the URL will not load.
    func testProtocolRelativeThumbnailGetsHTTPSPrefix() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString,
                       "https://yt3.googleusercontent.com/ytc/abc=s88")
    }

    // Regression lock #3. descriptionSnippet.runs had 1-5 segments across live
    // results; taking only the first yields fragments like "I'm giving away a ".
    func testDescriptionRunsAreJoined() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].summary, "I'm giving away a philosophy degree for free.")
    }

    func testAbsoluteThumbnailURLIsLeftAlone() {
        let renderer = """
        {"channelRenderer":{"channelId":"UCSHZKyawb77ixDdsGog4iWA","title":{"simpleText":"T"},
        "thumbnail":{"thumbnails":[{"url":"https://example.com/a.jpg"}]}}}
        """
        let items = results(ChannelSearchParser.parse(page(renderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString, "https://example.com/a.jpg")
    }

    func testMissingOptionalFieldsDegradeGracefully() {
        let renderer = """
        {"channelRenderer":{"channelId":"UCSHZKyawb77ixDdsGog4iWA","title":{"simpleText":"Bare"}}}
        """
        let items = results(ChannelSearchParser.parse(page(renderer)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Bare")
        XCTAssertNil(items[0].handle)
        XCTAssertNil(items[0].subscriberText)
        XCTAssertNil(items[0].summary)
        XCTAssertNil(items[0].thumbnailURL)
    }

    func testSkipsRenderersMissingChannelIdOrTitle() {
        let renderer = """
        {"channelRenderer":{"title":{"simpleText":"No id"}}},
        {"channelRenderer":{"channelId":"UCSHZKyawb77ixDdsGog4iWA"}},
        \(fullRenderer)
        """
        let items = results(ChannelSearchParser.parse(page(renderer)))
        XCTAssertEqual(items.map(\.channelId), ["UCSHZKyawb77ixDdsGog4iWA"])
    }

    func testDeduplicatesByChannelId() {
        let items = results(ChannelSearchParser.parse(page("\(fullRenderer),\(fullRenderer)")))
        XCTAssertEqual(items.count, 1)
    }

    // A real no-match response: 200, ytInitialData present, zero renderers.
    // This is a legitimate empty answer and must NOT be reported as a failure.
    func testZeroResultsIsParsedNotStructureMissing() {
        let outcome = ChannelSearchParser.parse(page(""))
        guard case .parsed(let items) = outcome else {
            return XCTFail("zero results must be .parsed, not .structureMissing")
        }
        XCTAssertTrue(items.isEmpty)
    }

    // The distinct failure: the page shape changed and ytInitialData is gone.
    func testMissingYtInitialDataReportsStructureMissing() {
        let html = Data("<html><body>no data here</body></html>".utf8)
        guard case .structureMissing = ChannelSearchParser.parse(html) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testMalformedJSONReportsStructureMissing() {
        let html = Data("<script>var ytInitialData = {\"broken\":;</script>".utf8)
        guard case .structureMissing = ChannelSearchParser.parse(html) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testEmptyDataReportsStructureMissing() {
        guard case .structureMissing = ChannelSearchParser.parse(Data()) else {
            return XCTFail("expected .structureMissing")
        }
    }

    // Renderers are nested at varying depths in real responses, so the walk must
    // be recursive rather than assuming a fixed path.
    func testFindsRenderersAtArbitraryDepth() {
        let deep = Data("""
        <script>var ytInitialData = {"a":{"b":{"c":[{"d":{"e":[\(fullRenderer)]}}]}}};</script>
        """.utf8)
        XCTAssertEqual(results(ChannelSearchParser.parse(deep)).count, 1)
    }
}
