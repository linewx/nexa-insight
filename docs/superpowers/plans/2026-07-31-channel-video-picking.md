# Channel Detail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users open a subscribed channel, search inside it for a specific video, and import that video.

**Architecture:** A pure parser for the in-channel search response goes in `NexaInsight/Logic/`; the request joins the existing `DiscoverFeedFetching` protocol. A new `ChannelDetailViewModel` holds per-channel state. A new `ChannelDetailView` is pushed via `navigationDestination`. Importing reuses `POST /api/episodes/import` untouched — no backend changes.

**Tech Stack:** Swift 5.9, SwiftUI, `URLSession`, `JSONSerialization`, XCTest. No new dependencies.

**Prerequisite:** The two prior Discover rounds must be present — this plan extends `DiscoverFeedFetching`, `SubscriptionStore`, `EpisodeStore`, `DiscoverFeedParser`, and `YouTubeChannelLogic`.

## Global Constraints

- No new package dependencies; **no backend changes**.
- All new tests pass with `cd ios && swift test` — offline, no network. Parser tests use inline JSON fixtures.
- Pure logic in `NexaInsight/Logic/`; stateful services in `NexaInsight/Services/`.
- Search URL must be exactly `https://www.youtube.com/channel/<UCxxxx>/search?query=<escaped>&hl=en&gl=US`.
- Every YouTube **HTML** request needs the browser `User-Agent` (`DiscoverFeedService.browserUserAgent`) and `Accept-Language: en-US,en;q=0.9`. Without the UA, YouTube serves a consent page: HTTP 200, ~475 KB, zero renderers. The RSS feed needs neither.
- A missing `ytInitialData` and a zero-result query are DIFFERENT states and must stay distinguishable.
- The paste-a-link fallback is never removed.

## Verified facts this plan depends on

Measured against the live site, encoded below as tests so nobody re-derives them.

| Fact | Measurement |
|---|---|
| In-channel search reaches the back catalog | results for `physics` included a 3-year-old and a 6-year-old upload |
| Search returns 30 results | consistent across queries |
| Search uses the OLDER renderer | `videoRenderer` = 30, `lockupViewModel` = 0 — the opposite of the videos page |
| `videoId` is always 11 chars | 30/30, matching the backend's `youtube_id()` validation |
| `lengthText` present | 30/30, e.g. `2:19:34` |
| `descriptionSnippet` sometimes absent | **4 of 30 had none** — must be optional |
| Search thumbnails are ABSOLUTE | 0/30 protocol-relative, unlike the channel-search page where 20/20 were `//...` |
| `title` uses `runs`, not `simpleText` | 1 run in the sample, but join defensively |
| No match returns 200 with 0 results | `ytInitialData` present — a valid answer, not a failure |
| Search returns no Shorts | 0 `/shorts/` references |
| RSS caps at 15 | `max-results` and `start-index` both ignored |

Note the two differences from the existing `ChannelSearchParser`: thumbnails here
are already absolute (so no `https:` prefixing), and the title lives under `runs`
(not `simpleText`). Do not copy that parser without adjusting both.

## Build and test commands

```bash
cd ios && swift test

cd ios && ./generate.sh
xcodebuild -project NexaInsight.xcodeproj -target NexaInsight \
  -sdk iphonesimulator -configuration Debug -arch arm64 \
  EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets' \
  ASSETCATALOG_COMPILER_APPICON_NAME='' \
  CONFIGURATION_BUILD_DIR=/tmp/nexa-build build
```

`actool` rejects this machine's SDK/runtime pair, so the asset catalog (app icon
only, no code references it) is excluded. `-destination` cannot resolve here.

## File structure

| File | Responsibility |
|---|---|
| Create `NexaInsight/Models/ChannelVideo.swift` | The video model |
| Create `NexaInsight/Logic/ChannelVideoParser.swift` | Pure: in-channel search JSON → `[ChannelVideo]`, with a structural-failure signal |
| Modify `NexaInsight/Services/DiscoverFeedService.swift` | Add `searchVideos(channelId:query:)` and `fetchChannelUploads(channelId:)` |
| Create `NexaInsight/Import/ChannelDetailViewModel.swift` | Per-channel state: search, recency list, import, already-imported marking |
| Modify `NexaInsight/Views/LibraryView.swift` | Push the detail screen; add a "View content" entry on search results |
| Create `NexaInsight/Views/ChannelDetailView.swift` | The screen itself — kept out of `LibraryView.swift`, already 2350+ lines |
| Create `NexaInsightCoreTests/ChannelVideoParserTests.swift` | Task 2 tests |
| Create `NexaInsightCoreTests/ChannelDetailViewModelTests.swift` | Task 4 tests |

---

### Task 1: ChannelVideo model

**Files:**
- Create: `ios/NexaInsight/Models/ChannelVideo.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct ChannelVideo: Identifiable, Equatable` with `watchURL`.

- [ ] **Step 1: Write the model**

```swift
import Foundation

// One video from a channel, ready to be imported.
//
// Every metadata field keeps YouTube's own display string rather than being
// parsed into Int/Date. These arrive already localized ("3 years ago",
// "3,028,760 views"); parsing them back would mean handling every language and
// abbreviation format, and we only ever display them. This is a deliberate
// difference from DiscoverEntry, whose `published` is a real Date because RSS
// provides an ISO-8601 timestamp.
struct ChannelVideo: Identifiable, Equatable {
    let videoId: String
    let title: String
    let durationText: String?    // "2:19:34" — present in 30/30 measured
    let viewsText: String?       // "3,028,760 views"
    let publishedText: String?   // "3 years ago"
    let summary: String?         // absent in 4/30 measured, so optional
    let thumbnailURL: URL?

    var id: String { videoId }

    // All 30 measured videoIds were 11 chars, which is exactly what the
    // backend's youtube_id() accepts, so this URL imports without backend work.
    var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoId)")
    }
}
```

- [ ] **Step 2: Verify and commit**

Run: `cd ios && swift build && swift test`
Expected: build succeeds; 160 tests pass (unchanged).

```bash
git add ios/NexaInsight/Models/ChannelVideo.swift
git commit -m "Add ChannelVideo model

Metadata fields keep YouTube's localized display strings rather than
parsing to Int/Date, since they are only ever displayed. Summary is
optional because 4 of 30 measured results had none."
```

---

### Task 2: In-channel search parser

**Files:**
- Create: `ios/NexaInsight/Logic/ChannelVideoParser.swift`
- Test: `ios/NexaInsightCoreTests/ChannelVideoParserTests.swift`

**Interfaces:**
- Consumes: `ChannelVideo` (Task 1), `YouTubeChannelLogic.isShortsLink` (existing).
- Produces:
  - `enum ChannelVideoOutcome { case parsed([ChannelVideo]); case structureMissing }`
  - `enum ChannelVideoParser` with `static func parse(_ data: Data) -> ChannelVideoOutcome`

- [ ] **Step 1: Write the failing tests**

Create `ios/NexaInsightCoreTests/ChannelVideoParserTests.swift`:

```swift
import XCTest
@testable import NexaInsightCore

final class ChannelVideoParserTests: XCTestCase {
    private func page(_ renderersJSON: String) -> Data {
        Data("""
        <html><body><script>
        var ytInitialData = {"contents":{"twoColumnBrowseResultsRenderer":{"tabs":
        [{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":
        {"contents":[\(renderersJSON)]}}]}}}}]}}};</script></body></html>
        """.utf8)
    }

    // Trimmed from a real in-channel search response. Note: title is under
    // `runs`, and the thumbnail URL is already absolute — both differ from the
    // channel-search page that ChannelSearchParser handles.
    private let fullRenderer = """
    {"videoRenderer":{
      "videoId":"y3cw_9ELpQw",
      "title":{"runs":[{"text":"Andrew Strominger: Black Holes"}]},
      "lengthText":{"simpleText":"2:19:34"},
      "publishedTimeText":{"simpleText":"3 years ago"},
      "viewCountText":{"simpleText":"3,028,760 views"},
      "descriptionSnippet":{"runs":[{"text":"Andrew Strominger is a "},{"text":"theoretical physicist"},{"text":" at Harvard."}]},
      "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/y3cw_9ELpQw/hqdefault.jpg","width":168,"height":94}]}
    }}
    """

    private func videos(_ outcome: ChannelVideoOutcome) -> [ChannelVideo] {
        guard case .parsed(let items) = outcome else {
            XCTFail("expected .parsed, got \(outcome)")
            return []
        }
        return items
    }

    func testParsesAllFields() {
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items.count, 1)
        let v = items[0]
        XCTAssertEqual(v.videoId, "y3cw_9ELpQw")
        XCTAssertEqual(v.title, "Andrew Strominger: Black Holes")
        XCTAssertEqual(v.durationText, "2:19:34")
        XCTAssertEqual(v.publishedText, "3 years ago")
        XCTAssertEqual(v.viewsText, "3,028,760 views")
        XCTAssertEqual(v.id, "y3cw_9ELpQw")
    }

    // Regression lock: title here is `runs`, not `simpleText`. Copying
    // ChannelSearchParser's simpleText reader would silently drop every title.
    func testTitleComesFromRunsNotSimpleText() {
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].title, "Andrew Strominger: Black Holes")
    }

    func testDescriptionRunsAreJoined() {
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].summary, "Andrew Strominger is a theoretical physicist at Harvard.")
    }

    // Regression lock: these thumbnails are ALREADY absolute (0/30 were
    // protocol-relative), unlike the channel-search page where 20/20 were
    // `//...`. Prefixing unconditionally would corrupt the URL.
    func testAbsoluteThumbnailIsNotDoublePrefixed() {
        let items = videos(ChannelVideoParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString,
                       "https://i.ytimg.com/vi/y3cw_9ELpQw/hqdefault.jpg")
    }

    func testProtocolRelativeThumbnailStillGetsPrefixed() {
        let renderer = """
        {"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"T"}]},
        "thumbnail":{"thumbnails":[{"url":"//i.ytimg.com/vi/abcdefghijk/hq.jpg"}]}}}
        """
        let items = videos(ChannelVideoParser.parse(page(renderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString,
                       "https://i.ytimg.com/vi/abcdefghijk/hq.jpg")
    }

    // 4 of 30 measured results had no descriptionSnippet.
    func testMissingOptionalFieldsDegradeGracefully() {
        let renderer = """
        {"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Bare"}]}}}
        """
        let items = videos(ChannelVideoParser.parse(page(renderer)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Bare")
        XCTAssertNil(items[0].summary)
        XCTAssertNil(items[0].durationText)
        XCTAssertNil(items[0].viewsText)
        XCTAssertNil(items[0].thumbnailURL)
    }

    func testSkipsRenderersMissingVideoIdOrTitle() {
        let renderer = """
        {"videoRenderer":{"title":{"runs":[{"text":"No id"}]}}},
        {"videoRenderer":{"videoId":"abcdefghijk"}},
        \(fullRenderer)
        """
        let items = videos(ChannelVideoParser.parse(page(renderer)))
        XCTAssertEqual(items.map(\.videoId), ["y3cw_9ELpQw"])
    }

    func testDeduplicatesByVideoId() {
        let items = videos(ChannelVideoParser.parse(page("\(fullRenderer),\(fullRenderer)")))
        XCTAssertEqual(items.count, 1)
    }

    func testPreservesResultOrder() {
        let second = fullRenderer.replacingOccurrences(of: "y3cw_9ELpQw", with: "HUkBz-cdB-k")
        let items = videos(ChannelVideoParser.parse(page("\(fullRenderer),\(second)")))
        XCTAssertEqual(items.map(\.videoId), ["y3cw_9ELpQw", "HUkBz-cdB-k"],
                       "relevance order from YouTube must be preserved")
    }

    // Measured: a no-match query returns 200 with ytInitialData present and zero
    // renderers. That is a real answer, not a failure.
    func testZeroResultsIsParsedNotStructureMissing() {
        guard case .parsed(let items) = ChannelVideoParser.parse(page("")) else {
            return XCTFail("zero results must be .parsed")
        }
        XCTAssertTrue(items.isEmpty)
    }

    func testMissingYtInitialDataReportsStructureMissing() {
        guard case .structureMissing = ChannelVideoParser.parse(Data("<html>nope</html>".utf8)) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testMalformedJSONReportsStructureMissing() {
        let html = Data("<script>var ytInitialData = {\"broken\":;</script>".utf8)
        guard case .structureMissing = ChannelVideoParser.parse(html) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testEmptyDataReportsStructureMissing() {
        guard case .structureMissing = ChannelVideoParser.parse(Data()) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testFindsRenderersAtArbitraryDepth() {
        let deep = Data("""
        <script>var ytInitialData = {"a":{"b":[{"c":{"d":[\(fullRenderer)]}}]}};</script>
        """.utf8)
        XCTAssertEqual(videos(ChannelVideoParser.parse(deep)).count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter ChannelVideoParserTests`
Expected: FAIL — `cannot find 'ChannelVideoParser' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/NexaInsight/Logic/ChannelVideoParser.swift`:

```swift
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
```

- [ ] **Step 4: Run tests and the full suite**

Run: `cd ios && swift test --filter ChannelVideoParserTests` → PASS, 14 tests.
Run: `cd ios && swift test` → PASS, 174 tests.

- [ ] **Step 5: Validate against a real response**

The fixture above is hand-built, so confirm the parser handles the live page.
Save a real response and run the parser over it:

```bash
python3 - <<'PY'
import socket, urllib.request, time
_o = socket.getaddrinfo
socket.getaddrinfo = lambda *a, **k: [x for x in _o(*a, **k) if x[0] == socket.AF_INET]
H = {'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
     'Accept-Language': 'en-US,en;q=0.9'}
u = 'https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA/search?query=physics&hl=en&gl=US'
for a in range(3):
    try:
        open('/tmp/live_chan.html','wb').write(urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=30).read())
        print('saved'); break
    except Exception as e:
        print('retry', type(e).__name__); time.sleep(3)
PY

mkdir -p /tmp/cv && cd /tmp/cv
cp ~/git/my_projects/nexa-insight/ios/NexaInsight/Logic/ChannelVideoParser.swift .
cp ~/git/my_projects/nexa-insight/ios/NexaInsight/Models/ChannelVideo.swift .
cat > main.swift <<'SWIFT'
import Foundation
let d = try! Data(contentsOf: URL(fileURLWithPath: "/tmp/live_chan.html"))
switch ChannelVideoParser.parse(d) {
case .structureMissing: print("STRUCTURE_MISSING — parser failed on the real page")
case .parsed(let v):
    print("parsed \(v.count)")
    for x in v.prefix(4) {
        print("  \(x.title.prefix(38)) | \(x.durationText ?? "-") | \(x.publishedText ?? "-")")
    }
}
SWIFT
swiftc -O main.swift ChannelVideoParser.swift ChannelVideo.swift -o cv && ./cv
```

Expected: ~30 parsed, with real durations like `2:19:34` and ages like
`3 years ago`. If it prints `STRUCTURE_MISSING`, the live shape differs from the
fixture — fix the parser, do not weaken the test. Then `rm -rf /tmp/cv /tmp/live_chan.html`.

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Logic/ChannelVideoParser.swift ios/NexaInsightCoreTests/ChannelVideoParserTests.swift
git commit -m "Parse in-channel video search results

A separate parser rather than a copy of ChannelSearchParser: this page
puts the title under runs instead of simpleText, and its thumbnail URLs
are already absolute where the other page's are protocol-relative.
Both differences are locked by tests."
```

---

### Task 3: Channel video requests in the feed service

**Files:**
- Modify: `ios/NexaInsight/Services/DiscoverFeedService.swift`

**Interfaces:**
- Consumes: `ChannelVideoParser`, `ChannelVideoOutcome` (Task 2); `YouTubeChannelLogic.feedURL` and `DiscoverFeedParser` (existing).
- Produces, added to `DiscoverFeedFetching` and implemented on `DiscoverFeedService`:
  - `func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome`
  - `func fetchChannelUploads(channelId: String) async -> [DiscoverEntry]`

`fetchChannelUploads` returns `[DiscoverEntry]` — the RSS type — rather than
`[ChannelVideo]`. That is deliberate: it reuses the already-tested
`DiscoverFeedParser`, and the two lists genuinely carry different fields (RSS has
no duration, search has no ISO date). The view renders each with its own row type
rather than forcing a lossy common shape.

- [ ] **Step 1: Extend the protocol**

```swift
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry]
```

The existing `StubFeedService` in `DiscoverViewModelTests.swift` will stop
compiling. Task 4 fixes it.

- [ ] **Step 2: Implement both on DiscoverFeedService**

```swift
    // In-channel search. This is the surface that reaches the back catalog:
    // results for one query included 3-year-old and 6-year-old uploads, where
    // RSS caps at 15 recent entries.
    //
    // Needs the browser UA like every other YouTube HTML request — with
    // URLSession's default UA, YouTube serves a consent page instead.
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, YouTubeChannelLogic.isValidChannelId(channelId) else {
            return .parsed([])
        }

        var components = URLComponents(string: "https://www.youtube.com/channel/\(channelId)/search")!
        components.queryItems = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "US"),
        ]
        guard let url = components.url else { return .structureMissing }

        var request = URLRequest(url: url)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .structureMissing }
            return ChannelVideoParser.parse(data)
        } catch {
            return .structureMissing
        }
    }

    // The channel's recent uploads, from its RSS feed.
    //
    // RSS rather than the channel videos page: the videos page would need a
    // second parser (it serves lockupViewModel where search serves
    // videoRenderer) and it is the shape YouTube is actively migrating to. RSS
    // is stable Atom XML and already parsed. Cost: 15 entries, no duration.
    //
    // Returns [] on any failure — a missing recency list is not worth an error
    // state when search is the primary surface.
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] {
        guard let url = YouTubeChannelLogic.feedURL(channelId: channelId) else { return [] }
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return [] }
            return DiscoverFeedParser.parse(data)
        } catch {
            return []
        }
    }
```

Note `fetchChannelUploads` sends no User-Agent. The RSS feed was measured working
with no headers at all; only HTML pages need the browser UA.

- [ ] **Step 3: Verify**

Run: `cd ios && swift build`
Expected: the library builds; `DiscoverViewModelTests.swift` fails to compile
because `StubFeedService` lacks the two new methods. That is expected here.

- [ ] **Step 4: Commit**

```bash
git add ios/NexaInsight/Services/DiscoverFeedService.swift
git commit -m "Add in-channel search and uploads requests

Search is the surface that reaches the back catalog; the uploads list
reuses the RSS feed and its existing parser rather than adding a second
scraper for a shape YouTube is actively migrating."
```

---

### Task 4: Channel detail view model

**Files:**
- Create: `ios/NexaInsight/Import/ChannelDetailViewModel.swift`
- Test: `ios/NexaInsightCoreTests/ChannelDetailViewModelTests.swift`
- Modify: `ios/NexaInsightCoreTests/DiscoverViewModelTests.swift` (stub conformance only)

**Interfaces:**
- Consumes: `DiscoverFeedFetching` (Task 3), `ChannelVideo`, `DiscoverEntry`, `Subscription`.
- Produces `@MainActor final class ChannelDetailViewModel: ObservableObject`:
  - `init(subscription: Subscription, service: DiscoverFeedFetching, importedVideoIds: @escaping () -> Set<String>)`
  - `@Published var query`, `results: [ChannelVideo]`, `uploads: [DiscoverEntry]`,
    `searching`, `loadingUploads`, `searchUnavailable`, `searchedTerm: String?`
  - `func loadUploads() async`, `func runSearch() async`, `func clearSearch()`
  - `func isImported(videoId: String) -> Bool`

`importedVideoIds` is injected as a closure rather than the view model holding an
`EpisodeStore`. `EpisodeStore` is SwiftData-backed and awkward to construct in
tests, and the view model only needs the set of ids. The production call site
passes `{ Set(store.downloadedEpisodes().compactMap(\.youtubeId)) }`.

- [ ] **Step 1: Fix the existing stub, then write the failing tests**

In `DiscoverViewModelTests.swift`, add to `StubFeedService`:

```swift
    var videoOutcome: ChannelVideoOutcome = .parsed([])
    var uploads: [DiscoverEntry] = []

    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome { videoOutcome }
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] { uploads }
```

Create `ios/NexaInsightCoreTests/ChannelDetailViewModelTests.swift`:

```swift
import XCTest
@testable import NexaInsightCore

private struct StubService: DiscoverFeedFetching {
    var videoOutcome: ChannelVideoOutcome = .parsed([])
    var uploads: [DiscoverEntry] = []
    var capturedQueries: Captured = Captured()

    final class Captured { var queries: [String] = [] }

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult {
        FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    }
    func resolveChannel(fromURL url: String) async throws -> Subscription {
        throw DiscoverFeedError.unrecognizedChannelLink
    }
    func searchChannels(query: String) async -> ChannelSearchOutcome { .parsed([]) }
    func searchVideos(channelId: String, query: String) async -> ChannelVideoOutcome {
        capturedQueries.queries.append(query)
        return videoOutcome
    }
    func fetchChannelUploads(channelId: String) async -> [DiscoverEntry] { uploads }
}

private func video(_ id: String, _ title: String) -> ChannelVideo {
    ChannelVideo(videoId: id, title: title, durationText: "1:02:03",
                 viewsText: "10K views", publishedText: "2 years ago",
                 summary: "about \(title)", thumbnailURL: nil)
}

private func upload(_ id: String, _ title: String, at seconds: TimeInterval) -> DiscoverEntry {
    DiscoverEntry(videoId: id, channelId: "UCSHZKyawb77ixDdsGog4iWA", title: title,
                  channelTitle: "Chan", published: Date(timeIntervalSince1970: seconds),
                  summary: nil, thumbnailURL: nil, viewCount: nil,
                  watchURL: URL(string: "https://www.youtube.com/watch?v=\(id)")!)
}

@MainActor
final class ChannelDetailViewModelTests: XCTestCase {
    private let sub = Subscription(channelId: "UCSHZKyawb77ixDdsGog4iWA",
                                   title: "Lex Fridman",
                                   addedAt: Date(timeIntervalSince1970: 0))

    private func makeVM(_ service: StubService,
                        imported: Set<String> = []) -> ChannelDetailViewModel {
        ChannelDetailViewModel(subscription: sub, service: service,
                               importedVideoIds: { imported })
    }

    func testLoadUploadsPopulatesRecencyList() async {
        var service = StubService()
        service.uploads = [upload("v2", "Newer", at: 2000), upload("v1", "Older", at: 1000)]

        let vm = makeVM(service)
        await vm.loadUploads()

        XCTAssertEqual(vm.uploads.map(\.videoId), ["v2", "v1"])
        XCTAssertFalse(vm.loadingUploads)
    }

    func testRunSearchPopulatesResults() async {
        var service = StubService()
        service.videoOutcome = .parsed([video("a", "Alpha"), video("b", "Beta")])

        let vm = makeVM(service)
        vm.query = "physics"
        await vm.runSearch()

        XCTAssertEqual(vm.results.map(\.videoId), ["a", "b"])
        XCTAssertEqual(vm.searchedTerm, "physics")
        XCTAssertFalse(vm.searching)
        XCTAssertFalse(vm.searchUnavailable)
    }

    func testSearchPreservesRelevanceOrder() async {
        var service = StubService()
        service.videoOutcome = .parsed([video("old", "3 years ago one"), video("new", "recent one")])

        let vm = makeVM(service)
        vm.query = "physics"
        await vm.runSearch()

        XCTAssertEqual(vm.results.map(\.videoId), ["old", "new"],
                       "YouTube relevance order must not be re-sorted by date")
    }

    // Zero results is a real answer — the UI says "no match", not "broken".
    func testZeroResultsIsNotUnavailable() async {
        var service = StubService()
        service.videoOutcome = .parsed([])

        let vm = makeVM(service)
        vm.query = "zzqqxx"
        await vm.runSearch()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertFalse(vm.searchUnavailable)
        XCTAssertEqual(vm.searchedTerm, "zzqqxx")
    }

    func testStructureMissingSetsUnavailable() async {
        var service = StubService()
        service.videoOutcome = .structureMissing

        let vm = makeVM(service)
        vm.query = "physics"
        await vm.runSearch()

        XCTAssertTrue(vm.searchUnavailable)
        XCTAssertTrue(vm.results.isEmpty)
    }

    func testBlankQueryIssuesNoRequest() async {
        let service = StubService()
        let vm = makeVM(service)
        vm.query = "   "
        await vm.runSearch()

        XCTAssertTrue(service.capturedQueries.queries.isEmpty,
                      "an empty query returns nothing from YouTube, so do not ask")
        XCTAssertNil(vm.searchedTerm)
    }

    func testClearSearchRestoresRecencyList() async {
        var service = StubService()
        service.uploads = [upload("v1", "Older", at: 1000)]
        service.videoOutcome = .parsed([video("a", "Alpha")])

        let vm = makeVM(service)
        await vm.loadUploads()
        vm.query = "physics"
        await vm.runSearch()
        vm.clearSearch()

        XCTAssertTrue(vm.results.isEmpty)
        XCTAssertNil(vm.searchedTerm)
        XCTAssertEqual(vm.query, "")
        XCTAssertEqual(vm.uploads.map(\.videoId), ["v1"], "uploads survive a search")
    }

    // Prevents re-running a pipeline that takes tens of minutes.
    func testIsImportedMarksAlreadyImportedVideos() async {
        let vm = makeVM(StubService(), imported: ["a"])
        XCTAssertTrue(vm.isImported(videoId: "a"))
        XCTAssertFalse(vm.isImported(videoId: "b"))
    }

    // The closure is re-read each call, so a video imported during this session
    // flips to "in library" without rebuilding the view model.
    func testIsImportedReflectsLaterChanges() async {
        final class Box { var ids: Set<String> = [] }
        let box = Box()
        let vm = ChannelDetailViewModel(subscription: sub, service: StubService(),
                                        importedVideoIds: { box.ids })
        XCTAssertFalse(vm.isImported(videoId: "a"))
        box.ids.insert("a")
        XCTAssertTrue(vm.isImported(videoId: "a"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter ChannelDetailViewModelTests`
Expected: FAIL — `cannot find 'ChannelDetailViewModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/NexaInsight/Import/ChannelDetailViewModel.swift`:

```swift
import Foundation

// State for one channel's detail screen.
//
// Search is the primary surface — it is the only measured path that reaches a
// channel's back catalog. The uploads list is a secondary convenience for when
// the user has no particular query in mind.
@MainActor
final class ChannelDetailViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [ChannelVideo] = []
    @Published var uploads: [DiscoverEntry] = []
    @Published var searching = false
    @Published var loadingUploads = false
    // True only when the page could not be read; never for an empty result set.
    @Published var searchUnavailable = false
    @Published var searchedTerm: String?

    let subscription: Subscription
    private let service: DiscoverFeedFetching
    private let importedVideoIds: () -> Set<String>

    init(subscription: Subscription,
         service: DiscoverFeedFetching,
         importedVideoIds: @escaping () -> Set<String>) {
        self.subscription = subscription
        self.service = service
        self.importedVideoIds = importedVideoIds
    }

    var isSearchActive: Bool { searchedTerm != nil }

    func loadUploads() async {
        loadingUploads = true
        defer { loadingUploads = false }
        uploads = await service.fetchChannelUploads(channelId: subscription.channelId)
    }

    func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty query was measured to return zero results, so skip the request.
        guard !trimmed.isEmpty else { return }

        searching = true
        searchUnavailable = false
        defer { searching = false }

        switch await service.searchVideos(channelId: subscription.channelId, query: trimmed) {
        case .parsed(let videos):
            // Keep YouTube's relevance order; do not sort by date.
            results = videos
            searchedTerm = trimmed
        case .structureMissing:
            results = []
            searchedTerm = trimmed
            searchUnavailable = true
        }
    }

    func clearSearch() {
        results = []
        searchedTerm = nil
        searchUnavailable = false
        query = ""
    }

    // Re-reads the closure each call so a video imported during this session
    // flips to "in library" without rebuilding the view model.
    func isImported(videoId: String) -> Bool {
        importedVideoIds().contains(videoId)
    }
}
```

- [ ] **Step 4: Run tests and the full suite**

Run: `cd ios && swift test --filter ChannelDetailViewModelTests` → PASS, 9 tests.
Run: `cd ios && swift test` → PASS, 183 tests.

- [ ] **Step 5: Commit**

```bash
git add ios/NexaInsight/Import/ChannelDetailViewModel.swift \
        ios/NexaInsightCoreTests/ChannelDetailViewModelTests.swift \
        ios/NexaInsightCoreTests/DiscoverViewModelTests.swift
git commit -m "Add channel detail view model

Imported-video ids arrive as a closure rather than an EpisodeStore
reference: the view model only needs the id set, and re-reading it each
call lets a row flip to 'in library' mid-session.

Search results keep YouTube's relevance order rather than being sorted
by date, since relevance is the point of searching."
```

---

### Task 5: Channel detail screen and navigation

**Files:**
- Create: `ios/NexaInsight/Views/ChannelDetailView.swift`
- Modify: `ios/NexaInsight/Views/LibraryView.swift`

A new file rather than more of `LibraryView.swift`, which is already 2350+ lines.

Locate declarations by name, not line number:
```bash
grep -n "private struct DiscoverChannelFilters\|private struct ChannelSearchRow\|navigationDestination" ios/NexaInsight/Views/LibraryView.swift
```

**Interfaces:**
- Consumes: `ChannelDetailViewModel`, `ChannelVideo`, `DiscoverEntry`, `Subscription`, `EpisodeStore`.
- Produces: `ChannelDetailView` (internal, not private — `LibraryView` references it), plus private `ChannelVideoRow` and `ChannelUploadRow`.

Design-system components already exist with these signatures, confirmed against
`DesignSystem.swift`:
`NXPrimaryButton(title:systemName:disabled:action:)`,
`NXSecondaryButton(title:systemName:action:)`,
`NXTextButton(title:systemName:disabled:action:)`,
`NXSectionHeader(title:actionTitle:action:)`, `NXTag(text:tint:)`,
`NXErrorState(message:retry:)`, `NXEmptyState(title:message:actionTitle:action:)`.

- [ ] **Step 1: Write the screen**

Create `ios/NexaInsight/Views/ChannelDetailView.swift`:

```swift
#if os(iOS)
import SwiftUI

// One channel: search inside it, or browse its recent uploads.
//
// Search is the primary surface because it is the only path that reaches the
// back catalog — a channel with years of history cannot be served by a
// "latest N" list.
struct ChannelDetailView: View {
    @StateObject var vm: ChannelDetailViewModel
    let importing: Bool
    let onImport: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                searchField

                if vm.isSearchActive {
                    searchSection
                } else {
                    uploadsSection
                }
            }
            .padding(.horizontal, NXSpacing.x4)
            .padding(.vertical, NXSpacing.x4)
        }
        .background(NXColor.background(scheme))
        .navigationTitle(vm.subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if vm.uploads.isEmpty { await vm.loadUploads() } }
    }

    private var searchField: some View {
        HStack(spacing: NXSpacing.x3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
            TextField("Search in this channel", text: $vm.query)
                .font(NXFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await vm.runSearch() } }
            if vm.isSearchActive || !vm.query.isEmpty {
                Button(action: vm.clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NXSpacing.x3)
        .frame(height: 48)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
    }

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Results")

            if vm.searchUnavailable {
                // Distinct from "no match": the page could not be read at all,
                // so point at the fallback that needs no page structure.
                NXErrorState(
                    message: "Browsing this channel is unavailable right now. You can paste a video link on Discover to import it.",
                    retry: { Task { await vm.runSearch() } })
            } else if vm.searching {
                ProgressView("Searching").font(NXFont.auxiliary)
            } else if vm.results.isEmpty {
                Text("No videos in this channel match \(vm.searchedTerm ?? "").")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                rows(vm.results)
                // Pagination would need the innertube API, so the cap is real
                // and stated rather than silently truncating.
                Text("Showing the top \(vm.results.count) matches.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
        }
    }

    @ViewBuilder
    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Recent uploads")

            if vm.loadingUploads && vm.uploads.isEmpty {
                ProgressView("Loading").font(NXFont.auxiliary)
            } else if vm.uploads.isEmpty {
                Text("Could not load recent uploads. Try searching instead.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.uploads) { entry in
                        ChannelUploadRow(
                            entry: entry,
                            imported: vm.isImported(videoId: entry.videoId),
                            importing: importing,
                            onImport: { onImport(entry.watchURL.absoluteString) })
                        if entry.id != vm.uploads.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
                // The feed itself caps at 15; searching reaches older uploads.
                Text("The channel feed lists its \(vm.uploads.count) most recent uploads. Search to find older ones.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rows(_ videos: [ChannelVideo]) -> some View {
        VStack(spacing: 0) {
            ForEach(videos) { video in
                ChannelVideoRow(
                    video: video,
                    imported: vm.isImported(videoId: video.videoId),
                    importing: importing,
                    onImport: { if let url = video.watchURL { onImport(url.absoluteString) } })
                if video.id != videos.last?.id {
                    Divider().overlay(NXColor.border(scheme))
                }
            }
        }
    }
}

private struct ChannelVideoRow: View {
    let video: ChannelVideo
    let imported: Bool
    let importing: Bool
    let onImport: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Text(video.title)
                .font(NXFont.bodyMedium)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(byline)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
            if let summary = video.summary {
                Text(summary)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .lineLimit(2)
            }
            action
        }
        .padding(.vertical, NXSpacing.x3)
    }

    // Duration first: it is the strongest signal for whether a 4-hour episode is
    // worth committing to, and the pipeline run is expensive.
    private var byline: String {
        [video.durationText, video.publishedText, video.viewsText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        if imported {
            NXTag(text: "In your library", tint: NXColor.success)
        } else {
            NXSecondaryButton(
                title: importing ? "Adding" : "Add to Nexa",
                systemName: importing ? "clock" : "plus",
                action: onImport)
        }
    }
}

private struct ChannelUploadRow: View {
    let entry: DiscoverEntry
    let imported: Bool
    let importing: Bool
    let onImport: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Text(entry.title)
                .font(NXFont.bodyMedium)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
            // No duration here — the RSS feed carries none. Reusing
            // DiscoverFormat.byline keeps this consistent with the Discover feed.
            Text(DiscoverFormat.byline(entry))
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
            if imported {
                NXTag(text: "In your library", tint: NXColor.success)
            } else {
                NXSecondaryButton(
                    title: importing ? "Adding" : "Add to Nexa",
                    systemName: importing ? "clock" : "plus",
                    action: onImport)
            }
        }
        .padding(.vertical, NXSpacing.x3)
    }
}
#endif
```

`DiscoverFormat.byline` is reachable from this file: `DiscoverFormat` is declared
`internal` (not `private`) at `LibraryView.swift:1157`, confirmed. No change is
needed there.

- [ ] **Step 2: Add navigation from LibraryView**

`Subscription` is already `Codable, Identifiable, Equatable`; add `Hashable` to it
in `ios/NexaInsight/Models/DiscoverEntry.swift` so it can be a navigation value:

```swift
struct Subscription: Codable, Identifiable, Equatable, Hashable {
```

In `LibraryView.body`, next to the existing `navigationDestination(for: Int.self)`:

```swift
            .navigationDestination(for: Subscription.self) { subscription in
                ChannelDetailView(
                    vm: ChannelDetailViewModel(
                        subscription: subscription,
                        service: DiscoverFeedService(),
                        importedVideoIds: { Set(store.downloadedEpisodes().compactMap(\.youtubeId)) }),
                    importing: vm.importing,
                    onImport: addToNexa)
            }
```

Note this reads `youtubeId` — the one place this round still depends on that
YouTube-specific field. When it becomes `source_id`, this moves with it.

- [ ] **Step 3: Add the two entry points**

In `DiscoverChannelFilters`, make each subscription chip a `NavigationLink` instead
of a filter button, or add a separate "Open" affordance. Simplest correct change:
add a subscriptions list section above the feed when not searching, each row a
`NavigationLink(value: subscription)`. Keep the existing filter chips — filtering
the feed and opening a channel are different intents and both are useful.

In `ChannelSearchRow` (the channel search result row), add a browse action beside
Follow so a user can inspect a channel before subscribing:

```swift
            NXTextButton(title: "View", systemName: "chevron.right", action: onOpen)
```

Use `NavigationLink(value:)` directly in the row — no closure threading and no
`NavigationPath` binding. This matches the codebase, which uses
`NavigationLink(value:)` in five places (`LibraryView.swift:1559`, `1597`, `1624`,
`1681`) and holds no `NavigationPath` anywhere:

```swift
            NavigationLink(value: Subscription(channelId: result.channelId,
                                               title: result.title,
                                               addedAt: Date())) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
            .buttonStyle(.plain)
```

Building a `Subscription` here for a channel the user has not subscribed to is
intentional — it is the navigation value, not a stored record. Nothing is written
to `SubscriptionStore` unless the user taps Follow.

- [ ] **Step 4: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 183 tests.

- [ ] **Step 5: Build for the simulator**

```bash
cd ios && ./generate.sh
xcodebuild -project NexaInsight.xcodeproj -target NexaInsight \
  -sdk iphonesimulator -configuration Debug -arch arm64 \
  EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets' \
  ASSETCATALOG_COMPILER_APPICON_NAME='' \
  CONFIGURATION_BUILD_DIR=/tmp/nexa-build build 2>&1 | grep -E "^\*\*|error:"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Verify on the simulator against live data**

Seed a subscription so the channel is reachable without typing:

```bash
DEV=$(xcrun simctl list devices available | grep -m1 'iPhone 15' | grep -o '[0-9A-F-]\{36\}')
xcrun simctl boot $DEV 2>/dev/null; open -a Simulator
xcrun simctl install $DEV "/tmp/nexa-build/Nexa Insight.app"
JSON='[{"channelId":"UCSHZKyawb77ixDdsGog4iWA","title":"Lex Fridman","addedAt":0}]'
xcrun simctl spawn $DEV defaults write com.nexainsight.app discoverSubscriptions \
  -data "$(printf '%s' "$JSON" | xxd -p | tr -d '\n')"
xcrun simctl launch $DEV com.nexainsight.app
sleep 4
xcrun simctl io $DEV screenshot /tmp/chan1.png
```

Read the screenshot, then open the channel and search for `physics`. Compare
against live ground truth:

```bash
python3 - <<'PY'
import socket, urllib.request, re, json, time
_o = socket.getaddrinfo
socket.getaddrinfo = lambda *a, **k: [x for x in _o(*a, **k) if x[0] == socket.AF_INET]
def walk(o, key):
    if isinstance(o, dict):
        if key in o: yield o[key]
        for v in o.values(): yield from walk(v, key)
    elif isinstance(o, list):
        for v in o: yield from walk(v, key)
H = {'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
     'Accept-Language': 'en-US,en;q=0.9'}
u = 'https://www.youtube.com/channel/UCSHZKyawb77ixDdsGog4iWA/search?query=physics&hl=en&gl=US'
for a in range(3):
    try:
        h = urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=30).read().decode('utf-8','ignore'); break
    except Exception: time.sleep(3)
vs = list(walk(json.loads(re.search(r'var ytInitialData = (\{.*?\});</script>', h).group(1)), 'videoRenderer'))
for v in vs[:5]:
    print((v.get('title',{}).get('runs') or [{}])[0].get('text','')[:44],
          '|', (v.get('lengthText') or {}).get('simpleText'),
          '|', (v.get('publishedTimeText') or {}).get('simpleText'))
PY
```

Check four things:
1. Titles in the screenshot match the script's output.
2. Durations appear (`2:19:34`-style). Their absence means `lengthText` was missed.
3. **At least one result is years old.** That is the whole point — if everything
   is recent, search is not reaching the back catalog and something is wrong.
4. Tapping "Add to Nexa" starts an import; on return the row shows "In your
   library".

If synthetic clicks cannot drive the simulator (other apps steal focus on this
machine — guard every click by checking the frontmost process is `Simulator` and
abort otherwise), say so plainly rather than reporting the UI verified. Parsing is
covered by tests; the live request can be verified by compiling
`DiscoverFeedService` into a small host binary and calling
`searchVideos(channelId:query:)` directly, as was done for the previous round.

- [ ] **Step 7: Commit**

```bash
git add ios/NexaInsight/Views/ChannelDetailView.swift \
        ios/NexaInsight/Views/LibraryView.swift \
        ios/NexaInsight/Models/DiscoverEntry.swift
git commit -m "Add channel detail screen with in-channel search

Search is the primary surface since it is the only path that reaches a
channel's back catalog; the uploads list is the no-query fallback.
Already-imported videos are marked so a user cannot re-run a pipeline
that takes tens of minutes, and both list caps are stated rather than
silently truncating."
```

---

## Verification constraints

Recorded so an implementer does not mistake an environment limit for a bug:

- `curl` cannot reach YouTube from this sandbox (no IPv6 route, then timeout).
  Use Python `urllib` forced to IPv4, with the browser User-Agent. Transient
  `URLError`/SSL EOF failures need retries — one failure does not mean an
  endpoint is down.
- Every YouTube HTML request needs the browser User-Agent. Without it the
  response is a consent page: HTTP 200, ~475 KB, zero renderers. The RSS feed
  needs no headers.
- `xcodebuild -destination 'platform=iOS Simulator,...'` cannot resolve on this
  machine. Use `-target` plus `-sdk iphonesimulator`.
- The asset catalog must be excluded from simulator builds here; `actool` rejects
  the installed SDK/runtime pair. Affects the app icon only.
- Synthetic clicks into the simulator are unreliable — other apps steal focus
  mid-sequence. Guard every click on the frontmost process being `Simulator`.
