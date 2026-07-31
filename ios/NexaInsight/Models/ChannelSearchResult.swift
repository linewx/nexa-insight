import Foundation

// One channel from a search.
//
// Two of these fields come from response keys whose names contradict their
// contents: handle is read from `subscriberCountText` and subscriberText from
// `videoCountText`. Verified across several queries with locale pinned. The
// names here describe what the values ARE, not where they came from.
struct ChannelSearchResult: Identifiable, Equatable {
    let channelId: String
    let title: String
    let handle: String?
    let subscriberText: String?
    let summary: String?
    let thumbnailURL: URL?

    var id: String { channelId }
}
