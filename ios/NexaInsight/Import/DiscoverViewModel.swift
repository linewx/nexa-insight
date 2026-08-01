import Foundation

// State for the Discover screen.
//
// The screen has exactly two shapes, and this type's job is to keep them from
// bleeding into each other:
//
//   empty query  → two tabs (Latest feed / My channels)
//   submitted    → search state covering both tabs
//
// An earlier version had `query` doing two jobs — filtering the feed locally as
// you typed AND running a channel search on submit — so the keystrokes and the
// results were unrelated. Typing now does nothing until submitted.
@MainActor
final class DiscoverViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case latest
        case channels

        var id: String { rawValue }

        var title: String {
            switch self {
            case .latest: return "Latest"
            case .channels: return "My channels"
            }
        }
    }

    // Feed
    @Published var entries: [DiscoverEntry] = []
    @Published var loading = false
    // Two error channels on purpose: feedError is page-level (every source
    // failed) while failedChannelIds marks individual dead sources without
    // hiding the entries that did load.
    @Published var feedError: String?
    @Published var failedChannelIds: [String] = []
    @Published var addError: String?

    // Navigation
    @Published var tab: Tab = .latest

    // Search
    @Published var query = ""
    @Published var results: [ChannelVideo] = []
    @Published var searching = false
    // True only when the page could not be read at all — never for an empty
    // result set, which is a legitimate answer.
    @Published var searchUnavailable = false
    @Published var searchedTerm: String?

    // The API-sourced feed, kept separate from `entries` (RSS) because only one is
    // ever in use — exactly one of the two is non-empty at any time.
    @Published var apiEntries: [ChannelVideo] = []
    // Videos from outside the followed set, mixed into the feed and marked. Kept
    // separate so a bad recommendation can be identified and removed rather than
    // being indistinguishable from a subscription.
    @Published var exploration: [ChannelVideo] = []
    @Published var explorationTopic: String?
    // Engagement per channel, from local playback data. No network cost.
    private var engagement: [String: ChannelEngagement] = [:]
    // How the app learns what a channel is about, so it knows what is adjacent.
    private var topicProfile: [String: [String]] = [:]

    private let store: SubscriptionStore
    private let service: DiscoverFeedFetching
    // nil when no API key is configured, which is the normal state for a user who
    // has not set one up. Every path degrades to RSS rather than erroring.
    private let api: YouTubeAPIFetching?

    // Local engagement data, injected so this stays testable without a store.
    private let episodesProvider: () -> [EpisodeDTO]
    private let explorationCache: ExplorationCache
    // A closure, not a stored value: the Settings toggle can change while Discover
    // is on screen, and a captured Locale would keep the old language until relaunch.
    private let bylineLocale: () -> Locale

    init(store: SubscriptionStore,
         service: DiscoverFeedFetching,
         api: YouTubeAPIFetching? = nil,
         episodesProvider: @escaping () -> [EpisodeDTO] = { [] },
         explorationCache: ExplorationCache = ExplorationCache(),
         bylineLocale: @escaping () -> Locale = { DiscoverFormat.defaultLocale }) {
        self.store = store
        self.service = service
        self.api = api
        self.episodesProvider = episodesProvider
        self.explorationCache = explorationCache
        self.bylineLocale = bylineLocale
    }

    var subscriptions: [Subscription] { store.subscriptions }
    var hasSubscriptions: Bool { !store.subscriptions.isEmpty }

    // Search covers the tabs rather than living inside one, so the tab selection
    // is preserved underneath and restored on exit.
    var isSearchActive: Bool { searchedTerm != nil }

    // One card type for both sources, so the feed and search results look
    // identical apart from the data they genuinely have. The API feed wins when
    // present — it carries durations, which RSS does not.
    var feedCards: [VideoCardItem] {
        let locale = bylineLocale()
        let followed = apiEntries.isEmpty
            ? entries.map { VideoCardItem($0, locale: locale) }
            : apiEntries.compactMap { VideoCardItem($0) }
        return mixExploration(into: followed.map(withAvatar))
    }

    // Followed channels already have an avatar stored from when they were followed,
    // so the card shows a real image rather than a monogram — no extra request.
    private func withAvatar(_ card: VideoCardItem) -> VideoCardItem {
        guard let channelId = card.channelId,
              let subscription = store.subscriptions.first(where: { $0.channelId == channelId })
        else { return card }
        var copy = card
        copy.channelAvatarURL = subscription.avatarURL
        return copy
    }

    // Which cards came from outside the followed set, so the view can mark them.
    var explorationIds: Set<String> { Set(exploration.map(\.videoId)) }

    // Newest video per followed channel, for the Channels list. Derived from the
    // feed already in memory, so the rows cost no request — and are simply absent
    // until the feed has loaded once.
    var latestByChannel: [String: ChannelLatest] {
        ChannelList.latestByChannel(entries: entries, apiEntries: apiEntries)
    }

    // Interleaves at fixed slots rather than appending: a section at the bottom
    // never gets read, and leading with an unproven pick is worse than not making
    // one. Never first, never adjacent — see Recommend.insertionSlots.
    private func mixExploration(into followed: [VideoCardItem]) -> [VideoCardItem] {
        let extras = exploration.compactMap { VideoCardItem($0) }
        guard !extras.isEmpty else { return followed }
        let slots = Recommend.insertionSlots(feedCount: followed.count,
                                             explorationCount: extras.count)
        guard !slots.isEmpty else { return followed }

        var result = followed
        // Descending, so each insertion cannot shift the index of the next one.
        for (extra, slot) in zip(extras, slots).reversed() where slot - 1 <= result.count {
            result.insert(extra, at: slot - 1)
        }
        return result
    }

    var resultCards: [VideoCardItem] { results.compactMap { VideoCardItem($0) } }

    // For a screen that wants the feed but must not pay for it twice. Discover's
    // .task and pull-to-refresh still call refresh() directly; this is what the
    // Channels tab uses, since switching tabs re-runs .task and N channels cost 2N
    // requests.
    //
    // Following a new channel does not refetch here — Discover's own refresh covers
    // that, and the new row falls back to its subscriber count until then. Pull to
    // refresh on this list forces it.
    func loadFeedIfNeeded() async {
        guard entries.isEmpty, apiEntries.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        let channelIds = store.subscriptions.map(\.channelId)
        guard !channelIds.isEmpty else {
            entries = []
            apiEntries = []
            failedChannelIds = []
            feedError = nil
            return
        }

        loading = true
        defer { loading = false }

        // With a key, the feed comes from the Data API: same source as a channel
        // page, so the cards carry durations here too. Without one it stays on RSS.
        if api != nil, await refreshFromAPI(channelIds: channelIds) { return }

        apiEntries = []
        let result = await service.fetchFeeds(channelIds: channelIds)
        engagement = localEngagement()
        entries = Recommend.rankedFeed(result.entries, engagement: engagement)
        failedChannelIds = result.failedChannelIds
        // Page-level error only when nothing at all came back.
        feedError = result.failedChannelIds.count == channelIds.count
            ? "Could not reach any of your channels. Check your connection and try again."
            : nil
    }

    // Returns false when nothing at all came back, so the caller can fall back to
    // RSS — a key that is invalid or out of quota must not empty the feed.
    //
    // Only the FIRST page of each channel is fetched: this is "what's new", not a
    // catalog, and N channels already costs 2N requests. Browsing deeper is what
    // the channel page is for.
    private func refreshFromAPI(channelIds: [String]) async -> Bool {
        guard let api else { return false }

        var collected: [ChannelVideo] = []
        var failed: [String] = []

        await withTaskGroup(of: (String, [ChannelVideo]?).self) { group in
            for channelId in channelIds {
                group.addTask {
                    let page = try? await api.fetchUploads(channelId: channelId, pageToken: nil)
                    return (channelId, page?.videos)
                }
            }
            for await (channelId, videos) in group {
                guard let videos else {
                    failed.append(channelId)
                    continue
                }
                collected += videos
            }
        }

        guard !collected.isEmpty else { return false }

        // Newest-first across channels, which needs the real timestamp — the
        // relative display string ("3 years ago") cannot be sorted. Items without
        // one sort last rather than being dropped.
        // Newest-first across channels, then engagement decides the order within a
        // recency band — see Recommend.rankedFeed for why recency stays outermost.
        engagement = localEngagement()
        apiEntries = rankByEngagement(collected)
        entries = []
        failedChannelIds = failed
        feedError = nil
        await loadExploration(channelIds: channelIds)
        return true
    }

    // Same banding as the RSS path, expressed over ChannelVideo (which carries
    // publishedAt only on the API path).
    private func rankByEngagement(_ videos: [ChannelVideo]) -> [ChannelVideo] {
        videos.sorted { left, right in
            let leftDate = left.publishedAt ?? .distantPast
            let rightDate = right.publishedAt ?? .distantPast
            let leftBand = Recommend.recencyBand(leftDate)
            let rightBand = Recommend.recencyBand(rightDate)
            if leftBand != rightBand { return leftBand < rightBand }
            let leftScore = left.channelId.flatMap { engagement[$0]?.score } ?? 0
            let rightScore = right.channelId.flatMap { engagement[$0]?.score } ?? 0
            if abs(leftScore - rightScore) > 0.01 { return leftScore > rightScore }
            return leftDate > rightDate
        }
    }

    // Local only: playback position, and whether an episode was finished. Costs
    // nothing and is a truer signal than the follow list — following says "I want
    // to", finishing three hours says "I am studying this".
    private func localEngagement() -> [String: ChannelEngagement] {
        let episodes = episodesProvider()
        guard !episodes.isEmpty else { return [:] }
        // Episodes store a channel NAME, while subscriptions are keyed by id, so
        // the two are matched by title here.
        let idByTitle = Dictionary(
            store.subscriptions.map { ($0.title, $0.channelId) },
            uniquingKeysWith: { first, _ in first })
        return Recommend.engagement(from: episodes) { episode in
            episode.channel.flatMap { idByTitle[$0] }
        }
    }

    // One search per day, cached. search.list costs 100 units from a bucket of
    // exactly 100 per day, so refreshing Discover must not spend it again.
    private func loadExploration(channelIds: [String]) async {
        guard let api else { return }

        if explorationCache.isFresh() {
            exploration = explorationCache.videos()
            explorationTopic = explorationCache.topic()
            return
        }

        // Profiling is free (1 unit for every channel at once), so it happens
        // before deciding whether the expensive search is worth it.
        topicProfile = (try? await api.fetchTopics(channelIds: channelIds)) ?? [:]
        var covered: [String: Int] = [:]
        for labels in topicProfile.values {
            for label in labels { covered[label, default: 0] += 1 }
        }
        guard let topic = Recommend.explorationTopic(covered: covered) else { return }

        // Marked before the request returns, so a failure cannot retry on the next
        // refresh and burn the day's only search.
        explorationCache.markAttempted(topic: topic)
        explorationTopic = topic

        let found = (try? await api.searchTopic(query: Recommend.query(for: topic))) ?? []
        // Anything from a channel already followed is not exploration.
        let followed = Set(channelIds)
        let fresh = found.filter { video in
            guard let id = video.channelId else { return true }
            return !followed.contains(id)
        }
        exploration = Array(fresh.prefix(3))
        if !exploration.isEmpty {
            explorationCache.store(topic: topic, videos: exploration)
        }
    }

    // Site-wide video search. Runs on submit only — see the type comment.
    func runSearch(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        searching = true
        searchUnavailable = false
        searchedTerm = trimmed
        defer { searching = false }

        switch await service.searchVideosSiteWide(query: trimmed) {
        case .parsed(let videos):
            // Keep YouTube's relevance order; do not sort by date.
            results = videos
        case .structureMissing:
            results = []
            searchUnavailable = true
        }
    }

    // Leaving the search state. "← Back" and the field's clear button both call
    // this — two controls that looked alike but behaved differently is exactly
    // the confusion this screen was rebuilt to remove.
    func clearSearch() {
        results = []
        searchedTerm = nil
        searchUnavailable = false
        query = ""
    }

    func addSubscription(url: String) async {
        addError = nil
        do {
            let subscription = try await service.resolveChannel(fromURL: url)
            store.add(subscription)
            await refresh()
        } catch {
            addError = error.localizedDescription
        }
    }

    func removeSubscription(channelId: String) {
        store.remove(channelId: channelId)
        // Both feed sources, not just RSS: whichever one is live, the unfollowed
        // channel's videos have to leave the list immediately.
        entries.removeAll { $0.channelId == channelId }
        apiEntries.removeAll { $0.channelId == channelId }
        failedChannelIds.removeAll { $0 == channelId }
    }

    // Called when returning from a channel screen, where the user may have
    // followed or unfollowed. Refreshing only when the set actually changed
    // avoids N feed requests on every back-navigation.
    func syncAfterChannelVisit(previousChannelIds: [String]) async {
        guard Set(previousChannelIds) != Set(store.subscriptions.map(\.channelId)) else { return }
        await refresh()
    }
}
