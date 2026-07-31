import XCTest
@testable import NexaInsightCore

private struct StubFeedService: DiscoverFeedFetching {
    var result = FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    var resolved: Subscription?
    var resolveError: Error?

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult { result }

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
}
