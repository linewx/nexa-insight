import Foundation

// What one video card shows, regardless of where the video came from.
//
// DiscoverEntry (RSS) and ChannelVideo (scraped HTML) stay separate models —
// different sources, different reliability, different field availability, and
// merging them would mean optional-everything. But the UI must have exactly one
// card, so this presentation type sits between them. It replaces three
// separately-written row layouts that differed in whether they showed a
// thumbnail at all, which is what made Discover feel inconsistent.
//
// Duration is the one field the two sources genuinely disagree on: RSS carries
// none. That is expressed by `durationText == nil` rather than by a second card.
struct VideoCardItem: Identifiable, Equatable {
    let videoId: String
    let title: String
    let channelTitle: String?
    let channelId: String?
    let durationText: String?
    // Already-joined display string ("3 days ago · 1.2M views"). Excludes the
    // channel name, which the card renders on its own line as a tap target.
    let metaText: String
    let thumbnailURL: URL?
    let watchURL: URL

    var id: String { videoId }

    // The channel name is the only route to following a channel, so it must be
    // tappable — but only when we actually know which channel to open.
    var channelIsTappable: Bool { channelId != nil && channelTitle != nil }

    // Drops the channel attribution. Used on a channel's own screen, where the
    // channel is already known and a tappable name would navigate back to the
    // screen you are on.
    func withoutChannel() -> VideoCardItem {
        VideoCardItem(
            videoId: videoId, title: title,
            channelTitle: nil, channelId: nil,
            durationText: durationText, metaText: metaText,
            thumbnailURL: thumbnailURL, watchURL: watchURL)
    }
}

extension VideoCardItem {
    // `now` is injectable so relative-date rendering is testable offline.
    init(_ entry: DiscoverEntry, now: Date = Date()) {
        var parts = [VideoCardItem.relativeDate(entry.published, now: now)]
        if let views = entry.viewCount {
            parts.append("\(views.formatted(.number.notation(.compactName))) views")
        }
        self.init(
            videoId: entry.videoId,
            title: entry.title,
            channelTitle: entry.channelTitle,
            channelId: entry.channelId,
            durationText: nil,  // RSS has no duration tag anywhere in the feed
            metaText: parts.joined(separator: " · "),
            thumbnailURL: entry.thumbnailURL,
            watchURL: entry.watchURL)
    }

    // Fails only when the videoId cannot form a watch URL, since a card with no
    // import target would be dead weight.
    init?(_ video: ChannelVideo) {
        guard let watchURL = video.watchURL else { return nil }
        self.init(
            videoId: video.videoId,
            title: video.title,
            channelTitle: video.channelTitle,
            channelId: video.channelId,
            durationText: video.durationText,
            metaText: [video.publishedText, video.viewsText]
                .compactMap { $0 }
                .joined(separator: " · "),
            thumbnailURL: video.thumbnailURL,
            watchURL: watchURL)
    }

    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
