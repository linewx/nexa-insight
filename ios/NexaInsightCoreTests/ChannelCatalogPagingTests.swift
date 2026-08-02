import XCTest
@testable import NexaInsightCore

// Paging behaviour for a channel's full catalog via the Data API.
//
// The interesting failures here are not parsing (covered in
// YouTubeAPIParserTests) but coordination: re-entrant scroll triggers, running out
// of pages, and falling back to RSS when the key does not work.
private struct StubAPI: YouTubeAPIFetching {
    // Pages served in order; each call takes the next one.
    var pages: [UploadsPage] = []
    var error: Error?
    let calls = Calls()

    final class Calls {
        var tokens: [String?] = []
        var topicCalls = 0
        var searchQueries: [String] = []
        var count: Int { tokens.count }
    }

    func fetchUploads(channelId: String, pageToken: String?) async throws -> UploadsPage {
        calls.tokens.append(pageToken)
        if let error { throw error }
        let index = calls.count - 1
        guard index < pages.count else { return .empty }
        return pages[index]
    }

    var topics: [String: [String]] = [:]
    var searchResults: [ChannelVideo] = []

    func fetchTopics(channelIds: [String]) async throws -> [String: [String]] {
        calls.topicCalls += 1
        return topics
    }

    func searchTopic(query: String) async throws -> [ChannelVideo] {
        // Counted, because search.list costs 100 units from a 100/day bucket — a
        // test that lets this run twice is describing a real quota bug.
        calls.searchQueries.append(query)
        return searchResults
    }
}

private struct StubFeed: DiscoverFeedFetching {
    var uploads: [DiscoverEntry] = []
    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult {
        FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    }
    func resolveChannel(fromURL url: String) async throws -> Subscription {
        throw DiscoverFeedError.unrecognizedChannelLink
    }
    var siteWideOutcome: ChannelVideoOutcome = .parsed([])
    let siteWideCalls = SiteWideCalls()

    final class SiteWideCalls {
        var queries: [String] = []
        var recentFlags: [Bool] = []
    }

    func searchVideosSiteWide(query: String, recentOnly: Bool) async -> ChannelVideoOutcome {
        siteWideCalls.queries.append(query)
        siteWideCalls.recentFlags.append(recentOnly)
        return siteWideOutcome
    }
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome { .parsed([]) }
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] { uploads }
    func fetchChannelHeader(channelId: String) async -> ChannelHeader { .empty }
}

private func video(_ id: String) -> ChannelVideo {
    ChannelVideo(videoId: id, title: "Video \(id)", durationText: "1:02:03",
                 viewsText: "10K views", publishedText: "2 years ago",
                 summary: nil, thumbnailURL: nil)
}

private func upload(_ id: String, at seconds: TimeInterval) -> DiscoverEntry {
    DiscoverEntry(videoId: id, channelId: "UCSHZKyawb77ixDdsGog4iWA", title: "RSS \(id)",
                  channelTitle: "Lex Fridman", published: Date(timeIntervalSince1970: seconds),
                  summary: nil, thumbnailURL: nil, viewCount: nil,
                  watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
}

@MainActor
final class ChannelCatalogPagingTests: XCTestCase {
    private let channelId = "UCSHZKyawb77ixDdsGog4iWA"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ChannelCatalogPagingTests")!
        defaults.removePersistentDomain(forName: "ChannelCatalogPagingTests")
    }

    private func makeVM(api: YouTubeAPIFetching?, feed: StubFeed = StubFeed()) -> ChannelDetailViewModel {
        ChannelDetailViewModel(
            channelId: channelId, fallbackTitle: "Lex Fridman",
            store: SubscriptionStore(defaults: defaults),
            service: feed, api: api, importedVideoIds: { [] })
    }

    func testFirstPagePopulatesCatalogAndTotal() async {
        var api = StubAPI()
        api.pages = [UploadsPage(videos: [video("a"), video("b")],
                                 nextPageToken: "TOKEN2", totalCount: 865)]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()

        XCTAssertEqual(vm.catalog.map(\.videoId), ["a", "b"])
        XCTAssertEqual(vm.catalogTotal, 865, "so the UI can say 2 of 865, not just 2")
        XCTAssertTrue(vm.canLoadMore)
    }

    func testLoadMoreAppendsAndAdvancesTheToken() async {
        var api = StubAPI()
        api.pages = [
            UploadsPage(videos: [video("a")], nextPageToken: "TOKEN2", totalCount: 3),
            UploadsPage(videos: [video("b")], nextPageToken: "TOKEN3", totalCount: 3),
        ]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()
        await vm.loadMoreIfNeeded()

        XCTAssertEqual(vm.catalog.map(\.videoId), ["a", "b"])
        XCTAssertEqual(api.calls.tokens, [nil, "TOKEN2"], "the second call must carry the token")
    }

    // A scroll trigger can fire repeatedly before the first request returns. Each
    // firing would append the same page again, and duplicate SwiftUI ids corrupt
    // the list rather than merely showing an extra row.
    func testConcurrentTriggersDoNotDoubleAppend() async {
        var api = StubAPI()
        api.pages = [
            UploadsPage(videos: [video("a")], nextPageToken: "TOKEN2", totalCount: 10),
            UploadsPage(videos: [video("b")], nextPageToken: "TOKEN3", totalCount: 10),
            UploadsPage(videos: [video("c")], nextPageToken: nil, totalCount: 10),
        ]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { await vm.loadMoreIfNeeded() } }
        }

        XCTAssertEqual(Set(vm.catalog.map(\.videoId)).count, vm.catalog.count,
                       "no duplicate ids: \(vm.catalog.map(\.videoId))")
    }

    // Belt and braces alongside the re-entry guard: the API returned no overlap
    // between consecutive pages when measured, but appending blind would corrupt
    // the list if that ever changed.
    func testOverlappingPagesAreDeduped() async {
        var api = StubAPI()
        api.pages = [
            UploadsPage(videos: [video("a"), video("b")], nextPageToken: "T2", totalCount: 3),
            UploadsPage(videos: [video("b"), video("c")], nextPageToken: nil, totalCount: 3),
        ]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()
        await vm.loadMoreIfNeeded()

        XCTAssertEqual(vm.catalog.map(\.videoId), ["a", "b", "c"], "b must appear once")
    }

    func testPagingStopsWhenTokenRunsOut() async {
        var api = StubAPI()
        api.pages = [UploadsPage(videos: [video("a")], nextPageToken: nil, totalCount: 1)]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()

        XCTAssertFalse(vm.canLoadMore, "no token means the end; otherwise the UI spins forever")
        await vm.loadMoreIfNeeded()
        XCTAssertEqual(api.calls.count, 1, "and no further requests are made")
    }

    // Failing mid-scroll must not retry on every tick — that would burn quota
    // against a dead key while the user keeps scrolling.
    func testPagingFailureStopsFurtherRequests() async {
        var api = StubAPI()
        api.pages = [UploadsPage(videos: [video("a")], nextPageToken: "T2", totalCount: 10)]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()

        api = StubAPI()   // fresh stub that always errors
        api.error = YouTubeAPIError.rejected(reason: "quotaExceeded")
        let failing = makeVM(api: api)
        await failing.loadFirstPage()
        await failing.loadMoreIfNeeded()
        await failing.loadMoreIfNeeded()

        XCTAssertEqual(api.calls.count, 1, "one failed attempt, then it stops")
        XCTAssertNotNil(failing.catalogError)
        XCTAssertTrue(failing.catalogError?.lowercased().contains("quota") ?? false,
                      "quota exhaustion reads differently from a bad key")
    }

    // MARK: - Fallback

    // A user with no key is the normal case, not an error case.
    func testNoKeyUsesRSSUploads() async {
        var feed = StubFeed()
        feed.uploads = [upload("r1", at: 2000), upload("r2", at: 1000)]

        let vm = makeVM(api: nil, feed: feed)
        await vm.load()

        XCTAssertTrue(vm.catalog.isEmpty)
        XCTAssertFalse(vm.hasCatalog)
        XCTAssertEqual(vm.uploadCards.map(\.videoId), ["r1", "r2"])
    }

    // A key that is rejected must degrade to the shorter list, not an empty screen.
    func testRejectedKeyFallsBackToRSS() async {
        var api = StubAPI()
        api.error = YouTubeAPIError.rejected(reason: "badRequest")
        var feed = StubFeed()
        feed.uploads = [upload("r1", at: 2000)]

        let vm = makeVM(api: api, feed: feed)
        await vm.load()

        XCTAssertTrue(vm.catalog.isEmpty)
        XCTAssertEqual(vm.uploadCards.map(\.videoId), ["r1"], "content, not an error state")
        XCTAssertNotNil(vm.catalogError, "but the reason is still surfaced")
    }

    // The catalog is the whole channel with durations; RSS is 15 entries without.
    // When both exist the catalog must win, or the extra request bought nothing.
    func testCatalogWinsOverRSSWhenBothLoaded() async {
        var api = StubAPI()
        api.pages = [UploadsPage(videos: [video("a")], nextPageToken: nil, totalCount: 1)]
        var feed = StubFeed()
        feed.uploads = [upload("r1", at: 2000)]

        let vm = makeVM(api: api, feed: feed)
        await vm.load()

        XCTAssertEqual(vm.uploadCards.map(\.videoId), ["a"])
        XCTAssertEqual(vm.uploadCards[0].durationText, "1:02:03", "the catalog carries duration")
    }

    // Pull-to-refresh must reset paging, or the next scroll would append page 2 of
    // the old list onto page 1 of the new one.
    func testReloadResetsPagingState() async {
        var api = StubAPI()
        api.pages = [
            UploadsPage(videos: [video("a")], nextPageToken: "T2", totalCount: 3),
            UploadsPage(videos: [video("b")], nextPageToken: "T3", totalCount: 3),
            UploadsPage(videos: [video("c")], nextPageToken: "T2", totalCount: 3),
        ]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()
        await vm.loadMoreIfNeeded()
        XCTAssertEqual(vm.catalog.count, 2)

        await vm.reload()

        // tokens.last is String?? — flatten it, or the assertion compares
        // Optional(nil) against nil and fails for the wrong reason.
        XCTAssertNil(api.calls.tokens.last ?? "sentinel", "refresh starts from the first page")
        XCTAssertEqual(vm.catalog.map(\.videoId), ["c"], "the old pages are dropped")
    }

    // Cards on a channel's own screen never link back to that channel.
    func testCatalogCardsCarryNoChannelLink() async {
        var api = StubAPI()
        api.pages = [UploadsPage(videos: [video("a")], nextPageToken: nil, totalCount: 1)]

        let vm = makeVM(api: api)
        await vm.loadFirstPage()

        XCTAssertFalse(vm.uploadCards[0].channelIsTappable)
    }
}


// Exploration is the one path that spends the expensive quota, so these lock the
// spending rules rather than the recommendations themselves.
@MainActor
final class ExplorationQuotaTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ExplorationQuotaTests")!
        defaults.removePersistentDomain(forName: "ExplorationQuotaTests")
    }

    private func makeVM(_ api: StubAPI, subs: [String] = ["UCSHZKyawb77ixDdsGog4iWA"])
        -> (DiscoverViewModel, StubFeed) {
        let store = SubscriptionStore(defaults: defaults)
        for id in subs {
            store.add(Subscription(channelId: id, title: "Ch", addedAt: Date(timeIntervalSince1970: 0)))
        }
        let feed = StubFeed()
        let vm = DiscoverViewModel(
            store: store, service: feed, api: api,
            episodesProvider: { [] },
            explorationCache: ExplorationCache(defaults: defaults))
        return (vm, feed)
    }

    private func stub() -> StubAPI {
        var api = StubAPI()
        api.pages = [UploadsPage(videos: [video("a")], nextPageToken: nil, totalCount: 1)]
        api.topics = ["UCSHZKyawb77ixDdsGog4iWA": ["Knowledge"]]
        api.searchResults = [video("x"), video("y")]
        return api
    }

    // search.list has its own bucket of exactly 100 calls per day. Refreshing must
    // reuse the cached result, or a few pull-to-refreshes exhaust the day.
    func testSearchesAtMostOncePerDay() async {
        let api = stub()
        let (vm, _) = makeVM(api)

        await vm.refresh()
        await vm.refresh()
        await vm.refresh()

        XCTAssertEqual(api.calls.searchQueries.count, 1,
                       "three refreshes must not mean three searches")
    }

    // A search that fails or returns nothing still consumed the quota, so it must
    // not be retried on the next refresh.
    func testFailedSearchDoesNotRetryToday() async {
        var api = stub()
        api.searchResults = []
        let (vm, _) = makeVM(api)

        await vm.refresh()
        await vm.refresh()

        XCTAssertEqual(api.calls.searchQueries.count, 1, "an empty result still cost 100 units")
    }

    // Profiling is 1 unit for every channel at once, so it runs before deciding
    // whether the expensive call is worthwhile.
    func testProfilesTopicsBeforeSearching() async {
        let api = stub()
        let (vm, _) = makeVM(api)
        await vm.refresh()
        XCTAssertEqual(api.calls.topicCalls, 1)
        XCTAssertEqual(api.calls.searchQueries.first, Recommend.query(for: "History"))
    }

    // With no topic profile there is nothing to reason from, so no search happens.
    func testNoProfileMeansNoSearch() async {
        var api = stub()
        api.topics = [:]
        let (vm, _) = makeVM(api)
        await vm.refresh()
        XCTAssertTrue(api.calls.searchQueries.isEmpty)
        XCTAssertTrue(vm.exploration.isEmpty)
    }

    // A suggestion from a channel you already follow is not a suggestion.
    func testDropsResultsFromFollowedChannels() async {
        var api = stub()
        api.searchResults = [
            ChannelVideo(videoId: "own", title: "From a followed channel",
                         durationText: nil, viewsText: nil, publishedText: nil,
                         summary: nil, thumbnailURL: nil,
                         channelTitle: "Ch", channelId: "UCSHZKyawb77ixDdsGog4iWA"),
            video("new"),
        ]
        let (vm, _) = makeVM(api)
        await vm.refresh()
        XCTAssertFalse(vm.exploration.map(\.videoId).contains("own"))
    }

    // The marker is the only thing distinguishing a suggestion once it is mixed in.
    func testSuggestionsAreIdentifiable() async {
        let api = stub()
        let (vm, _) = makeVM(api)
        await vm.refresh()
        XCTAssertFalse(vm.explorationIds.isEmpty)
        XCTAssertNotNil(vm.explorationTopic)
    }
}


// Cold start: what Discover shows before anything is followed.
@MainActor
final class ColdStartTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ColdStartTests")!
        defaults.removePersistentDomain(forName: "ColdStartTests")
    }

    private func makeVM(_ api: StubAPI?) -> DiscoverViewModel {
        DiscoverViewModel(
            store: SubscriptionStore(defaults: defaults),   // deliberately empty
            service: StubFeed(), api: api,
            episodesProvider: { [] },
            explorationCache: ExplorationCache(defaults: defaults, namespace: "exp"),
            coldStartCache: ExplorationCache(defaults: defaults, namespace: "cold"))
    }

    private func stub() -> StubAPI {
        var api = StubAPI()
        api.searchResults = [video("a"), video("b"), video("c")]
        return api
    }

    // The point of the feature: an empty follow list produces content, not an
    // instruction telling the user to go find some.
    func testNoSubscriptionsYieldsSuggestions() async {
        let api = stub()
        let vm = makeVM(api)
        await vm.refresh()
        XCTAssertFalse(vm.hasSubscriptions)
        XCTAssertEqual(vm.coldStartCards.map(\.videoId), ["a", "b", "c"])
    }

    // Same quota rule as exploration: search.list draws on a 100-per-day bucket, so
    // pulling to refresh must not spend it again.
    func testSearchesOncePerDay() async {
        let api = stub()
        let vm = makeVM(api)
        await vm.refresh()
        await vm.refresh()
        await vm.refresh()
        XCTAssertEqual(api.calls.searchQueries.count, 1)
    }

    // An empty or failed result still consumed the quota.
    func testFailedSearchDoesNotRetryToday() async {
        var api = stub()
        api.searchResults = []
        let vm = makeVM(api)
        await vm.refresh()
        await vm.refresh()
        XCTAssertEqual(api.calls.searchQueries.count, 1)
    }

    // Without a key there is nothing to search with, and the screen falls back to the
    // written prompt rather than showing a spinner forever.
    func testNoApiKeyMeansNoSuggestionsAndNoSpinner() async {
        let vm = makeVM(nil)
        await vm.refresh()
        XCTAssertTrue(vm.coldStartCards.isEmpty)
        XCTAssertFalse(vm.coldStartLoading)
    }

    // Cold start and topic exploration share the cache type; they must not share a
    // slot, or one would be served as the other.
    func testColdStartAndExplorationDoNotShareCacheEntries() async {
        let cold = ExplorationCache(defaults: defaults, namespace: "cold")
        let exp = ExplorationCache(defaults: defaults, namespace: "exp")
        cold.store(topic: "english learning podcast", videos: [video("x")])
        XCTAssertTrue(cold.isFresh())
        XCTAssertFalse(exp.isFresh(), "the other namespace is untouched")
        XCTAssertTrue(exp.videos().isEmpty)
    }

    // Once channels exist, the feed replaces the suggestions.
    func testSubscriptionsTakeOverFromColdStart() async {
        var api = stub()
        api.pages = [UploadsPage(videos: [video("feed")], nextPageToken: nil, totalCount: 1)]
        let store = SubscriptionStore(defaults: defaults)
        store.add(Subscription(channelId: "UCSHZKyawb77ixDdsGog4iWA", title: "Ch",
                               addedAt: Date(timeIntervalSince1970: 0)))
        let vm = DiscoverViewModel(
            store: store, service: StubFeed(), api: api,
            episodesProvider: { [] },
            explorationCache: ExplorationCache(defaults: defaults, namespace: "exp"),
            coldStartCache: ExplorationCache(defaults: defaults, namespace: "cold"))

        await vm.refresh()
        XCTAssertTrue(vm.coldStartCards.isEmpty, "no cold start once there is a real feed")
        XCTAssertFalse(vm.feedCards.isEmpty)
    }
}


// The cache round-trip, which is where cold start silently produced nothing: the
// search had succeeded and 10 videos were stored, but the screen still showed the
// empty-state prompt.
@MainActor
final class ExplorationCacheRoundTripTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ExplorationCacheRoundTripTests")!
        defaults.removePersistentDomain(forName: "ExplorationCacheRoundTripTests")
    }

    func testStoredVideosSurviveAndStillBuildCards() {
        let cache = ExplorationCache(defaults: defaults, namespace: "cold")
        let original = ChannelVideo(
            videoId: "XyXBwO5jYpw", title: "How to Stay Ahead as a Software Engineer",
            durationText: "1:02:03", viewsText: "10K views", publishedText: "2 days ago",
            summary: "a talk", thumbnailURL: URL(string: "https://i.ytimg.com/vi/x/hq.jpg"),
            channelTitle: "Some Channel", channelId: "UCSHZKyawb77ixDdsGog4iWA")

        cache.store(topic: "software engineering talk", videos: [original])
        let restored = cache.videos()

        XCTAssertEqual(restored.count, 1, "the payload decodes")
        XCTAssertEqual(restored.first?.videoId, original.videoId)
        XCTAssertEqual(restored.first?.durationText, "1:02:03")

        // The step that actually failed: a restored video must still form a card.
        // VideoCardItem's initialiser is failable on watchURL, so a round trip that
        // loses videoId yields an empty list and an apparently broken feature.
        let cards = restored.compactMap { VideoCardItem($0) }
        XCTAssertEqual(cards.count, 1, "restored videos must still produce cards")
        XCTAssertEqual(cards.first?.title, original.title)
    }
}


// Regression lock on the reason cold start appeared broken: the client was captured
// at init, and DiscoverViewModel is a @StateObject whose initialiser runs once for the
// life of the screen. A key entered in Settings therefore did nothing until relaunch.
@MainActor
final class LazyAPIResolutionTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LazyAPIResolutionTests")!
        defaults.removePersistentDomain(forName: "LazyAPIResolutionTests")
    }

    func testKeyAddedAfterInitTakesEffectOnNextRefresh() async {
        // Starts with no key, exactly as a first launch does.
        final class Box { var api: YouTubeAPIFetching? }
        let box = Box()

        var stub = StubAPI()
        stub.searchResults = [video("a"), video("b")]

        let vm = DiscoverViewModel(
            store: SubscriptionStore(defaults: defaults),
            service: StubFeed(),
            apiProvider: { box.api },
            episodesProvider: { [] },
            explorationCache: ExplorationCache(defaults: defaults, namespace: "exp"),
            coldStartCache: ExplorationCache(defaults: defaults, namespace: "cold"))

        await vm.refresh()
        XCTAssertTrue(vm.coldStartCards.isEmpty, "no key yet, so nothing to suggest")

        // The user enters a key in Settings; no relaunch.
        box.api = stub
        await vm.refresh()

        XCTAssertEqual(vm.coldStartCards.count, 2,
                       "a key added after init must work without relaunching")
    }
}


// The first-run case: no API key, which is what every new user has.
@MainActor
final class KeylessColdStartTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "KeylessColdStartTests")!
        defaults.removePersistentDomain(forName: "KeylessColdStartTests")
    }

    private func makeVM(_ feed: StubFeed) -> DiscoverViewModel {
        DiscoverViewModel(
            store: SubscriptionStore(defaults: defaults),   // no channels
            service: feed,
            api: nil,                                        // and no key
            episodesProvider: { [] },
            explorationCache: ExplorationCache(defaults: defaults, namespace: "exp"),
            coldStartCache: ExplorationCache(defaults: defaults, namespace: "cold"))
    }

    // Without this, a brand-new install showed a prompt telling the user to go find
    // content — the empty screen was the default first experience, even though the
    // scraped search needs neither a key nor quota.
    func testSuggestsWithoutAnApiKey() async {
        var feed = StubFeed()
        feed.siteWideOutcome = .parsed([video("a"), video("b")])
        let vm = makeVM(feed)

        await vm.refresh()

        XCTAssertEqual(vm.coldStartCards.count, 2)
        XCTAssertEqual(feed.siteWideCalls.queries.count, 1)
        XCTAssertTrue(Recommend.coldStartQueries.contains(feed.siteWideCalls.queries[0]))
    }

    // The scraped path costs no quota, so the daily cache must not lock it out — that
    // throttle exists only to protect the 100-per-day search.list budget.
    func testKeylessPathIsNotRateLimitedByTheDailyCache() async {
        var feed = StubFeed()
        feed.siteWideOutcome = .parsed([video("a")])
        let vm = makeVM(feed)

        await vm.refresh()
        XCTAssertFalse(vm.coldStart.isEmpty)

        // A second view model on the same defaults, as a relaunch would produce.
        let again = makeVM(feed)
        await again.refresh()
        XCTAssertFalse(again.coldStart.isEmpty, "no key means no quota to preserve")
    }

    // The filter belongs on cold start and nowhere else. Measured on one query:
    // unfiltered results mixed 3-day-old and 10-month-old uploads, while YouTube's
    // this-month filter returned everything within three days.
    func testColdStartAsksForRecentResults() async {
        var feed = StubFeed()
        feed.siteWideOutcome = .parsed([video("a")])
        let vm = makeVM(feed)
        await vm.refresh()
        XCTAssertEqual(feed.siteWideCalls.recentFlags, [true])
    }

    // But a user hunting a specific talk must not have it hidden for being a year old.
    func testUserSearchIsNotDateFiltered() async {
        var feed = StubFeed()
        feed.siteWideOutcome = .parsed([video("a")])
        let vm = makeVM(feed)
        await vm.runSearch("andrew strominger black holes")
        XCTAssertEqual(feed.siteWideCalls.recentFlags.last, false)
    }

    // A broken scrape leaves the written prompt rather than a permanent spinner.
    func testStructureMissingLeavesNoSuggestionsAndNoSpinner() async {
        var feed = StubFeed()
        feed.siteWideOutcome = .structureMissing
        let vm = makeVM(feed)

        await vm.refresh()

        XCTAssertTrue(vm.coldStartCards.isEmpty)
        XCTAssertFalse(vm.coldStartLoading)
    }
}
