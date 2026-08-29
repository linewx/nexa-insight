import XCTest
@testable import NexaInsightCore

// Walking past a run of Shorts to reach a channel's long-form uploads.
//
// These have to run against the HTTP layer rather than the YouTubeAPIFetching stub:
// the page-walking lives inside YouTubeAPIClient.fetchUploads, so a fake that
// replaces that method cannot exercise it. That is exactly how this bug survived —
// the paging tests passed while the real client returned an empty first page.
private final class StubURLProtocol: URLProtocol {
    /// Responses keyed by a substring of the request URL, plus a record of what was asked.
    nonisolated(unsafe) static var bodies: [(match: String, json: String)] = []
    nonisolated(unsafe) static var requested: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.requested.append(url)
        let json = Self.bodies.first { url.contains($0.match) }?.json ?? "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class UploadsPageWalkTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.bodies = []
        StubURLProtocol.requested = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    /// One playlistItems page of `count` videos, ids prefixed so details can match.
    private func playlistPage(prefix: String, count: Int, nextToken: String?) -> String {
        let items = (0..<count).map { i in
            // videoId comes from contentDetails, not snippet.resourceId — the parser
            // decodes a required `contentDetails.videoId`, and a fixture missing it
            // throws `unreadable` rather than returning an empty page.
            """
            {"snippet":{"title":"v\(i)","publishedAt":"2026-01-01T00:00:00Z","thumbnails":{}},
             "contentDetails":{"videoId":"\(prefix)\(i)"}}
            """
        }.joined(separator: ",")
        let token = nextToken.map { "\"nextPageToken\":\"\($0)\"," } ?? ""
        return """
        {\(token)"pageInfo":{"totalResults":300},"items":[\(items)]}
        """
    }

    /// A videos-endpoint response giving every requested id the same duration.
    private func detailsPage(prefix: String, count: Int, duration: String) -> String {
        let items = (0..<count).map { i in
            """
            {"id":"\(prefix)\(i)","contentDetails":{"duration":"\(duration)"},
             "statistics":{"viewCount":"1000"}}
            """
        }.joined(separator: ",")
        return "{\"items\":[\(items)]}"
    }

    func testItWalksPastAPageOfShortsToReachTheLongVideos() async throws {
        // The measured shape of Ariannita la Gringa: the uploads playlist is ordered
        // by upload time and includes Shorts, so 50 shorts filled page one and the
        // first video over ten minutes sat at position 51. The screen said "No
        // long-form videos found" for a channel with dozens of 11-22 minute lessons.
        StubURLProtocol.bodies = [
            // Page one: all shorts. Page two: real lessons.
            ("playlistItems", playlistPage(prefix: "short", count: 3, nextToken: "PAGE2")),
            ("videos", detailsPage(prefix: "short", count: 3, duration: "PT45S")),
        ]
        // The second round of responses, swapped in once page two is requested.
        let client = YouTubeAPIClient(apiKey: "k", session: session)

        // Serve page two when the token appears in the URL.
        StubURLProtocol.bodies = [
            ("pageToken=PAGE2", playlistPage(prefix: "long", count: 2, nextToken: nil)),
            ("id=long", detailsPage(prefix: "long", count: 2, duration: "PT15M53S")),
            ("playlistItems", playlistPage(prefix: "short", count: 3, nextToken: "PAGE2")),
            ("videos", detailsPage(prefix: "short", count: 3, duration: "PT45S")),
        ]

        let page = try await client.fetchUploads(channelId: "UC3uODtYvKjb7gPY9EFOlUWw",
                                                 pageToken: nil)

        XCTAssertEqual(page.videos.count, 2, "the lessons on page two are reached")
        XCTAssertEqual(page.skippedShortCount, 3, "and the shorts walked past are counted")
        XCTAssertTrue(StubURLProtocol.requested.contains { $0.contains("pageToken=PAGE2") },
                      "page two was actually requested")
    }

    func testItStopsAtTheFirstPageThatHasSomething() async throws {
        // Walking must not continue past a usable page: that would spend quota and
        // skip videos the learner should see.
        StubURLProtocol.bodies = [
            ("playlistItems", playlistPage(prefix: "long", count: 2, nextToken: "PAGE2")),
            ("videos", detailsPage(prefix: "long", count: 2, duration: "PT20M")),
        ]
        let client = YouTubeAPIClient(apiKey: "k", session: session)
        let page = try await client.fetchUploads(channelId: "UC3uODtYvKjb7gPY9EFOlUWw",
                                                pageToken: nil)

        XCTAssertEqual(page.videos.count, 2)
        XCTAssertEqual(page.skippedShortCount, 0)
        XCTAssertFalse(StubURLProtocol.requested.contains { $0.contains("pageToken=PAGE2") },
                       "no second page fetched when the first one has videos")
    }

    func testItStopsWhenThereAreNoMorePages() async throws {
        // A channel that genuinely has only shorts must terminate, not loop to the cap.
        StubURLProtocol.bodies = [
            ("playlistItems", playlistPage(prefix: "short", count: 2, nextToken: nil)),
            ("videos", detailsPage(prefix: "short", count: 2, duration: "PT30S")),
        ]
        let client = YouTubeAPIClient(apiKey: "k", session: session)
        let page = try await client.fetchUploads(channelId: "UC3uODtYvKjb7gPY9EFOlUWw",
                                                pageToken: nil)

        XCTAssertTrue(page.videos.isEmpty)
        XCTAssertEqual(page.skippedShortCount, 2, "the screen can say shorts were skipped")
        // One playlistItems call and one videos call, no walking.
        XCTAssertEqual(StubURLProtocol.requested.filter { $0.contains("playlistItems") }.count, 1)
    }

    func testTheWalkIsBounded() {
        // Cheap, but not unbounded: playlistItems and videos cost 1 unit each, so five
        // pages is 10 units against a daily 10,000. search.list would let YouTube
        // filter server-side but costs 100 units from a separate 100-per-day bucket,
        // and its "long" bucket means over 20 minutes — which would hide the 12 of 15
        // videos on this channel that run 11-20.
        XCTAssertLessThanOrEqual(YouTubeAPIClient.maxEmptyPageWalk, 8)
        XCTAssertGreaterThanOrEqual(YouTubeAPIClient.maxEmptyPageWalk, 2,
                                    "one extra page is the minimum that fixes the measured case")
    }
}
