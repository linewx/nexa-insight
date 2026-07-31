import Foundation

// A channel's own identity, shown at the top of its detail screen.
//
// Every field is optional because this comes from scraping a page that YouTube is
// actively migrating. A failed parse must degrade to the channel title the video
// card already supplied, never to an error state — the content below the header
// comes from RSS and in-channel search, which are unaffected.
struct ChannelHeader: Equatable {
    let title: String?
    let avatarURL: URL?
    let subscriberText: String?   // "4.7M subscribers"

    static let empty = ChannelHeader(title: nil, avatarURL: nil, subscriberText: nil)

    var isEmpty: Bool { self == .empty }
}
