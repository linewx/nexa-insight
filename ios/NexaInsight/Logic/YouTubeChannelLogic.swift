import Foundation

// Resolving a YouTube channel to its RSS feed.
//
// The feed is keyed strictly by channel id (UC + 22 chars). Users paste two
// shapes: /channel/UCxxxx (id inline) and /@handle (id only in the page HTML).
//
// Handle resolution reads <link rel="canonical">, NOT the first "channelId"
// key in the HTML. Verified against two live pages: the naive key match returns
// a RECOMMENDED VIDEO's author id, because those appear before the page's own
// canonical link. For @lexfridman that wrong id was UCJIfeSCssxSC_Dhc5s7woww
// where the correct one is UCSHZKyawb77ixDdsGog4iWA.
enum YouTubeChannelLogic {
    private static let idPattern = "UC[A-Za-z0-9_-]{22}"

    static func channelId(fromChannelURL url: String) -> String? {
        firstMatch(in: url, pattern: "/channel/(\(idPattern))")
    }

    static func channelId(fromHTML html: String) -> String? {
        firstMatch(
            in: html,
            pattern: "<link[^>]+rel=\"canonical\"[^>]+href=\"https://www\\.youtube\\.com/channel/(\(idPattern))\"")
    }

    static func feedURL(channelId: String) -> URL? {
        guard isValidChannelId(channelId) else { return nil }
        return URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)")
    }

    static func isShortsLink(_ link: String) -> Bool {
        link.contains("/shorts/")
    }

    static func isValidChannelId(_ value: String) -> Bool {
        guard let match = firstMatch(in: value, pattern: "^(\(idPattern))$") else { return false }
        return match == value
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
