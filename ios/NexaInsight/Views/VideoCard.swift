#if os(iOS)
import SwiftUI

// The one video card. Every video in the app renders through this, whether it
// came from a channel's RSS feed, a site-wide search, or an in-channel search.
//
// Three separately-written row layouts preceded it and disagreed on whether to
// show a thumbnail at all, which is what made the app feel inconsistent from one
// screen to the next.
struct VideoCard: View {
    let item: VideoCardItem
    let imported: Bool
    let importing: Bool
    let onImport: () -> Void
    // nil on a channel's own screen, where the channel is already known.
    var onOpenChannel: ((String, String) -> Void)?
    // Tapping the card itself. Nothing responded to this before — only the channel
    // name and the Add button — so the obvious gesture on the obvious target was
    // inert.
    var onTap: (() -> Void)?
    // Set on items from outside the followed set. Mixed into the feed rather than
    // sectioned off, so the marker is the only thing distinguishing them — without
    // it the feed would silently contain channels you never chose.
    var explorationTopic: String?
    // When set, the thumbnail is replaced in place by the embed player. Expanding
    // inline rather than pushing a sheet keeps you in the list — the decision this
    // screen supports is a comparison between videos, and a modal hides the others.
    var playing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Full-width 16:9, as on YouTube. This costs density — about 2.4 cards
            // per screen against 6.3 for the previous row — bought back partly by
            // moving Add into the ⋮ menu so no card carries a button.
            // The player takes the thumbnail's exact frame, so expanding does not
            // move anything below it.
            ZStack {
                if playing, let url = YouTubeWeb.embed(videoId: item.videoId) {
                    WebPage(url: url, wrapInFrame: true)
                        .background(Color.black)
                } else {
                    VideoThumbnail(url: item.thumbnailURL, durationText: item.durationText)
                        .onTapGesture { onTap?() }
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: NXRadius.surface))

            HStack(alignment: .top, spacing: NXSpacing.x3) {
                channelAvatar

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // One line, not two: channel, views and age read as a single
                    // byline the way they do on YouTube.
                    Text(byline)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(1)

                    if let explorationTopic {
                        Text("Suggested · \(explorationTopic)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(NXColor.insight)
                    }
                }
                .onTapGesture { onTap?() }

                Spacer(minLength: 0)

                addButton
            }
            .padding(.top, NXSpacing.x3)
            .padding(.horizontal, NXSpacing.x1)
        }
        .padding(.bottom, NXSpacing.x4)
        // `.contain`, NOT `.combine`: combining would swallow the menu and the
        // channel link into one label, making both unreachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var byline: String {
        // The channel name joins the byline here rather than having its own line —
        // it is still reachable through the avatar and the ⋮ menu.
        [item.channelTitle, item.metaText.isEmpty ? nil : item.metaText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var channelAvatar: some View {
        if let channelTitle = item.channelTitle {
            let avatar = ChannelAvatar(
                url: item.channelAvatarURL,
                title: channelTitle,
                channelId: item.channelId ?? channelTitle,
                size: 36)
            if let channelId = item.channelId, let onOpenChannel {
                Button { onOpenChannel(channelId, channelTitle) } label: { avatar }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open channel \(channelTitle)")
            } else {
                avatar
            }
        }
    }

    // One glyph, no menu and no words.
    //
    // "Add to Nexa" as text was wider than the action deserved on a card whose job
    // is to show a thumbnail and a title, and burying it in a ⋮ menu hid the only
    // thing you come here to do behind an extra tap. The ⋮ carried a second item —
    // go to channel — which the tappable avatar already provides.
    //
    // The three states are distinct glyphs rather than one that changes colour, so
    // "already added" cannot be mistaken for "tap to add" at a glance.
    @ViewBuilder
    private var addButton: some View {
        if imported {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(NXColor.success)
                .frame(width: 36, height: 36)
                .accessibilityLabel("In your library")
        } else {
            Button(action: onImport) {
                Image(systemName: importing ? "clock" : "plus.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(importing
                                     ? NXColor.textTertiary(scheme)
                                     : NXColor.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(importing)
            // The label carries the title, since the glyph alone would announce as
            // "add" with no indication of what is being added.
            .accessibilityLabel(importing
                                ? "Adding \(item.title)"
                                : "Add to Nexa: \(item.title)")
        }
    }

    // Title, publisher, length — the order in which someone decides whether to
    // spend four hours on this.
    private var accessibilityDescription: String {
        [item.title, item.channelTitle, item.durationText, item.metaText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

// Fixed 16:9 at 112pt. All three sources provide thumbnails, so this column is
// never empty — and it degrades to a glyph rather than a blank gap when a
// specific image fails.
private struct VideoThumbnail: View {
    let url: URL?
    let durationText: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            image
            // Duration overlays the image instead of joining the metadata line.
            // RSS carries no duration, and a missing badge is invisible where a
            // missing text segment would leave the byline ragged. It is also the
            // strongest signal for whether a 4-hour episode is worth an
            // expensive pipeline run, so it earns the prominence.
            if let durationText {
                Text(durationText)
                    .accessibilityHidden(true)   // already in the row's label
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .padding(NXSpacing.x2)
            }
        }
        // Width first, then height derived from it. A fixed 112pt frame was still
        // here, which is why the "full-width" card kept rendering as a thumbnail
        // strip down the left third of the row.
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: NXRadius.surface))
    }

    @ViewBuilder
    private var image: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                default:
                    NXColor.surface2(scheme)
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            NXColor.surface2(scheme)
            Image(systemName: "play.rectangle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
    }
}

// Shown while a search is in flight. A text spinner collapsed the layout and
// then re-expanded it, because search replaces the whole page.
struct VideoCardSkeleton: View {
    @Environment(\.colorScheme) private var scheme
    @State private var pulse = false

    var body: some View {
        // Mirrors VideoCard's shape exactly. A skeleton of the wrong proportions
        // makes the list jump when real content replaces it.
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            RoundedRectangle(cornerRadius: NXRadius.surface)
                .fill(NXColor.surface2(scheme))
                .aspectRatio(16 / 9, contentMode: .fit)
            HStack(alignment: .top, spacing: NXSpacing.x3) {
                Circle()
                    .fill(NXColor.surface2(scheme))
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    bar(widthFraction: 0.9)
                    bar(widthFraction: 0.5)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.bottom, NXSpacing.x4)
        .opacity(pulse ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }

    private func bar(widthFraction: CGFloat) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3)
                .fill(NXColor.surface2(scheme))
                .frame(width: geo.size.width * widthFraction, height: 10)
        }
        .frame(height: 10)
    }
}

// A channel's avatar, or a monogram when we have none. Subscriptions saved
// before avatars were captured have no URL, and backfilling one request per row
// is not worth it for decoration — so the monogram is a first-class state, with
// a colour derived from the channel id so it stays stable across launches.
struct ChannelAvatar: View {
    let url: URL?
    let title: String
    let channelId: String
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var monogram: some View {
        ZStack {
            tint
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var initial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.first ?? "?").uppercased()
    }

    // Stable per channel: a hash of the id, not a random or ordinal colour, so
    // the same channel keeps its colour between launches and across screens.
    private var tint: Color {
        let hues: [Double] = [0.58, 0.72, 0.06, 0.34, 0.87, 0.13]
        let sum = channelId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Color(hue: hues[sum % hues.count], saturation: 0.52, brightness: 0.68)
    }
}
#endif
