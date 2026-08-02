import Foundation

// Caches the daily exploration search.
//
// search.list costs 100 units from a bucket of exactly 100 PER DAY — separate from
// the 10,000-unit pool everything else draws on. So the app gets one search per
// day, and refreshing Discover must not spend it again. Everything else here
// (uploads, topics, durations) costs 1 unit and needs no caching.
final class ExplorationCache {
    private let defaults: UserDefaults
    // Bumped whenever the SEARCH ITSELF changes — new query wording, a different
    // date bound, another sort order. Without it a cached result from the old
    // parameters counted as "already searched today", so a fix to the query looked
    // like no change at all until the next day.
    private static let schema = 2

    private let dayKey: String
    private let topicKey: String
    private let payloadKey: String
    private let schemaKey: String

    // `namespace` lets cold start and topic exploration share this type without
    // sharing a slot: both spend the same daily search budget, but a cold-start
    // result must not be mistaken for a topic suggestion once channels exist.
    init(defaults: UserDefaults = .standard, namespace: String = "exploration") {
        self.defaults = defaults
        self.dayKey = "\(namespace)Day"
        self.topicKey = "\(namespace)Topic"
        self.payloadKey = "\(namespace)Videos"
        self.schemaKey = "\(namespace)Schema"
    }

    // Day granularity rather than a timestamp: the quota resets daily, so "already
    // searched today" is exactly the question worth asking.
    private func today(_ now: Date) -> Int {
        Int(now.timeIntervalSince1970 / 86_400)
    }

    func isFresh(now: Date = Date()) -> Bool {
        guard defaults.integer(forKey: schemaKey) == Self.schema else { return false }
        return defaults.integer(forKey: dayKey) == today(now)
    }

    func topic() -> String? { defaults.string(forKey: topicKey) }

    func videos() -> [ChannelVideo] {
        guard let data = defaults.data(forKey: payloadKey),
              let stored = try? JSONDecoder().decode([StoredVideo].self, from: data)
        else { return [] }
        return stored.map(\.video)
    }

    func store(topic: String, videos: [ChannelVideo], now: Date = Date()) {
        defaults.set(Self.schema, forKey: schemaKey)
        defaults.set(today(now), forKey: dayKey)
        defaults.set(topic, forKey: topicKey)
        if let data = try? JSONEncoder().encode(videos.map(StoredVideo.init)) {
            defaults.set(data, forKey: payloadKey)
        }
    }

    // Records that a search happened even when it produced nothing, so a failed or
    // empty search does not retry on every refresh and burn the day's quota.
    func markAttempted(topic: String, now: Date = Date()) {
        defaults.set(Self.schema, forKey: schemaKey)
        defaults.set(today(now), forKey: dayKey)
        defaults.set(topic, forKey: topicKey)
        defaults.removeObject(forKey: payloadKey)
    }

    // ChannelVideo is not Codable (it is a display model built from several
    // sources), so this is the persistence shape.
    private struct StoredVideo: Codable {
        let videoId: String
        let title: String
        let durationText: String?
        let viewsText: String?
        let publishedText: String?
        let summary: String?
        let thumbnailURL: URL?
        let channelTitle: String?
        let channelId: String?

        init(_ video: ChannelVideo) {
            videoId = video.videoId
            title = video.title
            durationText = video.durationText
            viewsText = video.viewsText
            publishedText = video.publishedText
            summary = video.summary
            thumbnailURL = video.thumbnailURL
            channelTitle = video.channelTitle
            channelId = video.channelId
        }

        var video: ChannelVideo {
            ChannelVideo(
                videoId: videoId, title: title, durationText: durationText,
                viewsText: viewsText, publishedText: publishedText,
                // publishedAt is deliberately dropped: it exists only to sort the
                // followed feed, and an explored item is placed by slot, not date.
                publishedAt: nil,
                summary: summary, thumbnailURL: thumbnailURL,
                channelTitle: channelTitle, channelId: channelId)
        }
    }
}
