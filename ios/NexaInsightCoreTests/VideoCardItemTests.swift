import XCTest
@testable import NexaInsightCore

final class VideoCardItemTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func entry(views: Int? = nil, thumbnail: URL? = nil) -> DiscoverEntry {
        DiscoverEntry(
            videoId: "abc12345678",
            channelId: "UCSHZKyawb77ixDdsGog4iWA",
            title: "Black Holes and Quantum Gravity",
            channelTitle: "Lex Fridman",
            published: now.addingTimeInterval(-3 * 24 * 3600),
            summary: "a description we deliberately do not display",
            thumbnailURL: thumbnail,
            viewCount: views,
            watchURL: URL(string: "https://www.youtube.com/watch?v=abc12345678")!)
    }

    private func video(
        duration: String? = "2:19:34",
        channelTitle: String? = "Lex Fridman",
        channelId: String? = "UCSHZKyawb77ixDdsGog4iWA"
    ) -> ChannelVideo {
        ChannelVideo(
            videoId: "y3cw_9ELpQw",
            title: "Andrew Strominger: Black Holes",
            durationText: duration,
            viewsText: "3,028,760 views",
            publishedText: "3 years ago",
            summary: "snippet",
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/y3cw_9ELpQw/hqdefault.jpg"),
            channelTitle: channelTitle,
            channelId: channelId)
    }

    // The one field the two sources genuinely disagree on. RSS carries no
    // duration tag, so the card must render without one rather than showing a
    // placeholder or a second layout.
    func testRSSSourceHasNoDuration() {
        let item = VideoCardItem(entry(), now: now)
        XCTAssertNil(item.durationText)
    }

    func testChannelVideoSourceKeepsDuration() {
        let item = VideoCardItem(video())
        XCTAssertEqual(item?.durationText, "2:19:34")
    }

    func testRSSMetaTextJoinsRelativeDateAndViews() {
        let item = VideoCardItem(entry(views: 1_200_000), now: now)
        XCTAssertTrue(item.metaText.contains("views"), "got \(item.metaText)")
        XCTAssertTrue(item.metaText.contains("·"), "date and views are joined: \(item.metaText)")
    }

    func testRSSMetaTextOmitsViewsWhenAbsent() {
        let item = VideoCardItem(entry(views: nil), now: now)
        XCTAssertFalse(item.metaText.contains("views"))
        XCTAssertFalse(item.metaText.contains("·"), "no trailing separator: \(item.metaText)")
    }

    // The channel name never appears in metaText — the card renders it on its own
    // line as a tap target, so duplicating it here would show it twice.
    func testMetaTextExcludesChannelName() {
        XCTAssertFalse(VideoCardItem(entry(), now: now).metaText.contains("Lex Fridman"))
        XCTAssertFalse(VideoCardItem(video())!.metaText.contains("Lex Fridman"))
    }

    func testChannelVideoMetaTextJoinsPublishedAndViews() {
        XCTAssertEqual(VideoCardItem(video())?.metaText, "3 years ago · 3,028,760 views")
    }

    func testRSSSourceCarriesChannelIdSoTheNameIsTappable() {
        let item = VideoCardItem(entry(), now: now)
        XCTAssertEqual(item.channelId, "UCSHZKyawb77ixDdsGog4iWA")
        XCTAssertTrue(item.channelIsTappable)
    }

    // In-channel search results carry no owner fields — you already know whose
    // channel you are looking at. The name must then not pretend to be a link.
    func testMissingChannelIdMakesTheNameNonTappable() {
        let item = VideoCardItem(video(channelTitle: nil, channelId: nil))
        XCTAssertFalse(item!.channelIsTappable)
        XCTAssertNil(item?.channelTitle)
    }

    func testChannelTitleWithoutIdIsStillNotTappable() {
        let item = VideoCardItem(video(channelTitle: "Lex Fridman", channelId: nil))
        XCTAssertFalse(item!.channelIsTappable, "a name with nowhere to go is not a link")
        XCTAssertEqual(item?.channelTitle, "Lex Fridman", "but it is still displayed")
    }

    func testWatchURLIsPreserved() {
        XCTAssertEqual(
            VideoCardItem(entry(), now: now).watchURL.absoluteString,
            "https://www.youtube.com/watch?v=abc12345678")
        XCTAssertEqual(
            VideoCardItem(video())?.watchURL.absoluteString,
            "https://www.youtube.com/watch?v=y3cw_9ELpQw")
    }

    func testIdentityIsTheVideoId() {
        XCTAssertEqual(VideoCardItem(entry(), now: now).id, "abc12345678")
        XCTAssertEqual(VideoCardItem(video())?.id, "y3cw_9ELpQw")
    }

    func testThumbnailPassesThrough() {
        let url = URL(string: "https://i.ytimg.com/vi/abc12345678/hqdefault.jpg")!
        XCTAssertEqual(VideoCardItem(entry(thumbnail: url), now: now).thumbnailURL, url)
    }
}
