#if os(iOS)
import SwiftUI

// Discover has exactly two shapes, and the whole point of this file is that they
// never overlap:
//
//   empty query  → two tabs (Latest / My channels)
//   submitted    → search results, covering both tabs
//
// What this replaced had a search box returning channels while the identical box
// inside a channel returned videos, two rows of chips that looked the same and
// meant opposite things, and subscriptions shown twice with different behaviour.
struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    let importing: Bool
    let onAddToNexa: (String) -> Void
    let onOpenChannel: (String, String) -> Void
    @State private var showAddChannel = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            header
            searchField

            if vm.isSearchActive {
                searchState
            } else {
                tabs
                tabContent
            }
        }
        // Single column. The old two-pane layout auto-selected a card and showed
        // a preview duplicating it, on a page whose only action is import — so
        // "selected" meant nothing and tapping a card appeared to do nothing.
        .frame(maxWidth: 720, alignment: .leading)
        .task { await vm.refresh() }
        .refreshable { await vm.refresh() }
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x1) {
            Text("DISCOVER")
                .font(NXFont.label)
                .foregroundStyle(NXColor.primary)
            Text("Find something worth thinking through.")
                .font(compact ? .system(size: 20, weight: .semibold) : NXFont.pageTitle)
                .foregroundStyle(NXColor.text(scheme))
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

    private var tabs: some View {
        HStack(spacing: NXSpacing.x6) {
            ForEach(DiscoverViewModel.Tab.allCases) { tab in
                Button {
                    vm.tab = tab
                } label: {
                    Text(tab.title)
                        .font(vm.tab == tab ? NXFont.bodyMedium : NXFont.body)
                        .foregroundStyle(vm.tab == tab
                            ? NXColor.text(scheme)
                            : NXColor.textSecondary(scheme))
                        .padding(.bottom, NXSpacing.x2)
                        .overlay(alignment: .bottom) {
                            // A 2pt indicator rather than a segmented control,
                            // whose pill shape fights the app's flat language.
                            Rectangle()
                                .fill(vm.tab == tab ? NXColor.primary : .clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NXColor.border(scheme))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch vm.tab {
        case .latest: latestTab
        case .channels: channelsTab
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
    private var channelsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.subscriptions.isEmpty {
                NXEmptyState(
                    title: "No channels yet",
                    message: "Search for a video above and tap its channel name to follow that channel.",
                    actionTitle: "Paste a channel link",
                    action: { showAddChannel = true })
            } else {
                ForEach(vm.subscriptions) { subscription in
                    Button {
                        onOpenChannel(subscription.channelId, subscription.title)
                    } label: {
                        ChannelRow(subscription: subscription)
                    }
                    .buttonStyle(.plain)
                    // Swipe to unfollow: the native gesture, so no extra edit
                    // mode or per-row button is needed.
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            vm.removeSubscription(channelId: subscription.channelId)
                        } label: {
                            Label("Unfollow", systemImage: "minus.circle")
                        }
                    }
                    Divider().overlay(NXColor.border(scheme))
                }

                Button {
                    showAddChannel = true
                } label: {
                    HStack(spacing: NXSpacing.x3) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Paste a channel link")
                            .font(NXFont.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(NXColor.primary)
                    .padding(.vertical, NXSpacing.x3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
                    imported: false,
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

private struct ChannelRow: View {
    let subscription: Subscription
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            ChannelAvatar(
                url: subscription.avatarURL,
                title: subscription.title,
                channelId: subscription.channelId)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.title)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(1)
                if let subscriberText = subscription.subscriberText {
                    Text(subscriberText)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
        .padding(.vertical, NXSpacing.x3)
        .contentShape(Rectangle())
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
