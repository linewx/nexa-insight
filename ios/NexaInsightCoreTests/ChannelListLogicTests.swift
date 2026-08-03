import XCTest
@testable import NexaInsightCore

final class ChannelListLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, channel: String, title: String, daysAgo: Double) -> DiscoverEntry {
        DiscoverEntry(videoId: id, channelId: channel, title: title, channelTitle: "C",
                      published: now.addingTimeInterval(-daysAgo * 86_400), summary: nil,
                      thumbnailURL: nil, viewCount: nil,
                      watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
    }

    private func video(_ id: String, channel: String?, title: String,
                       daysAgo: Double?, publishedText: String? = nil) -> ChannelVideo {
        ChannelVideo(videoId: id, title: title, durationText: nil, viewsText: nil,
                     publishedText: publishedText,
                     publishedAt: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
                     summary: nil, thumbnailURL: nil, channelTitle: "C", channelId: channel)
    }

    // The point of the row: what is new, not merely that the channel exists.
    func testPicksTheNewestVideoPerChannel() {
        let result = ChannelList.latestByChannel(
            entries: [
                entry("1", channel: "A", title: "old", daysAgo: 30),
                entry("2", channel: "A", title: "new", daysAgo: 1),
                entry("3", channel: "B", title: "only", daysAgo: 5),
            ],
            apiEntries: [], now: now)

        XCTAssertEqual(result["A"]?.title, "new")
        XCTAssertEqual(result["B"]?.title, "only")
    }

    // The feed is ranked by engagement, not sorted by date, so the first entry seen
    // for a channel is not necessarily its newest. This is the bug the explicit
    // date comparison exists to prevent.
    func testRankedOrderDoesNotDecideWhichIsNewest() {
        // Newest deliberately placed last, as engagement ranking may do.
        let result = ChannelList.latestByChannel(
            entries: [
                entry("1", channel: "A", title: "older but ranked first", daysAgo: 10),
                entry("2", channel: "A", title: "actually newest", daysAgo: 2),
            ],
            apiEntries: [], now: now)

        XCTAssertEqual(result["A"]?.title, "actually newest")
    }

    // The API path is the richer source and supplies the whole feed when present;
    // mixing it with RSS would put two date formats side by side.
    func testAPIFeedIsUsedInsteadOfRSSWhenPresent() {
        let result = ChannelList.latestByChannel(
            entries: [entry("1", channel: "A", title: "from rss", daysAgo: 1)],
            apiEntries: [video("2", channel: "A", title: "from api", daysAgo: 9)],
            now: now)

        XCTAssertEqual(result["A"]?.title, "from api",
                       "the API feed replaces RSS rather than competing with it")
    }

    // Scraped paths carry no timestamp at all. The row still says something.
    func testFallsBackToThePreRenderedAgeStringWithoutATimestamp() {
        let result = ChannelList.latestByChannel(
            entries: [],
            apiEntries: [video("1", channel: "A", title: "t", daysAgo: nil,
                               publishedText: "3 years ago")],
            now: now)

        XCTAssertEqual(result["A"]?.ageText, "3 years ago")
    }

    // A nil date must never displace a known one, or an undated entry would win by
    // arriving late.
    func testUndatedEntryDoesNotDisplaceADatedOne() {
        let result = ChannelList.latestByChannel(
            entries: [],
            apiEntries: [
                video("1", channel: "A", title: "dated", daysAgo: 4),
                video("2", channel: "A", title: "undated", daysAgo: nil),
            ],
            now: now)

        XCTAssertEqual(result["A"]?.title, "dated")
    }

    // An entry with no channel cannot be attributed to a row, and must not crash or
    // land under some default key.
    func testVideosWithoutAChannelAreSkipped() {
        let result = ChannelList.latestByChannel(
            entries: [],
            apiEntries: [video("1", channel: nil, title: "orphan", daysAgo: 1)],
            now: now)

        XCTAssertTrue(result.isEmpty)
    }

    // A cold Channels tab: rows fall back to the subscriber count rather than
    // showing an empty second line.
    func testEmptyFeedYieldsNothingRatherThanPlaceholders() {
        XCTAssertTrue(ChannelList.latestByChannel(entries: [], apiEntries: [], now: now).isEmpty)
    }
}
