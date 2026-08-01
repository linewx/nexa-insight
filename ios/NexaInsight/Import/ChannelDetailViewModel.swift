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

    // The full catalog, when an API key is configured. Separate from `uploads`
    // (RSS) rather than merged into it, because the two have different ceilings
    // and only one can page — collapsing them would hide which one you are
    // looking at.
    @Published var catalog: [ChannelVideo] = []
    @Published var catalogTotal: Int?
    @Published var loadingMore = false
    @Published var catalogError: String?
    private var nextPageToken: String?
    private var reachedEnd = false

    let channelId: String
    private let fallbackTitle: String
    private let store: SubscriptionStore
    private let service: DiscoverFeedFetching
    // nil when no API key is configured, which is the normal state for a user who
    // has not set one up. That is why every catalog path degrades to RSS instead
    // of erroring.
    private let api: YouTubeAPIFetching?
    private let importedVideoIds: () -> Set<String>

    init(channelId: String,
         fallbackTitle: String,
         store: SubscriptionStore,
         service: DiscoverFeedFetching,
         api: YouTubeAPIFetching? = nil,
         importedVideoIds: @escaping () -> Set<String>) {
        self.channelId = channelId
        self.fallbackTitle = fallbackTitle
        self.store = store
        self.service = service
        self.api = api
        self.importedVideoIds = importedVideoIds
        self.following = store.contains(channelId: channelId)
    }

    var hasCatalog: Bool { api != nil }

    var isSearchActive: Bool { searchedTerm != nil }

    // The parsed header wins when present; otherwise the name we arrived with.
    var title: String { header.title ?? fallbackTitle }

    var subscriberText: String? { header.subscriberText }
    var avatarURL: URL? { header.avatarURL }

    // On this screen the channel is already known, so the attribution is dropped
    // from both lists — a tappable name here would navigate back to this screen.
    //
    // The catalog wins when available: it is the whole channel, newest-first, with
    // durations. RSS is the fallback for users with no API key, capped at 15.
    var uploadCards: [VideoCardItem] {
        let source = catalog.isEmpty
            ? uploads.map { VideoCardItem($0) }
            : catalog.compactMap { VideoCardItem($0) }
        return source.map { $0.withoutChannel() }
    }

    // True once there is another page to fetch. Drives the scroll trigger, so it
    // must be false at the end or the list would spin forever.
    var canLoadMore: Bool { !catalog.isEmpty && nextPageToken != nil && !reachedEnd }

    var resultCards: [VideoCardItem] {
        results.compactMap { VideoCardItem($0)?.withoutChannel() }
    }

    func load() async {
        // The header is decoration, so it never blocks content: both start
        // together and each renders when it arrives.
        async let headerTask: Void = loadHeader()
        async let contentTask: Void = loadContent()
        _ = await (headerTask, contentTask)
    }

    // The API when a key is configured, RSS otherwise. A key that turns out to be
    // invalid also falls back, so a bad key degrades to a shorter list with an
    // explanation rather than an empty screen.
    private func loadContent() async {
        guard api != nil else {
            await loadUploads()
            return
        }
        await loadFirstPage()
        if catalog.isEmpty { await loadUploads() }
    }

    func loadFirstPage() async {
        guard let api else { return }
        loadingUploads = true
        catalogError = nil
        defer { loadingUploads = false }

        do {
            let page = try await api.fetchUploads(channelId: channelId, pageToken: nil)
            catalog = page.videos
            catalogTotal = page.totalCount
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
        } catch {
            catalogError = (error as? YouTubeAPIError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // Called when the list nears its end. Guarded against re-entry: a scroll
    // trigger can fire several times before the first request returns, and
    // without this the same page would append two or three times.
    func loadMoreIfNeeded() async {
        guard let api, let token = nextPageToken, !loadingMore, !reachedEnd else { return }
        loadingMore = true
        defer { loadingMore = false }

        do {
            let page = try await api.fetchUploads(channelId: channelId, pageToken: token)
            // Dedupe by videoId. The API returned no overlap between consecutive
            // pages when measured, but appending blind would produce duplicate
            // SwiftUI ids if that ever changed — which corrupts the list rather
            // than just showing an extra row.
            let known = Set(catalog.map(\.videoId))
            catalog += page.videos.filter { !known.contains($0.videoId) }
            nextPageToken = page.nextPageToken
            reachedEnd = page.nextPageToken == nil
        } catch {
            // Stop paging on failure rather than retrying on every scroll tick,
            // which would burn quota against a dead key.
            reachedEnd = true
            catalogError = (error as? YouTubeAPIError)?.errorDescription
                ?? error.localizedDescription
        }
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
