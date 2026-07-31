import Foundation

// Parses a YouTube channel RSS feed into DiscoverEntry values.
//
// Shorts are dropped. A Short's <link rel="alternate"> points at /shorts/<id>
// instead of /watch?v=<id>, and that link form is the only reliable signal —
// the feed has no duration to threshold on. Verified live: 3 of Veritasium's 15
// entries were Shorts, which are noise for an intensive-listening app.
enum DiscoverFeedParser {
    static func parse(_ data: Data) -> [DiscoverEntry] {
        let delegate = FeedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return delegate.entries }
        return delegate.entries
    }

    static func merge(_ groups: [[DiscoverEntry]]) -> [DiscoverEntry] {
        var seen = Set<String>()
        var all: [DiscoverEntry] = []
        for entry in groups.flatMap({ $0 }) where seen.insert(entry.videoId).inserted {
            all.append(entry)
        }
        return all.sorted { $0.published > $1.published }
    }

    static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private final class FeedDelegate: NSObject, XMLParserDelegate {
    var entries: [DiscoverEntry] = []

    private var inEntry = false
    private var text = ""
    private var videoId: String?
    private var channelId: String?
    private var title: String?
    private var channelTitle: String?
    private var published: Date?
    private var summary: String?
    private var thumbnail: URL?
    private var views: Int?
    private var link: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String] = [:]) {
        text = ""
        switch name {
        case "entry":
            inEntry = true
            videoId = nil; channelId = nil; title = nil; channelTitle = nil
            published = nil; summary = nil; thumbnail = nil; views = nil; link = nil
        case "link" where inEntry:
            if attrs["rel"] == "alternate", let href = attrs["href"] { link = href }
        case "media:thumbnail" where inEntry:
            if let url = attrs["url"] { thumbnail = URL(string: url) }
        case "media:statistics" where inEntry:
            if let v = attrs["views"] { views = Int(v) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard inEntry else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "yt:videoId": videoId = value
        case "yt:channelId": channelId = value
        // <title> appears both directly under <entry> and inside <media:group>;
        // taking the first non-empty one is enough since they carry the same text.
        case "title": if title == nil, !value.isEmpty { title = value }
        case "name": if channelTitle == nil, !value.isEmpty { channelTitle = value }
        case "published": published = DiscoverFeedParser.dateFormatter.date(from: value)
        case "media:description": summary = value.isEmpty ? nil : value
        case "entry":
            inEntry = false
            appendEntry()
        default:
            break
        }
        text = ""
    }

    private func appendEntry() {
        guard let videoId, let channelId, let title, let channelTitle,
              let published, let link,
              !YouTubeChannelLogic.isShortsLink(link),
              let watchURL = URL(string: link)
        else { return }
        entries.append(DiscoverEntry(
            videoId: videoId, channelId: channelId, title: title,
            channelTitle: channelTitle, published: published, summary: summary,
            thumbnailURL: thumbnail, viewCount: views, watchURL: watchURL))
    }
}
