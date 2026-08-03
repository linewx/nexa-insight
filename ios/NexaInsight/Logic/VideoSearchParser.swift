import Foundation

// Parses YouTube's site-wide results page (/results?search_query=) into videos.
//
// This is a separate parser from ChannelVideoParser for one reason: site-wide
// results carry owner fields (which channel published this) that in-channel
// results omit, because there the channel is already known from the screen you
// are on. The card needs those fields to make the channel name tappable, which
// is the only route to following a channel.
//
// IMPORTANT — the renderer shape here is NOT verified. In-channel search serves
// the older `videoRenderer`; the channel videos page has already migrated to
// `lockupViewModel`. Which side this page sits on could not be measured (the
// sandbox cannot reach YouTube), so BOTH shapes are handled rather than betting
// on one and shipping a page that silently returns nothing. Confirm on device.
enum VideoSearchParser {
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

    // Collects both renderer shapes. A lockupViewModel is normalised into the
    // same dictionary keys videoRenderer uses, so makeVideo reads one shape.
    private static func findRenderers(in node: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let dict = node as? [String: Any] {
            if let renderer = dict["videoRenderer"] as? [String: Any] {
                found.append(renderer)
            } else if let lockup = dict["lockupViewModel"] as? [String: Any],
                      let normalised = normaliseLockup(lockup) {
                found.append(normalised)
            }
            for value in dict.values { found += findRenderers(in: value) }
        } else if let array = node as? [Any] {
            for value in array { found += findRenderers(in: value) }
        }
        return found
    }

    // lockupViewModel nests its text under metadata/lockupMetadataViewModel and
    // keys the video by `contentId` rather than `videoId`. Mapping it here keeps
    // the shape-specific knowledge in one place.
    private static func normaliseLockup(_ lockup: [String: Any]) -> [String: Any]? {
        guard let contentId = lockup["contentId"] as? String, !contentId.isEmpty else { return nil }
        var out: [String: Any] = ["videoId": contentId]

        let metadata = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        if let titleText = (metadata?["title"] as? [String: Any])?["content"] as? String {
            out["title"] = ["simpleText": titleText]
        }
        return out
    }

    private static func makeVideo(_ r: [String: Any]) -> ChannelVideo? {
        guard let videoId = r["videoId"] as? String, !videoId.isEmpty,
              let title = text(r["title"]), !title.isEmpty
        else { return nil }

        let owner = ownerFields(r)
        return ChannelVideo(
            videoId: videoId,
            title: title,
            durationText: text(r["lengthText"]),
            viewsText: text(r["viewCountText"]),
            publishedText: text(r["publishedTimeText"]),
            summary: text(r["descriptionSnippet"]),
            thumbnailURL: thumbnailURL(r["thumbnail"]),
            channelTitle: owner.title,
            channelId: owner.id)
    }

    // The channel behind a result. `ownerText` is the measured location on the
    // in-channel page's sibling shape; `longBylineText` and `shortBylineText`
    // carry the same runs on results pages, so all three are tried. The id comes
    // from the run's navigationEndpoint, NOT from a "channelId" key elsewhere in
    // the page — YouTubeChannelLogic's tests lock in that such keys belong to
    // recommended videos and give the wrong channel.
    private static func ownerFields(_ r: [String: Any]) -> (title: String?, id: String?) {
        for key in ["ownerText", "longBylineText", "shortBylineText"] {
            guard let node = r[key] as? [String: Any],
                  let runs = node["runs"] as? [[String: Any]],
                  let first = runs.first
            else { continue }

            let title = runs.compactMap { $0["text"] as? String }.joined()
            let endpoint = first["navigationEndpoint"] as? [String: Any]
            let browse = endpoint?["browseEndpoint"] as? [String: Any]
            let id = browse?["browseId"] as? String

            if !title.isEmpty {
                return (title, id.flatMap { YouTubeChannelLogic.isValidChannelId($0) ? $0 : nil })
            }
        }
        return (nil, nil)
    }

    // Reads either shape: `simpleText` or joined `runs`. Site-wide results were
    // measured using both across different fields on sibling pages, so trying
    // one and giving up would silently drop titles or durations.
    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String, !simple.isEmpty { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    private static func thumbnailURL(_ node: Any?) -> URL? {
        guard let dict = node as? [String: Any],
              let thumbs = dict["thumbnails"] as? [[String: Any]],
              let raw = thumbs.first?["url"] as? String
        else { return nil }
        let absolute = raw.hasPrefix("//") ? "https:\(raw)" : raw
        return URL(string: absolute)
    }
}
