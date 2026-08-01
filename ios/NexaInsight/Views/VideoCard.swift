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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            // Thumbnail and title open the preview; the channel link and Add stay
            // separate targets below, which is why this is not one big Button.
            VideoThumbnail(url: item.thumbnailURL, durationText: item.durationText)
                .onTapGesture { onTap?() }

            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(item.title)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { onTap?() }

                channelLine

                if !item.metaText.isEmpty {
                    Text(item.metaText)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(1)
                }

                action
                    .padding(.top, NXSpacing.x1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, NXSpacing.x3)
        // `.contain`, NOT `.combine`: combining would swallow the Add button and
        // the channel link into one label, making both unreachable. This groups the
        // row while leaving its controls as separate targets.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    // Title, publisher, length — the order in which someone decides whether to
    // spend four hours on this.
    private var accessibilityDescription: String {
        [item.title, item.channelTitle, item.durationText, item.metaText]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    // The channel name is the only route to following a channel, so when it can
    // navigate it reads as a link. When it cannot, it stays plain text rather
    // than looking tappable and doing nothing.
    @ViewBuilder
    private var channelLine: some View {
        if let title = item.channelTitle {
            if let channelId = item.channelId, let onOpenChannel {
                Button {
                    onOpenChannel(channelId, title)
                } label: {
                    HStack(spacing: 2) {
                        Text(title)
                            .font(NXFont.auxiliary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(NXColor.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开频道 \(title)")
            } else {
                Text(title)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .lineLimit(1)
            }
        }
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
            .accessibilityLabel(importing ? "正在加入 Nexa" : "加入 Nexa：\(item.title)")
        }
    }
}

// Fixed 16:9 at 112pt. All three sources provide thumbnails, so this column is
// never empty — and it degrades to a glyph rather than a blank gap when a
// specific image fails.
private struct VideoThumbnail: View {
    let url: URL?
    let durationText: String?
    @Environment(\.colorScheme) private var scheme

    private let width: CGFloat = 112

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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: NXRadius.small))
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
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            RoundedRectangle(cornerRadius: NXRadius.small)
                .fill(NXColor.surface2(scheme))
                .frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                bar(widthFraction: 0.9)
                bar(widthFraction: 0.4)
                bar(widthFraction: 0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, NXSpacing.x3)
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
