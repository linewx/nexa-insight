# Discover Channel Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users find and subscribe to YouTube channels by keyword or preset shortcut term, instead of having to paste an exact channel URL.

**Architecture:** Pure JSON parsing goes in `NexaInsight/Logic/`; the search call joins the existing `DiscoverFeedFetching` protocol in `Services/`. `DiscoverViewModel` gains search state. `DiscoverView` gains a search results section and shortcut chips. No backend changes.

**Tech Stack:** Swift 5.9, SwiftUI, `URLSession`, `JSONSerialization`, XCTest. All system frameworks — no new dependencies.

**Prerequisite:** The work from `2026-07-31-discover-real-sources.md` must be merged or present. This plan extends `DiscoverViewModel`, `DiscoverFeedFetching`, `SubscriptionStore`, and `DiscoverView`, all of which that plan created.

## Global Constraints

- No new package dependencies; no backend changes.
- All new tests pass with `cd ios && swift test` — offline, no network. Parser tests use inline JSON string fixtures.
- Pure logic in `NexaInsight/Logic/`; stateful services in `NexaInsight/Services/`.
- Search URL must be exactly: `https://www.youtube.com/results?search_query=<escaped>&sp=EgIQAg%3D%3D&hl=en&gl=US` plus the header `Accept-Language: en-US,en;q=0.9`.
- Parse by extracting JSON from `var ytInitialData = {...};</script>` then walking for `channelRenderer`. Never regex for `"channelId":"UC..."` directly.
- A missing `ytInitialData` and a zero-result query are DIFFERENT states and must stay distinguishable.
- The paste-URL path (`AddChannelSheet`) is never removed.

## Verified facts this plan depends on

Each was measured against the live site, not assumed. The plan encodes them as
tests so a future reader does not have to re-derive them.

| Fact | Measurement |
|---|---|
| `sp=EgIQAg%3D%3D` restricts to channels | with it: 20 channels / 0 videos; without: 0 channels / 19 videos |
| Locale must be pinned **twice** | no locale hint returned Japanese `チャンネル登録者数 2.04万人`; only `hl=en&gl=US` **and** `Accept-Language` reliably gave `1.67M subscribers` |
| `subscriberCountText` holds the **@handle** | e.g. `@restishistorypod` |
| `videoCountText` holds the **subscriber count** | e.g. `541K subscribers` |
| Thumbnails are protocol-relative | 20/20 were `//yt3.googleusercontent.com/...` |
| `descriptionSnippet.runs` must be **joined** | 1–5 segments per result; first run alone yields fragments like `"My "` or `"Welcome to "` |
| No results ≠ broken parse | gibberish query → HTTP 200, `ytInitialData` present, 0 renderers |
| Only one assignment form exists | `var ytInitialData = {...};</script>` matched; `ytInitialData"] = {...}` did not |
| Shorter terms give worse results | `ai` returned 감다살 AI / あい。; `documentary` and `psychology` were most on-target |

## Build and test commands

```bash
# Unit tests (offline, macOS — use for every task)
cd ios && swift test

# Simulator build (this machine needs these workarounds)
cd ios && ./generate.sh
xcodebuild -project NexaInsight.xcodeproj -target NexaInsight \
  -sdk iphonesimulator -configuration Debug -arch arm64 \
  EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets' \
  ASSETCATALOG_COMPILER_APPICON_NAME='' \
  CONFIGURATION_BUILD_DIR=/tmp/nexa-build build
```

`actool` rejects this machine's SDK/runtime pair, so the asset catalog (app icon
only, no code references) is excluded. `-destination` cannot resolve here, hence
`-target` + `-sdk`.

## File structure

| File | Responsibility |
|---|---|
| Create `NexaInsight/Models/ChannelSearchResult.swift` | The search result model |
| Create `NexaInsight/Logic/ChannelSearchParser.swift` | Pure: `ytInitialData` JSON → `[ChannelSearchResult]`, with a distinct signal for structural failure |
| Create `NexaInsight/Logic/ChannelSearchTerms.swift` | The eight shortcut terms |
| Modify `NexaInsight/Services/DiscoverFeedService.swift` | Add `searchChannels(query:)` to the protocol and implementation |
| Modify `NexaInsight/Import/DiscoverViewModel.swift` | Search state, run/clear search, subscribe from a result |
| Modify `NexaInsight/Views/LibraryView.swift` | Shortcut chips, results list, wire the existing search field |
| Create `NexaInsightCoreTests/ChannelSearchParserTests.swift` | Task 2 tests |
| Modify `NexaInsightCoreTests/DiscoverViewModelTests.swift` | Task 4 tests |

---

### Task 1: Model and shortcut terms

Two small pure-data files with no logic to test beyond their own shape, so they
are grouped into one task.

**Files:**
- Create: `ios/NexaInsight/Models/ChannelSearchResult.swift`
- Create: `ios/NexaInsight/Logic/ChannelSearchTerms.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct ChannelSearchResult`, `enum ChannelSearchTerms`.

- [ ] **Step 1: Write the model**

Create `ios/NexaInsight/Models/ChannelSearchResult.swift`:

```swift
import Foundation

// One channel from a search.
//
// Two of these fields come from response keys whose names contradict their
// contents: handle is read from `subscriberCountText` and subscriberText from
// `videoCountText`. Verified across several queries with locale pinned. The
// names here describe what the values ARE, not where they came from.
struct ChannelSearchResult: Identifiable, Equatable {
    let channelId: String
    let title: String
    let handle: String?
    let subscriberText: String?
    let summary: String?
    let thumbnailURL: URL?

    var id: String { channelId }
}
```

- [ ] **Step 2: Write the shortcut terms**

Create `ios/NexaInsight/Logic/ChannelSearchTerms.swift`:

```swift
import Foundation

// Preset search terms shown as chips so a first-time user has somewhere to
// start. These are strings, NOT a category taxonomy — tapping one runs a real
// search, so there is no term-to-channel mapping to maintain or go stale. That
// is the difference from the invented DiscoverKind list this replaced.
//
// Thirteen candidates were tested against live results; these eight returned 20
// on-topic channels each. Rejected: `ai` (matched 감다살 AI, あい。), `health`
// (a band and an auto-generated Topic channel), `interview` (job-interview
// content), `business` and `education` (mixed with low-quality channels).
//
// The pattern worth remembering: shorter terms give worse results. Prefer
// specific subject names over abbreviations or broad words.
enum ChannelSearchTerms {
    static let all = [
        "podcast",
        "history",
        "philosophy",
        "science",
        "technology",
        "economics",
        "psychology",
        "documentary",
    ]
}
```

- [ ] **Step 3: Verify it compiles and the suite still passes**

Run: `cd ios && swift build && swift test`
Expected: build succeeds; 139 tests pass (unchanged).

- [ ] **Step 4: Commit**

```bash
git add ios/NexaInsight/Models/ChannelSearchResult.swift ios/NexaInsight/Logic/ChannelSearchTerms.swift
git commit -m "Add channel search result model and shortcut terms

Field names describe the values rather than their misnamed response keys.
Shortcut terms are plain strings, so there is no taxonomy to maintain;
thirteen were tested against live results and five rejected."
```

---

### Task 2: Search response parser

The heart of this feature. Pure function, offline-testable, and where all four
response traps get locked down by tests.

**Files:**
- Create: `ios/NexaInsight/Logic/ChannelSearchParser.swift`
- Test: `ios/NexaInsightCoreTests/ChannelSearchParserTests.swift`

**Interfaces:**
- Consumes: `ChannelSearchResult` (Task 1).
- Produces:
  - `enum ChannelSearchParser`
  - `enum ChannelSearchOutcome { case parsed([ChannelSearchResult]); case structureMissing }`
  - `static func parse(_ data: Data) -> ChannelSearchOutcome`

`structureMissing` exists because the UI must distinguish "YouTube returned no
matches" from "we could not understand the page". Verified: a gibberish query
returns HTTP 200 with `ytInitialData` present and zero renderers, so an empty
result set is a legitimate answer, not a failure.

- [ ] **Step 1: Write the failing tests**

Create `ios/NexaInsightCoreTests/ChannelSearchParserTests.swift`:

```swift
import XCTest
@testable import NexaInsightCore

final class ChannelSearchParserTests: XCTestCase {
    // Shaped exactly like a real response: the renderer is nested inside
    // itemSectionRenderer contents, description arrives as multiple runs, and
    // the thumbnail URL is protocol-relative.
    private func page(_ renderersJSON: String) -> Data {
        Data("""
        <html><body><script>
        var ytInitialData = {"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":
        {"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[\(renderersJSON)]}}]}}}}};</script>
        </body></html>
        """.utf8)
    }

    private let fullRenderer = """
    {"channelRenderer":{
      "channelId":"UCSHZKyawb77ixDdsGog4iWA",
      "title":{"simpleText":"Philosophy Tube"},
      "subscriberCountText":{"simpleText":"@PhilosophyTube"},
      "videoCountText":{"simpleText":"1.67M subscribers"},
      "descriptionSnippet":{"runs":[{"text":"I'm giving away a "},{"text":"philosophy","bold":true},{"text":" degree for free."}]},
      "thumbnail":{"thumbnails":[{"url":"//yt3.googleusercontent.com/ytc/abc=s88","width":88,"height":88}]}
    }}
    """

    private func results(_ outcome: ChannelSearchOutcome) -> [ChannelSearchResult] {
        guard case .parsed(let items) = outcome else {
            XCTFail("expected .parsed, got \(outcome)")
            return []
        }
        return items
    }

    func testParsesAllFields() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].channelId, "UCSHZKyawb77ixDdsGog4iWA")
        XCTAssertEqual(items[0].title, "Philosophy Tube")
        XCTAssertEqual(items[0].id, "UCSHZKyawb77ixDdsGog4iWA")
    }

    // Regression lock #1. Verified against live results: the response key
    // `subscriberCountText` carries the @handle and `videoCountText` carries the
    // subscriber count. Reading by name puts a handle where a count belongs.
    func testFieldNamesAreMislabeledInTheResponse() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].handle, "@PhilosophyTube",
                       "handle must come from subscriberCountText")
        XCTAssertEqual(items[0].subscriberText, "1.67M subscribers",
                       "subscriberText must come from videoCountText")
    }

    // Regression lock #2. All 20 live thumbnails were protocol-relative; without
    // a scheme the URL will not load.
    func testProtocolRelativeThumbnailGetsHTTPSPrefix() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString,
                       "https://yt3.googleusercontent.com/ytc/abc=s88")
    }

    // Regression lock #3. descriptionSnippet.runs had 1-5 segments across live
    // results; taking only the first yields fragments like "I'm giving away a ".
    func testDescriptionRunsAreJoined() {
        let items = results(ChannelSearchParser.parse(page(fullRenderer)))
        XCTAssertEqual(items[0].summary, "I'm giving away a philosophy degree for free.")
    }

    func testAbsoluteThumbnailURLIsLeftAlone() {
        let renderer = """
        {"channelRenderer":{"channelId":"UCSHZKyawb77ixDdsGog4iWA","title":{"simpleText":"T"},
        "thumbnail":{"thumbnails":[{"url":"https://example.com/a.jpg"}]}}}
        """
        let items = results(ChannelSearchParser.parse(page(renderer)))
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString, "https://example.com/a.jpg")
    }

    func testMissingOptionalFieldsDegradeGracefully() {
        let renderer = """
        {"channelRenderer":{"channelId":"UCSHZKyawb77ixDdsGog4iWA","title":{"simpleText":"Bare"}}}
        """
        let items = results(ChannelSearchParser.parse(page(renderer)))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Bare")
        XCTAssertNil(items[0].handle)
        XCTAssertNil(items[0].subscriberText)
        XCTAssertNil(items[0].summary)
        XCTAssertNil(items[0].thumbnailURL)
    }

    func testSkipsRenderersMissingChannelIdOrTitle() {
        let renderer = """
        {"channelRenderer":{"title":{"simpleText":"No id"}}},
        {"channelRenderer":{"channelId":"UCSHZKyawb77ixDdsGog4iWA"}},
        \(fullRenderer)
        """
        let items = results(ChannelSearchParser.parse(page(renderer)))
        XCTAssertEqual(items.map(\.channelId), ["UCSHZKyawb77ixDdsGog4iWA"])
    }

    func testDeduplicatesByChannelId() {
        let items = results(ChannelSearchParser.parse(page("\(fullRenderer),\(fullRenderer)")))
        XCTAssertEqual(items.count, 1)
    }

    // A real no-match response: 200, ytInitialData present, zero renderers.
    // This is a legitimate empty answer and must NOT be reported as a failure.
    func testZeroResultsIsParsedNotStructureMissing() {
        let outcome = ChannelSearchParser.parse(page(""))
        guard case .parsed(let items) = outcome else {
            return XCTFail("zero results must be .parsed, not .structureMissing")
        }
        XCTAssertTrue(items.isEmpty)
    }

    // The distinct failure: the page shape changed and ytInitialData is gone.
    func testMissingYtInitialDataReportsStructureMissing() {
        let html = Data("<html><body>no data here</body></html>".utf8)
        guard case .structureMissing = ChannelSearchParser.parse(html) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testMalformedJSONReportsStructureMissing() {
        let html = Data("<script>var ytInitialData = {\"broken\":;</script>".utf8)
        guard case .structureMissing = ChannelSearchParser.parse(html) else {
            return XCTFail("expected .structureMissing")
        }
    }

    func testEmptyDataReportsStructureMissing() {
        guard case .structureMissing = ChannelSearchParser.parse(Data()) else {
            return XCTFail("expected .structureMissing")
        }
    }

    // Renderers are nested at varying depths in real responses, so the walk must
    // be recursive rather than assuming a fixed path.
    func testFindsRenderersAtArbitraryDepth() {
        let deep = Data("""
        <script>var ytInitialData = {"a":{"b":{"c":[{"d":{"e":[\(fullRenderer)]}}]}}};</script>
        """.utf8)
        XCTAssertEqual(results(ChannelSearchParser.parse(deep)).count, 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter ChannelSearchParserTests`
Expected: FAIL — `cannot find 'ChannelSearchParser' in scope`.

- [ ] **Step 3: Write the implementation**

Create `ios/NexaInsight/Logic/ChannelSearchParser.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && swift test --filter ChannelSearchParserTests`
Expected: PASS, 13 tests.

- [ ] **Step 5: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 152 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Logic/ChannelSearchParser.swift ios/NexaInsightCoreTests/ChannelSearchParserTests.swift
git commit -m "Parse YouTube channel search results

Locks down four measured response quirks: two keys whose names
contradict their contents, protocol-relative thumbnail URLs,
descriptions split across runs that must be joined, and a zero-result
query being a valid answer rather than a parse failure."
```

---

### Task 3: Search request in the feed service

Adds the network call. Kept thin so the view model stays testable through the
protocol.

**Files:**
- Modify: `ios/NexaInsight/Services/DiscoverFeedService.swift`

**Interfaces:**
- Consumes: `ChannelSearchParser`, `ChannelSearchOutcome` (Task 2).
- Produces: `func searchChannels(query: String) async -> ChannelSearchOutcome`
  added to `DiscoverFeedFetching` and implemented on `DiscoverFeedService`.

Returning `ChannelSearchOutcome` rather than throwing keeps the
"no matches" / "cannot read the page" distinction intact all the way to the UI.
A network error maps to `.structureMissing` because from the user's side both
mean "search is not working right now, use the paste fallback".

- [ ] **Step 1: Extend the protocol**

Add to `protocol DiscoverFeedFetching`:

```swift
    func searchChannels(query: String) async -> ChannelSearchOutcome
```

Existing conformances that do not implement it will fail to compile; Task 4
updates the test stub.

- [ ] **Step 2: Implement it on DiscoverFeedService**

Add inside `struct DiscoverFeedService`:

```swift
    // Searches channels via YouTube's public results page.
    //
    // All three query parameters are load-bearing and were measured:
    //   sp=EgIQAg== restricts results to channels (with it: 20 channels, 0
    //     videos; without it: 0 channels, 19 videos)
    //   hl=en&gl=US pins the response language — AND the Accept-Language header
    //     is also required. With neither, results came back Japanese
    //     ("チャンネル登録者数 2.04万人"); only pinning both reliably produced
    //     "1.67M subscribers".
    func searchChannels(query: String) async -> ChannelSearchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .parsed([]) }

        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: trimmed),
            URLQueryItem(name: "sp", value: "EgIQAg=="),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "gl", value: "US"),
        ]
        guard let url = components.url else { return .structureMissing }

        var request = URLRequest(url: url)
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { return .structureMissing }
            return ChannelSearchParser.parse(data)
        } catch {
            // A transport failure is indistinguishable from a broken page as far
            // as the user's next action goes: fall back to pasting a link.
            return .structureMissing
        }
    }
```

Note `URLComponents` percent-encodes `sp=EgIQAg==` for you, producing
`sp=EgIQAg%3D%3D`. Do not pre-encode it or the `%` itself gets escaped.

- [ ] **Step 3: Verify it compiles**

Run: `cd ios && swift build`
Expected: one error, in `DiscoverViewModelTests.swift` — `StubFeedService` does
not yet conform. That is expected and Task 4 fixes it.

- [ ] **Step 4: Commit**

```bash
git add ios/NexaInsight/Services/DiscoverFeedService.swift
git commit -m "Add channel search request to the feed service

All three query parameters are load-bearing: sp restricts results to
channels, and the locale must be pinned in both the query and the
Accept-Language header or the response comes back in another language.

Transport failures map to structureMissing because either way the user's
next move is the paste-a-link fallback."
```

---

### Task 4: Search state in the view model

**Files:**
- Modify: `ios/NexaInsight/Import/DiscoverViewModel.swift`
- Test: `ios/NexaInsightCoreTests/DiscoverViewModelTests.swift`

**Interfaces:**
- Consumes: `ChannelSearchOutcome`, `ChannelSearchResult`, `SubscriptionStore`.
- Produces on `DiscoverViewModel`:
  - `@Published var searchResults: [ChannelSearchResult]`
  - `@Published var searching: Bool`
  - `@Published var searchUnavailable: Bool`
  - `@Published var searchedTerm: String?`
  - `func runSearch(_ term: String) async`
  - `func clearSearch()`
  - `func subscribe(to result: ChannelSearchResult) async`
  - `func isFollowing(_ result: ChannelSearchResult) -> Bool`

`searchedTerm` records what produced the current results so the UI can say
"No channels found for X" and highlight the active chip.

`subscribe(to:)` does NOT reuse `resolveChannel` — a search result already has
its `channelId`, so handle resolution would be a pointless extra request. That
path stays for pasted URLs.

- [ ] **Step 1: Update the stub, then write the failing tests**

In `DiscoverViewModelTests.swift`, extend `StubFeedService`:

```swift
private struct StubFeedService: DiscoverFeedFetching {
    var result = FeedFetchResult(entries: [], failedChannelIds: [], channelTitles: [:])
    var resolved: Subscription?
    var resolveError: Error?
    var searchOutcome: ChannelSearchOutcome = .parsed([])

    func fetchFeeds(channelIds: [String]) async -> FeedFetchResult { result }

    func searchChannels(query: String) async -> ChannelSearchOutcome { searchOutcome }

    func resolveChannel(fromURL url: String) async throws -> Subscription {
        if let resolveError { throw resolveError }
        guard let resolved else { throw DiscoverFeedError.unrecognizedChannelLink }
        return resolved
    }
}
```

Add this helper next to the existing `entry(...)` helper:

```swift
private func searchResult(_ id: String, _ title: String) -> ChannelSearchResult {
    ChannelSearchResult(
        channelId: id, title: title, handle: "@\(title.lowercased())",
        subscriberText: "100K subscribers", summary: "about \(title)",
        thumbnailURL: nil)
}
```

Then append these tests to `DiscoverViewModelTests`:

```swift
    func testRunSearchPopulatesResults() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha"), searchResult("UCb", "Beta")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")

        XCTAssertEqual(vm.searchResults.map(\.channelId), ["UCa", "UCb"])
        XCTAssertEqual(vm.searchedTerm, "philosophy")
        XCTAssertFalse(vm.searching)
        XCTAssertFalse(vm.searchUnavailable)
    }

    // Zero results is a real answer, not a malfunction: the UI shows "nothing
    // found", not "search is broken".
    func testZeroResultsIsNotUnavailable() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("zzqqxx")

        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertFalse(vm.searchUnavailable, "an empty result set is not a failure")
        XCTAssertEqual(vm.searchedTerm, "zzqqxx")
    }

    // The other case: the page shape changed. This one DOES tell the user search
    // is unavailable and to paste a link instead.
    func testStructureMissingSetsUnavailable() async {
        var service = StubFeedService()
        service.searchOutcome = .structureMissing

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")

        XCTAssertTrue(vm.searchUnavailable)
        XCTAssertTrue(vm.searchResults.isEmpty)
    }

    func testBlankSearchIsIgnored() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("   ")

        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertNil(vm.searchedTerm)
    }

    func testClearSearchResetsState() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")
        vm.clearSearch()

        XCTAssertTrue(vm.searchResults.isEmpty)
        XCTAssertNil(vm.searchedTerm)
        XCTAssertFalse(vm.searchUnavailable)
    }

    func testSubscribeFromResultStoresAndRefreshes() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCnew", "New Channel")])
        service.result = FeedFetchResult(
            entries: [entry("v1", channel: "UCnew", title: "First", at: 1000)],
            failedChannelIds: [], channelTitles: [:])

        let store = makeStore()
        let vm = DiscoverViewModel(store: store, service: service)
        await vm.runSearch("philosophy")
        await vm.subscribe(to: vm.searchResults[0])

        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCnew"])
        XCTAssertEqual(store.subscriptions[0].title, "New Channel")
        XCTAssertEqual(vm.entries.map(\.videoId), ["v1"])
    }

    func testIsFollowingReflectsStore() async {
        let store = makeStore(["UCa"])
        let vm = DiscoverViewModel(store: store, service: StubFeedService())
        XCTAssertTrue(vm.isFollowing(searchResult("UCa", "Alpha")))
        XCTAssertFalse(vm.isFollowing(searchResult("UCb", "Beta")))
    }

    func testSubscribingKeepsResultsVisibleSoFollowingStateShows() async {
        var service = StubFeedService()
        service.searchOutcome = .parsed([searchResult("UCa", "Alpha"), searchResult("UCb", "Beta")])

        let vm = DiscoverViewModel(store: makeStore(), service: service)
        await vm.runSearch("philosophy")
        await vm.subscribe(to: vm.searchResults[0])

        XCTAssertEqual(vm.searchResults.count, 2, "results stay so the row can flip to Following")
        XCTAssertTrue(vm.isFollowing(vm.searchResults[0]))
        XCTAssertFalse(vm.isFollowing(vm.searchResults[1]))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios && swift test --filter DiscoverViewModelTests`
Expected: FAIL — `value of type 'DiscoverViewModel' has no member 'runSearch'`.

- [ ] **Step 3: Write the implementation**

Add to `DiscoverViewModel`:

```swift
    @Published var searchResults: [ChannelSearchResult] = []
    @Published var searching = false
    // True only when the page could not be read at all — never for an empty
    // result set, which is a legitimate answer.
    @Published var searchUnavailable = false
    @Published var searchedTerm: String?
```

and these methods:

```swift
    func runSearch(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        searching = true
        searchUnavailable = false
        defer { searching = false }

        switch await service.searchChannels(query: trimmed) {
        case .parsed(let results):
            searchResults = results
            searchedTerm = trimmed
        case .structureMissing:
            searchResults = []
            searchedTerm = trimmed
            searchUnavailable = true
        }
    }

    func clearSearch() {
        searchResults = []
        searchedTerm = nil
        searchUnavailable = false
        query = ""
    }

    // Search results already carry channelId, so this skips resolveChannel's
    // handle lookup — that extra request only exists for pasted URLs.
    func subscribe(to result: ChannelSearchResult) async {
        store.add(Subscription(channelId: result.channelId, title: result.title, addedAt: Date()))
        await refresh()
    }

    func isFollowing(_ result: ChannelSearchResult) -> Bool {
        store.contains(channelId: result.channelId)
    }
```

Note `subscribe(to:)` deliberately leaves `searchResults` untouched so the row
can flip to "Following" in place.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios && swift test --filter DiscoverViewModelTests`
Expected: PASS, 18 tests (10 existing + 8 new).

- [ ] **Step 5: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 160 tests.

- [ ] **Step 6: Commit**

```bash
git add ios/NexaInsight/Import/DiscoverViewModel.swift ios/NexaInsightCoreTests/DiscoverViewModelTests.swift
git commit -m "Add search state to the Discover view model

Keeps 'no matches' separate from 'could not read the page' so a
YouTube-side break is not reported as a failed search. Subscribing from
a result skips handle resolution, which only pasted URLs need."
```

---

### Task 5: Search UI and cold start

The only task touching `LibraryView.swift`. Turns the empty state into a usable
search surface.

**Files:**
- Modify: `ios/NexaInsight/Views/LibraryView.swift`

Locate declarations by name, not line number — they shift as you edit:
```bash
grep -n "private struct DiscoverView\|private struct DiscoverHeader\|private struct DiscoverChannelFilters" ios/NexaInsight/Views/LibraryView.swift
```

**Interfaces:**
- Consumes: `DiscoverViewModel` search members (Task 4), `ChannelSearchTerms` (Task 1), `ChannelSearchResult`.
- Produces: `DiscoverShortcutChips`, `ChannelSearchResults`, `ChannelSearchRow`. `DiscoverHeader` gains an `onSubmitSearch` closure.

- [ ] **Step 1: Wire the existing search field to search**

`DiscoverHeader` already has a `TextField` bound to `$vm.query` with an
`onSubmit(submitQuery)` and a paste-detection branch (`looksLikeSourceURL`).
Keep the URL branch — a pasted link should still import — and route plain text
to search.

Add a parameter to `DiscoverHeader`:

```swift
    let onSubmitSearch: (String) -> Void
```

In its `submitQuery()`, keep the existing URL handling and add the text case, so
a pasted link still imports while a keyword searches:

```swift
    private func submitQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if looksLikeSourceURL(trimmed) {
            onAddToNexa(trimmed)
        } else {
            onSubmitSearch(trimmed)
        }
    }
```

Read the existing `submitQuery` before editing and preserve whatever it already
does for the URL case rather than replacing it wholesale.

Update the `DiscoverHeader(...)` call in `DiscoverView` to pass:

```swift
            DiscoverHeader(
                query: $vm.query,
                importing: importing,
                onAddToNexa: onAddToNexa,
                onSubmitSearch: { term in Task { await vm.runSearch(term) } })
```

- [ ] **Step 2: Add the shortcut chips**

```swift
// Preset search terms. Tapping one runs a real search — these are strings, not
// a category taxonomy, so nothing here can go stale.
private struct DiscoverShortcutChips: View {
    let activeTerm: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NXSpacing.x2) {
                ForEach(ChannelSearchTerms.all, id: \.self) { term in
                    DiscoverFilterButton(
                        title: term.capitalized,
                        systemName: "magnifyingglass",
                        selected: activeTerm == term,
                        action: { onSelect(term) })
                }
            }
        }
    }
}
```

`DiscoverFilterButton` already exists with signature
`(title:systemName:selected:action:)` and is reused unchanged.

- [ ] **Step 3: Add the results list and row**

```swift
private struct ChannelSearchResults: View {
    @ObservedObject var vm: DiscoverViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            HStack {
                NXSectionHeader(title: "Channels")
                Spacer()
                NXTextButton(title: "Clear", systemName: "xmark", action: vm.clearSearch)
            }

            if vm.searchUnavailable {
                // Distinct from "nothing found": the page could not be read, so
                // point at the fallback that does not depend on page structure.
                NXErrorState(
                    message: "Channel search is unavailable right now. You can still add a channel by pasting its link.",
                    retry: { Task { await vm.runSearch(vm.searchedTerm ?? "") } })
            } else if vm.searching {
                ProgressView("Searching")
                    .font(NXFont.auxiliary)
            } else if vm.searchResults.isEmpty {
                Text("No channels found for \(vm.searchedTerm ?? "").")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.searchResults) { result in
                        ChannelSearchRow(
                            result: result,
                            following: vm.isFollowing(result),
                            onFollow: { Task { await vm.subscribe(to: result) } })
                        if result.id != vm.searchResults.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
            }
        }
    }
}

private struct ChannelSearchRow: View {
    let result: ChannelSearchResult
    let following: Bool
    let onFollow: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            thumbnail
            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(result.title)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(1)
                Text(byline)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .lineLimit(1)
                if let summary = result.summary {
                    Text(summary)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: NXSpacing.x2)
            if following {
                NXTag(text: "Following", tint: NXColor.success)
            } else {
                NXSecondaryButton(title: "Follow", systemName: "plus", action: onFollow)
            }
        }
        .padding(.vertical, NXSpacing.x3)
    }

    // subscriberText comes from the response's `videoCountText` — see
    // ChannelSearchParser for why that is not a mistake.
    private var byline: String {
        [result.subscriberText, result.handle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = result.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(NXColor.surface2(scheme))
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(NXColor.surface2(scheme))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 15))
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
        }
    }
}
```

These components already exist and are used above with their real signatures,
confirmed against `DesignSystem.swift`:

- `NXSecondaryButton(title:systemName:action:)`
- `NXTextButton(title:systemName:disabled:action:)` — `disabled` defaults to false
- `NXSectionHeader(title:actionTitle:action:)` — the latter two default to nil
- `NXTag(text:tint:)` — uppercases its text internally
- `NXEmptyState(title:message:actionTitle:action:)`

- [ ] **Step 4: Restructure DiscoverView's body**

Replace `DiscoverView`'s `body` so that chips are always visible and search
results, when present, take precedence over the feed:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            DiscoverHeader(
                query: $vm.query,
                importing: importing,
                onAddToNexa: onAddToNexa,
                onSubmitSearch: { term in Task { await vm.runSearch(term) } })

            DiscoverShortcutChips(
                activeTerm: vm.searchedTerm,
                onSelect: { term in
                    vm.query = term
                    Task { await vm.runSearch(term) }
                })

            if vm.searchedTerm != nil {
                // Search results replace the feed while a search is active.
                ChannelSearchResults(vm: vm)
            } else if !vm.hasSubscriptions {
                NXEmptyState(
                    title: "Follow a channel to fill Discover",
                    message: "Tap a topic above, search for a channel, or paste a channel link.",
                    actionTitle: "Paste a channel link",
                    action: { showAddChannel = true })
            } else {
                subscribedFeed
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
```

Move the existing subscribed-feed branch (channel filters + error/loading/content)
into a `subscribedFeed` computed property, unchanged:

```swift
    @ViewBuilder
    private var subscribedFeed: some View {
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
```

The cold-start behaviour now: a first-time user sees the search field plus eight
tappable topic chips instead of a single button, and any chip yields 20 real
channels immediately.

- [ ] **Step 5: Run the full suite**

Run: `cd ios && swift test`
Expected: PASS — 160 tests.

- [ ] **Step 6: Build for the simulator**

```bash
cd ios && ./generate.sh
xcodebuild -project NexaInsight.xcodeproj -target NexaInsight \
  -sdk iphonesimulator -configuration Debug -arch arm64 \
  EXCLUDED_SOURCE_FILE_NAMES='Assets.xcassets' \
  ASSETCATALOG_COMPILER_APPICON_NAME='' \
  CONFIGURATION_BUILD_DIR=/tmp/nexa-build build 2>&1 | grep -E "^\*\*|error:"
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Run it and verify against the live site**

```bash
DEV=$(xcrun simctl list devices available | grep -m1 'iPhone 15' | grep -o '[0-9A-F-]\{36\}')
xcrun simctl boot $DEV 2>/dev/null; open -a Simulator
xcrun simctl terminate $DEV com.nexainsight.app 2>/dev/null
xcrun simctl install $DEV "/tmp/nexa-build/Nexa Insight.app"
xcrun simctl launch $DEV com.nexainsight.app
sleep 3
xcrun simctl io $DEV screenshot /tmp/search1.png
```

Read the screenshot. On a fresh install Discover should show the search field
and eight topic chips — not five fake cards, not a bare button.

Then tap a chip (e.g. Philosophy) and screenshot again. Verify against what the
live feed actually returns:

```bash
# Ground truth to compare the screenshot against
python3 - <<'PY'
import socket, urllib.request, re, json
_o = socket.getaddrinfo
socket.getaddrinfo = lambda *a, **k: [x for x in _o(*a, **k) if x[0] == socket.AF_INET]
def walk(o, key):
    if isinstance(o, dict):
        if key in o: yield o[key]
        for v in o.values(): yield from walk(v, key)
    elif isinstance(o, list):
        for v in o: yield from walk(v, key)
H = {'User-Agent': 'Mozilla/5.0', 'Accept-Language': 'en-US,en;q=0.9'}
u = 'https://www.youtube.com/results?search_query=philosophy&sp=EgIQAg%253D%253D&hl=en&gl=US'
h = urllib.request.urlopen(urllib.request.Request(u, headers=H), timeout=30).read().decode('utf-8', 'ignore')
ch = list(walk(json.loads(re.search(r'var ytInitialData = (\{.*?\});</script>', h).group(1)), 'channelRenderer'))
for c in ch[:5]:
    print((c.get('title') or {}).get('simpleText'),
          '|', (c.get('videoCountText') or {}).get('simpleText'),
          '|', (c.get('subscriberCountText') or {}).get('simpleText'))
PY
```

Check three things in the screenshot:
1. Channel names match the script's output.
2. The byline shows a **subscriber count** (e.g. `1.67M subscribers`), not an
   `@handle`. A handle there means the field-name trap was reintroduced.
3. Descriptions are complete sentences, not fragments like `"My "` — a fragment
   means `descriptionSnippet.runs` was not joined.

Then tap Follow on one result and confirm it flips to "Following" in place and
that channel's videos appear in the feed after clearing the search.

Note the sandbox this plan was written in could not reach YouTube via `curl`
(no IPv6 route, then timeout) and hit intermittent `URLError`/SSL EOF needing
retries. If the simulator cannot reach the network, say so plainly rather than
reporting the feature verified — parsing is covered by tests, but the live
request would then be unverified.

- [ ] **Step 8: Commit**

```bash
git add ios/NexaInsight/Views/LibraryView.swift
git commit -m "Add channel search and topic chips to Discover

A first-time user now lands on a search field and eight topic chips
instead of a single button, and each chip returns real channels
immediately. Pasted links keep importing as before, and the paste entry
stays as the fallback that survives a page-structure change."
```

---

## Verification constraints

Recorded so an implementer does not mistake an environment limit for a bug:

- `curl` cannot reach YouTube from the sandbox this was written in (no IPv6
  route, then timeout). Findings were verified with Python `urllib` forced to
  IPv4. Transient `URLError`/SSL EOF failures needed retries, so a single failed
  request does not mean an endpoint is down.
- `xcodebuild -destination 'platform=iOS Simulator,...'` cannot resolve on this
  machine (`-showdestinations` lists zero simulator destinations). Use `-target`
  plus `-sdk iphonesimulator`.
- The asset catalog must be excluded from simulator builds here; `actool` rejects
  the installed SDK/runtime pair. This affects the app icon only.
- Driving the simulator UI by synthetic clicks is unreliable on this machine —
  other apps steal focus mid-sequence. Guard every click by checking the
  frontmost process is `Simulator` and abort if not, rather than typing into
  whatever window took focus.
