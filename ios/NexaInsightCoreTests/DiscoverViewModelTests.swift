import XCTest
@testable import NexaInsightCore

private struct StubFeedService: DiscoverFeedFetching {
    var result = FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    var resolved: Subscription?
    var resolveError: Error?
    var searchOutcome: ChannelSearchOutcome = .parsed([])
    var videoOutcome: ChannelVideoOutcome = .parsed([])
    var uploads: [DiscoverEntry] = []

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult { result }

    func searchChannels(query: String) async -> ChannelSearchOutcome { searchOutcome }

    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome { videoOutcome }

    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] { uploads }

    func resolveChannel(fromURL url: String) async throws -> Subscription {
        if let resolveError { throw resolveError }
        guard let resolved else { throw DiscoverFeedError.unrecognizedChannelLink }
        return resolved
    }
}

private func searchResult(_ id: String, _ title: String) -> ChannelSearchResult {
    ChannelSearchResult(
        channelId: id, title: title, handle: "@\(title.lowercased())",
        subscriberText: "100K subscribers", summary: "about \(title)",
        thumbnailURL: nil)
}

private func entry(_ id: String, channel: String, title: String, at seconds: TimeInterval) -> DiscoverEntry {
    DiscoverEntry(
        videoId: id, channelId: channel, title: title, channelTitle: "Ch \(channel)",
        published: Date(timeIntervalSince1970: seconds), summary: "summary of \(title)",
        thumbnailURL: nil, viewCount: nil,
        watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
}

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DiscoverViewModelTests")!
        defaults.removePersistentDomain(forName: "DiscoverViewModelTests")
    }

    private func makeStore(_ channelIds: [String] = []) -> SubscriptionStore {
        let store = SubscriptionStore(defaults: defaults)
        for id in channelIds {
            store.add(Subscription(channelId: id, title: "Ch \(id)", addedAt: Date(timeIntervalSince1970: 0)))
        }
        return store
    }

    func testNoSubscriptionsMeansGuidanceStateAndNoFetch() async {
        let vm = DiscoverViewModel(store: makeStore(), service: StubFeedService())
        await vm.refresh()
        XCTAssertFalse(vm.hasSubscriptions)
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertNil(vm.feedError)
    }

    func testRefreshPopulatesEntries() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v2", channel: "UCb", title: "Newer", at: 2000),
                      entry("v1", channel: "UCa", title: "Older", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        XCTAssertEqual(vm.entries.map(\.videoId), ["v2", "v1"])
        XCTAssertFalse(vm.loading)
        XCTAssertNil(vm.feedError)
    }

    func testPartialFailureKeepsEntriesAndRecordsFailedChannel() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "Fine", at: 1000)],
            failedChannelIds: ["UCb"], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        XCTAssertEqual(vm.entries.count, 1, "a dead source must not blank the page")
        XCTAssertEqual(vm.failedChannelIds, ["UCb"])
        XCTAssertNil(vm.feedError, "partial failure is not a page-level error")
    }

    func testAllSourcesFailingSetsPageError() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(entries: [], failedChannelIds: ["UCa", "UCb"], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        XCTAssertNotNil(vm.feedError)
        XCTAssertTrue(vm.entries.isEmpty)
    }

    func testQueryFiltersOnTitleChannelAndSummary() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "Civil War history", at: 2000),
                      entry("v2", channel: "UCb", title: "Quantum physics", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()

        vm.query = "quantum"
        XCTAssertEqual(vm.visibleEntries.map(\.videoId), ["v2"])

        vm.query = "CIVIL"
        XCTAssertEqual(vm.visibleEntries.map(\.videoId), ["v1"], "matching is case-insensitive")

        vm.query = ""
        XCTAssertEqual(vm.visibleEntries.count, 2)
    }

    func testChannelFilterNarrowsToOneSubscription() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "From A", at: 2000),
                      entry("v2", channel: "UCb", title: "From B", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        vm.selectedChannelId = "UCb"
        XCTAssertEqual(vm.visibleEntries.map(\.videoId), ["v2"])
    }

    func testAddSubscriptionStoresAndRefreshes() async {
        var service = StubFeedService()
        service.resolved = Subscription(channelId: "UCnew", title: "New Channel", addedAt: Date(timeIntervalSince1970: 0))
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCnew", title: "First", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let store = makeStore()
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.addSubscription(url: "https://www.youtube.com/@new")

        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCnew"])
        XCTAssertEqual(vm.entries.map(\.videoId), ["v1"])
        XCTAssertNil(vm.addError)
    }

    func testAddSubscriptionSurfacesResolveFailure() async {
        var service = StubFeedService()
        service.resolveError = DiscoverFeedError.unrecognizedChannelLink

        let store = makeStore()
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.addSubscription(url: "not a channel")

        XCTAssertTrue(store.subscriptions.isEmpty)
        XCTAssertEqual(vm.addError, DiscoverFeedError.unrecognizedChannelLink.errorDescription)
    }

    func testRemoveSubscriptionDropsItsEntries() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "From A", at: 2000),
                      entry("v2", channel: "UCb", title: "From B", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let store = makeStore(["UCa", "UCb"])
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.refresh()
        vm.removeSubscription(channelId: "UCa")

        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCb"])
        XCTAssertEqual(vm.entries.map(\.videoId), ["v2"], "entries from a removed channel disappear immediately")
    }

    func testRemovingSelectedChannelClearsTheFilter() async {
        let store = makeStore(["UCa"])
        let vm = DiscoverViewModel(store: store, service: StubFeedService())
        vm.selectedChannelId = "UCa"
        vm.removeSubscription(channelId: "UCa")
        XCTAssertNil(vm.selectedChannelId)
    }

    func testRunSearchPopulatesResults() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha"), searchResult("UCb", "Beta")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")

        XCTAssertEqual(vm.searchResults.map(\.channelId), ["UCa", "UCb"])
        XCTAssertEqual(vm.searchedTerm, "philosophy")
        XCTAssertFalse(vm.searching)
        XCTAssertFalse(vm.searchUnavailable)
    }

    // Zero results is a real answer, not a malfunction: the UI shows "nothing
    // found", not "search is broken".
    func testZeroResultsIsNotUnavailable() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("zzqqxx")

        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertFalse(vm.searchUnavailable, "an empty result set is not a failure")
        XCTAssertEqual(vm.searchedTerm, "zzqqxx")
    }

    // The other case: the page shape changed. This one DOES tell the user search
    // is unavailable and to paste a link instead.
    func testStructureMissingSetsUnavailable() async {
        var service = StubFeedService()
        service.searchOutcome = .structureMissing

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")

        XCTAssertTrue(vm.searchUnavailable)
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testBlankSearchIsIgnored() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("   ")

        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertNil(vm.searchedTerm)
    }

    func testClearSearchResetsState() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")
        vm.clearSearch()

        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertNil(vm.searchedTerm)
        XCTAssertFalse(vm.searchUnavailable)
    }

    func testSubscribeFromResultStoresAndRefreshes() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCnew", "New Channel")])
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCnew", title: "First", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let store = makeStore()
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.runSearch("philosophy")
        await vm.subscribe(to: vm.searchResults[0])

        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCnew"])
        XCTAssertEqual(store.subscriptions[0].title, "New Channel")
        XCTAssertEqual(vm.entries.map(\.videoId), ["v1"])
    }

    func testIsFollowingReflectsStore() async {
        let store = makeStore(["UCa"])
        let vm = DiscoverViewModel(store: store, service: StubFeedService())
        XCTAssertTrue(vm.isFollowing(searchResult("UCa", "Alpha")))
        XCTAssertFalse(vm.isFollowing(searchResult("UCb", "Beta")))
    }

    func testSubscribingKeepsResultsVisibleSoFollowingStateShows() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha"), searchResult("UCb", "Beta")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")
        await vm.subscribe(to: vm.searchResults[0])

        XCTAssertEqual(vm.searchResults.count, 2, "results stay so the row can flip to Following")
        XCTAssertTrue(vm.isFollowing(vm.searchResults[0]))
        XCTAssertFalse(vm.isFollowing(vm.searchResults[1]))
    }
}
