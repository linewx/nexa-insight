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

    // All three factors contribute, so a channel you have genuinely studied can
    // outrank a fresher upload from one you ignore. The previous version sorted into
    // recency tiers first, which meant time always won outright and a channel followed
    // once and never played led the feed.
    func testHeavyEngagementCanOutrankFresherUpload() {
        let engagement = ["UCfav": ChannelEngagement(channelId: "UCfav", episodesFinished: 10,
                                                     totalListenedMs: 36_000_000)]
        let ranked = Recommend.rankedFeed(
            [entry("new", channel: "UCnew", daysAgo: 1), entry("studied", channel: "UCfav", daysAgo: 6)],
            engagement: engagement, now: now)
        XCTAssertEqual(ranked.first?.videoId, "studied")
    }

    // Recency still carries real weight: between two channels you study equally, the
    // newer upload leads.
    func testRecencyDecidesBetweenEqualChannels() {
        let engagement = [
            "UCa": ChannelEngagement(channelId: "UCa", episodesFinished: 3),
            "UCb": ChannelEngagement(channelId: "UCb", episodesFinished: 3),
        ]
        let ranked = Recommend.rankedFeed(
            [entry("older", channel: "UCa", daysAgo: 14), entry("newer", channel: "UCb", daysAgo: 1)],
            engagement: engagement, now: now)
        XCTAssertEqual(ranked.map(\.videoId), ["newer", "older"])
    }

    // A brand-new upload from an unknown channel is not buried: recency alone carries
    // 0.35, enough to beat a stale item from a channel with middling history.
    func testNewUploadFromUnknownChannelStillSurfaces() {
        let engagement = ["UCknown": ChannelEngagement(channelId: "UCknown", episodesAdded: 2)]
        let ranked = Recommend.rankedFeed(
            [entry("stale", channel: "UCknown", daysAgo: 30), entry("fresh", channel: "UCnew", daysAgo: 0)],
            engagement: engagement, now: now)
        XCTAssertEqual(ranked.first?.videoId, "fresh")
    }

    // MARK: - Topic affinity

    // The reason topics are tracked separately from channels: studying Veritasium
    // should lift PBS Space Time too, since both report "Knowledge".
    func testTopicAffinitySpreadsAcrossChannelsSharingASubject() {
        let engagement = ["UCver": ChannelEngagement(channelId: "UCver", episodesFinished: 4)]
        let topics = ["UCver": ["Knowledge"], "UCpbs": ["Knowledge"], "UCmusic": ["Music"]]
        let affinity = Recommend.topicAffinity(engagement: engagement, topics: topics)

        XCTAssertEqual(affinity.normalised(for: ["Knowledge"]), 1.0, accuracy: 0.001)
        XCTAssertEqual(affinity.normalised(for: ["Music"]), 0.0, accuracy: 0.001,
                       "an unstudied subject contributes nothing")
    }

    func testTopicMatchLiftsAnUnfollowedChannel() {
        let engagement = ["UCver": ChannelEngagement(channelId: "UCver", episodesFinished: 4)]
        let topics = ["UCver": ["Knowledge"], "UCpbs": ["Knowledge"], "UCrandom": ["Sports"]]
        let ranked = Recommend.rankedFeed(
            [entry("sports", channel: "UCrandom", daysAgo: 2),
             entry("knowledge", channel: "UCpbs", daysAgo: 2)],
            engagement: engagement, topics: topics, now: now)
        XCTAssertEqual(ranked.first?.videoId, "knowledge",
                       "same age, same lack of history — the subject match decides")
    }

    func testNoTopicsMeansTopicContributesNothing() {
        let engagement = ["UCa": ChannelEngagement(channelId: "UCa", episodesFinished: 2)]
        let ranked = Recommend.rankedFeed(
            [entry("a", channel: "UCa", daysAgo: 5), entry("b", channel: "UCb", daysAgo: 1)],
            engagement: engagement, topics: [:], now: now)
        XCTAssertEqual(ranked.count, 2, "ranking still works with no topic data at all")
    }

    // Relative to the heaviest channel, so a light user's scores do not all collapse
    // to zero and leave recency as the only signal.
    func testEngagementIsNormalisedAgainstTheHeaviestChannel() {
        let engagement = [
            "UCheavy": ChannelEngagement(channelId: "UCheavy", episodesFinished: 10),
            "UClight": ChannelEngagement(channelId: "UClight", episodesFinished: 1),
        ]
        XCTAssertEqual(Recommend.normalisedEngagement("UCheavy", engagement: engagement), 1.0,
                       accuracy: 0.001)
        let light = Recommend.normalisedEngagement("UClight", engagement: engagement)
        XCTAssertGreaterThan(light, 0)
        XCTAssertLessThan(light, 1)
        XCTAssertEqual(Recommend.normalisedEngagement("UCunknown", engagement: engagement), 0)
    }

    // Decays smoothly rather than stepping, so a 10-day-old upload does not rank
    // identically to a 3-day-old one.
    func testRecencyDecaysSmoothly() {
        let fresh = Recommend.recencyScore(now, now: now)
        let week = Recommend.recencyScore(now.addingTimeInterval(-7 * 86_400), now: now)
        let fortnight = Recommend.recencyScore(now.addingTimeInterval(-14 * 86_400), now: now)
        XCTAssertEqual(fresh, 1.0, accuracy: 0.01)
        XCTAssertEqual(week, 0.5, accuracy: 0.01, "one-week half-life")
        XCTAssertEqual(fortnight, 0.25, accuracy: 0.01)
        XCTAssertGreaterThan(Recommend.recencyScore(now.addingTimeInterval(-3 * 86_400), now: now), week)
    }

    // Subscription must not dominate — that was the reported problem.
    func testNoSingleFactorDominates() {
        let total = Recommend.subscriptionWeight + Recommend.topicWeight + Recommend.recencyWeight
        XCTAssertEqual(total, 1.0, accuracy: 0.001)
        for w in [Recommend.subscriptionWeight, Recommend.topicWeight, Recommend.recencyWeight] {
            XCTAssertLessThan(w, 0.5, "no factor may outweigh the other two combined")
        }
    }

    // MARK: - Cold start

    // Cycles subjects before repeating one, so consecutive days never land on the
    // same subject.
    func testColdStartNeverRepeatsASubjectOnConsecutiveDays() {
        func subjectIndex(_ day: Int) -> Int {
            let q = Recommend.coldStartQuery(dayIndex: day)
            return Recommend.coldStartSubjects.firstIndex { $0.contains(q) } ?? -1
        }
        for day in 0..<9 {
            XCTAssertNotEqual(subjectIndex(day), subjectIndex(day + 1),
                              "day \(day) and \(day + 1) share a subject")
        }
    }

    // All three subjects appear within a week, and the wording varies across cycles
    // so a returning user is not shown the identical query every third day.
    func testColdStartCoversEverySubjectAndVariesWording() {
        let week = (0..<7).map { Recommend.coldStartQuery(dayIndex: $0) }
        for subject in Recommend.coldStartSubjects {
            XCTAssertTrue(week.contains { subject.contains($0) },
                          "a week should reach \(subject.first ?? "")")
        }
        XCTAssertNotEqual(Recommend.coldStartQuery(dayIndex: 0),
                          Recommend.coldStartQuery(dayIndex: 3),
                          "same subject, different wording on the next cycle")
    }

    // The queries themselves were chosen by measuring median view counts, so the
    // list must stay the measured wording rather than drifting back to phrasing that
    // reads well: "technology deep dive" returned a 35,627 median against 1,664,861
    // for "ai podcast".
    func testColdStartUsesTheMeasuredQueries() {
        XCTAssertTrue(Recommend.coldStartQueries.contains("ai podcast"))
        XCTAssertTrue(Recommend.coldStartQueries.contains("business podcast"))
        XCTAssertTrue(Recommend.coldStartQueries.contains("learn english conversation"))
        XCTAssertFalse(Recommend.coldStartQueries.contains("technology deep dive"))
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

    // MARK: - Quality and diversity

    private func chVideo(_ id: String, channel: String?) -> ChannelVideo {
        ChannelVideo(videoId: id, title: "T\(id)", durationText: nil, viewsText: nil,
                     publishedText: nil, summary: nil, thumbnailURL: nil,
                     channelTitle: channel, channelId: channel)
    }

    // Relevance ordering let one prolific podcast take 4 of 10 slots, which is one
    // suggestion repeated rather than a set of them.
    func testDiversifiedKeepsOnePerChannel() {
        let videos = [
            chVideo("a1", channel: "UCa"), chVideo("a2", channel: "UCa"),
            chVideo("b1", channel: "UCb"), chVideo("a3", channel: "UCa"),
            chVideo("c1", channel: "UCc"),
        ]
        XCTAssertEqual(Recommend.diversified(videos).map(\.videoId), ["a1", "b1", "c1"])
    }

    func testDiversifiedPreservesOrder() {
        let videos = [chVideo("z", channel: "UCz"), chVideo("a", channel: "UCa")]
        XCTAssertEqual(Recommend.diversified(videos).map(\.videoId), ["z", "a"],
                       "the view-count ordering from the search is not re-sorted")
    }

    // Dropping them would silently lose results rather than merely reordering.
    func testVideosWithoutAChannelIdAreKept() {
        let videos = [chVideo("x", channel: nil), chVideo("y", channel: nil)]
        XCTAssertEqual(Recommend.diversified(videos).count, 2)
    }

    func testPerChannelLimitIsConfigurable() {
        let videos = [
            chVideo("a1", channel: "UCa"), chVideo("a2", channel: "UCa"),
            chVideo("a3", channel: "UCa"),
        ]
        XCTAssertEqual(Recommend.diversified(videos, perChannel: 2).count, 2)
    }

    // The floor exists because the measured spread ran from 755,241 views down to
    // 2,570 — the tail is unwatched material, not a milder version of the head.
    func testQualityThresholdsAreSet() {
        XCTAssertGreaterThan(Recommend.minimumViews, 0)
        XCTAssertGreaterThan(Recommend.minimumSubscribers, 0)
    }

    func testVideoRecommendationWeightsFollowedHistoryPopularityAndTime() {
        func recommended(_ id: String,
                         channel: String,
                         title: String? = nil,
                         views: String?,
                         published: String?) -> ChannelVideo {
            ChannelVideo(videoId: id, title: title ?? id, durationText: "1:00:00",
                         viewsText: views, publishedText: published, summary: nil,
                         thumbnailURL: nil, channelTitle: channel, channelId: channel)
        }
        let engagement = [
            "UCstudied": ChannelEngagement(channelId: "UCstudied",
                                           episodesFinished: 4,
                                           totalListenedMs: 7_200_000),
            "UChistory": ChannelEngagement(channelId: "UChistory",
                                           episodesFinished: 2,
                                           totalListenedMs: 3_600_000),
        ]
        let topics = [
            "UCstudied": ["Technology"],
            "UCpopular": ["Technology"],
            "UCold": ["Sports"],
            "UCrandom": ["Sports"],
        ]
        let ranked = Recommend.rankedVideos(
            [
                recommended("random", channel: "UCrandom", views: "900K views", published: "1 day ago"),
                recommended("studied", channel: "UCstudied", views: "40K views", published: "5 days ago"),
                recommended("popular", channel: "UCpopular", views: "2M views", published: "2 days ago"),
                recommended("old", channel: "UCold", views: "3M views", published: "2 years ago"),
            ],
            followedChannelIds: ["UCstudied"],
            engagement: engagement,
            topics: topics,
            now: now)

        XCTAssertEqual(ranked.first?.videoId, "studied",
                       "a followed channel with real playback history should lead")
        XCTAssertLessThan(ranked.firstIndex { $0.videoId == "popular" }!,
                          ranked.firstIndex { $0.videoId == "random" }!,
                          "popular videos in a studied category should beat unrelated fresh items")
        XCTAssertEqual(ranked.last?.videoId, "old", "stale videos should not win on views alone")
    }

    func testVideoMetadataParsingSupportsRecommendationSignals() {
        XCTAssertEqual(Recommend.parseViewCount("1.2M views"), 1_200_000)
        XCTAssertEqual(Recommend.parseViewCount("45K views"), 45_000)
        XCTAssertEqual(Recommend.parseViewCount("9,876 views"), 9_876)

        let threeWeeks = Recommend.parsePublishedText("3 weeks ago", now: now)
        XCTAssertNotNil(threeWeeks)
        XCTAssertEqual(threeWeeks!.timeIntervalSince(now.addingTimeInterval(-21 * 86_400)),
                       0,
                       accuracy: 0.1)
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
