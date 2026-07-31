import Foundation

// Byline text for a feed entry.
//
// Duration is deliberately absent — the RSS feed has no duration tag, so there
// is nothing truthful to show until after import.
//
// The locale is an explicit parameter rather than the system default. A bug
// reported from a ja-JP device showed this byline rendering "3日前" and
// "41万 views" while the video titles beside them stayed English, because
// RelativeDateTimeFormatter and .compactName both follow Locale.current.
//
// Worth recording where the Japanese did NOT come from: the network layer was
// already correct. Driving the real DiscoverFeedService with a session pinned to
// Accept-Language: ja-JP returned 0/20 and 0/30 Japanese metadata. Measured
// separately, the Accept-Language header is what controls YouTube's language —
// the hl=en&gl=US query parameters alone did not (a ja client with those
// parameters still got "チャンネル登録者数 4550人").
enum DiscoverFormat {
    // A fixed default rather than Locale.current, so a non-English device does
    // not silently produce mixed-language output again.
    static let defaultLocale = Locale(identifier: "en_US")

    static func byline(_ entry: DiscoverEntry,
                       now: Date = Date(),
                       locale: Locale = DiscoverFormat.defaultLocale) -> String {
        var parts = [entry.channelTitle, relativeDate(entry.published, now: now, locale: locale)]
        if let views = entry.viewCount {
            let formatted = views.formatted(.number.notation(.compactName).locale(locale))
            parts.append("\(formatted) views")
        }
        return parts.joined(separator: " · ")
    }

    static func relativeDate(_ date: Date,
                             now: Date = Date(),
                             locale: Locale = DiscoverFormat.defaultLocale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
