#if os(iOS)
import SwiftUI

// Discover has exactly two shapes, and the whole point of this file is that they
// never overlap:
//
//   empty query  → the newest videos from channels you follow
//   submitted    → site-wide video search results
//
// What this replaced had a search box returning channels while the identical box
// inside a channel returned videos, two rows of chips that looked the same and
// meant opposite things, and subscriptions shown twice with different behaviour.
// The Latest/Channels segmented control that followed it is gone too: Channels is
// a tab now, so this screen has no internal mode switch at all.
struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    let importing: Bool
    let onAddToNexa: (String) -> Void
    let onOpenChannel: (String, String) -> Void
    // Which videos are already in the library. Read as a closure so a video
    // imported during this session flips to "In your library" without rebuilding
    // the view — the card said "Add to Nexa" forever before this.
    var importedVideoIds: () -> Set<String> = { [] }
    @State private var showAddChannel = false
    @State private var searchExpanded = false
    @State private var previewing: VideoCardItem?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        // Nothing above the content but the shared brand header. No eyebrow, no
        // page title naming what the tab bar already highlights, and no docked
        // search field — the search lives in the toolbar as an icon.
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            if vm.isSearchActive {
                searchState
            } else {
                latestTab
            }
        }
        // Single column. The old two-pane layout auto-selected a card and showed
        // a preview duplicating it, on a page whose only action is import — so
        // "selected" meant nothing and tapping a card appeared to do nothing.
        .frame(maxWidth: 720, alignment: .leading)
        .toolbar {
            // The brand yields while searching: a toolbar splits its width between
            // leading and trailing items, so leaving it in squeezed the field to
            // about 100pt — too narrow to read your own query.
            if !searchExpanded && !vm.isSearchActive {
                BrandHeader()
            }
            ToolbarItem(placement: .topBarTrailing) {
                CollapsibleSearchField(
                    query: $vm.query,
                    active: vm.isSearchActive,
                    placeholder: "Search videos",
                    onSubmit: { term in Task { await vm.runSearch(term) } },
                    onClear: vm.clearSearch,
                    onPasteLink: onAddToNexa,
                    expanded: $searchExpanded)
            }
            .nxPlainToolbarItem()
            // Pasting a link keeps its own button: folding it behind the search
            // icon would add a tap to the one action that has no alternative.
            if !searchExpanded && !vm.isSearchActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAddChannel = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Follow a channel by link")
                }
                .nxPlainToolbarItem()
            }
        }
        .task { await vm.refresh() }
        .refreshable { await vm.refresh() }
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
        .sheet(item: $previewing) { card in
            VideoPreviewSheet(
                item: card,
                imported: importedVideoIds().contains(card.videoId),
                importing: importing,
                onImport: { onAddToNexa(card.watchURL.absoluteString) },
                onOpenChannel: onOpenChannel)
        }
    }

    @ViewBuilder
    private var latestTab: some View {
        if !vm.hasSubscriptions {
            NXEmptyState(
                title: "Follow a channel to fill this",
                message: "Search for a video above and tap its channel name to follow it, or paste a channel link.",
                actionTitle: "Paste a channel link",
                action: { showAddChannel = true })
        } else if let feedError = vm.feedError {
            NXErrorState(message: feedError, retry: { Task { await vm.refresh() } })
        } else if vm.loading && vm.entries.isEmpty {
            skeletons
        } else if vm.feedCards.isEmpty {
            NXEmptyState(
                title: "Nothing new from your channels",
                message: "Search above to find a specific video, including older ones.")
        } else {
            if !vm.failedChannelIds.isEmpty {
                // Partial failure is a notice, not an error state — the entries
                // that did load stay on screen.
                Text("\(vm.failedChannelIds.count) of your channels could not be reached.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
            cardList(vm.feedCards)
        }
    }

    @ViewBuilder
    private var searchState: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            // Leaving search returns to whichever tab was active underneath.
            Button(action: vm.clearSearch) {
                HStack(spacing: NXSpacing.x1) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(NXFont.control)
                }
                .foregroundStyle(NXColor.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("退出搜索")

            if vm.searching {
                skeletons
            } else if vm.searchUnavailable {
                // Distinct from "nothing found": the page could not be read, so
                // point at the fallback that depends on no page structure.
                NXErrorState(
                    message: "Search is unavailable right now. You can still paste a video link to import it.",
                    retry: { Task { await vm.runSearch(vm.searchedTerm ?? "") } })
            } else if vm.resultCards.isEmpty {
                Text("No videos match \(vm.searchedTerm ?? "").")
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
    private func cardList(_ cards: [VideoCardItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(cards) { card in
                VideoCard(
                    item: card,
                    imported: importedVideoIds().contains(card.videoId),
                    importing: importing,
                    onImport: { onAddToNexa(card.watchURL.absoluteString) },
                    onOpenChannel: onOpenChannel,
                    onTap: { previewing = card })
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

struct AddChannelSheet: View {
    @ObservedObject var vm: DiscoverViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var working = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: NXSpacing.x4) {
                Text("Paste a YouTube channel link.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                TextField("youtube.com/@handle", text: $draft)
                    .font(NXFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { submit() }
                if let addError = vm.addError {
                    Text(addError)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NXPrimaryButton(
                    title: working ? "Adding" : "Follow channel",
                    systemName: working ? "clock" : "plus",
                    disabled: working || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submit)
                Spacer()
            }
            .padding(NXSpacing.x4)
            .navigationTitle("Follow a channel")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func submit() {
        working = true
        Task {
            await vm.addSubscription(url: ImportViewModel.normalizedYouTubeURL(draft))
            working = false
            if vm.addError == nil { dismiss() }
        }
    }
}
#endif
