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

    // Orders the feed by engagement, then recency within a channel.
    //
    // NOT a pure score sort: that would bury a brand-new upload from a channel you
    // have not studied yet, and this is a feed of new things. Recency stays the
    // primary axis inside a band, engagement decides which channels lead.
    static func rankedFeed(_ entries: [DiscoverEntry],
                           engagement: [String: ChannelEngagement],
                           now: Date = Date()) -> [DiscoverEntry] {
        entries.sorted { left, right in
            let leftBand = recencyBand(left.published, now: now)
            let rightBand = recencyBand(right.published, now: now)
            if leftBand != rightBand { return leftBand < rightBand }
            let leftScore = engagement[left.channelId]?.score ?? 0
            let rightScore = engagement[right.channelId]?.score ?? 0
            if abs(leftScore - rightScore) > 0.01 { return leftScore > rightScore }
            return left.published > right.published
        }
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
