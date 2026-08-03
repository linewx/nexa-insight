import Foundation

// What one refresh produced. Sources that failed are reported alongside the
// entries that succeeded, because one dead channel must not blank the page.
struct FeedFetchResult {
    let entries: [DiscoverEntry]
    let failedChannelIds: [String]
    let channelTitles: [String: String]
}

enum DiscoverFeedError: LocalizedError {
    case unrecognizedChannelLink
    case channelNotFound

    var errorDescription: String? {
        switch self {
        case .unrecognizedChannelLink:
            return "Could not recognize that channel link. Paste a youtube.com/@handle or /channel/UC... URL."
        case .channelNotFound:
            return "That channel has no public feed."
        }
    }
}

protocol DiscoverFeedFetching {
    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult
    func resolveChannel(fromURL url: String) async throws -> Subscription
    // `recentOnly` applies YouTube's this-month + long-form filter, for the
    // cold-start feed. Plain search leaves it off: someone looking for a specific
    // talk does not want it hidden because it is a year old.
    func searchVideosSiteWide(query: String, recentOnly: Bool) async -> ChannelVideoOutcome
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry]
    func fetchChannelHeader(channelId: String) async -> ChannelHeader
}

// Fetches subscribed channels' public RSS feeds.
//
// The feed needs no API key, no auth, and no particular User-Agent — verified
// with no headers, a custom UA, and a browser UA, all returning 200. So this
// stays a plain URLSession GET with no backend in the middle.
struct DiscoverFeedService: DiscoverFeedFetching {
    // Sent on HTML page requests (search, channel-page resolution). The RSS feed
    // itself needs no UA — verified working with none, a custom one, and this.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    var session: URLSession = .shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult {
        // Each channel is fetched concurrently and failures are per-channel: an
        // invalid channel_id returns 404 (not an empty feed), so without this
        // isolation one bad subscription would empty the whole screen.
        await withTaskGroup(of: (String, [DiscoverEntry]?).self) { group in
            for channelId in channelIds {
                group.addTask { (channelId, try? await self.fetchOne(channelId: channelId)) }
            }

            var groups: [[DiscoverEntry]] = []
            var failed: [String] = []
            var titles: [String: String] = [:]
            for await (channelId, entries) in group {
                guard let entries else { failed.append(channelId); continue }
                groups.append(entries)
                if let title = entries.first?.channelTitle { titles[channelId] = title }
            }
            return FeedFetchResult(
                entries: DiscoverFeedParser.merge(groups),
                failedChannelIds: failed,
                channelTitles: titles)
        }
    }

    // Site-wide video search — what Discover's search box now does.
    //
    // Deliberately WITHOUT `sp=EgIQAg==`. That parameter restricted results to
    // channels (measured: with it 20 channels / 0 videos, without it 0 channels /
    // 19 videos). Dropping it is the whole switch from searching channels to
    // searching videos.
    //
    // hl=en&gl=US pin the response language, AND the Accept-Language header is
    // also required. With neither, results came back Japanese
    // ("チャンネル登録者数 2.04万人"); only pinning both reliably produced English.
    // YouTube's own search filters, encoded. Verified live: without it the results
    // page mixed 3-day-old and 10-month-old uploads; with it every result was within
    // three days. Used for the cold-start feed, where the point is what is current.
    static let recentLongFormFilter = "EgQIAxAB"   // this month + over 20 minutes

    func searchVideosSiteWide(query: String, recentOnly: Bool = false) async -> ChannelVideoOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .parsed([]) }

        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: trimmed),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "US"),
        ]
        if recentOnly {
            components.queryItems?.append(
                URLQueryItem(name: "sp", value: Self.recentLongFormFilter))
        }
        guard let url = components.url else { return .structureMissing }

        var request = URLRequest(url: url)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // A browser User-Agent is REQUIRED, not cosmetic. With URLSession's
        // default UA, YouTube serves a consent interstitial instead: HTTP 200,
        // ~475 KB, ytInitialData present but ZERO renderer nodes — which the
        // parser correctly reports as structureMissing. With a browser UA the
        // same request returns ~845 KB and 21 renderers. Measured both ways.
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .structureMissing }
            switch VideoSearchParser.parse(data) {
            case .parsed(let videos):
                // Site-wide search can surface short uploads. Anything under ten
                // minutes is noise for Nexa's long-form study surfaces.
                //
                // Filtering by duration rather than by link form: this page gives
                // us lengthText but no link to test, the reverse of the RSS path.
                // Videos with an unparseable duration are KEPT — one noisy short
                // item is less costly than hiding a real episode.
                return .parsed(videos.filter { !YouTubeChannelLogic.isShortDuration($0.durationText) })
            case .structureMissing:
                return .structureMissing
            }
        } catch {
            // A transport failure is indistinguishable from a broken page as far
            // as the user's next action goes: fall back to pasting a link.
            return .structureMissing
        }
    }

    // The channel's own avatar, title, and subscriber count.
    //
    // Returns .empty on any failure rather than throwing: this is decoration, and
    // the content below it comes from RSS and in-channel search. A header failure
    // must never become a page failure.
    func fetchChannelHeader(channelId: String) async -> ChannelHeader {
        guard YouTubeChannelLogic.isValidChannelId(channelId),
              let url = URL(string: "https://www.youtube.com/channel/\(channelId)?hl=en&gl=US")
        else { return .empty }

        var request = URLRequest(url: url)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Same browser-UA requirement as every other YouTube HTML request here.
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .empty }
            return ChannelHeaderParser.parse(data)
        } catch {
            return .empty
        }
    }

    // In-channel search. This is the surface that reaches the back catalog:
    // results for one query included 3-year-old and 6-year-old uploads, where
    // RSS caps at 15 recent entries.
    //
    // Needs the browser UA like every other YouTube HTML request — with
    // URLSession's default UA, YouTube serves a consent page instead.
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, YouTubeChannelLogic.isValidChannelId(channelId) else {
            return .parsed([])
        }

        var components = URLComponents(string: "https://www.youtube.com/channel/\(channelId)/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "US"),
        ]
        guard let url = components.url else { return .structureMissing }

        var request = URLRequest(url: url)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .structureMissing }
            return ChannelVideoParser.parse(data)
        } catch {
            return .structureMissing
        }
    }

    // The channel's recent uploads, from its RSS feed.
    //
    // RSS rather than the channel videos page: the videos page would need a
    // second parser (it serves lockupViewModel where search serves
    // videoRenderer) and it is the shape YouTube is actively migrating to. RSS
    // is stable Atom XML and already parsed. Cost: 15 entries, no duration.
    //
    // Returns [] on any failure — a missing recency list is not worth an error
    // state when search is the primary surface. No User-Agent needed here; the
    // RSS feed was measured working with no headers at all.
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] {
        guard let url = YouTubeChannelLogic.feedURL(channelId: channelId) else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return [] }
            return DiscoverFeedParser.parse(data)
        } catch {
            return []
        }
    }

    func resolveChannel(fromURL url: String) async throws -> Subscription {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId: String
        if let direct = YouTubeChannelLogic.channelId(fromChannelURL: trimmed) {
            channelId = direct
        } else {
            guard let pageURL = URL(string: trimmed), pageURL.scheme != nil else {
                throw DiscoverFeedError.unrecognizedChannelLink
            }
            // Same browser-UA requirement as search: with URLSession's default UA
            // the channel page comes back ~567 KB with NO canonical link, so
            // handle resolution silently fails. With a browser UA it is ~1.3 MB
            // and the canonical link is present. Measured both ways.
            var pageRequest = URLRequest(url: pageURL)
            pageRequest.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: pageRequest)
            guard let html = String(data: data, encoding: .utf8),
                  let resolved = YouTubeChannelLogic.channelId(fromHTML: html)
            else { throw DiscoverFeedError.unrecognizedChannelLink }
            channelId = resolved
        }

        // Fetch the feed once to validate the id and read the channel title.
        // A bad id 404s here, which doubles as the "no such channel" check.
        let entries = try await fetchOne(channelId: channelId)
        let title = entries.first?.channelTitle ?? channelId
        return Subscription(channelId: channelId, title: title, addedAt: Date())
    }

    private func fetchOne(channelId: String) async throws -> [DiscoverEntry] {
        guard let url = YouTubeChannelLogic.feedURL(channelId: channelId) else {
            throw DiscoverFeedError.unrecognizedChannelLink
        }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DiscoverFeedError.channelNotFound }
        return DiscoverFeedParser.parse(data)
    }
}
