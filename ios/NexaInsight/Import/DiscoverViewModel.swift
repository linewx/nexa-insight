import Foundation

// State for the Discover screen.
//
// Two error channels on purpose: feedError is page-level (every source failed)
// while failedChannelIds marks individual dead sources without hiding the
// entries that did load.
@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var entries: [DiscoverEntry] = []
    @Published var loading = false
    @Published var feedError: String?
    @Published var addError: String?
    @Published var failedChannelIds: [String] = []
    @Published var selectedChannelId: String?
    @Published var query = ""

    private let store: SubscriptionStore
    private let service: DiscoverFeedFetching

    init(store: SubscriptionStore, service: DiscoverFeedFetching) {
        self.store = store
        self.service = service
    }

    var subscriptions: [Subscription] { store.subscriptions }
    var hasSubscriptions: Bool { !store.subscriptions.isEmpty }

    var visibleEntries: [DiscoverEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesChannel = selectedChannelId == nil || entry.channelId == selectedChannelId
            guard matchesChannel else { return false }
            guard !trimmed.isEmpty else { return true }
            let haystack = "\(entry.title) \(entry.channelTitle) \(entry.summary ?? "")"
            return haystack.localizedCaseInsensitiveContains(trimmed)
        }
    }

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
        if selectedChannelId == channelId { selectedChannelId = nil }
    }
}
