import Foundation

/// Where something is discussed in an episode.
struct EpisodeSearchHit: Equatable {
    let atMs: Int
    /// The line itself, plus enough either side to tell a passing mention from a discussion.
    let context: String
    /// How many consecutive nearby lines mention the query. A topic that comes up once in passing
    /// scores 1; a segment about it scores several.
    let density: Int
}

/// Finds where a topic is discussed, so the teacher can seek by content rather than by timestamp.
///
/// Runs on device against the full transcript. The classroom context is only ±6 sentences plus
/// chapter titles, so without this the teacher cannot answer "jump to the part about Salesforce" —
/// and the chapter outline is not a substitute: measured on one episode, the chapter TITLED for
/// Salesforce opens with Nvidia and the actual discussion starts three minutes later.
enum EpisodeSearch {
    /// Lines within this distance count as the same discussion when scoring density.
    static let clusterWindowMs = 90_000
    /// Sentences either side included as context, so a hit can be judged rather than guessed at.
    static let contextRadius = 1
    static let maxHits = 5

    static func find(_ query: String, in sentences: [SentenceDTO]) -> [EpisodeSearchHit] {
        let needle = query.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: .current)
        guard needle.count >= 2 else { return [] }

        // Match against source AND translation: the learner may name a topic in Chinese while the
        // audio is English, which is the common case here.
        let matches = sentences.indices.filter { index in
            let line = sentences[index]
            let haystack = (line.sourceText + " " + line.chinese)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            return haystack.contains(needle)
        }
        guard !matches.isEmpty else { return [] }

        // Group into discussions. Twenty-five scattered mentions are not twenty-five answers, and
        // returning them all would leave the teacher picking the first rather than the best.
        var clusters: [[Int]] = []
        for index in matches {
            let startMs = sentences[index].startMs
            if let last = clusters.last, let tail = last.last,
               startMs - sentences[tail].startMs <= clusterWindowMs {
                clusters[clusters.count - 1].append(index)
            } else {
                clusters.append([index])
            }
        }

        // Densest first: where a topic is discussed beats where it is name-dropped.
        return clusters
            .sorted { ($0.count, -sentences[$0[0]].startMs) > ($1.count, -sentences[$1[0]].startMs) }
            .prefix(maxHits)
            .map { cluster in
                let anchor = cluster[0]
                let lower = max(0, anchor - contextRadius)
                let upper = min(sentences.count - 1, anchor + contextRadius)
                return EpisodeSearchHit(
                    atMs: sentences[anchor].startMs,
                    context: sentences[lower...upper].map(\.sourceText).joined(separator: " "),
                    density: cluster.count)
            }
    }

    /// The hits as the teacher reads them: a timestamp it can pass to seek_to_timestamp, and enough
    /// text to choose between them.
    static func describe(_ hits: [EpisodeSearchHit]) -> String {
        guard !hits.isEmpty else {
            return "Not found in this episode's transcript. Say so rather than guessing a position."
        }
        return hits.map { hit in
            let seconds = hit.atMs / 1000
            return "- \(seconds)s (\(seconds / 60)m\(String(format: "%02d", seconds % 60))s), "
                + "\(hit.density) mention\(hit.density == 1 ? "" : "s") nearby: \(hit.context)"
        }.joined(separator: "\n")
    }
}
