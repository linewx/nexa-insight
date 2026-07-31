import Foundation

// Preset search terms shown as chips so a first-time user has somewhere to
// start. These are strings, NOT a category taxonomy — tapping one runs a real
// search, so there is no term-to-channel mapping to maintain or go stale. That
// is the difference from the invented DiscoverKind list this replaced.
//
// Thirteen candidates were tested against live results; these eight returned 20
// on-topic channels each. Rejected: `ai` (matched 감다살 AI, あい。), `health`
// (a band and an auto-generated Topic channel), `interview` (job-interview
// content), `business` and `education` (mixed with low-quality channels).
//
// The pattern worth remembering: shorter terms give worse results. Prefer
// specific subject names over abbreviations or broad words.
enum ChannelSearchTerms {
    static let all = [
        "podcast",
        "history",
        "philosophy",
        "science",
        "technology",
        "economics",
        "psychology",
        "documentary",
    ]
}
