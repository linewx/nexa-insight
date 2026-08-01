#if os(iOS)
import SwiftUI

// Watch a bit before committing.
//
// Two problems this solves at once. Tapping a card did nothing at all — only the
// channel name and the Add button responded, so the obvious gesture on the obvious
// target was inert. And importing runs transcription, per-sentence translation and
// AI chaptering over content that is routinely three to four hours, which is a
// slow and expensive thing to trigger from a small outlined button with no way to
// check first.
struct VideoPreviewSheet: View {
    let item: VideoCardItem
    let imported: Bool
    let importing: Bool
    let onImport: () -> Void
    var onOpenChannel: ((String, String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var loading = true

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                player
                details
                Spacer(minLength: 0)
                importBar
            }
            .background(NXColor.background(scheme))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var player: some View {
        ZStack {
            // 16:9, matching the source. A fixed height would letterbox or crop
            // depending on the device width.
            Color.black
            if let url = YouTubeWeb.embed(videoId: item.videoId) {
                WebPage(url: url, onLoadingChange: { loading = $0 }, wrapInFrame: true)
            } else {
                Text("This video cannot be previewed.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(.white.opacity(0.7))
            }
            if loading {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Text(item.title)
                .font(NXFont.sectionTitle)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: NXSpacing.x2) {
                // Duration decides whether this is worth an expensive pipeline
                // run, so it is stated in words here rather than as a corner badge.
                if let duration = item.durationText {
                    NXTag(text: duration, tint: NXColor.primary)
                }
                Text(item.metaText)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            }

            if let channelTitle = item.channelTitle {
                if let channelId = item.channelId, let onOpenChannel {
                    Button {
                        dismiss()
                        onOpenChannel(channelId, channelTitle)
                    } label: {
                        HStack(spacing: 2) {
                            Text(channelTitle).font(NXFont.auxiliary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(NXColor.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open channel \(channelTitle)")
                } else {
                    Text(channelTitle)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                }
            }
        }
        .padding(NXSpacing.x4)
    }

    @ViewBuilder
    private var importBar: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            if imported {
                NXTag(text: "In your library", tint: NXColor.success)
            } else {
                NXPrimaryButton(
                    title: importing ? "Adding" : "Add to Nexa",
                    systemName: importing ? "clock" : "plus",
                    disabled: importing,
                    action: {
                        onImport()
                        dismiss()
                    })
                // Says what the button costs. The preview exists so this decision
                // can be made deliberately, so hiding the price would defeat it.
                Text("Transcribes, translates every sentence, and builds chapters. Runs in the background.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, NXSpacing.x4)
        .padding(.bottom, NXSpacing.x4)
    }
}
#endif
