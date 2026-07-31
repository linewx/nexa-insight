import Foundation

enum ChannelVideoOutcome: Equatable {
    case parsed([ChannelVideo])
    case structureMissing
}

// Parses YouTube's in-channel search page (/channel/<id>/search?query=).
//
// This scrapes a page, not an API. Two things differ from the channel-search
// page that ChannelSearchParser handles, and both were measured:
//   - the title lives under `runs`, not `simpleText`
//   - thumbnail URLs are already absolute (0/30 protocol-relative, versus 20/20
//     on the other page)
// So this is a separate parser rather than a copy.
//
// Notably this page still serves the OLDER `videoRenderer` shape while the
// channel videos page has moved to `lockupViewModel` — the two sit at different
// points in YouTube's own migration, which is why structureMissing exists.
enum ChannelVideoParser {
    static func parse(_ data: Data) -> ChannelVideoOutcome {
        guard let html = String(data: data, encoding: .utf8),
              let json = extractJSON(from: html),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        else { return .structureMissing }

        var seen = Set<String>()
        var videos: [ChannelVideo] = []
        for renderer in findRenderers(in: root) {
            guard let video = makeVideo(renderer),
                  seen.insert(video.videoId).inserted
            else { continue }
            videos.append(video)
        }
        // Order is YouTube's relevance ranking; do not re-sort.
        return .parsed(videos)
    }

    private static func extractJSON(from html: String) -> String? {
        guard let start = html.range(of: "var ytInitialData = ") else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: ";</script>") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    private static func findRenderers(in node: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let dict = node as? [String: Any] {
            if let renderer = dict["videoRenderer"] as? [String: Any] {
                found.append(renderer)
            }
            for value in dict.values { found += findRenderers(in: value) }
        } else if let array = node as? [Any] {
            for value in array { found += findRenderers(in: value) }
        }
        return found
    }

    private static func makeVideo(_ r: [String: Any]) -> ChannelVideo? {
        guard let videoId = r["videoId"] as? String, !videoId.isEmpty,
              let title = joinedRuns(r["title"]), !title.isEmpty
        else { return nil }

        return ChannelVideo(
            videoId: videoId,
            title: title,
            durationText: simpleText(r["lengthText"]),
            viewsText: simpleText(r["viewCountText"]),
            publishedText: simpleText(r["publishedTimeText"]),
            summary: joinedRuns(r["descriptionSnippet"]),
            thumbnailURL: thumbnailURL(r["thumbnail"]))
    }

    private static func simpleText(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any],
              let text = dict["simpleText"] as? String,
              !text.isEmpty
        else { return nil }
        return text
    }

    private static func joinedRuns(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any],
              let runs = dict["runs"] as? [[String: Any]]
        else { return nil }
        let text = runs.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    // Absolute here, unlike the channel-search page — so only prefix when the
    // URL is actually protocol-relative.
    private static func thumbnailURL(_ node: Any?) -> URL? {
        guard let dict = node as? [String: Any],
              let thumbs = dict["thumbnails"] as? [[String: Any]],
              let raw = thumbs.first?["url"] as? String
        else { return nil }
        let absolute = raw.hasPrefix("//") ? "https:\(raw)" : raw
        return URL(string: absolute)
    }
}
