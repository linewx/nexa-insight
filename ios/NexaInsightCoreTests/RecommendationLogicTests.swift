import XCTest
@testable import NexaInsightCore

final class RecommendationLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func episode(_ id: Int, channel: String, durationMs: Int?, positionMs: Int?) -> EpisodeDTO {
        EpisodeDTO(id: id, sourceUrl: "https://youtu.be/v\(id)", youtubeId: "v\(id)",
                   title: "Episode \(id)", channel: channel, durationMs: durationMs,
                   thumbnailUrl: nil, audioPath: nil, status: "ready", error: nil,
                   positionMs: positionMs)
    }

    private func entry(_ id: String, channel: String, daysAgo: Double) -> DiscoverEntry {
        DiscoverEntry(videoId: id, channelId: channel, title: "T\(id)", channelTitle: "C",
                      published: now.addingTimeInterval(-daysAgo * 86_400), summary: nil,
                      thumbnailURL: nil, viewCount: nil,
                      watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
    }

    // MARK: - Engagement

    // The whole premise: what you actually studied outranks what you merely added.
    func testFinishingOutweighsAdding() {
        let studied = ChannelEngagement(channelId: "A", episodesAdded: 1, episodesFinished: 1,
                                        totalListenedMs: 3_600_000)
        let hoarded = ChannelEngagement(channelId: "B", episodesAdded: 6)
        XCTAssertGreaterThan(studied.score, hoarded.score,
                             "one finished episode beats six untouched ones")
    }

    // Shadowing and notes are the rarest signals, so they must count.
    func testShadowingAndNotesRaiseTheScore() {
        var base = ChannelEngagement(channelId: "A", episodesAdded: 1, totalListenedMs: 1_800_000)
        let plain = base.score
        base.recordings = 3
        base.insights = 2
        XCTAssertGreaterThan(base.score, plain)
    }

    func testEngagementAggregatesPerChannel() {
        let episodes = [
            episode(1, channel: "UCa", durationMs: 3_600_000, positionMs: 3_580_000),  // finished
            episode(2, channel: "UCa", durationMs: 3_600_000, positionMs: 600_000),    // partial
            episode(3, channel: "UCb", durationMs: 3_600_000, positionMs: nil),        // untouched
        ]
        let result = Recommend.engagement(from: episodes, channelIdFor: { $0.channel })
        XCTAssertEqual(result["UCa"]?.episodesAdded, 2)
        XCTAssertEqual(result["UCa"]?.episodesFinished, 1)
        XCTAssertEqual(result["UCa"]?.totalListenedMs, 4_180_000)
        XCTAssertEqual(result["UCb"]?.episodesFinished, 0)
        XCTAssertGreaterThan(result["UCa"]!.score, result["UCb"]!.score)
    }

    func testMissingDurationCannotCountAsFinished() {
        let result = Recommend.engagement(
            from: [episode(1, channel: "UCa", durationMs: nil, positionMs: 9_000_000)],
            channelIdFor: { $0.channel })
        XCTAssertEqual(result["UCa"]?.episodesFinished, 0,
                       "without a duration there is no fraction to compare")
    }

    func testEpisodesWithNoChannelAreSkipped() {
        let result = Recommend.engagement(
            from: [episode(1, channel: "UCa", durationMs: 100, positionMs: 100)],
            channelIdFor: { _ in nil })
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Feed ranking

    // Engagement decides which channel leads, but recency stays the outer axis —
    // otherwise today's upload from a new channel would sit below a month-old one
    // from a favourite, in a feed whose whole purpose is new things.
    func testRecencyBandsOutrankEngagement() {
        let engagement = ["UCfav": ChannelEngagement(channelId: "UCfav", episodesFinished: 10)]
        let ranked = Recommend.rankedFeed(
            [entry("old", channel: "UCfav", daysAgo: 20), entry("new", channel: "UCnew", daysAgo: 1)],
            engagement: engagement, now: now)
        XCTAssertEqual(ranked.map(\.videoId), ["new", "old"])
    }

    func testEngagementOrdersWithinABand() {
        let engagement = [
            "UCfav": ChannelEngagement(channelId: "UCfav", episodesFinished: 5),
            "UCmeh": ChannelEngagement(channelId: "UCmeh", episodesAdded: 1),
        ]
        // Same band (both under three days), so engagement decides.
        let ranked = Recommend.rankedFeed(
            [entry("meh", channel: "UCmeh", daysAgo: 0.5), entry("fav", channel: "UCfav", daysAgo: 2)],
            engagement: engagement, now: now)
        XCTAssertEqual(ranked.map(\.videoId), ["fav", "meh"])
    }

    func testUnknownChannelsFallBackToRecency() {
        let ranked = Recommend.rankedFeed(
            [entry("a", channel: "UCx", daysAgo: 2), entry("b", channel: "UCy", daysAgo: 1)],
            engagement: [:], now: now)
        XCTAssertEqual(ranked.map(\.videoId), ["b", "a"], "no signal yet: newest first")
    }

    func testRecencyBands() {
        XCTAssertEqual(Recommend.recencyBand(now.addingTimeInterval(-3600), now: now), 0)
        XCTAssertEqual(Recommend.recencyBand(now.addingTimeInterval(-5 * 86_400), now: now), 1)
        XCTAssertEqual(Recommend.recencyBand(now.addingTimeInterval(-20 * 86_400), now: now), 2)
        XCTAssertEqual(Recommend.recencyBand(now.addingTimeInterval(-90 * 86_400), now: now), 3)
    }

    // MARK: - Exploration topic

    // Measured live: Veritasium and PBS Space Time report "Knowledge", Lex Fridman
    // reports "Politics"/"Society". So a real profile looks like this.
    func testPicksANeighbourOfTheStrongestTopic() {
        let topic = Recommend.explorationTopic(covered: ["Knowledge": 5, "Society": 1])
        XCTAssertNotNil(topic)
        XCTAssertTrue(Recommend.adjacency["Knowledge"]!.contains(topic!))
        XCTAssertNotEqual(topic, "Knowledge", "exploring means leaving the strongest topic")
    }

    // A topic you already cover heavily is not exploration.
    func testSkipsTopicsAlreadyWellCovered() {
        let topic = Recommend.explorationTopic(covered: ["Knowledge": 9, "History": 9])
        XCTAssertNotEqual(topic, "History")
    }

    func testNoProfileYieldsNoExploration() {
        XCTAssertNil(Recommend.explorationTopic(covered: [:]),
                     "nothing to reason from, so do not spend a search")
    }

    func testUnknownTopicYieldsNoExploration() {
        XCTAssertNil(Recommend.explorationTopic(covered: ["Gardening": 4]))
    }

    // topicId search returned zero results when measured; plain words return pages.
    func testQueriesAreWordsNotTopicIds() {
        XCTAssertEqual(Recommend.query(for: "History"), "history documentary")
        XCTAssertFalse(Recommend.query(for: "Philosophy").contains("/m/"))
    }

    // MARK: - Insertion

    // Never first, never adjacent: an unproven pick should not lead the feed, and a
    // cluster of them reads as the feed being taken over.
    func testExplorationNeverLeadsTheFeed() {
        let slots = Recommend.insertionSlots(feedCount: 20, explorationCount: 3)
        XCTAssertFalse(slots.contains(1))
        XCTAssertFalse(slots.contains(2))
        XCTAssertEqual(slots.first, 3)
    }

    func testExplorationItemsAreSpacedApart() {
        let slots = Recommend.insertionSlots(feedCount: 30, explorationCount: 3)
        for (a, b) in zip(slots, slots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 4, "slots \(slots) are too close together")
        }
    }

    // A feed too short to hide a recommendation in should not get one.
    func testShortFeedGetsNoExploration() {
        XCTAssertTrue(Recommend.insertionSlots(feedCount: 2, explorationCount: 3).isEmpty)
        XCTAssertTrue(Recommend.insertionSlots(feedCount: 20, explorationCount: 0).isEmpty)
    }
}
