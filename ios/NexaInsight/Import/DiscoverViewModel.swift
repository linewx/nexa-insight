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

    private let store: SubscriptionStore
    private let service: DiscoverFeedFetching
    // nil when no API key is configured, which is the normal state for a user who
    // has not set one up. Every path degrades to RSS rather than erroring.
    private let api: YouTubeAPIFetching?

    init(store: SubscriptionStore,
         service: DiscoverFeedFetching,
         api: YouTubeAPIFetching? = nil) {
        self.store = store
        self.service = service
        self.api = api
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
        apiEntries.isEmpty
            ? entries.map { VideoCardItem($0) }
            : apiEntries.compactMap { VideoCardItem($0) }
    }

    var resultCards: [VideoCardItem] { results.compactMap { VideoCardItem($0) } }

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
        entries = result.entries
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
        apiEntries = collected.sorted {
            ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }
        entries = []
        failedChannelIds = failed
        feedError = nil
        return true
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
