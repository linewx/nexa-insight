import Foundation

// One page of a channel's uploads, plus the token that reaches the next one.
struct UploadsPage: Equatable {
    let videos: [ChannelVideo]
    let nextPageToken: String?
    // What the channel actually holds, from pageInfo.totalResults (measured: 865
    // for Lex Fridman, against RSS's hard cap of 15). Shown so the UI can say how
    // much is there instead of implying the first page is everything.
    let totalCount: Int?

    static let empty = UploadsPage(videos: [], nextPageToken: nil, totalCount: nil)
}

enum YouTubeAPIError: LocalizedError, Equatable {
    case missingKey
    case rejected(reason: String?)   // 400/403 — bad key, API not enabled, quota
    case unreadable                  // transport or shape failure

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add a YouTube API key in Settings to browse a channel's full catalog."
        case .rejected(let reason) where reason == "quotaExceeded":
            return "This YouTube API key is out of quota for today. It resets at midnight Pacific time."
        case .rejected:
            return "YouTube rejected this API key. Check that the key is correct and that YouTube Data API v3 is enabled for it."
        case .unreadable:
            return "Could not reach YouTube. Check your connection and try again."
        }
    }
}

// Decodes YouTube Data API v3 responses.
//
// Deliberately Codable structs rather than the untyped dictionary-walking the
// scraped-page parsers use. Those scrape HTML whose shape YouTube changes without
// notice, so they tolerate anything; this is a documented API with a stability
// contract, so a shape mismatch is a real error worth surfacing.
//
// Every field below was verified against live responses.
enum YouTubeAPIParser {
    // MARK: - playlistItems.list

    private struct PlaylistItemsResponse: Decodable {
        struct Item: Decodable {
            struct Snippet: Decodable {
                struct Thumbnail: Decodable { let url: String }
                let title: String
                let description: String?
                let videoOwnerChannelId: String?
                let videoOwnerChannelTitle: String?
                let thumbnails: [String: Thumbnail]?
            }
            struct ContentDetails: Decodable {
                let videoId: String
                let videoPublishedAt: Date?
            }
            let snippet: Snippet
            let contentDetails: ContentDetails
        }
        let items: [Item]
        let nextPageToken: String?
        let pageInfo: PageInfo?

        struct PageInfo: Decodable { let totalResults: Int? }
    }

    static func parseUploads(_ data: Data, now: Date = Date()) throws -> UploadsPage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(PlaylistItemsResponse.self, from: data) else {
            throw YouTubeAPIError.unreadable
        }

        let videos = response.items.map { item -> ChannelVideo in
            ChannelVideo(
                videoId: item.contentDetails.videoId,
                title: item.snippet.title,
                // Duration and views need videos.list; merged in later so the
                // first page can render before that second request returns.
                durationText: nil,
                viewsText: nil,
                publishedText: item.contentDetails.videoPublishedAt
                    .map { VideoCardItem.relativeDate($0, now: now) },
                publishedAt: item.contentDetails.videoPublishedAt,
                summary: item.snippet.description?.isEmpty == false ? item.snippet.description : nil,
                thumbnailURL: bestThumbnail(item.snippet.thumbnails),
                channelTitle: item.snippet.videoOwnerChannelTitle,
                channelId: item.snippet.videoOwnerChannelId)
        }
        // The API returns the uploads playlist newest-first, which is the order we
        // want; do not re-sort. Deleted or private videos come back with an empty
        // videoId, so they are dropped rather than rendered as blank rows.
        return UploadsPage(
            videos: videos.filter { !$0.videoId.isEmpty },
            nextPageToken: response.nextPageToken,
            totalCount: response.pageInfo?.totalResults)
    }

    // Widest available. Measured keys: default, medium, high, standard, maxres —
    // but maxres is absent on older uploads, so this walks down rather than
    // assuming one exists.
    private static func bestThumbnail(
        _ thumbnails: [String: PlaylistItemsResponse.Item.Snippet.Thumbnail]?
    ) -> URL? {
        guard let thumbnails else { return nil }
        for key in ["maxres", "standard", "high", "medium", "default"] {
            if let raw = thumbnails[key]?.url, let url = URL(string: raw) { return url }
        }
        return nil
    }

    // MARK: - videos.list

    private struct VideosResponse: Decodable {
        struct Item: Decodable {
            struct ContentDetails: Decodable { let duration: String? }
            struct Statistics: Decodable { let viewCount: String? }
            let id: String
            let contentDetails: ContentDetails?
            let statistics: Statistics?
        }
        let items: [Item]
    }

    struct VideoDetail: Equatable {
        let durationText: String?   // "3:46:18"
        let viewsText: String?      // "220,947 views"
        let isShort: Bool
    }

    // Keyed by videoId so the caller can merge without relying on order — the API
    // does not promise to return ids in the order they were requested.
    static func parseVideoDetails(_ data: Data) throws -> [String: VideoDetail] {
        guard let response = try? JSONDecoder().decode(VideosResponse.self, from: data) else {
            throw YouTubeAPIError.unreadable
        }

        var details: [String: VideoDetail] = [:]
        for item in response.items {
            let duration = item.contentDetails?.duration
            details[item.id] = VideoDetail(
                durationText: ISO8601Duration.displayText(duration),
                viewsText: item.statistics?.viewCount.flatMap(formattedViews),
                isShort: ISO8601Duration.isShort(duration))
        }
        return details
    }

    // The API sends counts as raw strings ("220947"); the scraped pages send them
    // already formatted as "3,028,760 views", pinned to en-US by hl/gl.
    //
    // The locale is pinned HERE TOO, deliberately. Using the device locale
    // produced "22万 views" on a Chinese-locale machine — a localized number
    // welded to a hardcoded English word, in a UI whose strings are all English.
    // Matching the scraped source exactly is what makes one card type look like
    // one card type.
    private static func formattedViews(_ raw: String) -> String? {
        guard let count = Int(raw) else { return nil }
        return "\(count.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))) views"
    }


    // MARK: - channels.list topicDetails

    private struct TopicsResponse: Decodable {
        struct Item: Decodable {
            struct TopicDetails: Decodable { let topicCategories: [String]? }
            let id: String
            let topicDetails: TopicDetails?
        }
        let items: [Item]
    }

    // Wikipedia URLs reduced to their last path component: "Knowledge", "Politics".
    // Measured live — Veritasium reports Knowledge, Lex Fridman Politics/Society.
    // Returns [:] rather than throwing: a channel with no topics is normal, and a
    // missing profile only costs us the exploration slot.
    static func parseTopics(_ data: Data) -> [String: [String]] {
        guard let response = try? JSONDecoder().decode(TopicsResponse.self, from: data) else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for item in response.items {
            let labels = (item.topicDetails?.topicCategories ?? []).compactMap {
                URL(string: $0)?.lastPathComponent
            }
            if !labels.isEmpty { result[item.id] = labels }
        }
        return result
    }

    // MARK: - search.list

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct ID: Decodable { let videoId: String? }
            struct Snippet: Decodable {
                struct Thumbnail: Decodable { let url: String }
                let title: String
                let description: String?
                let channelId: String?
                let channelTitle: String?
                let publishedAt: Date?
                let thumbnails: [String: Thumbnail]?
            }
            let id: ID
            let snippet: Snippet
        }
        let items: [Item]
    }

    static func parseSearch(_ data: Data, now: Date = Date()) throws -> [ChannelVideo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(SearchResponse.self, from: data) else {
            throw YouTubeAPIError.unreadable
        }
        return response.items.compactMap { item -> ChannelVideo? in
            guard let videoId = item.id.videoId, !videoId.isEmpty else { return nil }
            return ChannelVideo(
                videoId: videoId,
                // search.list HTML-escapes its text ("Homer&#39;s Odyssey"), unlike
                // playlistItems. Left encoded it would display literally.
                title: decodingEntities(item.snippet.title),
                durationText: nil,
                viewsText: nil,
                publishedText: item.snippet.publishedAt
                    .map { VideoCardItem.relativeDate($0, now: now) },
                publishedAt: item.snippet.publishedAt,
                summary: item.snippet.description.flatMap {
                    $0.isEmpty ? nil : decodingEntities($0)
                },
                thumbnailURL: searchThumbnail(item.snippet.thumbnails),
                channelTitle: item.snippet.channelTitle.map(decodingEntities),
                channelId: item.snippet.channelId)
        }
    }

    // search.list offers only default/medium/high — no maxres or standard.
    private static func searchThumbnail(
        _ thumbnails: [String: SearchResponse.Item.Snippet.Thumbnail]?
    ) -> URL? {
        guard let thumbnails else { return nil }
        for key in ["high", "medium", "default"] {
            if let raw = thumbnails[key]?.url, let url = URL(string: raw) { return url }
        }
        return nil
    }

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: - Errors

    // Turns an error body into a reason string, so quota exhaustion (which the
    // user fixes by waiting) reads differently from a bad key (which they fix in
    // Settings). Verified error shape: error.errors[0].reason.
    static func errorReason(_ data: Data) -> String? {
        struct ErrorResponse: Decodable {
            struct Body: Decodable {
                struct Detail: Decodable { let reason: String? }
                let errors: [Detail]?
            }
            let error: Body
        }
        return (try? JSONDecoder().decode(ErrorResponse.self, from: data))?
            .error.errors?.first?.reason
    }

    // A channel's uploads playlist id. Verified: UCSHZKyawb77ixDdsGog4iWA ->
    // UUSHZKyawb77ixDdsGog4iWA returns that channel's 865 uploads.
    static func uploadsPlaylistId(channelId: String) -> String? {
        guard YouTubeChannelLogic.isValidChannelId(channelId) else { return nil }
        return "UU" + channelId.dropFirst(2)
    }
}
