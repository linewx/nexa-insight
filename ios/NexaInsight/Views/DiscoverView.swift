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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        // No eyebrow, no page title, no segmented control. The tab bar says where
        // you are, and Channels moved to its own tab — so this screen is now just
        // a field and the videos it finds.
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            searchField

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
        .navigationTitle("Discover")
        .task { await vm.refresh() }
        .refreshable { await vm.refresh() }
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
    }

    // One field, one behaviour: it searches videos when submitted, and imports
    // when what you pasted is a link. Typing does nothing on purpose — it used to
    // filter the feed locally, so the keystrokes and the submitted results were
    // unrelated.
    private var searchField: some View {
        DiscoverSearchField(
            query: $vm.query,
            active: vm.isSearchActive,
            importing: importing,
            onSubmitSearch: { term in Task { await vm.runSearch(term) } },
            onImportLink: onAddToNexa,
            onClear: vm.clearSearch)
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
                    onOpenChannel: onOpenChannel)
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

private struct DiscoverSearchField: View {
    @Binding var query: String
    let active: Bool
    let importing: Bool
    let onSubmitSearch: (String) -> Void
    let onImportLink: (String) -> Void
    let onClear: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(focused ? NXColor.primary : NXColor.textTertiary(scheme))
                .accessibilityHidden(true)   // the field itself is the control

            TextField("Search videos, or paste a link", text: $query)
                .font(NXFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit(submit)

            if looksLikeSourceURL(query) {
                NXPrimaryButton(
                    title: importing ? "Adding" : "Add",
                    systemName: importing ? "clock" : nil,
                    disabled: importing,
                    action: submit)
                .fixedSize(horizontal: true, vertical: false)
            } else if active || !query.isEmpty {
                // Same action as "Back" above. Two controls that looked alike but
                // behaved differently is the confusion this screen removed.
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, NXSpacing.x3)
        .frame(height: 48)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .modifier(NXFocusModifier(focused: focused))
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A URL cannot be a search term, so this branch has no ambiguity.
        if looksLikeSourceURL(trimmed) {
            onImportLink(trimmed)
        } else {
            focused = false
            onSubmitSearch(trimmed)
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
