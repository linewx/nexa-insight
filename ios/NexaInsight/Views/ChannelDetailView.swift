#if os(iOS)
import SwiftUI

// One channel: follow it, search inside it, or browse its recent uploads.
//
// Search is the primary surface because it is the only path that reaches the back
// catalog — a channel with years of history cannot be served by a "latest N" list.
//
// This screen works for channels the user does NOT follow. It is reached by
// tapping a channel name on any video card, which is how someone inspects what a
// channel publishes before committing to it.
struct ChannelDetailView: View {
    @StateObject var vm: ChannelDetailViewModel
    let importing: Bool
    let onImport: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x4) {
                header
                searchField

                if vm.isSearchActive {
                    searchSection
                } else {
                    uploadsSection
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, NXSpacing.x4)
            .padding(.vertical, NXSpacing.x4)
        }
        .background(NXColor.background(scheme))
        .navigationTitle(vm.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    // Avatar and subscriber count come from the channel page. When that parse
    // fails they are simply absent — the title falls back to the name the video
    // card supplied, and the content below is unaffected.
    private var header: some View {
        HStack(spacing: NXSpacing.x3) {
            ChannelAvatar(
                url: vm.avatarURL,
                title: vm.title,
                channelId: vm.channelId,
                size: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(vm.title)
                    .font(NXFont.sectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(2)
                if let subscriberText = vm.subscriberText {
                    Text(subscriberText)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
            }

            Spacer(minLength: NXSpacing.x2)

            followButton
        }
    }

    // Follow lives here, where the user can see what the channel publishes before
    // deciding. This is the only screen that writes to the subscription store.
    @ViewBuilder
    private var followButton: some View {
        if vm.following {
            Button(action: vm.toggleFollow) {
                NXTag(text: "Following", tint: NXColor.success)
            }
            .buttonStyle(.plain)
        } else {
            NXSecondaryButton(title: "Follow", systemName: "plus", action: vm.toggleFollow)
                .fixedSize(horizontal: true, vertical: false)
        }
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

            if vm.searching {
                skeletons
            } else if vm.searchUnavailable {
                // Distinct from "no match": the page could not be read at all,
                // so point at the fallback that needs no page structure.
                NXErrorState(
                    message: "Browsing this channel is unavailable right now. You can paste a video link on Discover to import it.",
                    retry: { Task { await vm.runSearch() } })
            } else if vm.resultCards.isEmpty {
                Text("No videos in this channel match \(vm.searchedTerm ?? "").")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                cardList(vm.resultCards)
                // Pagination would need the innertube API, so the cap is stated
                // rather than silently truncating.
                Text("Showing the top \(vm.resultCards.count) matches.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
        }
    }

    @ViewBuilder
    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            // The title states which source you are looking at, because the two
            // have very different ceilings — 865 versus 15 for the same channel.
            NXSectionHeader(title: vm.catalog.isEmpty ? "Recent uploads" : "All videos")

            if vm.loadingUploads && vm.uploadCards.isEmpty {
                skeletons
            } else if vm.uploadCards.isEmpty {
                Text("Could not load this channel's uploads. Try searching instead.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                cardList(vm.uploadCards)
                footer
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if vm.canLoadMore {
            // The trigger is the footer's own appearance rather than a "load more"
            // button: reaching the bottom IS the intent to see more.
            HStack(spacing: NXSpacing.x2) {
                ProgressView().controlSize(.small)
                Text(countText)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, NXSpacing.x3)
            .task(id: vm.uploadCards.count) { await vm.loadMoreIfNeeded() }
        } else {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                Text(countText)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                // A paging failure is stated inline: the videos already loaded
                // stay usable, so this is not an error state.
                if let catalogError = vm.catalogError {
                    Text(catalogError)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, NXSpacing.x2)
        }
    }

    // Never silently truncates: whichever source is in use, the count says what is
    // shown and what the ceiling is.
    private var countText: String {
        let shown = vm.uploadCards.count
        if vm.catalog.isEmpty {
            return vm.hasCatalog
                ? "Showing \(shown) recent uploads. The full catalog needs a working YouTube API key."
                : "Showing this channel's \(shown) most recent uploads. Add a YouTube API key in Settings to browse the full catalog, or search to find older videos."
        }
        if let total = vm.catalogTotal, total > shown {
            return "Showing \(shown) of \(total) videos."
        }
        return "Showing all \(shown) videos."
    }

    @ViewBuilder
    private func cardList(_ cards: [VideoCardItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(cards) { card in
                // No onOpenChannel here: the channel is already known, so a
                // tappable name would navigate back to this screen.
                VideoCard(
                    item: card,
                    imported: vm.isImported(videoId: card.videoId),
                    importing: importing,
                    onImport: { onImport(card.watchURL.absoluteString) })
                if card.id != cards.last?.id {
                    Divider().overlay(NXColor.border(scheme))
                }
            }
        }
    }

    private var skeletons: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { _ in
                VideoCardSkeleton()
                Divider().overlay(NXColor.border(scheme))
            }
        }
    }
}
#endif
