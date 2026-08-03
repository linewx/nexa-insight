import XCTest
@testable import NexaInsightCore

private struct StubFeedService: DiscoverFeedFetching {
    var result = FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    var resolved: Subscription?
    var resolveError: Error?
    var siteWideOutcome: ChannelVideoOutcome = .parsed([])
    var videoOutcome: ChannelVideoOutcome = .parsed([])
    var uploads: [DiscoverEntry] = []
    var header: ChannelHeader = .empty
    var captured = Captured()

    final class Captured {
        var siteWideQueries: [String] = []
        var recentFlags: [Bool] = []
        var feedRequests = 0
    }

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult {
        captured.feedRequests += 1
        return result
    }

    func searchVideosSiteWide(query: String, recentOnly: Bool) async -> ChannelVideoOutcome {
        captured.siteWideQueries.append(query)
        captured.recentFlags.append(recentOnly)
        return siteWideOutcome
    }

    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome { videoOutcome }

    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] { uploads }

    func fetchChannelHeader(channelId: String) async -> ChannelHeader { header }

    func resolveChannel(fromURL url: String) async throws -> Subscription {
        if let resolveError { throw resolveError }
        guard let resolved else { throw DiscoverFeedError.unrecognizedChannelLink }
        return resolved
    }
}

private func entry(_ id: String, channel: String, title: String, at seconds: TimeInterval) -> DiscoverEntry {
    DiscoverEntry(
        videoId: id, channelId: channel, title: title, channelTitle: "Ch \(channel)",
        published: Date(timeIntervalSince1970: seconds), summary: "summary of \(title)",
        thumbnailURL: nil, viewCount: nil,
        watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
}

private func video(_ id: String, _ title: String,
                   channelTitle: String? = "Some Channel",
                   channelId: String? = "UCSHZKyawb77ixDdsGog4iWA") -> ChannelVideo {
    ChannelVideo(
        videoId: id, title: title, durationText: "1:02:03",
        viewsText: "10K views", publishedText: "2 years ago",
        summary: "about \(title)", thumbnailURL: nil,
        channelTitle: channelTitle, channelId: channelId)
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

    // MARK: - Feed

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

    // MARK: - Tabs

    func testStartsOnLatestTab() {
        let vm = DiscoverViewModel(store: makeStore(), service: StubFeedService())
        XCTAssertEqual(vm.tab, .latest)
    }

    func testTabSelectionSurvivesASearch() async {
        var service = StubFeedService()
        service.siteWideOutcome = .parsed([video("a", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        vm.tab = .channels
        await vm.runSearch("quantum gravity")
        XCTAssertTrue(vm.isSearchActive)
        XCTAssertEqual(vm.tab, .channels, "search covers the tabs; it does not reset them")

        vm.clearSearch()
        XCTAssertFalse(vm.isSearchActive)
        XCTAssertEqual(vm.tab, .channels, "leaving search returns to the tab you were on")
    }

    // MARK: - Search

    // The core semantic change: Discover's search box returns videos, not
    // channels. Previously the same-looking box inside a channel returned videos
    // while this one returned channels.
    func testSearchReturnsVideos() async {
        var service = StubFeedService()
        service.siteWideOutcome = .parsed([video("a", "Alpha"), video("b", "Beta")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("quantum gravity")

        XCTAssertEqual(vm.results.map(\.videoId), ["a", "b"])
        XCTAssertEqual(vm.searchedTerm, "quantum gravity")
        XCTAssertFalse(vm.searching)
        XCTAssertFalse(vm.searchUnavailable)
    }

    // Typing used to filter the feed locally while submitting ran a network
    // search, so the keystrokes and the results were unrelated. Now typing does
    // nothing at all until submitted.
    func testTypingIssuesNoRequest() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "Quantum physics", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa"]), service: service)
        await vm.refresh()
        let requestsAfterRefresh = service.captured.feedRequests

        vm.query = "quantum"

        XCTAssertTrue(service.captured.siteWideQueries.isEmpty, "typing must not search")
        XCTAssertEqual(service.captured.feedRequests, requestsAfterRefresh, "typing must not refetch")
        XCTAssertFalse(vm.isSearchActive, "the feed stays visible while typing")
        XCTAssertEqual(vm.feedCards.count, 1, "and is not filtered down")
    }

    func testSearchResultsCarryTheChannelSoItCanBeFollowed() async {
        var service = StubFeedService()
        service.siteWideOutcome = .parsed([
            video("a", "Alpha", channelTitle: "PBS Space Time", channelId: "UCHnyfMqiRRG1u-2MsSQLbXA")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("quantum gravity")

        let card = vm.resultCards[0]
        XCTAssertEqual(card.channelTitle, "PBS Space Time")
        XCTAssertTrue(card.channelIsTappable, "tapping the channel name is the only way to follow")
    }

    // Zero results is a real answer, not a malfunction: the UI shows "nothing
    // found", not "search is broken".
    func testZeroResultsIsNotUnavailable() async {
        var service = StubFeedService()
        service.siteWideOutcome = .parsed([])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("zzqqxx")

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.searchUnavailable, "an empty result set is not a failure")
        XCTAssertEqual(vm.searchedTerm, "zzqqxx")
        XCTAssertTrue(vm.isSearchActive, "and the results page is still shown")
    }

    // The other case: the page shape changed. This one DOES tell the user search
    // is unavailable and to paste a link instead.
    func testStructureMissingSetsUnavailable() async {
        var service = StubFeedService()
        service.siteWideOutcome = .structureMissing

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("quantum gravity")

        XCTAssertTrue(vm.searchUnavailable)
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testBlankSearchIsIgnored() async {
        var service = StubFeedService()
        service.siteWideOutcome = .parsed([video("a", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("   ")

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.searchedTerm)
        XCTAssertTrue(service.captured.siteWideQueries.isEmpty)
    }

    func testSearchPreservesRelevanceOrder() async {
        var service = StubFeedService()
        service.siteWideOutcome = .parsed([video("old", "Older upload"), video("new", "Newer upload")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("physics")

        XCTAssertEqual(vm.results.map(\.videoId), ["old", "new"],
                       "YouTube relevance order must not be re-sorted by date")
    }

    func testClearSearchResetsStateAndQuery() async {
        var service = StubFeedService()
        service.siteWideOutcome = .parsed([video("a", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        vm.query = "quantum gravity"
        await vm.runSearch("quantum gravity")
        vm.clearSearch()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.searchedTerm)
        XCTAssertFalse(vm.searchUnavailable)
        XCTAssertEqual(vm.query, "", "Back and the clear button are the same action")
    }

    func testSearchDoesNotDisturbTheFeed() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "From the feed", at: 1000)],
            failedChannelIds: [], channelTitles: [:])
        service.siteWideOutcome = .parsed([video("a", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(["UCa"]), service: service)
        await vm.refresh()
        await vm.runSearch("physics")
        vm.clearSearch()

        XCTAssertEqual(vm.feedCards.map(\.videoId), ["v1"], "the feed survives a search round-trip")
    }

    // MARK: - Cards

    // One card type for both sources, differing only where the data genuinely
    // does: RSS carries no duration.
    func testFeedCardsHaveNoDurationAndSearchCardsDo() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "From RSS", at: 1000)],
            failedChannelIds: [], channelTitles: [:])
        service.siteWideOutcome = .parsed([video("a", "From search")])

        let vm = DiscoverViewModel(store: makeStore(["UCa"]), service: service)
        await vm.refresh()
        XCTAssertNil(vm.feedCards[0].durationText)

        await vm.runSearch("physics")
        XCTAssertEqual(vm.resultCards[0].durationText, "1:02:03")
    }

    func testFeedCardsAreTappableThroughToTheirChannel() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCSHZKyawb77ixDdsGog4iWA", title: "From RSS", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCSHZKyawb77ixDdsGog4iWA"]), service: service)
        await vm.refresh()
        XCTAssertTrue(vm.feedCards[0].channelIsTappable)
    }

    // MARK: - Subscriptions

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

    // Following happens on the channel screen, so coming back has to pick that
    // up — but only when the set actually changed, or every back-navigation would
    // refetch every channel's feed.
    func testReturningFromAChannelRefreshesOnlyWhenFollowsChanged() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])

        let store = makeStore(["UCa"])
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.refresh()
        let baseline = service.captured.feedRequests

        await vm.syncAfterChannelVisit(previousChannelIds: ["UCa"])
        XCTAssertEqual(service.captured.feedRequests, baseline, "nothing changed, so no refetch")

        store.add(Subscription(channelId: "UCb", title: "Ch UCb", addedAt: Date(timeIntervalSince1970: 0)))
        await vm.syncAfterChannelVisit(previousChannelIds: ["UCa"])
        XCTAssertEqual(service.captured.feedRequests, baseline + 1, "a new follow refreshes the feed")
    }
}
