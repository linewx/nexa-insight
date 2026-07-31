import Foundation

// One video from a channel, ready to be imported.
//
// Every metadata field keeps YouTube's own display string rather than being
// parsed into Int/Date. These arrive already localized ("3 years ago",
// "3,028,760 views"); parsing them back would mean handling every language and
// abbreviation format, and we only ever display them. This is a deliberate
// difference from DiscoverEntry, whose `published` is a real Date because RSS
// provides an ISO-8601 timestamp.
struct ChannelVideo: Identifiable, Equatable {
    let videoId: String
    let title: String
    let durationText: String?    // "2:19:34" — present in 30/30 measured
    let viewsText: String?       // "3,028,760 views"
    let publishedText: String?   // "3 years ago"
    let summary: String?         // absent in 4/30 measured, so optional
    let thumbnailURL: URL?
    // Present on site-wide search results, absent on in-channel results (there
    // the channel is already known from the screen you are on). The card needs
    // these to make the channel name tappable, which is the only route to
    // following a channel.
    var channelTitle: String?
    var channelId: String?

    var id: String { videoId }

    // All 30 measured videoIds were 11 chars, which is exactly what the
    // backend's youtube_id() accepts, so this URL imports without backend work.
    var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }
}
