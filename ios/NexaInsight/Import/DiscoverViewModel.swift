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

    private let store: SubscriptionStore
    private let service: DiscoverFeedFetching

    init(store: SubscriptionStore, service: DiscoverFeedFetching) {
        self.store = store
        self.service = service
    }

    var subscriptions: [Subscription] { store.subscriptions }
    var hasSubscriptions: Bool { !store.subscriptions.isEmpty }

    // Search covers the tabs rather than living inside one, so the tab selection
    // is preserved underneath and restored on exit.
    var isSearchActive: Bool { searchedTerm != nil }

    // One card type for both sources, so the feed and search results look
    // identical apart from the data they genuinely have.
    var feedCards: [VideoCardItem] { entries.map { VideoCardItem($0) } }

    var resultCards: [VideoCardItem] { results.compactMap { VideoCardItem($0) } }

    func refresh() async {
        let channelIds = store.subscriptions.map(\.channelId)
        guard !channelIds.isEmpty else {
            entries = []
            failedChannelIds = []
            feedError = nil
            return
        }

        loading = true
        defer { loading = false }

        let result = await service.fetchFeeds(channelIds: channelIds)
        entries = result.entries
        failedChannelIds = result.failedChannelIds
        // Page-level error only when nothing at all came back.
        feedError = result.failedChannelIds.count == channelIds.count
            ? "Could not reach any of your channels. Check your connection and try again."
            : nil
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
        entries.removeAll { $0.channelId == channelId }
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
