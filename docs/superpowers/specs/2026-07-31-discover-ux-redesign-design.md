# Discover: one search, one card, two tabs

Date: 2026-07-31

Follows `2026-07-31-discover-channel-search-design.md` and
`2026-07-31-channel-video-picking-design.md`. Those rounds built the data layer —
RSS feeds, channel search, in-channel search — and each worked in isolation. This
round is about what they add up to on screen, which is currently incoherent.

## Problem

Three structural confusions, all in `DiscoverView` (`LibraryView.swift:622-681`).

**Search returns a different kind of thing depending on where you are.** The
Discover search box returns *channels* (`searchChannels` forces this with
`sp=EgIQAg==`). The identical-looking box inside a channel returns *videos*. Two
search fields, same appearance, different semantics.

**Two rows of chips look identical and mean opposite things.**
`DiscoverShortcutChips` (preset search terms, magnifying-glass icon, always
visible) and `DiscoverChannelFilters` (channel filters plus "Add channel", play
icon, only visible when a feed exists) both render through the same
`DiscoverFilterButton`. The second row swaps its entire meaning based on state.

**Subscriptions appear twice with different behaviour.** As filter chips
(`:664` — tap filters the feed) and as a "Your channels" list (`:671` — tap
navigates). Same entity, two places, two behaviours.

A fourth problem underlies these: `vm.query` serves two jobs. Typing filters the
feed locally (`visibleEntries`, `DiscoverViewModel.swift:35`); submitting replaces
the whole page with channel results. What you see while typing has no relationship
to what you get on submit.

## Decisions

Each was chosen by the user during brainstorming.

| Question | Decision |
|---|---|
| What does Discover's search return? | Videos, not channels |
| Search scope | All of YouTube |
| Default state (empty query) | Latest videos from followed channels |
| How subscriptions appear | A "My channels" tab |
| How to follow a new channel | Tap a video card's channel name → channel page (pasting a link also still works) |
| Unfollow | Swipe-to-delete on the channel row |
| Tabs during search | Hidden; the page enters a search state |
| Channel page header | Fetch the channel page for avatar + subscriber count |

## Information architecture

```
Discover
├─ empty query → two tabs
│   ├─ Latest       RSS feed of followed channels
│   └─ My channels  channel list (swipe to unfollow) + paste a channel link
└─ submitted query → search state (tabs hidden, "← Back" appears)
      └─ site-wide video results

any video card's channel name → Channel page
                                  (Follow · in-channel search · recent uploads)
```

Following happens on the channel page — reached by tapping any card's channel
name. That ordering is deliberate: a user inspects what a channel publishes before
committing, rather than following blind and looking afterwards. Pasting a channel
link from the "My channels" tab is the one other way in, kept because a user who
already knows the channel should not have to search for it.

The channel page must therefore work for channels that are **not** followed. It
already navigates on a `Subscription` value built ad-hoc from a search result
(`LibraryView.swift:861`) without writing to the store; that stays, and the header
carries Follow / Unfollow so the state is visible where the decision is made.

### Typing does nothing

Search runs on submit only. The local feed filter is removed.

This gives up instant filtering of the feed, which is a real loss. It is worth it
because that filter shared one text field with a network search, and the two
produced unrelated results from the same keystrokes. One field, one behaviour.

### Filter chips are removed entirely

The user first chose "keep only the filter chips", then switched to the two-tab
layout. These are alternatives, not additions: the tab carries subscriptions, so
the chips would restore the duplication this round removes. Subscriptions appear
exactly once in Discover — the "My channels" tab.

### Preset search-term chips are removed

`ChannelSearchTerms`' eight terms were validated **for channel search** — its own
comment records testing 13 candidates and keeping the 8 that each returned 20
on-topic channels. Searching `podcast` for *videos* returns miscellaneous videos;
that validation does not transfer. Rather than ship chips whose results nobody has
checked, the empty state uses prose guidance.

Pasting a link still imports directly. A URL cannot be a search term, so that
branch has no ambiguity.

## Data model

### One card type

"Latest" carries `DiscoverEntry` (RSS); search carries `ChannelVideo` (HTML).
Those models stay separate for the reason the earlier spec gives — different
sources, different reliability, different field availability, and merging them
would mean optional-everything. But the *UI* must have one card, so a
presentation type sits between:

```swift
struct VideoCardItem: Identifiable, Equatable {
    let videoId: String
    let title: String
    let channelTitle: String?
    let channelId: String?     // nil → channel name is not tappable
    let durationText: String?  // always nil from RSS
    let metaText: String       // "3 days ago · 1.2M views"
    let thumbnailURL: URL?
    let watchURL: URL
    var id: String { videoId }
}
```

Two initialisers, one from each source. One `VideoCard` view. Missing duration is
expressed by `durationText == nil` rather than by a second card layout.

This replaces three separately-written row types — `DiscoverListItem`,
`ChannelVideoRow`, `ChannelUploadRow` — which differ in whether they show a
thumbnail at all. That divergence is the direct cause of the inconsistent feel.

### Site-wide search

Dropping `sp=EgIQAg==` switches `youtube.com/results` from channels to videos;
the earlier spec measured 0 channels / 19 videos without it.

**The renderer shape is unverified.** In-channel search serves the older
`videoRenderer`; the channel videos page has already migrated to
`lockupViewModel`. Which side the site-wide results page sits on is unknown —
`curl` cannot reach YouTube from this sandbox, the same constraint both earlier
specs recorded. Implementation targets `videoRenderer`, whose parser already
exists, and `structureMissing` is the honest fallback if that guess is wrong.
Confirm on device before assuming either shape.

`ChannelVideo` gains `channelTitle` and `channelId`, read from `ownerText` and
`browseEndpoint.browseId`. Without them a search result's card has no channel name
to tap, which would break the only path to following.

**Shorts filtering is also unverified for site-wide search.** In-channel search
returned zero `/shorts/` references; site-wide search probably returns some. The
RSS path's existing `/shorts/` filter is the model, but the signal needs
on-device confirmation.

### Channel page header

One extra request to the channel page, plus a parser for avatar, subscriber count,
and title. This layer is mid-migration on YouTube's side, so a header parse
failure must not produce an error state: the page falls back to the channel title
the video card already supplied and shows content as usual.

`ChannelDetailViewModel` currently holds only a `Subscription` value and a fetch
service; it has no access to `SubscriptionStore`. Putting Follow / Unfollow in the
header requires injecting the store, so the button reflects live follow state and
writes through. The header's own copy of avatar and subscriber count comes from
this fetch, not from the stored `Subscription` — the stored fields exist to render
the "My channels" list without N extra requests, and the two must not be confused.

`Subscription` gains `avatarURL` and `subscriberText`, captured when following.
Subscriptions saved before this change have neither; they render a monogram
placeholder rather than triggering a backfill fetch, which avoids a migration for
cosmetic data.

**Both new fields must be optional.** `SubscriptionStore` decodes the whole array
with one `try?` (`SubscriptionStore.swift:20`) — a single undecodable element
silently empties the follow list. A required field would wipe every existing
user's subscriptions.

## Visual design

Existing `NXSpacing` / `NXColor` / `NXFont` tokens throughout; no new tokens.

### Video card

```
┌──────────┐  Title, up to two lines          NXFont.bodyMedium
│ thumb    │  Channel name ›                  NXColor.primary, tappable
│ 16:9  ⏱  │  3 days ago · 1.2M views         auxiliary / textSecondary
└──────────┘  + Add to Nexa   |   In your library
```

- Thumbnail fixed 16:9 at 112pt wide, `NXRadius.small`. All three sources provide
  thumbnails, so the column is never empty. Loading shows a `surface2` block;
  failure degrades to a play glyph — never a blank gap.
- **Duration overlays the thumbnail's bottom-right corner**, not the byline. When
  RSS supplies none, a corner badge is simply absent, whereas a missing byline
  segment makes text lines ragged. Duration is also the strongest signal for
  whether a 4-hour episode is worth an expensive pipeline run (per the earlier
  spec), so the image corner suits it better than a run of small text.
- Channel name gets its own line and is tappable, because it is the only entry
  point to following and needs to read as a target.
- **No description snippet.** All three current row types show two lines of it, so
  a screen holds 2-3 cards. YouTube descriptions typically open with sponsor copy
  and links. Dropping it fits 5-6 cards per screen.

### Tabs

Text labels with a 2pt `NXColor.primary` indicator under the selected one, and a
`border` hairline beneath the row. Not a UIKit segmented control — its pill shape
does not match the app's flat, squared visual language.

### Channel row

32pt circular avatar, title, subscriber count, trailing chevron. Missing avatar
renders a monogram on a colour derived from hashing `channelId`, so a given
channel keeps the same colour across launches.

### The two-column preview is removed

`DiscoverView.content` (`:699-717`) shows a list beside a `DiscoverPreview` in
regular width, auto-selecting the first entry. The preview duplicates what the
card shows, and "selected" carries no meaning on a page whose only action is
import — tapping a card merely changes the right pane, which is its own piece of
counter-intuitive behaviour. Single column, max-width constrained and centred on
wide screens. `DiscoverPreview`, `selectedEntry`, and the auto-select logic go
with it.

## States

Search state sits over the tabs rather than beside them: submitting enters it,
and leaving it returns to whichever tab was active. "← Back" and the field's clear
button are the same action — both empty the query and exit. Two controls that
looked similar but behaved differently is the class of problem this round removes,
so they are deliberately identical.

| Case | Display |
|---|---|
| No subscriptions (Latest) | Guidance + "Paste a channel link"; notes that search works too |
| No subscriptions (My channels) | Same guidance, with the paste action as the primary button |
| Subscribed, feed empty | Suggests searching |
| Some channels failed | Show the rest; one thin notice (existing `failedChannelIds`) |
| All channels failed | `NXErrorState` with retry |
| Searching | Skeleton cards |
| No results | "No videos match X." |
| Structure missing | "Search is unavailable right now — you can paste a video link to import it." + retry |
| Channel header parse failed | Title-only header, content unaffected |

Skeleton cards rather than a text `ProgressView`: search replaces the whole page,
and a text spinner collapses the layout and then re-expands it. The three current
spinners are all text.

## Code organisation

`LibraryView.swift` is 2384 lines. Discover moves out:

- `Views/DiscoverView.swift` — the screen, tabs, search state
- `Views/VideoCard.swift` — the shared card
- `Models/VideoCardItem.swift`
- `Logic/VideoSearchParser.swift` — site-wide results
- `Logic/ChannelHeaderParser.swift` — avatar, subscriber count

Deleted, having lost their purpose once search returns videos: `searchChannels`,
`ChannelSearchParser`, `ChannelSearchResult`, `ChannelSearchRow`,
`ChannelSearchTerms`, `DiscoverShortcutChips`, `DiscoverChannelFilters`,
`DiscoverPreview`, `DiscoverListItem`, and their tests. Keeping them would keep
the channel-versus-video ambiguity alive in the codebase.

`resolveChannel` stays — pasting a channel link still uses it.

## Testing

Existing layering: pure logic in `Logic/`, offline via `swift test` (183 cases
today).

- `VideoCardItem` — RSS init yields nil duration; `ChannelVideo` init keeps it;
  nil `channelId` makes the channel name non-tappable
- `VideoSearchParser` — parses `channelTitle`/`channelId` from local HTML; absent
  `ytInitialData` → `structureMissing`; present but zero renderers → `parsed([])`.
  These two must stay distinct: one is "YouTube changed", the other is "nothing
  matched", and they lead to different UI.
- `ChannelHeaderParser` — parses avatar and subscriber count; returns nil rather
  than throwing on failure
- `DiscoverViewModel` — tab switching; submit then clear returns to the prior tab;
  typing issues no request; unfollowing drops that channel's entries from the feed
- `ChannelDetailViewModel` — Follow writes to the store and the button flips;
  Unfollow reverses it; the screen still loads for a channel never followed
- `SubscriptionStore` — decodes JSON written before `avatarURL` and
  `subscriberText` existed, without emptying the list

### Device-only

Two items cannot be verified offline, and the sandbox cannot reach YouTube:

1. Whether site-wide search serves `videoRenderer` or `lockupViewModel`
2. The Shorts signal in site-wide results

Both ship behind `structureMissing` and need a device run to confirm.

## Out of scope

- No backend changes; `POST /api/episodes/import` is reused unchanged.
- No pagination — still requires forging the innertube API.
- No avatar backfill for existing subscriptions.
- No search history or suggestions.
- No restoration of the local feed filter under a second input.
