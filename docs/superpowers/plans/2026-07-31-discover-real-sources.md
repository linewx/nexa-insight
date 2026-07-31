# Discover Real Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Discover's five hardcoded fake items with real entries fetched from the user's subscribed YouTube channel RSS feeds.

**Architecture:** Pure parsing/URL logic goes in `NexaInsight/Logic/` (offline-testable, no network). Subscription persistence and feed fetching go in `NexaInsight/Services/`. `DiscoverView` in `LibraryView.swift` switches from a hardcoded array to a `@StateObject` view model. No backend changes — the channel RSS feed is public XML needing no key or auth, and "Add to Nexa" reuses the existing `POST /api/episodes/import` untouched.

**Tech Stack:** Swift 5.9, SwiftUI, `URLSession`, `XMLParser`, `UserDefaults`, XCTest. All system frameworks — no new dependencies.

## Global Constraints

- Deployment target iOS 17.0; Swift version 5.9.
- No new package dependencies. `URLSession` and `XMLParser` only.
- No backend changes. `POST /api/episodes/import` is reused as-is.
- All new tests must pass with `cd ios && swift test` — offline, no network. Feed tests use inline XML string fixtures.
- Pure logic goes in `NexaInsight/Logic/`; stateful services in `NexaInsight/Services/`. This matches `AudioRouteLogic`/`ClassroomLogic` vs `AppSettings`/`BackendClient`.
- Feed URL format is exactly `https://www.youtube.com/feeds/videos.xml?channel_id=<UCxxxx>`.
- Channel ids match `UC` followed by 22 characters from `[A-Za-z0-9_-]`.
- Handle resolution MUST read `<link rel="canonical" href="https://www.youtube.com/channel/UC...">`. A naive `"channelId":"(UC[\w-]{22})"` regex extracted the WRONG id for both channels tested — for `@lexfridman` it yielded `UCJIfeSCssxSC_Dhc5s7woww` instead of the correct `UCSHZKyawb77ixDdsGog4iWA`, because recommended-video author ids appear earlier in the HTML.
- Entries whose alternate link contains `/shorts/` are excluded from the feed.
- RSS carries no duration. Never display duration in Discover.

## Build and test commands

```bash
# Unit tests (offline, macOS, fastest — use this for every task)
cd ios && swift test

# Simulator build (Xcode 26 on this machine needs these workarounds)
cd ios && ./generate.sh
xcodebuild -project NexaInsight.xcodeproj -target NexaInsight \
  -sdk iphonesimulator -configuration Debug -arch arm64 \
  EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets' \
  ASSETCATALOG_COMPILER_APPICON_NAME='' \
  CONFIGURATION_BUILD_DIR=/tmp/nexa-build build
```

The asset-catalog exclusion is required because `actool` rejects this machine's
SDK/runtime pair (`No simulator runtime version from ["21F79"] available to use
with iphonesimulator SDK version 23F81a`). The catalog holds only the app icon
and no code references it. `-destination` cannot resolve on this machine, hence
`-target` + `-sdk`.

## File structure

| File | Responsibility |
|---|---|
| Create `NexaInsight/Logic/YouTubeChannelLogic.swift` | Pure: channel-id extraction from URL/HTML, feed URL construction |
| Create `NexaInsight/Logic/DiscoverFeedParser.swift` | Pure: RSS XML → `[DiscoverEntry]`, Shorts filtering, merge/sort |
| Create `NexaInsight/Models/DiscoverEntry.swift` | The real item model (replaces `DiscoverItem`) and `Subscription` |
| Create `NexaInsight/Services/SubscriptionStore.swift` | `UserDefaults`-backed subscription list |
| Create `NexaInsight/Services/DiscoverFeedService.swift` | Concurrent fetch, per-source error isolation |
| Create `NexaInsight/Import/DiscoverViewModel.swift` | `@MainActor` state for the Discover screen |
| Modify `NexaInsight/Views/LibraryView.swift` | Rewire `DiscoverView` and its subviews to the view model |
| Create `NexaInsightCoreTests/YouTubeChannelLogicTests.swift` | Task 1 tests |
| Create `NexaInsightCoreTests/DiscoverFeedParserTests.swift` | Task 2 tests |
| Create `NexaInsightCoreTests/SubscriptionStoreTests.swift` | Task 3 tests |
| Create `NexaInsightCoreTests/DiscoverViewModelTests.swift` | Task 5 tests |

`LibraryView.swift` is already 2345 lines. This plan does not restructure it
wholesale, but it does move the Discover *data* out (into the files above),
which is a net reduction: the ~90 lines of `featuredDiscoverItems` literals and
the `DiscoverItem`/`DiscoverKind` declarations are deleted from it.

---

### Task 1: Channel id and feed URL logic

Pure functions with no network. This is the foundation both the store and the
feed service depend on.

**Files:**
- Create: `ios/NexaInsight/Logic/YouTubeChannelLogic.swift`
- Test: `ios/NexaInsightCoreTests/YouTubeChannelLogicTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum YouTubeChannelLogic`
  - `static func channelId(fromChannelURL url: String) -> String?`
  - `static func channelId(fromHTML html: String) -> String?`
  - `static func feedURL(channelId: String) -> URL?`
  - `static func isShortsLink(_ link: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `ios/NexaInsightCoreTests/YouTubeChannelLogicTests.swift`:

```swift
import XCTest
@testable import NexaInsightCore

final class YouTubeChannelLogicTests: XCTestCase {
    func testChannelIdFromDirectChannelURL() {
        XCTAssertEqual(
            YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA"),
            "UCSHZKyawb77ixDdsGog4iWA")
    }

    func testChannelIdFromDirectURLToleratesTrailingPathAndQuery() {
        XCTAssertEqual(
            YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA/videos?view=0"),
            "UCSHZKyawb77ixDdsGog4iWA")
    }

    func testChannelIdFromHandleURLReturnsNil() {
        // A handle URL carries no id; the caller must fetch the page and use
        // channelId(fromHTML:) instead.
        XCTAssertNil(YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/@lexfridman"))
    }

    func testChannelIdFromDirectURLRejectsMalformedId() {
        XCTAssertNil(YouTubeChannelLogic.channelId(fromChannelURL: "https://www.youtube.com/channel/UCtooshort"))
    }

    func testChannelIdFromHTMLUsesCanonicalLink() {
        let html = """
        <link rel="canonical" href="https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA">
        """
        XCTAssertEqual(YouTubeChannelLogic.channelId(fromHTML: html), "UCSHZKyawb77ixDdsGog4iWA")
    }

    // Regression lock. Verified against two live channel pages: a naive
    // "channelId":"(UC...)" regex extracts a RECOMMENDED VIDEO's author id,
    // which appears earlier in the HTML than the page's own canonical link.
    // For @lexfridman that wrong id was UCJIfeSCssxSC_Dhc5s7woww.
    func testChannelIdFromHTMLIgnoresEarlierChannelIdKeys() {
        let html = """
        {"channelId":"UCJIfeSCssxSC_Dhc5s7woww","title":"a recommended video"}
        <link rel="canonical" href="https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA">
        """
        XCTAssertEqual(YouTubeChannelLogic.channelId(fromHTML: html), "UCSHZKyawb77ixDdsGog4iWA")
    }

    func testChannelIdFromHTMLReturnsNilWhenNoCanonicalChannelLink() {
        XCTAssertNil(YouTubeChannelLogic.channelId(fromHTML: "<html><body>nothing here</body></html>"))
    }

    func testFeedURLFormat() {
        XCTAssertEqual(
            YouTubeChannelLogic.feedURL(channelId: "UCSHZKyawb77ixDdsGog4iWA")?.absoluteString,
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCSHZKyawb77ixDdsGog4iWA")
    }

    func testFeedURLRejectsMalformedChannelId() {
        XCTAssertNil(YouTubeChannelLogic.feedURL(channelId: "not-a-channel"))
    }

    func testIsShortsLink() {
        XCTAssertTrue(YouTubeChannelLogic.isShortsLink("https://www.youtube.com/shorts/3HQkVfZ4DNY"))
        XCTAssertFalse(YouTubeChannelLogic.isShortsLink("https://www.youtube.com/watch?v=XyXBwO5jYpw"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter YouTubeChannelLogicTests`
Expected: FAIL — `cannot find 'YouTubeChannelLogic' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/NexaInsight/Logic/YouTubeChannelLogic.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && swift test --filter YouTubeChannelLogicTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the full suite for regressions**

Run: `cd ios && swift test`
Expected: PASS — 106 existing + 10 new = 116 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Logic/YouTubeChannelLogic.swift ios/NexaInsightCoreTests/YouTubeChannelLogicTests.swift
git commit -m "Resolve YouTube channel ids to RSS feed URLs

Handle resolution reads the canonical link rather than the first
channelId key in the HTML. Verified against two live channel pages:
the naive key match returns a recommended video's author id, which
appears earlier in the markup than the page's own canonical link."
```

---

### Task 2: Discover entry model and RSS parser

Pure XML parsing with no network. The XML fixtures below are trimmed from real
feeds so the field shapes are exact.

**Files:**
- Create: `ios/NexaInsight/Models/DiscoverEntry.swift`
- Create: `ios/NexaInsight/Logic/DiscoverFeedParser.swift`
- Test: `ios/NexaInsightCoreTests/DiscoverFeedParserTests.swift`

**Interfaces:**
- Consumes: `YouTubeChannelLogic.isShortsLink(_:)` from Task 1.
- Produces:
  - `struct DiscoverEntry: Identifiable, Equatable` with members
    `videoId: String`, `channelId: String`, `title: String`,
    `channelTitle: String`, `published: Date`, `summary: String?`,
    `thumbnailURL: URL?`, `viewCount: Int?`, `watchURL: URL`,
    and `var id: String { videoId }`
  - `enum DiscoverFeedParser` with
    `static func parse(_ data: Data) -> [DiscoverEntry]` and
    `static func merge(_ groups: [[DiscoverEntry]]) -> [DiscoverEntry]`

- [ ] **Step 1: Write the failing tests**

Create `ios/NexaInsightCoreTests/DiscoverFeedParserTests.swift`:

```swift
import XCTest
@testable import NexaInsightCore

final class DiscoverFeedParserTests: XCTestCase {
    // Trimmed from a real feed. Two entries: one normal watch video, one Short.
    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <title>Lex Fridman</title>
     <entry>
      <yt:videoId>XyXBwO5jYpw</yt:videoId>
      <yt:channelId>UCSHZKyawb77ixDdsGog4iWA</yt:channelId>
      <title>Gary Gallagher: American Civil War &amp; Lincoln</title>
      <link rel="alternate" href="https://www.youtube.com/watch?v=XyXBwO5jYpw"/>
      <author><name>Lex Fridman</name></author>
      <published>2026-07-28T20:02:11+00:00</published>
      <media:group>
       <media:thumbnail url="https://i1.ytimg.com/vi/XyXBwO5jYpw/hqdefault.jpg" width="480" height="360"/>
       <media:description>Gary Gallagher is a historian of the American Civil War.</media:description>
       <media:statistics views="189212"/>
      </media:group>
     </entry>
     <entry>
      <yt:videoId>3HQkVfZ4DNY</yt:videoId>
      <yt:channelId>UCSHZKyawb77ixDdsGog4iWA</yt:channelId>
      <title>Zippers are stronger than you think</title>
      <link rel="alternate" href="https://www.youtube.com/shorts/3HQkVfZ4DNY"/>
      <author><name>Lex Fridman</name></author>
      <published>2026-07-27T10:00:00+00:00</published>
      <media:group>
       <media:thumbnail url="https://i1.ytimg.com/vi/3HQkVfZ4DNY/hqdefault.jpg" width="480" height="360"/>
       <media:description>short clip</media:description>
       <media:statistics views="500"/>
      </media:group>
     </entry>
    </feed>
    """

    func testParsesEntryFields() {
        let items = DiscoverFeedParser.parse(Data(feed.utf8))
        XCTAssertEqual(items.count, 1, "the Short must be excluded")
        let item = items[0]
        XCTAssertEqual(item.videoId, "XyXBwO5jYpw")
        XCTAssertEqual(item.channelId, "UCSHZKyawb77ixDdsGog4iWA")
        XCTAssertEqual(item.title, "Gary Gallagher: American Civil War & Lincoln")
        XCTAssertEqual(item.channelTitle, "Lex Fridman")
        XCTAssertEqual(item.summary, "Gary Gallagher is a historian of the American Civil War.")
        XCTAssertEqual(item.thumbnailURL?.absoluteString, "https://i1.ytimg.com/vi/XyXBwO5jYpw/hqdefault.jpg")
        XCTAssertEqual(item.viewCount, 189212)
        XCTAssertEqual(item.watchURL.absoluteString, "https://www.youtube.com/watch?v=XyXBwO5jYpw")
        XCTAssertEqual(item.id, "XyXBwO5jYpw")
    }

    func testParsesPublishedDate() {
        let items = DiscoverFeedParser.parse(Data(feed.utf8))
        // 2026-07-28T20:02:11Z
        XCTAssertEqual(items[0].published.timeIntervalSince1970, 1785312131, accuracy: 1)
    }

    // Verified live: description and thumbnail were non-empty in all 15 entries
    // of both channels sampled, but that is a sample, not a guarantee. Missing
    // values must degrade, not crash or drop the entry.
    func testMissingOptionalFieldsDegradeGracefully() {
        let sparse = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
         <entry>
          <yt:videoId>abcdefghijk</yt:videoId>
          <yt:channelId>UCSHZKyawb77ixDdsGog4iWA</yt:channelId>
          <title>No extras</title>
          <link rel="alternate" href="https://www.youtube.com/watch?v=abcdefghijk"/>
          <author><name>Someone</name></author>
          <published>2026-07-01T00:00:00+00:00</published>
         </entry>
        </feed>
        """
        let items = DiscoverFeedParser.parse(Data(sparse.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].summary)
        XCTAssertNil(items[0].thumbnailURL)
        XCTAssertNil(items[0].viewCount)
        XCTAssertEqual(items[0].title, "No extras")
    }

    func testSkipsEntriesMissingRequiredFields() {
        let broken = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
         <entry>
          <title>No video id at all</title>
          <published>2026-07-01T00:00:00+00:00</published>
         </entry>
        </feed>
        """
        XCTAssertTrue(DiscoverFeedParser.parse(Data(broken.utf8)).isEmpty)
    }

    func testMalformedXMLReturnsEmptyWithoutCrashing() {
        XCTAssertTrue(DiscoverFeedParser.parse(Data("<feed><entry".utf8)).isEmpty)
        XCTAssertTrue(DiscoverFeedParser.parse(Data()).isEmpty)
    }

    func testMergeSortsNewestFirstAndDeduplicates() {
        let older = DiscoverEntry(
            videoId: "old11111111", channelId: "UCSHZKyawb77ixDdsGog4iWA", title: "Older",
            channelTitle: "A", published: Date(timeIntervalSince1970: 1000),
            summary: nil, thumbnailURL: nil, viewCount: nil,
            watchURL: URL(string: "https://www.youtube.com/watch?v=old11111111")!)
        let newer = DiscoverEntry(
            videoId: "new11111111", channelId: "UCHnyfMqiRRG1u-2MsSQLbXA", title: "Newer",
            channelTitle: "B", published: Date(timeIntervalSince1970: 2000),
            summary: nil, thumbnailURL: nil, viewCount: nil,
            watchURL: URL(string: "https://www.youtube.com/watch?v=new11111111")!)

        let merged = DiscoverFeedParser.merge([[older], [newer], [newer]])
        XCTAssertEqual(merged.map(\.videoId), ["new11111111", "old11111111"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter DiscoverFeedParserTests`
Expected: FAIL — `cannot find 'DiscoverFeedParser' in scope`.

- [ ] **Step 3: Write the model**

Create `ios/NexaInsight/Models/DiscoverEntry.swift`:

```swift
import Foundation

// One video from a subscribed channel's RSS feed.
//
// Every field here is something the feed actually provides. Notably absent:
// duration — the feed carries no duration tag anywhere, so Discover never shows
// one. Chapters, discussion directions, and transcript state are absent for the
// same reason: they only exist after import, and inventing them pre-import is
// what made the old hardcoded Discover fake.
struct DiscoverEntry: Identifiable, Equatable {
    let videoId: String
    let channelId: String
    let title: String
    let channelTitle: String
    let published: Date
    let summary: String?
    let thumbnailURL: URL?
    let viewCount: Int?
    let watchURL: URL

    var id: String { videoId }
}

// A channel the user follows. channelId is the RSS key, so it is also the
// identity — subscribing twice to the same channel collapses to one entry.
struct Subscription: Codable, Identifiable, Equatable {
    let channelId: String
    var title: String
    let addedAt: Date

    var id: String { channelId }
}
```

- [ ] **Step 4: Write the parser**

Create `ios/NexaInsight/Logic/DiscoverFeedParser.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ios && swift test --filter DiscoverFeedParserTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 122 tests.

- [ ] **Step 7: Commit**

```bash
git add ios/NexaInsight/Models/DiscoverEntry.swift ios/NexaInsight/Logic/DiscoverFeedParser.swift ios/NexaInsightCoreTests/DiscoverFeedParserTests.swift
git commit -m "Parse channel RSS feeds into Discover entries

Carries only fields the feed actually provides. Duration is absent
because the feed has no duration tag at all, which also makes the
/shorts/ link form the only reliable way to drop Shorts — 3 of 15
entries in one sampled channel."
```

---

### Task 3: Subscription store

`UserDefaults`-backed list, following the `AppSettings` pattern (`didSet`
persistence, injectable defaults for tests).

**Files:**
- Create: `ios/NexaInsight/Services/SubscriptionStore.swift`
- Test: `ios/NexaInsightCoreTests/SubscriptionStoreTests.swift`

**Interfaces:**
- Consumes: `Subscription` from Task 2.
- Produces:
  - `final class SubscriptionStore: ObservableObject`
  - `init(defaults: UserDefaults = .standard)`
  - `@Published private(set) var subscriptions: [Subscription]`
  - `func add(_ subscription: Subscription)`
  - `func remove(channelId: String)`
  - `func contains(channelId: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `ios/NexaInsightCoreTests/SubscriptionStoreTests.swift`:

```swift
import XCTest
@testable import NexaInsightCore

final class SubscriptionStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Isolated suite so tests never touch the app's real preferences.
        defaults = UserDefaults(suiteName: "SubscriptionStoreTests")!
        defaults.removePersistentDomain(forName: "SubscriptionStoreTests")
    }

    private func sub(_ id: String, _ title: String = "Channel") -> Subscription {
        Subscription(channelId: id, title: title, addedAt: Date(timeIntervalSince1970: 0))
    }

    func testStartsEmpty() {
        XCTAssertTrue(SubscriptionStore(defaults: defaults).subscriptions.isEmpty)
    }

    func testAddThenRead() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA", "Lex Fridman"))
        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCSHZKyawb77ixDdsGog4iWA"])
        XCTAssertEqual(store.subscriptions[0].title, "Lex Fridman")
    }

    func testAddingSameChannelTwiceKeepsOneAndUpdatesTitle() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA", "Old Name"))
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA", "New Name"))
        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(store.subscriptions[0].title, "New Name")
    }

    func testRemove() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA"))
        store.add(sub("UCHnyfMqiRRG1u-2MsSQLbXA"))
        store.remove(channelId: "UCSHZKyawb77ixDdsGog4iWA")
        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCHnyfMqiRRG1u-2MsSQLbXA"])
    }

    func testContains() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA"))
        XCTAssertTrue(store.contains(channelId: "UCSHZKyawb77ixDdsGog4iWA"))
        XCTAssertFalse(store.contains(channelId: "UCHnyfMqiRRG1u-2MsSQLbXA"))
    }

    func testPersistsAcrossInstances() {
        let first = SubscriptionStore(defaults: defaults)
        first.add(sub("UCSHZKyawb77ixDdsGog4iWA", "Lex Fridman"))

        let second = SubscriptionStore(defaults: defaults)
        XCTAssertEqual(second.subscriptions.map(\.channelId), ["UCSHZKyawb77ixDdsGog4iWA"])
        XCTAssertEqual(second.subscriptions[0].title, "Lex Fridman")
    }

    func testCorruptStoredValueIsIgnored() {
        defaults.set("not json", forKey: "discoverSubscriptions")
        XCTAssertTrue(SubscriptionStore(defaults: defaults).subscriptions.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter SubscriptionStoreTests`
Expected: FAIL — `cannot find 'SubscriptionStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/NexaInsight/Services/SubscriptionStore.swift`:

```swift
import Foundation

// The channels the user follows.
//
// Lives in UserDefaults rather than SwiftData/EpisodeStore: a subscription list
// is a device-local preference, while EpisodeStore holds imported study content.
// Different lifecycles, so different homes.
final class SubscriptionStore: ObservableObject {
    private static let key = "discoverSubscriptions"

    private let defaults: UserDefaults

    @Published private(set) var subscriptions: [Subscription] = [] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = stored
        }
    }

    func add(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.channelId == subscription.channelId }) {
            subscriptions[index].title = subscription.title
        } else {
            subscriptions.append(subscription)
        }
    }

    func remove(channelId: String) {
        subscriptions.removeAll { $0.channelId == channelId }
    }

    func contains(channelId: String) -> Bool {
        subscriptions.contains { $0.channelId == channelId }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
```

Note: `init` assigns `subscriptions` directly, which fires `didSet` and writes
back what was just read. That is a harmless idempotent write, and keeping it
avoids a second code path for loading.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && swift test --filter SubscriptionStoreTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 129 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Services/SubscriptionStore.swift ios/NexaInsightCoreTests/SubscriptionStoreTests.swift
git commit -m "Store Discover channel subscriptions in UserDefaults

Keyed by channelId so re-subscribing collapses to one entry. Kept out
of EpisodeStore because a follow list is device-local preference, not
imported study content."
```

---

### Task 4: Feed service with per-source error isolation

Networking layer. Kept thin and injectable so the view model can be tested
without it.

**Files:**
- Create: `ios/NexaInsight/Services/DiscoverFeedService.swift`

**Interfaces:**
- Consumes: `YouTubeChannelLogic.feedURL(channelId:)`, `YouTubeChannelLogic.channelId(fromHTML:)`, `YouTubeChannelLogic.channelId(fromChannelURL:)` (Task 1); `DiscoverFeedParser.parse(_:)` (Task 2); `Subscription` (Task 2).
- Produces:
  - `struct FeedFetchResult` with `entries: [DiscoverEntry]`, `failedChannelIds: [String]`, `channelTitles: [String: String]`
  - `protocol DiscoverFeedFetching` with
    `func fetchFeeds(channelIds: [String]) async -> FeedFetchResult` and
    `func resolveChannel(fromURL url: String) async throws -> Subscription`
  - `struct DiscoverFeedService: DiscoverFeedFetching` with `init(session: URLSession = .shared)`
  - `enum DiscoverFeedError: LocalizedError { case unrecognizedChannelLink, channelNotFound }`

- [ ] **Step 1: Write the implementation**

There is no separate failing-test step here: this file is pure I/O against
YouTube, and the plan's testing strategy keeps tests offline. The behaviour that
*can* be tested offline (partial-failure handling, ordering, state transitions)
is covered in Task 5 through the `DiscoverFeedFetching` protocol with a stub.

Create `ios/NexaInsight/Services/DiscoverFeedService.swift`:

```swift
import Foundation

// What one refresh produced. Sources that failed are reported alongside the
// entries that succeeded, because one dead channel must not blank the page.
struct FeedFetchResult {
    let entries: [DiscoverEntry]
    let failedChannelIds: [String]
    let channelTitles: [String: String]
}

enum DiscoverFeedError: LocalizedError {
    case unrecognizedChannelLink
    case channelNotFound

    var errorDescription: String? {
        switch self {
        case .unrecognizedChannelLink:
            return "Could not recognize that channel link. Paste a youtube.com/@handle or /channel/UC... URL."
        case .channelNotFound:
            return "That channel has no public feed."
        }
    }
}

protocol DiscoverFeedFetching {
    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult
    func resolveChannel(fromURL url: String) async throws -> Subscription
}

// Fetches subscribed channels' public RSS feeds.
//
// The feed needs no API key, no auth, and no particular User-Agent — verified
// with no headers, a custom UA, and a browser UA, all returning 200. So this
// stays a plain URLSession GET with no backend in the middle.
struct DiscoverFeedService: DiscoverFeedFetching {
    var session: URLSession = .shared

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult {
        // Each channel is fetched concurrently and failures are per-channel: an
        // invalid channel_id returns 404 (not an empty feed), so without this
        // isolation one bad subscription would empty the whole screen.
        await withTaskGroup(of: (String, [DiscoverEntry]?).self) { group in
            for channelId in channelIds {
                group.addTask { (channelId, try? await self.fetchOne(channelId: channelId)) }
            }

            var groups: [[DiscoverEntry]] = []
            var failed: [String] = []
            var titles: [String: String] = [:]
            for await (channelId, entries) in group {
                guard let entries else { failed.append(channelId); continue }
                groups.append(entries)
                if let title = entries.first?.channelTitle { titles[channelId] = title }
            }
            return FeedFetchResult(
                entries: DiscoverFeedParser.merge(groups),
                failedChannelIds: failed,
                channelTitles: titles)
        }
    }

    func resolveChannel(fromURL url: String) async throws -> Subscription {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelId: String
        if let direct = YouTubeChannelLogic.channelId(fromChannelURL: trimmed) {
            channelId = direct
        } else {
            guard let pageURL = URL(string: trimmed), pageURL.scheme != nil else {
                throw DiscoverFeedError.unrecognizedChannelLink
            }
            let (data, _) = try await session.data(from: pageURL)
            guard let html = String(data: data, encoding: .utf8),
                  let resolved = YouTubeChannelLogic.channelId(fromHTML: html)
            else { throw DiscoverFeedError.unrecognizedChannelLink }
            channelId = resolved
        }

        // Fetch the feed once to validate the id and read the channel title.
        // A bad id 404s here, which doubles as the "no such channel" check.
        let entries = try await fetchOne(channelId: channelId)
        let title = entries.first?.channelTitle ?? channelId
        return Subscription(channelId: channelId, title: title, addedAt: Date())
    }

    private func fetchOne(channelId: String) async throws -> [DiscoverEntry] {
        guard let url = YouTubeChannelLogic.feedURL(channelId: channelId) else {
            throw DiscoverFeedError.unrecognizedChannelLink
        }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw DiscoverFeedError.channelNotFound }
        return DiscoverFeedParser.parse(data)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd ios && swift build`
Expected: build succeeds with no errors.

- [ ] **Step 3: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 129 tests, unchanged.

- [ ] **Step 4: Commit**

```bash
git add ios/NexaInsight/Services/DiscoverFeedService.swift
git commit -m "Fetch subscribed channel feeds with per-source isolation

An invalid channel_id returns 404 rather than an empty feed, so one bad
subscription would otherwise blank the whole screen. Failed channels are
reported alongside the entries that succeeded."
```

---

### Task 5: Discover view model

Holds the screen's state and the load/refresh/subscribe transitions. Tested
offline via a stub `DiscoverFeedFetching`.

**Files:**
- Create: `ios/NexaInsight/Import/DiscoverViewModel.swift`
- Test: `ios/NexaInsightCoreTests/DiscoverViewModelTests.swift`

**Interfaces:**
- Consumes: `DiscoverFeedFetching`, `FeedFetchResult`, `DiscoverFeedError` (Task 4); `SubscriptionStore` (Task 3); `DiscoverEntry`, `Subscription` (Task 2).
- Produces:
  - `@MainActor final class DiscoverViewModel: ObservableObject`
  - `init(store: SubscriptionStore, service: DiscoverFeedFetching)`
  - `@Published var entries: [DiscoverEntry]`, `@Published var loading: Bool`,
    `@Published var feedError: String?`, `@Published var addError: String?`,
    `@Published var failedChannelIds: [String]`,
    `@Published var selectedChannelId: String?`, `@Published var query: String`
  - `var subscriptions: [Subscription]`
  - `var visibleEntries: [DiscoverEntry]`
  - `var hasSubscriptions: Bool`
  - `func refresh() async`
  - `func addSubscription(url: String) async`
  - `func removeSubscription(channelId: String)`

- [ ] **Step 1: Write the failing tests**

Create `ios/NexaInsightCoreTests/DiscoverViewModelTests.swift`:

```swift
import XCTest
@testable import NexaInsightCore

private struct StubFeedService: DiscoverFeedFetching {
    var result = FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    var resolved: Subscription?
    var resolveError: Error?

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult { result }

    func resolveChannel(fromURL url: String) async throws -> Subscription {
        if let resolveError { throw resolveError }
        guard let resolved else { throw DiscoverFeedError.unrecognizedChannelLink }
        return resolved
    }
}

private func entry(_ id: String, channel: String, title: String, at seconds: TimeInterval) -> DiscoverEntry {
    DiscoverEntry(
        videoId: id, channelId: channel, title: title, channelTitle: "Ch \(channel)",
        published: Date(timeIntervalSince1970: seconds), summary: "summary of \(title)",
        thumbnailURL: nil, viewCount: nil,
        watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
}

@MainActor
final class DiscoverViewModelTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "DiscoverViewModelTests")!
        defaults.removePersistentDomain(forName: "DiscoverViewModelTests")
    }

    private func makeStore(_ channelIds: [String] = []) -> SubscriptionStore {
        let store = SubscriptionStore(defaults: defaults)
        for id in channelIds {
            store.add(Subscription(channelId: id, title: "Ch \(id)", addedAt: Date(timeIntervalSince1970: 0)))
        }
        return store
    }

    func testNoSubscriptionsMeansGuidanceStateAndNoFetch() async {
        let vm = DiscoverViewModel(store: makeStore(), service: StubFeedService())
        await vm.refresh()
        XCTAssertFalse(vm.hasSubscriptions)
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertNil(vm.feedError)
    }

    func testRefreshPopulatesEntries() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v2", channel: "UCb", title: "Newer", at: 2000),
                      entry("v1", channel: "UCa", title: "Older", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        XCTAssertEqual(vm.entries.map(\.videoId), ["v2", "v1"])
        XCTAssertFalse(vm.loading)
        XCTAssertNil(vm.feedError)
    }

    func testPartialFailureKeepsEntriesAndRecordsFailedChannel() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "Fine", at: 1000)],
            failedChannelIds: ["UCb"], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        XCTAssertEqual(vm.entries.count, 1, "a dead source must not blank the page")
        XCTAssertEqual(vm.failedChannelIds, ["UCb"])
        XCTAssertNil(vm.feedError, "partial failure is not a page-level error")
    }

    func testAllSourcesFailingSetsPageError() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(entries: [], failedChannelIds: ["UCa", "UCb"], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        XCTAssertNotNil(vm.feedError)
        XCTAssertTrue(vm.entries.isEmpty)
    }

    func testQueryFiltersOnTitleChannelAndSummary() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "Civil War history", at: 2000),
                      entry("v2", channel: "UCb", title: "Quantum physics", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()

        vm.query = "quantum"
        XCTAssertEqual(vm.visibleEntries.map(\.videoId), ["v2"])

        vm.query = "CIVIL"
        XCTAssertEqual(vm.visibleEntries.map(\.videoId), ["v1"], "matching is case-insensitive")

        vm.query = ""
        XCTAssertEqual(vm.visibleEntries.count, 2)
    }

    func testChannelFilterNarrowsToOneSubscription() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "From A", at: 2000),
                      entry("v2", channel: "UCb", title: "From B", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let vm = DiscoverViewModel(store: makeStore(["UCa", "UCb"]), service: service)
        await vm.refresh()
        vm.selectedChannelId = "UCb"
        XCTAssertEqual(vm.visibleEntries.map(\.videoId), ["v2"])
    }

    func testAddSubscriptionStoresAndRefreshes() async {
        var service = StubFeedService()
        service.resolved = Subscription(channelId: "UCnew", title: "New Channel", addedAt: Date(timeIntervalSince1970: 0))
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCnew", title: "First", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let store = makeStore()
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.addSubscription(url: "https://www.youtube.com/@new")

        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCnew"])
        XCTAssertEqual(vm.entries.map(\.videoId), ["v1"])
        XCTAssertNil(vm.addError)
    }

    func testAddSubscriptionSurfacesResolveFailure() async {
        var service = StubFeedService()
        service.resolveError = DiscoverFeedError.unrecognizedChannelLink

        let store = makeStore()
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.addSubscription(url: "not a channel")

        XCTAssertTrue(store.subscriptions.isEmpty)
        XCTAssertEqual(vm.addError, DiscoverFeedError.unrecognizedChannelLink.errorDescription)
    }

    func testRemoveSubscriptionDropsItsEntries() async {
        var service = StubFeedService()
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCa", title: "From A", at: 2000),
                      entry("v2", channel: "UCb", title: "From B", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let store = makeStore(["UCa", "UCb"])
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.refresh()
        vm.removeSubscription(channelId: "UCa")

        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCb"])
        XCTAssertEqual(vm.entries.map(\.videoId), ["v2"], "entries from a removed channel disappear immediately")
    }

    func testRemovingSelectedChannelClearsTheFilter() async {
        let store = makeStore(["UCa"])
        let vm = DiscoverViewModel(store: store, service: StubFeedService())
        vm.selectedChannelId = "UCa"
        vm.removeSubscription(channelId: "UCa")
        XCTAssertNil(vm.selectedChannelId)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter DiscoverViewModelTests`
Expected: FAIL — `cannot find 'DiscoverViewModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/NexaInsight/Import/DiscoverViewModel.swift`:

```swift
import Foundation

// State for the Discover screen.
//
// Two error channels on purpose: feedError is page-level (every source failed)
// while failedChannelIds marks individual dead sources without hiding the
// entries that did load.
@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published var entries: [DiscoverEntry] = []
    @Published var loading = false
    @Published var feedError: String?
    @Published var addError: String?
    @Published var failedChannelIds: [String] = []
    @Published var selectedChannelId: String?
    @Published var query = ""

    private let store: SubscriptionStore
    private let service: DiscoverFeedFetching

    init(store: SubscriptionStore, service: DiscoverFeedFetching) {
        self.store = store
        self.service = service
    }

    var subscriptions: [Subscription] { store.subscriptions }
    var hasSubscriptions: Bool { !store.subscriptions.isEmpty }

    var visibleEntries: [DiscoverEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesChannel = selectedChannelId == nil || entry.channelId == selectedChannelId
            guard matchesChannel else { return false }
            guard !trimmed.isEmpty else { return true }
            let haystack = "\(entry.title) \(entry.channelTitle) \(entry.summary ?? "")"
            return haystack.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func refresh() async {
        let channelIds = store.subscriptions.map(\.channelId)
        guard !channelIds.isEmpty else {
            entries = []
            failedChannelIds = []
            feedError = nil
            return
        }

        loading = true
        defer { loading = false }

        let result = await service.fetchFeeds(channelIds: channelIds)
        entries = result.entries
        failedChannelIds = result.failedChannelIds
        // Page-level error only when nothing at all came back.
        feedError = result.failedChannelIds.count == channelIds.count
            ? "Could not reach any of your channels. Check your connection and try again."
            : nil
    }

    func addSubscription(url: String) async {
        addError = nil
        do {
            let subscription = try await service.resolveChannel(fromURL: url)
            store.add(subscription)
            await refresh()
        } catch {
            addError = error.localizedDescription
        }
    }

    func removeSubscription(channelId: String) {
        store.remove(channelId: channelId)
        entries.removeAll { $0.channelId == channelId }
        failedChannelIds.removeAll { $0 == channelId }
        if selectedChannelId == channelId { selectedChannelId = nil }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && swift test --filter DiscoverViewModelTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 139 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Import/DiscoverViewModel.swift ios/NexaInsightCoreTests/DiscoverViewModelTests.swift
git commit -m "Add Discover view model over subscriptions and feeds

Separates page-level failure from per-source failure so one dead
channel leaves the rest of the feed visible."
```

---

### Task 6: Rewire the Discover UI

Replaces the hardcoded data with the view model and deletes the invented fields.
This is the only task that touches `LibraryView.swift`.

**Files:**
- Modify: `ios/NexaInsight/Views/LibraryView.swift`
  - Delete `DiscoverKind` (currently around lines 455-472)
  - Delete `DiscoverItem` (currently around lines 474-489)
  - Delete `featuredDiscoverItems` (currently around lines 491-~600)
  - Rewrite `DiscoverView`, `DiscoverFilters`, `DiscoverList`, `DiscoverListItem`, `DiscoverPreview`
  - Remove the `DiscoverFilterButton` `systemName` icon argument that came from `DiscoverKind.icon`

Line numbers drift as you edit. Locate each declaration by name with
`grep -n 'private struct DiscoverItem' ios/NexaInsight/Views/LibraryView.swift`
rather than trusting the numbers above.

**Interfaces:**
- Consumes: `DiscoverViewModel`, `DiscoverEntry`, `Subscription`, `SubscriptionStore`, `DiscoverFeedService`.
- Produces: no new public API. `DiscoverView`'s initializer changes to
  `DiscoverView(vm: DiscoverViewModel, importing: Bool, onAddToNexa: (String) -> Void)`.

**Fields removed from the UI and why:** `kind`, `permission`, `duration`,
`chapters`, `transcriptState`, `discussionDirections`, `related`. The feed
provides none of them. `chapters` and `discussionDirections` only exist after
import (chapters need transcription, discussion directions need an LLM), so
showing them pre-import is exactly what made the old screen fake. The
"Available context", "Suggested discussion", and "Recommended next" sections of
`DiscoverPreview` are deleted along with them.

- [ ] **Step 1: Wire the view model into DashboardShell**

`DiscoverView` is constructed in two places — `regularMainContent` and
`compactLayout`. Both must pass the view model.

In `LibraryView` (the outer view), add the store and view model as state, and
pass the view model down through `DashboardShell`:

```swift
struct LibraryView: View {
    let store: EpisodeStore
    @ObservedObject var settings: AppSettings
    @StateObject private var vm: ImportViewModel
    @StateObject private var discover: DiscoverViewModel
    @State private var selectedSection: AppSection = .home
    @State private var showImport = false
    @State private var showSettings = false
    @State private var urlDraft = ""

    init(store: EpisodeStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        _vm = StateObject(wrappedValue: ImportViewModel(
            client: BackendClient(baseURL: URL(string: settings.backendBaseURL) ?? URL(string: "http://localhost:8000")!),
            store: store))
        _discover = StateObject(wrappedValue: DiscoverViewModel(
            store: SubscriptionStore(),
            service: DiscoverFeedService()))
    }
```

Add `discover` to the `DashboardShell(...)` call in `body`:

```swift
            DashboardShell(
                episodes: vm.episodes,
                progress: vm.progress,
                importError: vm.importError,
                backendBaseURL: vm.backendBaseURL,
                importing: vm.importing,
                discover: discover,
                selectedSection: $selectedSection,
```

And in `DashboardShell`, declare it next to the other stored properties:

```swift
    @ObservedObject var discover: DiscoverViewModel
```

Then both `DiscoverView(...)` call sites become:

```swift
            DiscoverView(vm: discover, importing: importing, onAddToNexa: onAddToNexa)
```

- [ ] **Step 2: Rewrite DiscoverView**

Replace the whole `private struct DiscoverView` with:

```swift
private struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    let importing: Bool
    let onAddToNexa: (String) -> Void
    @State private var selectedEntry: DiscoverEntry?
    @State private var showAddChannel = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            DiscoverHeader(query: $vm.query, importing: importing, onAddToNexa: onAddToNexa)

            if !vm.hasSubscriptions {
                NXEmptyState(
                    title: "Follow a channel to fill Discover",
                    message: "Paste a YouTube channel link — youtube.com/@handle or a /channel/UC... URL — and new videos from it show up here.",
                    actionTitle: "Add a channel",
                    action: { showAddChannel = true })
            } else {
                DiscoverChannelFilters(
                    subscriptions: vm.subscriptions,
                    selectedChannelId: $vm.selectedChannelId,
                    onAddChannel: { showAddChannel = true })

                if let feedError = vm.feedError {
                    NXErrorState(message: feedError, retry: { Task { await vm.refresh() } })
                } else if vm.loading && vm.entries.isEmpty {
                    ProgressView("Loading your channels")
                        .font(NXFont.auxiliary)
                } else {
                    content
                }
            }
        }
        .task { await vm.refresh() }
        .refreshable { await vm.refresh() }
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
        .onChange(of: vm.visibleEntries) { _, items in
            if let selectedEntry, !items.contains(selectedEntry) {
                self.selectedEntry = compact ? nil : items.first
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if compact {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                DiscoverList(
                    items: vm.visibleEntries,
                    selectedEntry: $selectedEntry,
                    autoSelectFirst: false,
                    onClear: { vm.query = "" })
                if let selectedEntry {
                    DiscoverPreview(
                        entry: selectedEntry,
                        importing: importing,
                        onAddToNexa: { onAddToNexa(selectedEntry.watchURL.absoluteString) })
                }
            }
        } else {
            let previewEntry = selectedEntry ?? vm.visibleEntries.first
            HStack(alignment: .top, spacing: NXSpacing.x8) {
                DiscoverList(
                    items: vm.visibleEntries,
                    selectedEntry: $selectedEntry,
                    autoSelectFirst: true,
                    onClear: { vm.query = "" })
                .frame(minWidth: 360, maxWidth: 520)

                if let previewEntry {
                    DiscoverPreview(
                        entry: previewEntry,
                        importing: importing,
                        onAddToNexa: { onAddToNexa(previewEntry.watchURL.absoluteString) })
                    .frame(maxWidth: 420)
                }
            }
        }
    }
}
```

A plain `ProgressView` is used rather than `NXProgressIndicator` because that
component takes `(value: Int, label: String)` — it renders a determinate
percentage bar for import jobs, and a feed fetch has no percentage to report.

- [ ] **Step 3: Replace DiscoverFilters with channel filters**

Delete `private struct DiscoverFilters` and add:

```swift
private struct DiscoverChannelFilters: View {
    let subscriptions: [Subscription]
    @Binding var selectedChannelId: String?
    let onAddChannel: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NXSpacing.x2) {
                DiscoverFilterButton(title: "All", systemName: "line.3.horizontal.decrease", selected: selectedChannelId == nil) {
                    selectedChannelId = nil
                }
                ForEach(subscriptions) { subscription in
                    DiscoverFilterButton(
                        title: subscription.title,
                        systemName: "play.rectangle",
                        selected: selectedChannelId == subscription.channelId
                    ) {
                        selectedChannelId = subscription.channelId
                    }
                }
                DiscoverFilterButton(title: "Add channel", systemName: "plus", selected: false, action: onAddChannel)
            }
        }
    }
}
```

`DiscoverFilterButton` is unchanged and reused as-is.

- [ ] **Step 4: Add the channel sheet**

```swift
private struct AddChannelSheet: View {
    @ObservedObject var vm: DiscoverViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var working = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: NXSpacing.x4) {
                Text("Paste a YouTube channel link.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                TextField("youtube.com/@handle", text: $draft)
                    .font(NXFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { submit() }
                if let addError = vm.addError {
                    Text(addError)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NXPrimaryButton(
                    title: working ? "Adding" : "Add channel",
                    systemName: working ? "clock" : "plus",
                    disabled: working || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submit)
                Spacer()
            }
            .padding(NXSpacing.x4)
            .navigationTitle("Add channel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        working = true
        Task {
            await vm.addSubscription(url: ImportViewModel.normalizedYouTubeURL(draft))
            working = false
            if vm.addError == nil { dismiss() }
        }
    }
}
```

`ImportViewModel.normalizedYouTubeURL` is reused so a bare `youtube.com/@x`
paste gets the `https://` prefix.

- [ ] **Step 5: Rewrite DiscoverList and DiscoverListItem**

```swift
private struct DiscoverList: View {
    let items: [DiscoverEntry]
    @Binding var selectedEntry: DiscoverEntry?
    let autoSelectFirst: Bool
    let onClear: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "From your channels")
            if items.isEmpty {
                NXEmptyState(
                    title: "Nothing matches",
                    message: "Try a broader search, or pick a different channel.",
                    actionTitle: "Clear search",
                    action: onClear)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        DiscoverListItem(
                            item: item,
                            selected: item == selectedEntry || (autoSelectFirst && selectedEntry == nil && item == items.first),
                            action: { selectedEntry = item })
                        if item.id != items.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
            }
        }
    }
}

private struct DiscoverListItem: View {
    let item: DiscoverEntry
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: NXSpacing.x3) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? NXColor.primary : NXColor.textTertiary(scheme))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text(item.title)
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineLimit(2)
                    Text(DiscoverFormat.byline(item))
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(1)
                    if let summary = item.summary {
                        Text(summary)
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textTertiary(scheme))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, NXSpacing.x3)
            .padding(.leading, selected ? NXSpacing.x3 : 0)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(selected ? NXColor.primary : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 6: Rewrite DiscoverPreview**

```swift
private struct DiscoverPreview: View {
    let entry: DiscoverEntry
    let importing: Bool
    let onAddToNexa: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                Text(entry.title)
                    .font(NXFont.sectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(DiscoverFormat.byline(entry))
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                if let summary = entry.summary {
                    Text(summary)
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NXPrimaryButton(
                title: importing ? "Adding" : "Add to Nexa",
                systemName: importing ? "clock" : "plus",
                disabled: importing,
                action: onAddToNexa)

            Text("Transcript, chapters, and discussion become available after you add it.")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 0 : NXSpacing.x4)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: NXRadius.surface)
                    .fill(NXColor.surface1(scheme))
            }
        }
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: NXRadius.surface)
                    .stroke(NXColor.border(scheme), lineWidth: 1)
            }
        }
    }
}

// Byline for a feed entry. Duration is deliberately absent — the RSS feed has
// no duration tag, so there is nothing truthful to show until after import.
enum DiscoverFormat {
    static func byline(_ entry: DiscoverEntry) -> String {
        var parts = [entry.channelTitle, relativeDate(entry.published)]
        if let views = entry.viewCount {
            parts.append("\(views.formatted(.number.notation(.compactName))) views")
        }
        return parts.joined(separator: " · ")
    }

    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
```

The `Save` and `Follow` buttons are dropped. Following is now the subscription
list itself, and `savedIds`/`followedIds` were in-memory `@State` that reset on
every navigation — they persisted nothing.

- [ ] **Step 7: Delete the dead declarations**

Delete `DiscoverKind`, `DiscoverItem`, and `featuredDiscoverItems`. Also delete
`DiscoverRightRail`'s hardcoded "Followable sources" copy about podcasts,
newsletters, and topics, replacing its body with the real subscription list:

```swift
private struct DiscoverRightRail: View {
    let onOpenDiscover: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            Text("Discover")
                .font(NXFont.subsectionTitle)
                .foregroundStyle(NXColor.text(scheme))
            PanelSection(title: "How this works") {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    Text("New videos from the channels you follow stay in Discover until you choose Add to Nexa.")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    NXTextButton(title: "Browse Discover", systemName: "sparkle.magnifyingglass", action: onOpenDiscover)
                }
            }
            Spacer()
        }
        .padding(NXSpacing.x4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NXColor.surface1(scheme))
    }
}
```

- [ ] **Step 8: Verify no references to the deleted types remain**

Run:
```bash
cd ios && grep -n "DiscoverKind\|DiscoverItem\|featuredDiscoverItems" NexaInsight/Views/LibraryView.swift
```
Expected: no output.

- [ ] **Step 9: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 139 tests.

- [ ] **Step 10: Build for the simulator**

```bash
cd ios && ./generate.sh
xcodebuild -project NexaInsight.xcodeproj -target NexaInsight \
  -sdk iphonesimulator -configuration Debug -arch arm64 \
  EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets' \
  ASSETCATALOG_COMPILER_APPICON_NAME='' \
  CONFIGURATION_BUILD_DIR=/tmp/nexa-build build 2>&1 | grep -E "^\*\*|error:"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 11: Run it and look at the screen**

```bash
xcrun simctl list devices available | grep iPhone
DEV=<pick a booted or bootable id>
xcrun simctl boot $DEV 2>/dev/null; open -a Simulator
xcrun simctl install $DEV "/tmp/nexa-build/Nexa Insight.app"
xcrun simctl launch $DEV com.nexainsight.app
sleep 3
xcrun simctl io $DEV screenshot /tmp/discover.png
```

Then read `/tmp/discover.png`. Expected: Discover shows the "Follow a channel"
guidance state, not five fake cards and not a blank screen.

This is a real-device-network step: the simulator must reach
`youtube.com` for the next check. Add a channel through the sheet (paste
`https://www.youtube.com/@lexfridman`), screenshot again, and confirm real video
titles appear with a channel/date byline and **no duration**.

If the simulator has no network, say so rather than reporting the feature
verified — parsing is covered by tests, but the live fetch would then be
unverified.

- [ ] **Step 12: Commit**

```bash
git add ios/NexaInsight/Views/LibraryView.swift
git commit -m "Show real subscribed-channel videos in Discover

Replaces five hardcoded items whose summaries, chapters, and discussion
directions were hand-written copy. Cards now show only what the feed
provides; chapters and discussion prompts move to post-import, where
they actually exist."
```

---

## Verification constraints

Recorded so the implementer does not mistake an environment limit for a bug:

- `curl` cannot reach YouTube from the sandbox this plan was written in (no IPv6
  route, then timeout). Findings were verified with `yt-dlp` and with Python
  `urllib` forced to IPv4. If `curl` fails for you, try IPv4 or another client
  before concluding the feed is down.
- `xcodebuild -destination 'platform=iOS Simulator,...'` cannot resolve on this
  machine (`-showdestinations` lists zero simulator destinations). Use
  `-target` + `-sdk iphonesimulator`.
- The asset catalog must be excluded from simulator builds here; `actool`
  rejects the installed SDK/runtime pair. This only affects the app icon.
