import Foundation

// State for one channel's detail screen.
//
// Search is the primary surface — it is the only measured path that reaches a
// channel's back catalog. The uploads list is a secondary convenience for when
// the user has no particular query in mind.
//
// This screen is also where following happens, so it must work for channels the
// user does NOT follow: it is reached by tapping a channel name on any video
// card, which is how a user inspects what a channel publishes before committing.
// That is why it holds the store rather than just a Subscription value.
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
    // Decoration. A failed header parse leaves this empty and the screen falls
    // back to the title the video card already supplied — never an error state,
    // because the content below comes from RSS and in-channel search.
    @Published var header: ChannelHeader = .empty
    @Published private(set) var following: Bool

    let channelId: String
    private let fallbackTitle: String
    private let store: SubscriptionStore
    private let service: DiscoverFeedFetching
    private let importedVideoIds: () -> Set<String>

    init(channelId: String,
         fallbackTitle: String,
         store: SubscriptionStore,
         service: DiscoverFeedFetching,
         importedVideoIds: @escaping () -> Set<String>) {
        self.channelId = channelId
        self.fallbackTitle = fallbackTitle
        self.store = store
        self.service = service
        self.importedVideoIds = importedVideoIds
        self.following = store.contains(channelId: channelId)
    }

    var isSearchActive: Bool { searchedTerm != nil }

    // The parsed header wins when present; otherwise the name we arrived with.
    var title: String { header.title ?? fallbackTitle }

    var subscriberText: String? { header.subscriberText }
    var avatarURL: URL? { header.avatarURL }

    // On this screen the channel is already known, so the attribution is dropped
    // from both lists — a tappable name here would navigate back to this screen.
    var uploadCards: [VideoCardItem] {
        uploads.map { VideoCardItem($0).withoutChannel() }
    }

    var resultCards: [VideoCardItem] {
        results.compactMap { VideoCardItem($0)?.withoutChannel() }
    }

    func load() async {
        // The header is decoration, so it never blocks content: both start
        // together and each renders when it arrives.
        async let headerTask: Void = loadHeader()
        async let uploadsTask: Void = loadUploads()
        _ = await (headerTask, uploadsTask)
    }

    func loadHeader() async {
        let fetched = await service.fetchChannelHeader(channelId: channelId)
        header = fetched
        // Following an existing channel again refreshes its stored avatar and
        // subscriber count, so the channel list stops showing a monogram once
        // the user opens the channel.
        if following, !fetched.isEmpty { persistHeaderFields() }
    }

    func loadUploads() async {
        loadingUploads = true
        defer { loadingUploads = false }
        uploads = await service.fetchChannelUploads(channelId: channelId)
    }

    func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query was measured to return zero results, so skip the request.
        guard !trimmed.isEmpty else { return }

        searching = true
        searchUnavailable = false
        searchedTerm = trimmed
        defer { searching = false }

        switch await service.searchVideos(channelId: channelId, query: trimmed) {
        case .parsed(let videos):
            // Keep YouTube's relevance order; do not sort by date.
            results = videos
        case .structureMissing:
            results = []
            searchUnavailable = true
        }
    }

    func clearSearch() {
        results = []
        searchedTerm = nil
        searchUnavailable = false
        query = ""
    }

    func toggleFollow() {
        if following {
            store.remove(channelId: channelId)
            following = false
        } else {
            store.add(Subscription(
                channelId: channelId,
                title: title,
                addedAt: Date(),
                avatarURL: header.avatarURL,
                subscriberText: header.subscriberText))
            following = true
        }
    }

    // Re-reads the closure each call so a video imported during this session
    // flips to "in library" without rebuilding the view model.
    func isImported(videoId: String) -> Bool {
        importedVideoIds().contains(videoId)
    }

    private func persistHeaderFields() {
        store.add(Subscription(
            channelId: channelId,
            title: title,
            addedAt: Date(),
            avatarURL: header.avatarURL,
            subscriberText: header.subscriberText))
    }
}
