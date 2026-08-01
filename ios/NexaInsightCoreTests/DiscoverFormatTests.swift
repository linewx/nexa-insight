import XCTest
@testable import NexaInsightCore

// Regression tests for a bug reported from a ja-JP device: the Discover byline
// rendered "3日前" and "41万 views" while the video titles and everything else
// around them stayed English.
//
// The cause was NOT YouTube. Verified by driving the real DiscoverFeedService
// with a session pinned to Accept-Language: ja-JP — search returned 0/20 and
// 0/30 Japanese metadata, so the network layer was already correct. The
// Japanese came from RelativeDateTimeFormatter and .compactName inside
// DiscoverFormat, both of which follow the system locale by default.
final class DiscoverFormatTests: XCTestCase {
    private func entry(published: Date, viewCount: Int?) -> DiscoverEntry {
        DiscoverEntry(
            videoId: "abcdefghijk", channelId: "UCSHZKyawb77ixDdsGog4iWA",
            title: "T", channelTitle: "Chan", published: published,
            summary: nil, thumbnailURL: nil, viewCount: viewCount,
            watchURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // "3d ago" rather than "3 days ago" because unitsStyle is .abbreviated,
    // which is the pre-existing style and not part of this fix.
    func testRelativeDateUsesConfiguredLocale() {
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        XCTAssertEqual(
            DiscoverFormat.relativeDate(threeDaysAgo, now: now, locale: Locale(identifier: "en_US")),
            "3d ago")
    }

    // The reported symptom: on a Japanese device this produced "3日前".
    func testRelativeDateHonoursJapaneseWhenAsked() {
        let threeDaysAgo = now.addingTimeInterval(-3 * 86_400)
        let ja = DiscoverFormat.relativeDate(threeDaysAgo, now: now, locale: Locale(identifier: "ja_JP"))
        XCTAssertTrue(ja.contains("日"), "expected a Japanese rendering, got \(ja)")
        XCTAssertNotEqual(ja, "3 days ago")
    }

    func testViewCountUsesConfiguredLocale() {
        let line = DiscoverFormat.byline(entry(published: now, viewCount: 411_000),
                                         now: now,
                                         locale: Locale(identifier: "en_US"))
        XCTAssertTrue(line.contains("411K views"), "got \(line)")
    }

    // Compact notation is locale-sensitive too: ja_JP renders 411,000 as 41万,
    // which is what produced the "41万 views" mixed-language byline.
    func testViewCountCompactNotationIsLocaleSensitive() {
        let ja = DiscoverFormat.byline(entry(published: now, viewCount: 411_000),
                                       now: now,
                                       locale: Locale(identifier: "ja_JP"))
        XCTAssertFalse(ja.contains("411K"), "ja_JP must not render 411K, got \(ja)")
    }

    // The whole point of making this configurable: an en_US byline must stay
    // fully English regardless of what the device locale is.
    func testEnglishBylineIsFullyEnglish() {
        let line = DiscoverFormat.byline(entry(published: now.addingTimeInterval(-86_400),
                                               viewCount: 2_500_000),
                                         now: now,
                                         locale: Locale(identifier: "en_US"))
        XCTAssertEqual(line, "Chan · 1d ago · 2.5M views")
    }

    func testBylineOmitsViewsWhenAbsent() {
        let line = DiscoverFormat.byline(entry(published: now.addingTimeInterval(-86_400),
                                               viewCount: nil),
                                         now: now,
                                         locale: Locale(identifier: "en_US"))
        XCTAssertEqual(line, "Chan · 1d ago")
    }

    func testDefaultLocaleIsEnglishNotSystem() {
        // The default must be a fixed locale rather than Locale.current, so a
        // ja-JP device does not silently get mixed-language output again.
        XCTAssertEqual(DiscoverFormat.defaultLocale.identifier, "en_US")
    }
}
