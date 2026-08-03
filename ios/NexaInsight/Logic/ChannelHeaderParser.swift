import Foundation

// Parses a channel page for the channel's own avatar, title, and subscriber
// count.
//
// This layer is mid-migration on YouTube's side, so every field is optional and
// a total failure returns `.empty` rather than nil-vs-throw ambiguity. The
// caller shows the title it already has and carries on; the header is decoration,
// while the content below it comes from RSS and in-channel search.
enum ChannelHeaderParser {
    static func parse(_ data: Data) -> ChannelHeader {
        guard let html = String(data: data, encoding: .utf8),
              let json = extractJSON(from: html),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        else { return .empty }

        // c4TabbedHeaderRenderer is the older shape; pageHeaderRenderer is what
        // YouTube is migrating to. Both are searched for rather than assuming one.
        let header = firstDict(in: root, key: "c4TabbedHeaderRenderer")
        let pageHeader = firstDict(in: root, key: "pageHeaderViewModel")
        let metadata = firstDict(in: root, key: "channelMetadataRenderer")

        return ChannelHeader(
            title: title(header: header, pageHeader: pageHeader, metadata: metadata),
            avatarURL: avatar(header: header, pageHeader: pageHeader, metadata: metadata),
            subscriberText: subscriberText(header: header, pageHeader: pageHeader))
    }

    private static func extractJSON(from html: String) -> String? {
        guard let start = html.range(of: "var ytInitialData = ") else { return nil }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: ";</script>") else { return nil }
        return String(rest[..<end.lowerBound])
    }

    private static func title(
        header: [String: Any]?, pageHeader: [String: Any]?, metadata: [String: Any]?
    ) -> String? {
        if let t = text(header?["title"]) { return t }
        if let t = pageHeader?["title"] as? [String: Any],
           let dynamic = firstDict(in: t, key: "dynamicTextViewModel"),
           let content = (dynamic["text"] as? [String: Any])?["content"] as? String,
           !content.isEmpty {
            return content
        }
        if let t = metadata?["title"] as? String, !t.isEmpty { return t }
        return nil
    }

    private static func avatar(
        header: [String: Any]?, pageHeader: [String: Any]?, metadata: [String: Any]?
    ) -> URL? {
        // Widest thumbnail wins: these are served at several sizes and the header
        // renders at 32pt on a Retina screen, so the smallest is visibly soft.
        for node in [header?["avatar"], metadata?["avatar"]] {
            if let url = largestThumbnail(node) { return url }
        }
        if let pageHeader,
           let image = firstDict(in: pageHeader, key: "decoratedAvatarViewModel"),
           let avatar = firstDict(in: image, key: "avatarViewModel"),
           let url = largestThumbnail(firstDict(in: avatar, key: "image")) {
            return url
        }
        if let pageHeader, let url = largestThumbnail(firstDict(in: pageHeader, key: "image")) {
            return url
        }
        return nil
    }

    private static func subscriberText(header: [String: Any]?, pageHeader: [String: Any]?) -> String? {
        if let t = text(header?["subscriberCountText"]) { return t }
        // In the newer shape this is one of several metadata rows, so it is found
        // by content ("subscribers") rather than by position, which would break
        // the moment YouTube reorders them.
        if let pageHeader {
            for candidate in allStrings(in: pageHeader)
            where candidate.localizedCaseInsensitiveContains("subscriber") {
                return candidate
            }
        }
        return nil
    }

    private static func largestThumbnail(_ node: Any?) -> URL? {
        guard let dict = node as? [String: Any],
              let thumbs = dict["thumbnails"] as? [[String: Any]]
        else { return nil }
        let widest = thumbs.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }
        guard let raw = (widest ?? thumbs.first)?["url"] as? String, !raw.isEmpty else { return nil }
        return URL(string: raw.hasPrefix("//") ? "https:\(raw)" : raw)
    }

    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String, !simple.isEmpty { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    private static func firstDict(in node: Any, key: String) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if let hit = dict[key] as? [String: Any] { return hit }
            for value in dict.values {
                if let hit = firstDict(in: value, key: key) { return hit }
            }
        } else if let array = node as? [Any] {
            for value in array {
                if let hit = firstDict(in: value, key: key) { return hit }
            }
        }
        return nil
    }

    private static func allStrings(in node: Any) -> [String] {
        if let dict = node as? [String: Any] {
            return dict.values.flatMap { allStrings(in: $0) }
        } else if let array = node as? [Any] {
            return array.flatMap { allStrings(in: $0) }
        } else if let string = node as? String {
            return [string]
        }
        return []
    }
}
