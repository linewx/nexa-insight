import Foundation

// Outcome of parsing a search page.
//
// `parsed([])` and `structureMissing` are deliberately different. A query with
// no matches returns HTTP 200 with ytInitialData present and zero renderers —
// that is a real answer. `structureMissing` means the page shape changed and we
// could not read it, which the UI must report differently so a YouTube-side
// break does not look like the user's search was wrong.
enum ChannelSearchOutcome: Equatable {
    case parsed([ChannelSearchResult])
    case structureMissing
}

// Parses YouTube's channel-search page.
//
// This scrapes a page; it is not an API. ytInitialData is YouTube's internal
// front-end structure and a redesign will break it — hence structureMissing and
// the never-removed paste-URL fallback.
//
// Regex is used ONLY to cut out the JSON blob. Everything after is JSON walking:
// regexing for "channelId":"UC..." directly was tried and matched non-channel
// text (チャンネル登録) as well as recommended-video author ids.
enum ChannelSearchParser {
    static func parse(_ data: Data) -> ChannelSearchOutcome {
        guard let html = String(data: data, encoding: .utf8),
              let json = extractJSON(from: html),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        else { return .structureMissing }

        var seen = Set<String>()
        var results: [ChannelSearchResult] = []
        for renderer in findRenderers(in: root) {
            guard let result = makeResult(renderer),
                  seen.insert(result.channelId).inserted
            else { continue }
            results.append(result)
        }
        return .parsed(results)
    }

    // Only this assignment form exists; the `ytInitialData"] = {...}` variant was
    // checked against a live page and is absent.
    private static func extractJSON(from html: String) -> String? {
        guard let start = html.range(of: "var ytInitialData = ") else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: ";</script>") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    private static func findRenderers(in node: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let dict = node as? [String: Any] {
            if let renderer = dict["channelRenderer"] as? [String: Any] {
                found.append(renderer)
            }
            for value in dict.values { found += findRenderers(in: value) }
        } else if let array = node as? [Any] {
            for value in array { found += findRenderers(in: value) }
        }
        return found
    }

    private static func makeResult(_ r: [String: Any]) -> ChannelSearchResult? {
        guard let channelId = r["channelId"] as? String, !channelId.isEmpty,
              let title = simpleText(r["title"]), !title.isEmpty
        else { return nil }

        return ChannelSearchResult(
            channelId: channelId,
            title: title,
            // These two are crossed on purpose — the response keys are misnamed.
            handle: simpleText(r["subscriberCountText"]),
            subscriberText: simpleText(r["videoCountText"]),
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

    // Descriptions arrive split across 1-5 runs (the matched search term is its
    // own bolded run). Joining is required; the first run alone is a fragment.
    private static func joinedRuns(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any],
              let runs = dict["runs"] as? [[String: Any]]
        else { return nil }
        let text = runs.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    // Live thumbnails are protocol-relative (`//yt3.googleusercontent.com/...`)
    // and will not load without a scheme.
    private static func thumbnailURL(_ node: Any?) -> URL? {
        guard let dict = node as? [String: Any],
              let thumbs = dict["thumbnails"] as? [[String: Any]],
              let raw = thumbs.first?["url"] as? String
        else { return nil }
        let absolute = raw.hasPrefix("//") ? "https:\(raw)" : raw
        return URL(string: absolute)
    }
}
