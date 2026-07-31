import XCTest
@testable import NexaInsightCore

private struct StubService: DiscoverFeedFetching {
    var videoOutcome: ChannelVideoOutcome = .parsed([])
    var uploads: [DiscoverEntry] = []
    var capturedQueries: Captured = Captured()

    final class Captured { var queries: [String] = [] }

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult {
        FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    }
    func resolveChannel(fromURL url: String) async throws -> Subscription {
        throw DiscoverFeedError.unrecognizedChannelLink
    }
    func searchChannels(query: String) async -> ChannelSearchOutcome { .parsed([]) }
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome {
        capturedQueries.queries.append(query)
        return videoOutcome
    }
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] { uploads }
}

private func video(_ id: String, _ title: String) -> ChannelVideo {
    ChannelVideo(videoId: id, title: title, durationText: "1:02:03",
                 viewsText: "10K views", publishedText: "2 years ago",
                 summary: "about \(title)", thumbnailURL: nil)
}

private func upload(_ id: String, _ title: String, at seconds: TimeInterval) -> DiscoverEntry {
    DiscoverEntry(videoId: id, channelId: "UCSHZKyawb77ixDdsGog4iWA", title: title,
                  channelTitle: "Chan", published: Date(timeIntervalSince1970: seconds),
                  summary: nil, thumbnailURL: nil, viewCount: nil,
                  watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
}

@MainActor
final class ChannelDetailViewModelTests: XCTestCase {
    private let sub = Subscription(channelId: "UCSHZKyawb77ixDdsGog4iWA",
                                   title: "Lex Fridman",
                                   addedAt: Date(timeIntervalSince1970: 0))

    private func makeVM(_ service: StubService,
                        imported: Set<String> = []) -> ChannelDetailViewModel {
        ChannelDetailViewModel(subscription: sub, service: service,
                               importedVideoIds: { imported })
    }

    func testLoadUploadsPopulatesRecencyList() async {
        var service = StubService()
        service.uploads = [upload("v2", "Newer", at: 2000), upload("v1", "Older", at: 1000)]

        let vm = makeVM(service)
        await vm.loadUploads()

        XCTAssertEqual(vm.uploads.map(\.videoId), ["v2", "v1"])
        XCTAssertFalse(vm.loadingUploads)
    }

    func testRunSearchPopulatesResults() async {
        var service = StubService()
        service.videoOutcome = .parsed([video("a", "Alpha"), video("b", "Beta")])

        let vm = makeVM(service)
        vm.query = "physics"
        await vm.runSearch()

        XCTAssertEqual(vm.results.map(\.videoId), ["a", "b"])
        XCTAssertEqual(vm.searchedTerm, "physics")
        XCTAssertFalse(vm.searching)
        XCTAssertFalse(vm.searchUnavailable)
    }

    func testSearchPreservesRelevanceOrder() async {
        var service = StubService()
        service.videoOutcome = .parsed([video("old", "3 years ago one"), video("new", "recent one")])

        let vm = makeVM(service)
        vm.query = "physics"
        await vm.runSearch()

        XCTAssertEqual(vm.results.map(\.videoId), ["old", "new"],
                       "YouTube relevance order must not be re-sorted by date")
    }

    // Zero results is a real answer — the UI says "no match", not "broken".
    func testZeroResultsIsNotUnavailable() async {
        var service = StubService()
        service.videoOutcome = .parsed([])

        let vm = makeVM(service)
        vm.query = "zzqqxx"
        await vm.runSearch()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.searchUnavailable)
        XCTAssertEqual(vm.searchedTerm, "zzqqxx")
    }

    func testStructureMissingSetsUnavailable() async {
        var service = StubService()
        service.videoOutcome = .structureMissing

        let vm = makeVM(service)
        vm.query = "physics"
        await vm.runSearch()

        XCTAssertTrue(vm.searchUnavailable)
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testBlankQueryIssuesNoRequest() async {
        let service = StubService()
        let vm = makeVM(service)
        vm.query = "   "
        await vm.runSearch()

        XCTAssertTrue(service.capturedQueries.queries.isEmpty,
                      "an empty query returns nothing from YouTube, so do not ask")
        XCTAssertNil(vm.searchedTerm)
    }

    func testClearSearchRestoresRecencyList() async {
        var service = StubService()
        service.uploads = [upload("v1", "Older", at: 1000)]
        service.videoOutcome = .parsed([video("a", "Alpha")])

        let vm = makeVM(service)
        await vm.loadUploads()
        vm.query = "physics"
        await vm.runSearch()
        vm.clearSearch()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.searchedTerm)
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.uploads.map(\.videoId), ["v1"], "uploads survive a search")
    }

    // Prevents re-running a pipeline that takes tens of minutes.
    func testIsImportedMarksAlreadyImportedVideos() async {
        let vm = makeVM(StubService(), imported: ["a"])
        XCTAssertTrue(vm.isImported(videoId: "a"))
        XCTAssertFalse(vm.isImported(videoId: "b"))
    }

    // The closure is re-read each call, so a video imported during this session
    // flips to "in library" without rebuilding the view model.
    func testIsImportedReflectsLaterChanges() async {
        final class Box { var ids: Set<String> = [] }
        let box = Box()
        let vm = ChannelDetailViewModel(subscription: sub, service: StubService(),
                                        importedVideoIds: { box.ids })
        XCTAssertFalse(vm.isImported(videoId: "a"))
        box.ids.insert("a")
        XCTAssertTrue(vm.isImported(videoId: "a"))
    }
}
