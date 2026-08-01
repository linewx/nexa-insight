import Foundation

// What a channel row can say beyond its own name.
//
// The row showed a name, a subscriber count, and a chevron — three things, none of
// which answer the question the screen is actually for: which of my channels has
// something new. The feed already holds that answer; it was only ever rendered on
// Discover.
struct ChannelLatest: Equatable {
    // The newest video's title, so the row says what is new rather than only that
    // something is.
    let title: String
    // Relative age ("3d ago"). Optional because only one of the two feed sources
    // carries a real timestamp; the scraped pages supply a pre-rendered string, and
    // some entries have neither.
    let ageText: String?
}

enum ChannelList {
    // Newest video per channel, keyed by channelId.
    //
    // Built from whichever feed source is already loaded — this adds no request. On
    // a cold Channels tab the feed may be empty, in which case rows fall back to the
    // subscriber count, as before.
    //
    // The API path wins over RSS where both describe a channel: it is the richer
    // source, and mixing the two would put differently-formatted dates side by side.
    static func latestByChannel(
        entries: [DiscoverEntry],
        apiEntries: [ChannelVideo],
        now: Date = Date()
    ) -> [String: ChannelLatest] {
        var best: [String: (latest: ChannelLatest, sortDate: Date?)] = [:]

        // The feed is ranked by engagement, not strictly sorted by date, so "first
        // seen for this channel" is not necessarily the newest — compare dates.
        // A nil date never displaces a known one.
        func consider(_ channelId: String, _ latest: ChannelLatest, _ date: Date?) {
            guard let held = best[channelId] else {
                best[channelId] = (latest, date)
                return
            }
            guard let date else { return }
            if let heldDate = held.sortDate, heldDate >= date { return }
            best[channelId] = (latest, date)
        }

        if apiEntries.isEmpty {
            for entry in entries {
                consider(entry.channelId,
                         ChannelLatest(title: entry.title,
                                       ageText: VideoCardItem.relativeDate(entry.published, now: now)),
                         entry.published)
            }
        } else {
            for video in apiEntries {
                guard let channelId = video.channelId else { continue }
                consider(channelId,
                         ChannelLatest(title: video.title,
                                       // publishedAt exists only on the API path;
                                       // publishedText is already relative there.
                                       ageText: video.publishedAt.map { VideoCardItem.relativeDate($0, now: now) }
                                           ?? video.publishedText),
                         video.publishedAt)
            }
        }

        return best.mapValues(\.latest)
    }
}
