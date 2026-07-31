import Foundation

// One video from a subscribed channel's RSS feed.
//
// Every field here is something the feed actually provides. Notably absent:
// duration — the feed carries no duration tag anywhere, so Discover never shows
// one. Chapters, discussion directions, and transcript state are absent for the
// same reason: they only exist after import, and inventing them pre-import is
// what made the old hardcoded Discover fake.
struct DiscoverEntry: Identifiable, Equatable {
    let videoId: String
    let channelId: String
    let title: String
    let channelTitle: String
    let published: Date
    let summary: String?
    let thumbnailURL: URL?
    let viewCount: Int?
    let watchURL: URL

    var id: String { videoId }
}

// A channel the user follows. channelId is the RSS key, so it is also the
// identity — subscribing twice to the same channel collapses to one entry.
struct Subscription: Codable, Identifiable, Equatable, Hashable {
    let channelId: String
    var title: String
    let addedAt: Date
    // Captured when following, so the channel list renders avatars without one
    // request per row. MUST stay optional: SubscriptionStore decodes the whole
    // array under a single `try?`, so one undecodable element silently empties
    // the follow list — a required field would wipe existing users' channels.
    var avatarURL: URL?
    var subscriberText: String?

    var id: String { channelId }
}
