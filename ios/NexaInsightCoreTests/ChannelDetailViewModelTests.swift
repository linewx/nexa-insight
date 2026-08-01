import XCTest
@testable import NexaInsightCore

private struct StubService: DiscoverFeedFetching {
    var videoOutcome: ChannelVideoOutcome = .parsed([])
    var uploads: [DiscoverEntry] = []
    var header: ChannelHeader = .empty
    var capturedQueries: Captured = Captured()

    final class Captured { var queries: [String] = [] }

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult {
        FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    }
    func resolveChannel(fromURL url: String) async throws -> Subscription {
        throw DiscoverFeedError.unrecognizedChannelLink
    }
    func searchVideosSiteWide(query: String) async -> ChannelVideoOutcome { .parsed([]) }
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome {
        capturedQueries.queries.append(query)
        return videoOutcome
    }
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] { uploads }
    func fetchChannelHeader(channelId: String) async -> ChannelHeader { header }
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
    private let channelId = "UCSHZKyawb77ixDdsGog4iWA"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ChannelDetailViewModelTests")!
        defaults.removePersistentDomain(forName: "ChannelDetailViewModelTests")
    }

    private func makeStore(following: Bool = false) -> SubscriptionStore {
        let store = SubscriptionStore(defaults: defaults)
        if following {
            store.add(Subscription(channelId: channelId, title: "Lex Fridman",
                                   addedAt: Date(timeIntervalSince1970: 0)))
        }
        return store
    }

    private func makeVM(_ service: StubService,
                        imported: Set<String> = [],
                        store: SubscriptionStore? = nil) -> ChannelDetailViewModel {
        ChannelDetailViewModel(
            channelId: channelId,
            fallbackTitle: "Lex Fridman",
            store: store ?? makeStore(),
            service: service,
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
        let vm = ChannelDetailViewModel(
            channelId: channelId, fallbackTitle: "Lex Fridman",
            store: makeStore(), service: StubService(),
            importedVideoIds: { box.ids })
        XCTAssertFalse(vm.isImported(videoId: "a"))
        box.ids.insert("a")
        XCTAssertTrue(vm.isImported(videoId: "a"))
    }

    // MARK: - Following
    //
    // This screen is the only place that writes to the subscription store, and it
    // must work for a channel the user has never followed — that is how someone
    // inspects a channel before deciding.

    func testOpensForAChannelNeverFollowed() async {
        var service = StubService()
        service.uploads = [upload("v1", "Something", at: 1000)]

        let vm = makeVM(service, store: makeStore(following: false))
        XCTAssertFalse(vm.following)

        await vm.loadUploads()
        XCTAssertEqual(vm.uploadCards.map(\.videoId), ["v1"],
                       "content loads whether or not the channel is followed")
    }

    func testFollowWritesToTheStore() async {
        let store = makeStore(following: false)
        let vm = makeVM(StubService(), store: store)

        vm.toggleFollow()

        XCTAssertTrue(vm.following)
        XCTAssertEqual(store.subscriptions.map(\.channelId), [channelId])
    }

    func testUnfollowRemovesFromTheStore() async {
        let store = makeStore(following: true)
        let vm = makeVM(StubService(), store: store)
        XCTAssertTrue(vm.following, "state is read from the store at init")

        vm.toggleFollow()

        XCTAssertFalse(vm.following)
        XCTAssertTrue(store.subscriptions.isEmpty)
    }

    func testFollowCapturesHeaderFieldsForTheChannelList() async {
        var service = StubService()
        service.header = ChannelHeader(
            title: "Lex Fridman Official",
            avatarURL: URL(string: "https://yt3.googleusercontent.com/a=s176"),
            subscriberText: "4.7M subscribers")

        let store = makeStore(following: false)
        let vm = makeVM(service, store: store)
        await vm.loadHeader()
        vm.toggleFollow()

        let saved = store.subscriptions[0]
        XCTAssertEqual(saved.title, "Lex Fridman Official")
        XCTAssertEqual(saved.avatarURL?.absoluteString, "https://yt3.googleusercontent.com/a=s176")
        XCTAssertEqual(saved.subscriberText, "4.7M subscribers",
                       "so the channel list shows an avatar instead of a monogram")
    }

    // MARK: - Header

    func testHeaderTitleWinsOverTheFallback() async {
        var service = StubService()
        service.header = ChannelHeader(title: "Lex Fridman Official", avatarURL: nil, subscriberText: nil)

        let vm = makeVM(service)
        XCTAssertEqual(vm.title, "Lex Fridman", "the tapped card's name is used until the header arrives")

        await vm.loadHeader()
        XCTAssertEqual(vm.title, "Lex Fridman Official")
    }

    // The contract that keeps a scrape failure from breaking the screen: YouTube
    // is migrating this layer, and the content below comes from other sources.
    func testHeaderFailureLeavesTheScreenUsable() async {
        var service = StubService()
        service.header = .empty
        service.uploads = [upload("v1", "Still here", at: 1000)]

        let vm = makeVM(service)
        await vm.load()

        XCTAssertEqual(vm.title, "Lex Fridman", "falls back to the name we arrived with")
        XCTAssertNil(vm.avatarURL)
        XCTAssertNil(vm.subscriberText)
        XCTAssertEqual(vm.uploadCards.map(\.videoId), ["v1"], "content is unaffected")
    }

    // MARK: - Cards

    // A tappable channel name here would navigate back to this same screen.
    func testCardsOnThisScreenCarryNoChannelLink() async {
        var service = StubService()
        service.uploads = [upload("v1", "From this channel", at: 1000)]
        service.videoOutcome = .parsed([video("a", "Alpha")])

        let vm = makeVM(service)
        await vm.loadUploads()
        vm.query = "physics"
        await vm.runSearch()

        XCTAssertFalse(vm.uploadCards[0].channelIsTappable)
        XCTAssertNil(vm.uploadCards[0].channelTitle)
        XCTAssertFalse(vm.resultCards[0].channelIsTappable)
    }

    // Search results have a duration, RSS uploads do not. Same card, one nil.
    func testDurationPresentOnSearchResultsAbsentOnUploads() async {
        var service = StubService()
        service.uploads = [upload("v1", "An upload", at: 1000)]
        service.videoOutcome = .parsed([video("a", "Alpha")])

        let vm = makeVM(service)
        await vm.loadUploads()
        XCTAssertNil(vm.uploadCards[0].durationText)

        vm.query = "physics"
        await vm.runSearch()
        XCTAssertEqual(vm.resultCards[0].durationText, "1:02:03")
    }
}
