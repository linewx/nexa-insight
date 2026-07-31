import Foundation

// State for one channel's detail screen.
//
// Search is the primary surface — it is the only measured path that reaches a
// channel's back catalog. The uploads list is a secondary convenience for when
// the user has no particular query in mind.
@MainActor
final class ChannelDetailViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [ChannelVideo] = []
    @Published var uploads: [DiscoverEntry] = []
    @Published var searching = false
    @Published var loadingUploads = false
    // True only when the page could not be read; never for an empty result set.
    @Published var searchUnavailable = false
    @Published var searchedTerm: String?

    let subscription: Subscription
    private let service: DiscoverFeedFetching
    private let importedVideoIds: () -> Set<String>

    init(subscription: Subscription,
         service: DiscoverFeedFetching,
         importedVideoIds: @escaping () -> Set<String>) {
        self.subscription = subscription
        self.service = service
        self.importedVideoIds = importedVideoIds
    }

    var isSearchActive: Bool { searchedTerm != nil }

    func loadUploads() async {
        loadingUploads = true
        defer { loadingUploads = false }
        uploads = await service.fetchChannelUploads(channelId: subscription.channelId)
    }

    func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query was measured to return zero results, so skip the request.
        guard !trimmed.isEmpty else { return }

        searching = true
        searchUnavailable = false
        defer { searching = false }

        switch await service.searchVideos(channelId: subscription.channelId, query: trimmed) {
        case .parsed(let videos):
            // Keep YouTube's relevance order; do not sort by date.
            results = videos
            searchedTerm = trimmed
        case .structureMissing:
            results = []
            searchedTerm = trimmed
            searchUnavailable = true
        }
    }

    func clearSearch() {
        results = []
        searchedTerm = nil
        searchUnavailable = false
        query = ""
    }

    // Re-reads the closure each call so a video imported during this session
    // flips to "in library" without rebuilding the view model.
    func isImported(videoId: String) -> Bool {
        importedVideoIds().contains(videoId)
    }
}
