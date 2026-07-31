# Discover: channel search and cold start

Date: 2026-07-31

Follows `2026-07-31-discover-real-sources-design.md`, which replaced Discover's
hardcoded items with real subscribed-channel feeds. That left one gap: the only
way to subscribe is pasting an exact channel URL, and a user with no
subscriptions opens Discover to an empty state and a single button. They have to
already know what they want and where to find its URL.

## Approach

Add channel search: type a keyword, or tap a preset shortcut term, and get real
YouTube channels to subscribe to. Still client-only, still no backend.

### Request shape

All three parameters are required, and each was verified:

```
https://www.youtube.com/results?search_query=<q>&sp=EgIQAg%3D%3D&hl=en&gl=US
```
plus header `Accept-Language: en-US,en;q=0.9`

- `sp=EgIQAg%3D%3D` restricts results to channels. With it: 20 channels, 0
  videos. Without it: 0 channels, 19 videos.
- `hl=en&gl=US` **and** the `Accept-Language` header are both needed. Four
  combinations were tested; without a locale hint the response came back
  Japanese (`チャンネル登録者数 2.04万人`), and only pinning both reliably
  produced `1.67M subscribers`.

No API key, no auth. The official `googleapis.com/youtube/v3/search` was
rejected for this: it returns 403 without a key, a client-embedded key is
extractable (forcing a backend proxy), and `search.list` costs 100 quota units
against a 10,000/day free tier — 100 searches per day total.

### Parsing must go through JSON

Extract the JSON from `var ytInitialData = {...};</script>`, then walk it for
`channelRenderer` nodes. Only that assignment form exists; the alternate
`ytInitialData"] = {...}` form was checked and is absent.

Do not regex for `"channelId":"UC..."` directly. That was tried first and
matched non-channel text (e.g. `チャンネル登録`), and separately mis-extracted
recommended-video author ids — the same class of bug the feed work already hit.

### The field names lie

| Field name | What it actually contains |
|---|---|
| `subscriberCountText` | the **`@handle`** (e.g. `@restishistorypod`) |
| `videoCountText` | the **subscriber count** (e.g. `541K subscribers`) |

Verified across multiple queries with locale pinned. Reading by name puts a
handle where the subscriber count belongs. This gets a regression test.

### Thumbnails are protocol-relative

All 20 results returned `//yt3.googleusercontent.com/...`. The `https:` prefix
must be added before the URL will load.

### Field completeness

All 20 results had `channelId` and `title`; 0 were missing description or
subscriber text. That is a single-query sample, not a guarantee, so parsing
treats everything except `channelId` and `title` as optional and cards degrade
rather than showing blanks.

## Data model

```swift
struct ChannelSearchResult: Identifiable, Equatable {
    let channelId: String        // subscription key and dedup key
    let title: String
    let handle: String?          // from subscriberCountText (misnamed)
    let subscriberText: String?  // from videoCountText (misnamed)
    let summary: String?
    let thumbnailURL: URL?
    var id: String { channelId }
}
```

Parsing lives in `Logic/ChannelSearchParser.swift` as a pure function. The search
call joins the existing `DiscoverFeedFetching` protocol so `DiscoverViewModel`
tests keep using an offline stub.

## Cold start

Shortcut terms are **strings, not data**. Tapping one fills the search box and
runs a real search. There is no category-to-channel mapping table to maintain,
which is what separates this from the invented `DiscoverKind` taxonomy the
previous effort deleted: results come from YouTube live, so they cannot rot.

Thirteen candidate terms were tested. Eight are good:

| Term | First three results |
|---|---|
| `podcast` | Jay Shetty Podcast, New York Times Podcasts, The Mindset Mentor |
| `history` | HISTORY, Epic History, History Time |
| `philosophy` | Philosophy Tube, Bite-sized Philosophy, The Living Philosophy |
| `science` | Science Magazine, Science Channel, Science Max |
| `technology` | Technology Connections, Linus Tech Tips, Matt Talks Tech |
| `economics` | The Economist, Economics Explained, Garys Economics |
| `psychology` | Psych2Go, Psychology Simplified, Psychology Coded |
| `documentary` | Best Documentary, Free Documentary, WELT Documentary |

Rejected, with the reason each failed:

- `ai` — returned 감다살 AI, あい。; two-letter queries match too loosely
- `health` — returned HEALTH and HEALTH - Topic, a band and an auto-generated
  topic channel
- `interview` — returned Interviewing Japan, Hello Interview: job-interview
  content
- `business`, `education` — usable but mixed with low-quality channels
  (YASU Business Channel, Business Expertiz)

The pattern: **shorter terms give worse results.** `ai` was worst; `documentary`
and `psychology` were most on-target. So shortcut terms should be specific
subject names, not abbreviations or broad words.

These terms are English, and they surface mostly English channels. For an
English intensive-listening app that is correct, but covering Chinese-language
sources would need its own validation and is out of scope here.

### Empty state becomes the search surface

Today, no subscriptions means an `NXEmptyState` with one button. It becomes a
search field plus the eight shortcut chips, so the first thing a user sees is
eight tappable entry points, each producing 20 real channels immediately.

Shortcut terms stay visible after subscribing — finding new channels is an
ongoing need, not a one-time setup step.

### Result cards and subscribing

Each card shows title, subscriber count (from `videoCountText`), `@handle`,
description, and thumbnail, plus a subscribe button. Already-subscribed channels
render as "Following" and are not re-tappable, using the existing
`SubscriptionStore.contains(channelId:)`.

Search results already carry `channelId`, so subscribing skips
`resolveChannel`'s handle resolution — that path exists for pasted URLs and is
unnecessary here. Construct the `Subscription` directly, then `refresh()`.

## Fragility

This scrapes a page; it is not an API. `ytInitialData` is YouTube's internal
front-end structure and a redesign will break it. Three consequences:

1. **A parse failure is not the same as no results.** Verified: a no-match query
   returns 200 with `ytInitialData` present and 0 renderers, whereas a missing
   `ytInitialData` means the structure changed. The first shows "no channels
   found"; the second shows "search is unavailable right now — you can paste a
   channel link instead" and promotes the paste entry. Conflating them would make
   a YouTube-side break look like the user's search was wrong.
2. **The paste-URL entry is never removed.** It is the only path that survives a
   structural break, since it depends on nothing internal.
3. **Regex is used only to extract the JSON block**; everything after is JSON
   parsing.

Trending was considered and rejected on evidence: `youtube.com/feed/trending`
returns `ytInitialData` with **0** `videoRenderer` nodes — `richGridRenderer` is
an empty shell and entries load via a follow-up `youtubei/v1/browse` request,
which would require forging an innertube key. Beyond feasibility, YouTube's
platform-wide trending skews to music videos and gaming, which is noise for an
intensive-listening tool.

Related channels (`/@handle/channels`) were also tested and rejected as a primary
cold-start source. Coverage is too inconsistent: `@3blue1brown` yielded 12 good
peers (Mathologer, Welch Labs, Stand-up Maths), but `@veritasium` returned mostly
its own translation accounts, `@lexfridman` returned only Lex Clips, and
`@hubermanlab` returned 0. It is a channel-owner-curated list, so it may be
empty or self-promotional.

## Testing

Same layering as the feed work: pure logic in `Logic/`, tested offline on macOS
via SwiftPM. Tests feed local JSON strings and hit no network.

- `ChannelSearchParserTests`
  - full-field parse
  - **field-mislabel regression**: asserts `handle` comes from
    `subscriberCountText` and `subscriberText` from `videoCountText`
  - **protocol-relative thumbnail** gets `https:` prepended
  - missing optional fields degrade; entries without `channelId`/`title` are
    skipped
  - malformed JSON and absent `ytInitialData` return empty without crashing
  - a distinct signal for "structure missing" vs "zero results", since the UI
    must tell them apart
- `DiscoverViewModelTests` additions — search populates results, already-followed
  channels are marked, subscribing from a result stores it and refreshes, parse
  failure sets the unavailable state rather than the empty state

## Out of scope

- No backend changes.
- No trending, no interest categories, no related-channel recommendations
  (each rejected above on tested evidence).
- No Chinese-language shortcut terms without separate validation.

## Verification constraint

`curl` cannot reach YouTube from this sandbox (no IPv6 route, then timeout). All
findings were verified with Python `urllib` forced to IPv4. Transient
`URLError`/SSL EOF failures occurred and needed retries, so the sandbox network
is flaky — a single failed request here does not mean an endpoint is unavailable.
