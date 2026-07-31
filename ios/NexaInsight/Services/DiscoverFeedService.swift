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
}

// Fetches subscribed channels' public RSS feeds.
//
// The feed needs no API key, no auth, and no particular User-Agent — verified
// with no headers, a custom UA, and a browser UA, all returning 200. So this
// stays a plain URLSession GET with no backend in the middle.
struct DiscoverFeedService: DiscoverFeedFetching {
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

    func resolveChannel(fromURL url: String) async throws -> Subscription {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId: String
        if let direct = YouTubeChannelLogic.channelId(fromChannelURL: trimmed) {
            channelId = direct
        } else {
            guard let pageURL = URL(string: trimmed), pageURL.scheme != nil else {
                throw DiscoverFeedError.unrecognizedChannelLink
            }
            let (data, _) = try await session.data(from: pageURL)
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
