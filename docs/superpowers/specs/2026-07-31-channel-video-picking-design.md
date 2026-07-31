# Channel detail: finding a specific video to import

Date: 2026-07-31

Follows `2026-07-31-discover-channel-search-design.md`, which let users find and
subscribe to channels. Subscribing then only produced a cross-channel feed of
recent uploads. There was no way to reach a *particular* video — and for a
channel with years of back catalog, "the 15 most recent uploads" is the wrong
answer to "I want the episode about physics."

## The governing requirement

Finding content on demand is the priority, not browsing what is new. That
distinction drives the whole design: browsing is served by a recency list, but
on-demand retrieval needs search, and no "latest N" list can substitute for it.

This also removed a constraint from an earlier draft. Duration was going to be
the deciding factor in choosing a data source, because the import pipeline runs
transcription, per-sentence translation, and AI chaptering — and these channels'
videos are routinely 2–4 hours (measured: 3:46:18, 3:51:47, 2:53:43, 4:18:22).
Duration is still shown, but it no longer dictates the source choice, because the
chosen source provides it anyway.

## Data source: in-channel search

```
https://www.youtube.com/channel/<UCxxxx>/search?query=<q>&hl=en&gl=US
```
plus the browser `User-Agent` and `Accept-Language: en-US,en;q=0.9` headers
already required by the existing search work.

Measured for `physics` on one channel: 30 results, each carrying everything the
card needs.

| Field | Measured value |
|---|---|
| `videoId` | `y3cw_9ELpQw` — all 30 were exactly 11 chars |
| `title` | via `title.runs` |
| `lengthText` | `2:19:34` |
| `publishedTimeText` | `3 years ago` |
| `viewCountText` | `3,028,702 views` |
| `descriptionSnippet` | present |
| `thumbnail` | present |

The decisive property is **reach into the back catalog**: results included a
3-year-old Strominger episode and a 6-year-old Sean Carroll clip. Compare the
alternatives that only expose recent uploads:

| | RSS feed | Channel videos page | **Channel search** |
|---|---|---|---|
| Entry count | **hard cap 15** (`max-results` and `start-index` both ignored) | 30 | 30 |
| Duration | **absent** | present | present |
| Reaches old uploads | no | no | **yes** |
| Renderer | Atom XML | `lockupViewModel` | `videoRenderer` |

A structural surprise worth recording: channel search still returns the **older**
`videoRenderer` shape, while the channel videos page has already moved to
`lockupViewModel` — I measured `videoRenderer` as 0 there. The two pages sit at
different points in YouTube's own migration. That works in our favour, since
`videoRenderer` is the same family the existing channel-search parser handles.

### Recency list uses the videos page

With no query entered, the page shows the channel's latest uploads via the videos
page (30 entries, with duration) rather than RSS (15, without). Since in-channel
search already depends on `ytInitialData`, the recency list using it too lets both
share one failure path and one degradation story. RSS stays where it already is —
the cross-channel Discover feed, which needs no duration.

### No pagination

Loading more requires a `youtubei/v1/browse` POST with a `continuationCommand`
token and `INNERTUBE_API_KEY` — both present in the page, confirmed. That is
forging an internal API, the same road that ruled out trending. So both the
search results and the recency list cap at 30, and the UI **says so**. Silent
truncation would read as "this channel only has 30 videos."

## Data model

```swift
struct ChannelVideo: Identifiable, Equatable {
    let videoId: String
    let title: String
    let durationText: String?    // "2:19:34"
    let viewsText: String?       // "3,028,702 views"
    let publishedText: String?   // "3 years ago"
    let summary: String?         // descriptionSnippet
    let thumbnailURL: URL?
    var id: String { videoId }
}
```

Every metadata field keeps its raw display string rather than parsing to `Int` or
`Date`. These are YouTube's own localized strings ("3 years ago", "3,028,702
views"); parsing them back into structured values means handling every language
and abbreviation format, and we only ever display them. This is a deliberate
difference from the RSS path, where `published` is a real `Date` because the feed
provides an ISO-8601 timestamp.

`ChannelVideo` is a separate type from `DiscoverEntry` rather than a reuse: the
two come from different sources with different reliability and different field
availability, and collapsing them would mean optional-everything.

## Importing

All 30 measured `videoId` values were 11 characters, which is exactly what the
backend's `youtube_id()` validation expects (`app.py:16`). So importing
constructs `https://www.youtube.com/watch?v=<videoId>` and posts it to the
existing `POST /api/episodes/import`. **No backend change.**

Already-imported videos are marked. `videoId` is matched against the `youtubeId`
of rows from `EpisodeStore.downloadedEpisodes()`, and those rows show "In your
library" instead of an import button, so a user cannot accidentally re-run a
pipeline that takes tens of minutes. This check is client-side; the backend is not
consulted.

Note this is the one place the round still leans on the `youtubeId` field named in
the multi-source section below. When that field becomes `source_id`, this
comparison moves with it.

## Navigation

Today's channel filter chips filter the feed, which is browsing semantics.
On-demand retrieval needs its own surface, so channels get a detail screen:

```
Discover (cross-channel feed + channel search)
  └── Channel detail (in-channel search + latest 30)
        └── Import → existing POST /api/episodes/import
```

Pushed via `navigationDestination`, matching how `StudyView` is already reached
(`LibraryView.swift:41`), keyed on `Subscription`.

Two entry points:

1. The subscription list — tap a channel name.
2. Channel search results — a "View content" action next to Follow.

The second matters: it lets a user inspect what a channel actually publishes
*before* subscribing, instead of forcing subscribe-then-look.

Layout, top to bottom: channel name and subscriber count → a search field
("Search in this channel") → results or the recency list → each card with an
import action.

An empty query issues no request and shows the recency list, since an empty
query was measured to return 0 results anyway.

## Failure handling

The same three-way split as the existing channel search, because conflating the
last two would blame the user for a YouTube-side change.

| Case | Measured | UI |
|---|---|---|
| Results | 200, 30 entries | list |
| No match | 200, `ytInitialData` present, 0 entries | "No videos in this channel match X" |
| Structure changed | `ytInitialData` absent | "Browsing is unavailable right now — you can paste a video link to import it" |

The third case is not hypothetical: `videoRenderer` has already been replaced by
`lockupViewModel` on the videos page, so this layer demonstrably moves.

The paste-a-video-link fallback is kept, since it depends on no internal
structure.

Shorts: in-channel search returned zero `/shorts/` references, so search does not
surface them. The recency list can, so it reuses the existing `/shorts/` filter.

## Multi-source: not in this round, but here is the boundary

Deliberately deferred. Recording the real coupling so a future round does not
misjudge the cost.

The backend's `MediaAdapter` protocol (`pipeline.py:38` — `metadata`, `stream`,
`captions`, `download_audio`) is a sound seam; adding another audio source means
adding an adapter. The blocker is the data model, where YouTube leaks through the
full stack:

- `models.py:22` — `youtube_id` column
- `app.py:16` — `youtube_id(url)` accepts only youtube.com/youtu.be hosts and
  **422s everything else**, so a non-YouTube URL fails at the first step
- `schemas.py:17`, iOS `Models.swift:26`, `PersistentModels.swift:7` — `youtubeId`

Adding a second source means changing these to something like `source_kind` +
`source_id`, which requires a data migration.

One caveat that an adapter cannot absorb: **the pipeline assumes audio exists.**
`captions()` hardcodes `--sub-langs en-orig,en`, and shadowing depends on a
timeline. Podcasts and audiobooks fit. Text-only sources — the WeChat articles
raised earlier, for instance — have no audio to transcribe and no timeline to
align against, so shadowing cannot work on them at all. That is an architectural
fork to evaluate as a separate product line, not a third adapter.

## Out of scope

- No backend changes.
- No pagination (would require forging the innertube API).
- No preview/sample-before-import step. It was considered, since a mis-chosen
  4-hour video costs tens of minutes of pipeline time, and was declined in favour
  of keeping this round small. If mis-imports turn out to be common in practice,
  a captions-only preview is the cheapest remedy — captions fetch fast and cost
  almost nothing next to transcription.
- No multi-source refactor.

## Verification constraint

`curl` cannot reach YouTube from this sandbox (no IPv6 route, then timeout). All
findings were verified with Python `urllib` forced to IPv4, using the browser
User-Agent — without that UA, YouTube serves a consent interstitial instead of
the real page (measured previously: ~475 KB with zero renderers versus ~845 KB
with 21). Transient `URLError`/SSL EOF failures needed retries, so one failed
request does not mean an endpoint is down.
