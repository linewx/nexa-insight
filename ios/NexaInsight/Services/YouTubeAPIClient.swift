import Foundation

protocol YouTubeAPIFetching {
    func fetchUploads(channelId: String, pageToken: String?) async throws -> UploadsPage
    // Topic labels for many channels at once. One call covers every followed
    // channel for 1 unit, which is what makes profiling free.
    func fetchTopics(channelIds: [String]) async throws -> [String: [String]]
    // The only expensive call in the app: search.list costs 100 units from a
    // SEPARATE bucket of 100 per day. Caller must cache; one per day is the budget.
    func searchTopic(query: String) async throws -> [ChannelVideo]
}

// YouTube Data API v3, used for a channel's full upload list.
//
// This is the OFFICIAL API, not a scrape — which is the whole reason it is here.
// The RSS feed caps at 15 entries (max-results and start-index are both ignored)
// and the channel videos page holds 30, so neither can page. Loading more from
// those would mean POSTing to youtubei/v1/browse with a forged INNERTUBE_API_KEY,
// an internal endpoint with no compatibility contract. The documented API costs a
// user-supplied key instead, and that trade was made deliberately.
//
// Quota: 10,000 units/day by default; each request below costs 1 unit. One page
// costs 2 (uploads + durations), so ~5,000 pages/day. Not a practical limit.
struct YouTubeAPIClient: YouTubeAPIFetching {
    // Verified live: this channel's uploads playlist returned 865 videos across
    // pages of 50, with no overlap between consecutive pages.
    static let pageSize = 50

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func fetchUploads(channelId: String, pageToken: String?) async throws -> UploadsPage {
        guard !apiKey.isEmpty else { throw YouTubeAPIError.missingKey }
        guard let playlistId = YouTubeAPIParser.uploadsPlaylistId(channelId: channelId) else {
            throw YouTubeAPIError.unreadable
        }

        var items = [
            URLQueryItem(name: "part", value: "snippet,contentDetails"),
            URLQueryItem(name: "playlistId", value: playlistId),
            URLQueryItem(name: "maxResults", value: String(Self.pageSize)),
            URLQueryItem(name: "key", value: apiKey),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }

        let page = try YouTubeAPIParser.parseUploads(try await get("playlistItems", items))

        // Durations and view counts live on a different endpoint, so one page of
        // videos is two requests. Failing that second request must NOT lose the
        // page — the list is still usable without duration badges.
        let details = (try? await fetchDetails(videoIds: page.videos.map(\.videoId))) ?? [:]

        let merged = page.videos.compactMap { video -> ChannelVideo? in
            guard let detail = details[video.videoId] else { return video }
            // Shorts are dropped here rather than in the parser: the parser sees
            // no durations, so this is the first point where they are knowable.
            // Same asymmetry as the scraped path — an unknown duration is kept.
            guard !detail.isShort else { return nil }
            var enriched = video
            enriched.durationText = detail.durationText
            enriched.viewsText = detail.viewsText
            return enriched
        }

        return UploadsPage(
            videos: merged,
            nextPageToken: page.nextPageToken,
            totalCount: page.totalCount)
    }

    // Batched: one request covers up to 50 ids for 1 unit, so this never scales
    // with the number of videos on screen.
    private func fetchDetails(videoIds: [String]) async throws -> [String: YouTubeAPIParser.VideoDetail] {
        guard !videoIds.isEmpty else { return [:] }
        let data = try await get("videos", [
            URLQueryItem(name: "part", value: "contentDetails,statistics"),
            URLQueryItem(name: "id", value: videoIds.joined(separator: ",")),
            URLQueryItem(name: "key", value: apiKey),
        ])
        return try YouTubeAPIParser.parseVideoDetails(data)
    }


    // MARK: - Discovery

    func fetchTopics(channelIds: [String]) async throws -> [String: [String]] {
        guard !apiKey.isEmpty else { throw YouTubeAPIError.missingKey }
        let valid = channelIds.filter { YouTubeChannelLogic.isValidChannelId($0) }
        guard !valid.isEmpty else { return [:] }

        // Batched: 50 ids per call, 1 unit, so profiling never scales with follows.
        var topics: [String: [String]] = [:]
        for chunk in stride(from: 0, to: valid.count, by: 50).map({
            Array(valid[$0..<min($0 + 50, valid.count)])
        }) {
            let data = try await get("channels", [
                URLQueryItem(name: "part", value: "topicDetails"),
                URLQueryItem(name: "id", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "key", value: apiKey),
            ])
            for (id, labels) in YouTubeAPIParser.parseTopics(data) {
                topics[id] = labels
            }
        }
        return topics
    }

    func searchTopic(query: String) async throws -> [ChannelVideo] {
        guard !apiKey.isEmpty else { throw YouTubeAPIError.missingKey }
        let data = try await get("search", [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video"),
            // Long-form only. This app exists for material worth an hour of
            // intensive listening; a five-minute clip is not that.
            URLQueryItem(name: "videoDuration", value: "long"),
            URLQueryItem(name: "relevanceLanguage", value: "en"),
            URLQueryItem(name: "maxResults", value: "10"),
            URLQueryItem(name: "key", value: apiKey),
        ])
        let found = try YouTubeAPIParser.parseSearch(data)
        // Durations come from a second endpoint, as with uploads. Failing that must
        // not lose the results.
        let details = (try? await fetchDetails(videoIds: found.map(\.videoId))) ?? [:]
        return found.compactMap { video in
            guard let detail = details[video.videoId] else { return video }
            guard !detail.isShort else { return nil }
            var enriched = video
            enriched.durationText = detail.durationText
            enriched.viewsText = detail.viewsText
            return enriched
        }
    }

    private func get(_ endpoint: String, _ queryItems: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(endpoint)")!
        components.queryItems = queryItems
        guard let url = components.url else { throw YouTubeAPIError.unreadable }

        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                // 400 means a malformed or invalid key, 403 means quota or a
                // disabled API. The reason string separates "wait until midnight
                // Pacific" from "fix your key in Settings".
                throw YouTubeAPIError.rejected(reason: YouTubeAPIParser.errorReason(data))
            }
            return data
        } catch let error as YouTubeAPIError {
            throw error
        } catch {
            throw YouTubeAPIError.unreadable
        }
    }
}
