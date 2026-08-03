import Foundation

// What the app has actually observed about a channel, as opposed to the fact that
// you once followed it.
//
// Following says "I want to watch this". Finishing an episode, recording yourself
// shadowing it, and taking notes say "I am studying this". The second set is the
// better signal and it was already being stored — positionMs, recordings and
// insights all existed and none of them influenced what Discover showed.
struct ChannelEngagement: Equatable {
    let channelId: String
    var episodesAdded = 0
    var episodesFinished = 0
    var totalListenedMs = 0
    var recordings = 0
    var insights = 0

    // Deliberately not a tuned model. Each term is something a learner does
    // on purpose, and the weights say how much intent each one takes:
    // pressing add is cheap, finishing three hours is not, recording yourself
    // is rarer still.
    var score: Double {
        let hours = Double(totalListenedMs) / 3_600_000
        return Double(episodesFinished) * 3
            + hours * 2
            + Double(recordings) * 1.5
            + Double(insights) * 1.5
            // Adding without listening is weak evidence, and slightly negative
            // relative to nothing: a channel you keep adding and never playing is
            // one you are wrong about.
            + Double(episodesAdded) * 0.25
    }
}

enum Recommend {
    // An episode counts as studied rather than sampled past this point. Matches
    // Resume's own completion threshold so "finished" means one thing in the app.
    static let finishedFraction = Resume.completionFraction

    // Builds per-channel engagement from stored episodes. `listenedMs` is the saved
    // position, which is what we have — not true listening time, since a seek
    // forward would inflate it. Good enough to rank by, and free.
    static func engagement(from episodes: [EpisodeDTO], channelIdFor: (EpisodeDTO) -> String?,
                           recordingsFor: (Int) -> Int = { _ in 0 },
                           insightsFor: (Int) -> Int = { _ in 0 }) -> [String: ChannelEngagement] {
        var result: [String: ChannelEngagement] = [:]
        for episode in episodes {
            guard let channelId = channelIdFor(episode) else { continue }
            var entry = result[channelId] ?? ChannelEngagement(channelId: channelId)
            entry.episodesAdded += 1
            let position = episode.positionMs ?? 0
            entry.totalListenedMs += position
            if let duration = episode.durationMs, duration > 0,
               Double(position) / Double(duration) >= finishedFraction {
                entry.episodesFinished += 1
            }
            entry.recordings += recordingsFor(episode.id)
            entry.insights += insightsFor(episode.id)
            result[channelId] = entry
        }
        return result
    }

    // What a channel is about, and how much of your attention that subject has.
    //
    // Separate from ChannelEngagement because a topic's weight is shared across every
    // channel carrying it: finishing three Veritasium episodes should lift a PBS Space
    // Time upload too, since both report "Knowledge".
    struct TopicAffinity: Equatable {
        // Topic label -> summed engagement score of the channels carrying it.
        var weights: [String: Double] = [:]

        var strongest: Double { weights.values.max() ?? 0 }

        // 0...1, so it can be blended with the other factors on one scale. Same floor
        // as normalisedEngagement, and for the same reason.
        func normalised(for topics: [String]) -> Double {
            let best = max(Recommend.engagementFloor, strongest)
            let mine = topics.compactMap { weights[$0] }.max() ?? 0
            return min(1, mine / best)
        }
    }

    static func topicAffinity(engagement: [String: ChannelEngagement],
                              topics: [String: [String]]) -> TopicAffinity {
        var weights: [String: Double] = [:]
        for (channelId, entry) in engagement {
            guard entry.score > 0, let labels = topics[channelId] else { continue }
            for label in labels { weights[label, default: 0] += entry.score }
        }
        return TopicAffinity(weights: weights)
    }

    // Weights for the three factors. Subscription is deliberately NOT dominant: a
    // channel followed once and never played was outranking everything, which is the
    // behaviour this replaces.
    static let subscriptionWeight = 0.35
    static let topicWeight = 0.30
    static let recencyWeight = 0.35
    static let followedChannelWeight = 0.24
    static let watchedChannelWeight = 0.30
    static let relatedTopicWeight = 0.20
    static let popularityWeight = 0.12
    static let videoRecencyWeight = 0.14

    // A single blended score rather than the previous hard tiers.
    //
    // The old version sorted into recency bands first and only compared engagement
    // inside a band, so time always won outright and topic never entered at all. Now
    // all three contribute on a 0...1 scale, which lets a strong subject match pull an
    // older upload above a fresh one from a channel you ignore — while a genuinely new
    // upload from a channel you study still leads.
    static func score(_ entry: DiscoverEntry,
                      engagement: [String: ChannelEngagement],
                      affinity: TopicAffinity,
                      topics: [String: [String]],
                      now: Date = Date()) -> Double {
        let subscription = normalisedEngagement(entry.channelId, engagement: engagement)
        let topic = affinity.normalised(for: topics[entry.channelId] ?? [])
        return subscription * subscriptionWeight
            + topic * topicWeight
            + recencyScore(entry.published, now: now) * recencyWeight
    }

    // Relative to the most-studied channel, so one heavy user and one light user get
    // the same spread rather than the light user's scores all rounding to zero.
    //
    // The divisor has a floor, though. Without it, a user whose only history is
    // "added two episodes and played neither" had that channel normalise to a FULL
    // score — the weak signal became the maximum simply for being the only one, which
    // is the same "subscription dominates" problem in a new place. The floor is the
    // score of one finished hour, so meaningful study is what earns 1.0.
    static let engagementFloor = 5.0   // one finished episode (3) plus an hour (2)

    static func normalisedEngagement(_ channelId: String,
                                     engagement: [String: ChannelEngagement]) -> Double {
        let best = max(engagementFloor, engagement.values.map(\.score).max() ?? 0)
        return min(1, (engagement[channelId]?.score ?? 0) / best)
    }

    // Decays smoothly instead of stepping between bands: a 10-day-old upload should
    // not rank identically to a 3-day-old one just because both fall in "this month".
    // Half-life of a week, which matches how quickly a podcast feels stale.
    static func recencyScore(_ date: Date, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return pow(0.5, days / 7)
    }

    static func rankedFeed(_ entries: [DiscoverEntry],
                           engagement: [String: ChannelEngagement],
                           topics: [String: [String]] = [:],
                           now: Date = Date()) -> [DiscoverEntry] {
        let affinity = topicAffinity(engagement: engagement, topics: topics)
        return entries.sorted { left, right in
            let leftScore = score(left, engagement: engagement, affinity: affinity,
                                  topics: topics, now: now)
            let rightScore = score(right, engagement: engagement, affinity: affinity,
                                   topics: topics, now: now)
            if abs(leftScore - rightScore) > 0.0001 { return leftScore > rightScore }
            return left.published > right.published
        }
    }

    // Ranking for video search/recommendation results once the app has signals.
    //
    // This is intentionally separate from cold start. First-run suggestions should
    // be broad and plentiful; after playback/subscription data exists, ranking
    // should tilt toward followed channels, channels the user actually played,
    // adjacent topics, popular items in that neighborhood, and freshness.
    static func rankedVideos(_ videos: [ChannelVideo],
                             followedChannelIds: Set<String>,
                             engagement: [String: ChannelEngagement],
                             topics: [String: [String]] = [:],
                             now: Date = Date()) -> [ChannelVideo] {
        let affinity = topicAffinity(engagement: engagement, topics: topics)
        return videos.sorted { left, right in
            let l = videoScore(left, followedChannelIds: followedChannelIds,
                               engagement: engagement, affinity: affinity,
                               topics: topics, now: now)
            let r = videoScore(right, followedChannelIds: followedChannelIds,
                               engagement: engagement, affinity: affinity,
                               topics: topics, now: now)
            if abs(l - r) > 0.0001 { return l > r }
            return videoPublishedDate(left, now: now) > videoPublishedDate(right, now: now)
        }
    }

    static func videoScore(_ video: ChannelVideo,
                           followedChannelIds: Set<String>,
                           engagement: [String: ChannelEngagement],
                           affinity: TopicAffinity,
                           topics: [String: [String]],
                           now: Date = Date()) -> Double {
        let followed = video.channelId.map { followedChannelIds.contains($0) } == true ? 1.0 : 0.0
        let watched = normalisedVideoEngagement(video, engagement: engagement)
        let related = affinity.normalised(for: video.channelId.flatMap { topics[$0] } ?? [])
        let popular = popularityScore(video.viewsText)
        let fresh = videoRecencyScore(video, now: now)
        return followed * followedChannelWeight
            + watched * watchedChannelWeight
            + related * relatedTopicWeight
            + popular * popularityWeight
            + fresh * videoRecencyWeight
    }

    static func normalisedVideoEngagement(_ video: ChannelVideo,
                                          engagement: [String: ChannelEngagement]) -> Double {
        let keys = [video.channelId, video.channelTitle].compactMap { $0 }
        let best = max(engagementFloor, engagement.values.map(\.score).max() ?? 0)
        let score = keys.compactMap { engagement[$0]?.score }.max() ?? 0
        return min(1, score / best)
    }

    static func popularityScore(_ viewsText: String?) -> Double {
        guard let views = parseViewCount(viewsText), views > 0 else { return 0 }
        // 1M views is "very popular" for the long-form material Discover prefers;
        // log scaling keeps a 20M upload from flattening everything else.
        return min(1, log10(Double(views)) / 6)
    }

    static func videoRecencyScore(_ video: ChannelVideo, now: Date = Date()) -> Double {
        recencyScore(videoPublishedDate(video, now: now), now: now)
    }

    static func videoPublishedDate(_ video: ChannelVideo, now: Date = Date()) -> Date {
        if let publishedAt = video.publishedAt { return publishedAt }
        return parsePublishedText(video.publishedText, now: now) ?? .distantPast
    }

    // Coarse buckets, not exact timestamps: within "this week" it is engagement
    // that should decide the order, not which upload landed six hours earlier.
    static func recencyBand(_ date: Date, now: Date = Date()) -> Int {
        let days = now.timeIntervalSince(date) / 86_400
        if days < 3 { return 0 }
        if days < 10 { return 1 }
        if days < 30 { return 2 }
        return 3
    }

    // MARK: - Diversity

    // Which topic to explore, given what the followed channels already cover.
    //
    // Picks the neighbour of a well-covered topic rather than something unrelated:
    // a physics listener is far likelier to follow a history recommendation than a
    // cooking one, and an exploration nobody takes is wasted quota.
    static func explorationTopic(covered: [String: Int]) -> String? {
        recommendationTopic(covered: covered)
    }

    static func recommendationTopic(covered: [String: Int]) -> String? {
        guard !covered.isEmpty else { return nil }
        let strongest = covered.max { $0.value < $1.value }?.key
        guard let strongest, let neighbours = adjacency[strongest] else { return nil }
        // The first neighbour not already well covered. "Well covered" rather than
        // "present at all", so one stray video does not rule a whole topic out.
        let threshold = max(1, (covered[strongest] ?? 1) / 3)
        return neighbours.first { (covered[$0] ?? 0) <= threshold }
    }

    // Hand-written, not derived: these are reading paths a person might plausibly
    // take, and there is no data here to learn them from. Keys match the last
    // path component of YouTube's topicCategories URLs.
    static let adjacency: [String: [String]] = [
        "Knowledge":  ["History", "Philosophy", "Technology"],
        "Society":    ["History", "Economics", "Philosophy"],
        "Politics":   ["History", "Economics", "Philosophy"],
        "Technology": ["Science", "Philosophy", "Economics"],
        "Science":    ["Philosophy", "History", "Technology"],
        "History":    ["Philosophy", "Society", "Economics"],
        "Health":     ["Science", "Psychology", "Philosophy"],
        "Lifestyle":  ["Psychology", "Philosophy", "History"],
    ]

    // MARK: - Cold start

    // What to show before there is anything to personalise from.
    //
    // Measured against the alternatives. `videos.list?chart=mostPopular` costs only
    // 1 unit but returned 1 long-form video out of 12 — the rest music videos, game
    // trailers and episode clips, useless for intensive listening. Restricting it to
    // videoCategoryId=27 (Education) returns 404, and category 28 (Science & Tech)
    // gave 1 of 10 over twenty minutes.
    //
    // `search.list` with videoDuration=long enforces the twenty-minute floor
    // server-side, which is the filter mostPopular lacks: the same measurement
    // returned 21–122 minute talks and podcasts for both queries below. It costs 100
    // units from a 100-per-day bucket, so it runs once a day and is cached.
    // Three subjects, with the query for each chosen by measurement rather than by
    // guessing at wording. Median views over a 30-day window, ordered by viewCount:
    //
    //   ai podcast                 1,664,861   (technology podcast: 396,913)
    //   business podcast           1,310,894   (startup interview:  255,727)
    //   learn english conversation   374,071   (english learning podcast: 124,344)
    //
    // The earlier list averaged 35,627 — "deep dive" and "software engineering talk"
    // read like the right words but return niche uploads, not the popular ones.
    static let coldStartSubjects: [[String]] = [
        ["ai podcast", "technology podcast"],
        ["business podcast", "startup interview"],
        ["learn english conversation", "english learning podcast"],
    ]

    static var coldStartQueries: [String] { coldStartSubjects.flatMap { $0 } }

    // Cycles subjects first, then alternates within one, so consecutive days never
    // repeat a subject and a returning user sees all three across a week.
    static func coldStartQuery(dayIndex: Int) -> String {
        let day = abs(dayIndex)
        let subject = coldStartSubjects[day % coldStartSubjects.count]
        return subject[(day / coldStartSubjects.count) % subject.count]
    }

    static func coldStartFallbackQueries(startingWith query: String) -> [String] {
        var result = [query]
        for candidate in coldStartQueries where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }

    // MARK: - Quality

    // Suggestions were ranked by YouTube's relevance alone, which mixed a 755k-view
    // talk with a 2,570-view one and let a single channel take 4 of 10 slots.
    //
    // Measured on one query, relevance vs viewCount over the same 30-day window:
    // median views 35,627 -> 114,842, top result 114,842 -> 755,241, and distinct
    // channels among 15 results 8 -> 12. Popularity ordering improves variety too,
    // because it stops one prolific uploader dominating the relevance ranking.
    static let minimumViews = 5_000
    static let minimumSubscribers = 10_000

    // One video per channel. Four episodes from the same podcast is not a set of
    // suggestions, it is one suggestion repeated — and it crowds out the variety the
    // rest of the list is for.
    static func diversified(_ videos: [ChannelVideo], perChannel: Int = 1) -> [ChannelVideo] {
        var seenVideos: Set<String> = []
        var seen: [String: Int] = [:]
        var result: [ChannelVideo] = []
        for video in videos {
            guard seenVideos.insert(video.videoId).inserted else { continue }
            // Videos with no channel id are kept: dropping them would silently lose
            // results rather than merely reordering them.
            guard let channelId = video.channelId else {
                result.append(video)
                continue
            }
            let count = seen[channelId] ?? 0
            guard count < perChannel else { continue }
            seen[channelId] = count + 1
            result.append(video)
        }
        return result
    }

    static func parseViewCount(_ text: String?) -> Int? {
        guard let text else { return nil }
        let lower = text.lowercased()
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "views", with: "")
            .replacingOccurrences(of: "view", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = lower.last
        let multiplier: Double
        let numberText: String
        switch suffix {
        case "k":
            multiplier = 1_000
            numberText = String(lower.dropLast())
        case "m":
            multiplier = 1_000_000
            numberText = String(lower.dropLast())
        case "b":
            multiplier = 1_000_000_000
            numberText = String(lower.dropLast())
        default:
            multiplier = 1
            numberText = lower
        }
        guard let value = Double(numberText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return Int(value * multiplier)
    }

    static func parsePublishedText(_ text: String?, now: Date = Date()) -> Date? {
        guard let text else { return nil }
        let lower = text.lowercased()
        guard !lower.contains("premiere") else { return nil }
        let parts = lower.split(separator: " ")
        guard let amountText = parts.first else { return nil }
        let amount = amountText == "a" || amountText == "an"
            ? 1
            : Int(amountText)
        guard let amount,
              let unit = parts.dropFirst().first
        else { return nil }

        let days: Int
        if unit.hasPrefix("minute") || unit.hasPrefix("hour") {
            days = 0
        } else if unit.hasPrefix("day") {
            days = amount
        } else if unit.hasPrefix("week") {
            days = amount * 7
        } else if unit.hasPrefix("month") {
            days = amount * 30
        } else if unit.hasPrefix("year") {
            days = amount * 365
        } else {
            return nil
        }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    // A search query for a topic. Plain words rather than a topicId: searching by
    // topicId returned zero results when measured, while the same word as a query
    // returns full pages.
    static func query(for topic: String) -> String {
        switch topic {
        case "History": return "history documentary"
        case "Philosophy": return "philosophy lecture"
        case "Economics": return "economics explained"
        case "Psychology": return "psychology lecture"
        case "Science": return "science explained"
        case "Technology": return "technology deep dive"
        default: return topic.lowercased()
        }
    }

    // Where explored items sit in the feed.
    //
    // Mixed in rather than in their own section, but never at the very top and
    // never adjacent to each other: an unproven recommendation should not be the
    // first thing you see, and a cluster of them reads as the feed being taken
    // over. Positions are 1-indexed slots in the final list.
    static func insertionSlots(feedCount: Int, explorationCount: Int) -> [Int] {
        guard feedCount >= 3, explorationCount > 0 else { return [] }
        // Start at 3 so two known items lead, then every 5th slot.
        var slots: [Int] = []
        var slot = 3
        while slots.count < explorationCount && slot <= feedCount + slots.count {
            slots.append(slot)
            slot += 5
        }
        return slots
    }
}
