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
    @State private var showSearch = false
    @StateObject private var history = SearchHistoryStore()
    @State private var playingId: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        // The brand row is pinned above the scrolling content rather than living in
        // the navigation bar, which collapsed it on scroll.
        VStack(alignment: .leading, spacing: 0) {
            BrandHeader {
                // Opens the full-screen page rather than expanding here. Sharing a
                // 44pt bar with the brand and another icon left the field cramped,
                // and typing in it left a stale feed sitting behind.
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 19, weight: .medium))
                }
                .accessibilityLabel("Search")

                Button { showAddChannel = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                }
                .accessibilityLabel("Follow a channel by link")
            }

            // The row above stays put; only this scrolls.
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Same inset as the brand row, so both edges line up.
                    .padding(.horizontal, NXSpacing.x4)
            }
        }
        // Single column. The old two-pane layout auto-selected a card and showed
        // a preview duplicating it, on a page whose only action is import — so
        // "selected" meant nothing and tapping a card appeared to do nothing.
        .frame(maxWidth: 720, alignment: .leading)
        .task { await vm.refresh() }
        // Pulling is an explicit "this is not what I want" — it re-searches rather
        // than re-reading today's cache.
        .refreshable { await vm.refresh(forced: true) }
        // One header per screen: the brand row above. Left visible, the navigation
        // bar drew a second band behind it in a different tone.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
        .fullScreenCover(isPresented: $showSearch) {
            SearchScreen(
                query: $vm.query,
                history: history,
                onSubmit: { term in Task { await vm.runSearch(term) } },
                onDismiss: { showSearch = false },
                onPasteLink: onAddToNexa)
        }

    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            if vm.isSearchActive {
                searchState
            } else {
                latestTab
            }
        }
        .padding(.top, NXSpacing.x4)
    }

    @ViewBuilder
    private var latestTab: some View {
        if !vm.hasSubscriptions {
            // Something to start from rather than an instruction. An empty screen
            // that tells you to go find content puts the work on someone who has not
            // yet seen what the app is for.
            if vm.coldStartLoading && vm.coldStartCards.isEmpty {
                skeletons
            } else if vm.coldStartCards.isEmpty {
                if let diagnostic = vm.coldStartDiagnostic {
                    // Why it is empty, rather than a generic prompt that hides the
                    // reason. Reachable device logs would be better; this is what is
                    // available.
                    Text(diagnostic)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NXEmptyState(
                    title: "Follow a channel to fill this",
                    message: "Search for a video above and tap its channel name to follow it, or paste a channel link.",
                    actionTitle: "Paste a channel link",
                    action: { showAddChannel = true })
            } else {
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    // Says where these came from, so they are not mistaken for a
                    // feed the user built.
                    Text("Long-form talks and podcasts to start with. Follow a channel to replace this with its uploads.")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    cardList(vm.coldStartCards, onNearEnd: vm.loadMoreColdStartIfNeeded)
                    if vm.hasMoreColdStartCards {
                        LoadMoreHint()
                    }
                }
            }
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
    private func cardList(_ cards: [VideoCardItem],
                          onNearEnd: ((VideoCardItem) -> Void)? = nil) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(cards) { card in
                VideoCard(
                    item: card,
                    imported: importedVideoIds().contains(card.videoId),
                    importing: importing,
                    onImport: { onAddToNexa(card.watchURL.absoluteString) },
                    onOpenChannel: onOpenChannel,
                    // Toggles: tapping the playing card collapses it. Only one
                    // plays at a time, so each WKWebView is torn down when another
                    // starts — one WebContent process, not one per card.
                    onTap: { playingId = playingId == card.videoId ? nil : card.videoId },
                    explorationTopic: vm.explorationIds.contains(card.videoId)
                        ? vm.explorationTopic : nil,
                    playing: playingId == card.videoId)
                    .onAppear {
                        onNearEnd?(card)
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

private struct LoadMoreHint: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            ProgressView()
                .scaleEffect(0.72)
                .tint(NXColor.textTertiary(scheme))
            Text("Loading more")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NXSpacing.x4)
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
