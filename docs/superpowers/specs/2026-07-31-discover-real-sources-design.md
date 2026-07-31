# Discover: real content from subscribed YouTube channels

Date: 2026-07-31

## Problem

Discover shows no real content. `featuredDiscoverItems` (`ios/NexaInsight/Views/LibraryView.swift`)
is five hardcoded `DiscoverItem` literals. Not only the titles are invented — `summary`,
`chapters`, `discussionDirections`, `related`, and `transcriptState` are hand-written display
copy. Search and filtering run local string matching over that array. Discover makes no network
request and has no backend counterpart: the API exposes only import and episode reads, with no
browse/discover endpoint.

So the gap is not "more content" — it is that content has no source.

## Approach

Users subscribe to YouTube channels. The app fetches each channel's public RSS feed directly,
parses it, merges entries, and shows them newest-first. Adding an item to Nexa reuses the
existing `POST /api/episodes/import` unchanged.

### No backend changes

The channel feed is public XML requiring no API key, no headers, and no auth. Verified: requests
with no headers, a custom UA, and a browser UA all returned 200 / 61 KB / 15 entries.

```
https://www.youtube.com/feeds/videos.xml?channel_id=<UCxxxx>
```

This is not merely a way to avoid backend work — the feature does not need a backend:

- A subscription list is a personal device preference, not shared server state.
- The backend is deliberately a thin import layer (per its README). Adding a subscription table
  and a polling job would turn it into a stateful content service, conflicting with that role.
- Discover only browses. Content the user actually studies still goes through
  `POST /api/episodes/import`. Browsing on the client, processing on the backend is the right
  boundary.

`URLSession` and `XMLParser` are system frameworks, so this adds no dependency.

### RSS gives more than yt-dlp --flat-playlist

An earlier assumption — based on `yt-dlp --flat-playlist` — was that description, publish date,
and view count were unavailable. That was wrong for RSS. Fields verified present per entry:

| Field | Verified value |
|---|---|
| `yt:videoId` | `XyXBwO5jYpw` |
| `title` | full title |
| `published` | `2026-07-28T20:02:11+00:00` |
| `author/name` | channel name |
| `media:description` | full description |
| `media:thumbnail` | `hqdefault.jpg` with width/height |
| `media:statistics` | `views="189212"` |

**`duration` is absent** — no duration tag exists anywhere in the feed. This is the one real loss
of the client-only approach. Cards omit duration; the backend pipeline fills it after import.

## Data model

`DiscoverItem` changes from display-oriented literals to what RSS can actually fill.

Fields to keep, sourced from RSS: title, channel name, published date, summary
(`media:description`), thumbnail, view count.

Fields to remove from Discover cards: `chapters`, `discussionDirections`, `related`,
`transcriptState`, `permission`, `duration`. RSS has none of them, and it should not — these
exist only after processing (chapters need transcription; discussion directions need an LLM).
Pretending they exist pre-import is the root of the current fake data. They belong to `StudyView`.

`DiscoverKind` (podcast/video/article/channel/topic) is also fictional; all subscription content
is YouTube video. Filtering changes from invented kinds to subscribed channels, which is
meaningful once the data is real.

The governing rule: **Discover cards show only what a subscription feed genuinely provides.**

## Subscriptions

Stored in `UserDefaults` as JSON under one key, following `AppSettings`' existing `didSet`
pattern. Not SwiftData/`EpisodeStore` — that holds imported study content; subscriptions are
just "who I follow", a different lifecycle.

New `SubscriptionStore` (`Services/`):

```swift
struct Subscription: Codable, Identifiable, Equatable {
    let channelId: String      // UCxxxx — the RSS key
    var title: String          // channel name, read from the feed when added
    let addedAt: Date
    var id: String { channelId }
}
```

`channelId` as the primary key gives deduplication for free.

### Adding a subscription

Two input forms, because users have different link shapes:

1. `youtube.com/channel/UCxxxx` — the id comes from regex extraction alone.
2. `youtube.com/@handle` — resolving the id requires fetching the channel page.

Both forms then fetch the feed once to read the channel title and to validate the id (a bad id
returns 404, so this doubles as the "could not recognize that channel" check). So form 1 makes one
request and form 2 makes two.

**Handle resolution MUST use `<link rel="canonical" href=".../channel/UC...">`.** A naive
`"channelId":"(UC[\w-]{22})"` regex extracted the WRONG id for both channels tested — for
`@lexfridman` it returned `UCJIfeSC...` instead of `UCSHZKyawb...`, because recommended-video
author ids appear earlier in the HTML. The canonical link and the page's RSS link agreed for both
channels tested, making canonical the reliable anchor.

Parsing lives in `Logic/` as pure functions, matching the existing `AudioRouteLogic` /
`ClassroomLogic` layering:

```swift
enum YouTubeChannelLogic {
    static func channelId(fromChannelURL: String) -> String?   // direct form
    static func channelId(fromHTML: String) -> String?         // canonical parse
    static func feedURL(channelId: String) -> URL
}
```

## Fetching and merging

`DiscoverFeedService` (`Services/`) fetches all subscribed feeds concurrently via
`withThrowingTaskGroup`, parses each with `XMLParser`, merges, and sorts by `published`
descending.

**Partial failure must not take down the page.** An invalid `channel_id` returns **404**, not an
empty feed, so a single failing source is isolated: mark that source as errored and keep showing
the rest. A full-page error state appears only when every source fails.

### Shorts are filtered out

Shorts appear in the feed: 3 of Veritasium's 15 entries had `/shorts/` links instead of
`/watch?v=`. For an intensive-listening app, seconds-long Shorts are noise with nothing worth
transcribing. Entries whose alternate link contains `/shorts/` are excluded. The link form is the
only reliable signal, since RSS carries no duration.

### Optional fields

`media:description` and `media:thumbnail` were non-empty in all 15 entries of both channels
tested (0 missing, 0 empty). That is a two-channel sample, not a guarantee — parsing treats both
as optional and cards degrade gracefully rather than showing blanks or crashing.

## Error handling

- Single source 404 or network failure → mark that source errored, feed continues.
- All sources fail → full-page error state with retry.
- Handle resolution yields no id → explicit "could not recognize that channel link"; never fail
  silently.
- No subscriptions yet → guidance state, not an empty list. Today the page always has five fake
  items, so a true empty state has never existed.

## Testing

Matches the existing layering: pure logic in `Logic/`, tested offline on macOS via SwiftPM (the
current 106 tests run with `swift test` and no network). New tests feed local XML strings and hit
no network.

- `YouTubeChannelLogicTests` — direct `/channel/UCxxx` parse; canonical parse; **a regression
  test locking in that the naive `"channelId"` regex is wrong** (it mis-extracted for both
  channels tested); nil when unrecognizable.
- `DiscoverFeedParserTests` — full-field entry parse; degradation when description/thumbnail are
  missing; **Shorts entries are filtered**; malformed XML does not crash; multi-source merge is
  ordered by `published` descending.
- `SubscriptionStoreTests` — add/remove, `channelId` deduplication, `UserDefaults` round-trip
  (using an isolated suite, as `AppSettingsTests` does).

The parser is a pure function (`Data`/`String` in, `[DiscoverItem]` out) with networking in an
outer layer, so every case above is testable offline.

## Out of scope (YAGNI)

- No backend changes; `POST /api/episodes/import` is reused as-is.
- No scheduled background refresh — on-appear and pull-to-refresh suffice.
- No WeChat or Douyin. Neither exposes any API to read a user's own favorites: WeChat's OpenSDK
  is write-only (its "收藏" is a `SendMessageToWXReq` scene value, i.e. a share destination, not a
  data source), and Douyin's open platform covers only a user's own published videos. Local-DB
  extraction tools were taken down after legal pressure from WeChat. A share-extension flow
  (share from WeChat into the app) is feasible but is an import path, not Discover browsing, so it
  belongs in its own effort.
- No duration display — RSS lacks it; the backend pipeline fills it after import.

## Verification constraint

`curl` cannot reach YouTube from this sandbox (no IPv6 route, then timeout). All findings above
were verified with `yt-dlp` and with Python `urllib` forced to IPv4. The RSS-without-curl path was
confirmed; anything requiring `curl` was not independently checked.
