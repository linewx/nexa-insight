#if os(iOS)
import SwiftUI

struct LibraryView: View {
    let store: EpisodeStore
    @ObservedObject var settings: AppSettings
    @StateObject private var vm: ImportViewModel
    @StateObject private var discover: DiscoverViewModel
    @State private var selectedSection: AppSection = .home
    @State private var showImport = false
    @State private var showSettings = false
    @State private var urlDraft = ""

    init(store: EpisodeStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        _vm = StateObject(wrappedValue: ImportViewModel(
            client: BackendClient(baseURL: URL(string: settings.backendBaseURL) ?? URL(string: "http://localhost:8000")!),
            store: store))
        _discover = StateObject(wrappedValue: DiscoverViewModel(
            store: SubscriptionStore(),
            service: DiscoverFeedService()))
    }

    var body: some View {
        NavigationStack {
            DashboardShell(
                episodes: vm.episodes,
                progress: vm.progress,
                importError: vm.importError,
                backendBaseURL: vm.backendBaseURL,
                importing: vm.importing,
                discover: discover,
                selectedSection: $selectedSection,
                urlDraft: $urlDraft,
                showImport: $showImport,
                showSettings: $showSettings,
                onAddToNexa: addToNexa,
                onResync: { id in Task { await vm.resyncContent(episodeId: id) } }
            )
            .navigationDestination(for: Int.self) { id in
                StudyView(episodeId: id, store: store, backendBaseURL: vm.backendBaseURL)
            }
            .sheet(isPresented: $showImport) {
                ImportSheet(vm: vm, urlDraft: $urlDraft)
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .onAppear {
                syncBackendClient()
                vm.reload()
            }
            .onChange(of: settings.backendBaseURL) { _, _ in syncBackendClient() }
        }
    }

    private func syncBackendClient() {
        let url = URL(string: settings.backendBaseURL) ?? URL(string: "http://localhost:8000")!
        vm.updateClient(BackendClient(baseURL: url))
    }

    private func addToNexa(_ url: String) {
        selectedSection = .library
        Task { await vm.startImport(urlString: url) }
    }
}

private enum AppSection: String, CaseIterable {
    case home
    case discover
    case library

    var title: String {
        switch self {
        case .home: return "Home"
        case .discover: return "Discover"
        case .library: return "Library"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .discover: return "sparkle.magnifyingglass"
        case .library: return "rectangle.stack"
        }
    }
}

private struct DashboardShell: View {
    let episodes: [EpisodeDTO]
    let progress: ImportViewModel.ImportProgress?
    let importError: String?
    let backendBaseURL: URL
    let importing: Bool
    @ObservedObject var discover: DiscoverViewModel
    @Binding var selectedSection: AppSection
    @Binding var urlDraft: String
    @Binding var showImport: Bool
    @Binding var showSettings: Bool
    let onAddToNexa: (String) -> Void
    var onResync: (Int) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }
    private var firstRun: Bool { episodes.isEmpty }
    private let sampleURL = "https://www.youtube.com/watch?v=9IMwRIei-Xc&t=347s"

    var body: some View {
        Group {
            if compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .background(NXColor.background(scheme))
        .toolbar(.hidden, for: .navigationBar)
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            AppSidebar(selection: $selectedSection, showSettings: $showSettings)
                .frame(width: 232)

            Divider().overlay(NXColor.border(scheme))

            ScrollView {
                regularMainContent
            }

            if !firstRun {
                Divider().overlay(NXColor.border(scheme))

                rightPanel
            }
        }
    }

    @ViewBuilder
    private var regularMainContent: some View {
        if selectedSection == .discover {
            DiscoverView(
                vm: discover,
                importing: importing,
                onAddToNexa: onAddToNexa
            )
            .padding(.horizontal, NXSpacing.x8)
            .padding(.vertical, NXSpacing.x8)
            .frame(maxWidth: .infinity)
        } else if selectedSection == .library {
            LibraryMain(
                episodes: episodes,
                progress: progress,
                importError: importError,
                backendBaseURL: backendBaseURL,
                onDiscover: { selectedSection = .discover },
                onAddSource: { openImport() }
            )
            .frame(maxWidth: 920)
            .padding(.horizontal, NXSpacing.x8)
            .padding(.vertical, NXSpacing.x8)
            .frame(maxWidth: .infinity)
        } else if firstRun {
            FirstRunView(
                progress: progress,
                importError: importError,
                backendBaseURL: backendBaseURL,
                importing: importing,
                onImport: { selectedSection = .discover },
                onSample: { onAddToNexa(sampleURL) }
            )
            .frame(maxWidth: 720)
            .padding(.horizontal, NXSpacing.x8)
            .padding(.vertical, NXSpacing.x8)
            .frame(maxWidth: .infinity)
        } else {
            DashboardMain(
                episodes: episodes,
                importing: importing,
                onImport: { selectedSection = .discover },
                onImportDraft: { openImport(with: $0) },
                onResync: onResync
            )
            .frame(maxWidth: 920)
            .padding(.horizontal, NXSpacing.x8)
            .padding(.vertical, NXSpacing.x8)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var rightPanel: some View {
        if selectedSection == .discover {
            DiscoverRightRail(onOpenDiscover: { selectedSection = .discover })
                .frame(width: 304)
        } else {
            ContextPanel(
                episodes: episodes,
                progress: progress,
                importError: importError,
                backendBaseURL: backendBaseURL,
                onImport: { selectedSection = .discover }
            )
            .frame(width: 304)
        }
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                MobileTopBar(selection: $selectedSection, onSettings: { showSettings = true })
                if selectedSection == .discover {
                    DiscoverView(
                        vm: discover,
                        importing: importing,
                        onAddToNexa: onAddToNexa
                    )
                } else if selectedSection == .library {
                    LibraryMain(
                        episodes: episodes,
                        progress: progress,
                        importError: importError,
                        backendBaseURL: backendBaseURL,
                        onDiscover: { selectedSection = .discover },
                        onAddSource: { openImport() }
                    )
                } else if firstRun {
                    FirstRunView(
                        progress: progress,
                        importError: importError,
                        backendBaseURL: backendBaseURL,
                        importing: importing,
                        onImport: { selectedSection = .discover },
                        onSample: { onAddToNexa(sampleURL) }
                    )
                } else {
                    DashboardMain(
                        episodes: episodes,
                        importing: importing,
                        onImport: { selectedSection = .discover },
                        onImportDraft: { openImport(with: $0) },
                        onResync: onResync
                    )
                    MobileSourceStatus(
                        progress: progress,
                        importError: importError,
                        backendBaseURL: backendBaseURL,
                        onImport: { openImport() }
                    )
                }
            }
            .padding(.horizontal, NXSpacing.x4)
            .padding(.top, NXSpacing.x4)
            .padding(.bottom, NXSpacing.x8)
        }
    }

    private func openImport(with draft: String = "") {
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlDraft = draft
        }
        showImport = true
    }
}

private struct FirstRunView: View {
    let progress: ImportViewModel.ImportProgress?
    let importError: String?
    let backendBaseURL: URL
    let importing: Bool
    let onImport: () -> Void
    let onSample: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? NXSpacing.x8 : NXSpacing.x12) {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                if !compact {
                    TopBar()
                }

                VStack(alignment: .leading, spacing: NXSpacing.x4) {
                    Text("Bring in a podcast, video, or conversation.\nThink through it with AI.")
                        .font(compact ? .system(size: 24, weight: .semibold) : NXFont.pageTitle)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Add, understand, discuss, capture, and resume without losing the thread.")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NXSpacing.x3) {
                        firstSourceButton
                        sampleButton
                    }
                    VStack(alignment: .leading, spacing: NXSpacing.x3) {
                        firstSourceButton
                        sampleButton
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            FirstRunStatus(
                progress: progress,
                importError: importError,
                backendBaseURL: backendBaseURL,
                onRetry: onImport
            )

            FirstRunLoop()
        }
        .padding(.top, compact ? NXSpacing.x4 : NXSpacing.x8)
        .padding(.bottom, NXSpacing.x8)
    }

    private var firstSourceButton: some View {
        NXPrimaryButton(
            title: importing ? "Adding" : "Add your first source",
            systemName: importing ? "clock" : "plus",
            disabled: importing,
            action: onImport
        )
    }

    private var sampleButton: some View {
        NXSecondaryButton(title: "Try a sample", systemName: "play.rectangle", action: onSample)
    }
}

private struct FirstRunStatus: View {
    let progress: ImportViewModel.ImportProgress?
    let importError: String?
    let backendBaseURL: URL
    let onRetry: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            Text("Source status")
                .font(NXFont.label)
                .foregroundStyle(NXColor.textTertiary(scheme))

            if let progress {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    StatusLine(
                        systemName: "sparkles",
                        tint: NXColor.primary,
                        title: "Preparing your source",
                        detail: progress.stage.capitalized
                    )
                    NXProgressIndicator(value: progress.percent, label: progress.stage)
                }
            } else if let importError {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    StatusLine(
                        systemName: "exclamationmark.triangle",
                        tint: NXColor.error,
                        title: "Add failed",
                        detail: cleanedImportError(importError)
                    )
                    Text("Your source link is still here. Check the backend connection, then retry or use another link.")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    NXSecondaryButton(title: "Try again", systemName: "arrow.clockwise", action: onRetry)
                }
            } else {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    StatusLine(
                        systemName: "server.rack",
                        tint: NXColor.success,
                        title: "Ready to add",
                        detail: backendBaseURL.absoluteString
                    )
                    Text("Paste a supported link and Nexa Insight will prepare playback, transcript, discussion context, and insight capture.")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, NXSpacing.x4)
        .overlay(alignment: .top) {
            Divider().overlay(NXColor.border(scheme))
        }
        .overlay(alignment: .bottom) {
            Divider().overlay(NXColor.border(scheme))
        }
    }
}

private struct FirstRunLoop: View {
    @Environment(\.colorScheme) private var scheme

    private let steps = [
        ("play.circle", "Play a segment", "Start from the source, not a blank chat."),
        ("text.quote", "Ask from context", "Select transcript or use the current position."),
        ("sparkle.magnifyingglass", "Save an insight", "Keep useful ideas tied to their evidence."),
        ("arrow.uturn.forward", "Resume later", "Return to the same source, time, and discussion.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            Text("First thinking loop")
                .font(NXFont.subsectionTitle)
                .foregroundStyle(NXColor.text(scheme))

            VStack(spacing: 0) {
                ForEach(steps.indices, id: \.self) { index in
                    FirstRunLoopRow(
                        systemName: steps[index].0,
                        title: steps[index].1,
                        detail: steps[index].2
                    )
                    if index < steps.count - 1 {
                        Divider().overlay(NXColor.border(scheme))
                    }
                }
            }
        }
    }
}

private struct FirstRunLoopRow: View {
    let systemName: String
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(title)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                Text(detail)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, NXSpacing.x3)
    }
}

private struct AppSidebar: View {
    @Binding var selection: AppSection
    @Binding var showSettings: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            HStack(spacing: NXSpacing.x3) {
                BrandMark()
                Text("Nexa Insight")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NXColor.text(scheme))
            }
            .padding(.top, NXSpacing.x6)
            .padding(.horizontal, NXSpacing.x4)

            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                ForEach(AppSection.allCases, id: \.self) { item in
                    SidebarItem(
                        title: item.title,
                        systemName: item.icon,
                        selected: selection == item,
                        action: { selection = item }
                    )
                }
            }
            .padding(.horizontal, NXSpacing.x3)

            Spacer()

            Button {
                showSettings = true
            } label: {
                SidebarItemContent(title: "Settings", systemName: "gearshape", selected: false)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, NXSpacing.x3)
            .padding(.bottom, NXSpacing.x4)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NXColor.surface1(scheme))
    }
}

private struct SidebarItem: View {
    let title: String
    let systemName: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarItemContent(title: title, systemName: systemName, selected: selected)
        }
        .buttonStyle(.plain)
    }
}

private struct SidebarItemContent: View {
    let title: String
    let systemName: String
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            Rectangle()
                .fill(selected ? NXColor.primary : Color.clear)
                .frame(width: 2, height: 18)
                .clipShape(Capsule())
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 18)
            Text(title)
                .font(NXFont.control)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? NXColor.text(scheme) : NXColor.textSecondary(scheme))
        .frame(height: 36)
        .padding(.trailing, NXSpacing.x3)
        .background(selected ? NXColor.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: NXRadius.control))
        .contentShape(Rectangle())
    }
}

private struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NXRadius.small)
                .fill(NXColor.primary)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

private struct MobileTopBar: View {
    @Binding var selection: AppSection
    let onSettings: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            HStack {
                HStack(spacing: NXSpacing.x3) {
                    BrandMark()
                    Text("Nexa Insight")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(NXColor.text(scheme))
                }
                Spacer()
                NXIconButton(systemName: "gearshape", accessibilityLabel: "Settings", action: onSettings)
            }

            HStack(spacing: NXSpacing.x2) {
                ForEach(AppSection.allCases, id: \.self) { item in
                    Button {
                        selection = item
                    } label: {
                        Text(item.title)
                            .font(NXFont.control)
                            .foregroundStyle(selection == item ? NXColor.text(scheme) : NXColor.textSecondary(scheme))
                            .padding(.horizontal, NXSpacing.x2)
                            .frame(height: 32)
                            .background(selection == item ? NXColor.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: NXRadius.control))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct DiscoverView: View {
    @ObservedObject var vm: DiscoverViewModel
    let importing: Bool
    let onAddToNexa: (String) -> Void
    @State private var selectedEntry: DiscoverEntry?
    @State private var showAddChannel = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            DiscoverHeader(
                query: $vm.query,
                importing: importing,
                onAddToNexa: onAddToNexa,
                onSubmitSearch: { term in Task { await vm.runSearch(term) } })

            DiscoverShortcutChips(
                activeTerm: vm.searchedTerm,
                onSelect: { term in
                    vm.query = term
                    Task { await vm.runSearch(term) }
                })

            if vm.searchedTerm != nil {
                // Search results replace the feed while a search is active.
                ChannelSearchResults(vm: vm)
            } else if !vm.hasSubscriptions {
                NXEmptyState(
                    title: "Follow a channel to fill Discover",
                    message: "Tap a topic above, search for a channel, or paste a channel link.",
                    actionTitle: "Paste a channel link",
                    action: { showAddChannel = true })
            } else {
                subscribedFeed
            }
        }
        .task { await vm.refresh() }
        .refreshable { await vm.refresh() }
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
        .onChange(of: vm.visibleEntries) { _, items in
            if let selectedEntry, !items.contains(selectedEntry) {
                self.selectedEntry = compact ? nil : items.first
            }
        }
    }

    @ViewBuilder
    private var subscribedFeed: some View {
        DiscoverChannelFilters(
            subscriptions: vm.subscriptions,
            selectedChannelId: $vm.selectedChannelId,
            onAddChannel: { showAddChannel = true })

        if let feedError = vm.feedError {
            NXErrorState(message: feedError, retry: { Task { await vm.refresh() } })
        } else if vm.loading && vm.entries.isEmpty {
            ProgressView("Loading your channels")
                .font(NXFont.auxiliary)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if compact {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                DiscoverList(
                    items: vm.visibleEntries,
                    selectedEntry: $selectedEntry,
                    autoSelectFirst: false,
                    onClear: { vm.query = "" })
                if let selectedEntry {
                    DiscoverPreview(
                        entry: selectedEntry,
                        importing: importing,
                        onAddToNexa: { onAddToNexa(selectedEntry.watchURL.absoluteString) })
                }
            }
        } else {
            let previewEntry = selectedEntry ?? vm.visibleEntries.first
            HStack(alignment: .top, spacing: NXSpacing.x8) {
                DiscoverList(
                    items: vm.visibleEntries,
                    selectedEntry: $selectedEntry,
                    autoSelectFirst: true,
                    onClear: { vm.query = "" })
                .frame(minWidth: 360, maxWidth: 520)

                if let previewEntry {
                    DiscoverPreview(
                        entry: previewEntry,
                        importing: importing,
                        onAddToNexa: { onAddToNexa(previewEntry.watchURL.absoluteString) })
                    .frame(maxWidth: 420)
                }
            }
        }
    }
}

// Preset search terms. Tapping one runs a real search — these are strings, not
// a category taxonomy, so nothing here can go stale.
private struct DiscoverShortcutChips: View {
    let activeTerm: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NXSpacing.x2) {
                ForEach(ChannelSearchTerms.all, id: \.self) { term in
                    DiscoverFilterButton(
                        title: term.capitalized,
                        systemName: "magnifyingglass",
                        selected: activeTerm == term,
                        action: { onSelect(term) })
                }
            }
        }
    }
}

private struct ChannelSearchResults: View {
    @ObservedObject var vm: DiscoverViewModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            HStack {
                NXSectionHeader(title: "Channels")
                Spacer()
                NXTextButton(title: "Clear", systemName: "xmark", action: vm.clearSearch)
            }

            if vm.searchUnavailable {
                // Distinct from "nothing found": the page could not be read, so
                // point at the fallback that does not depend on page structure.
                NXErrorState(
                    message: "Channel search is unavailable right now. You can still add a channel by pasting its link.",
                    retry: { Task { await vm.runSearch(vm.searchedTerm ?? "") } })
            } else if vm.searching {
                ProgressView("Searching")
                    .font(NXFont.auxiliary)
            } else if vm.searchResults.isEmpty {
                Text("No channels found for \(vm.searchedTerm ?? "").")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.searchResults) { result in
                        ChannelSearchRow(
                            result: result,
                            following: vm.isFollowing(result),
                            onFollow: { Task { await vm.subscribe(to: result) } })
                        if result.id != vm.searchResults.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
            }
        }
    }
}

private struct ChannelSearchRow: View {
    let result: ChannelSearchResult
    let following: Bool
    let onFollow: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            thumbnail
            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(result.title)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(1)
                Text(byline)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .lineLimit(1)
                if let summary = result.summary {
                    Text(summary)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: NXSpacing.x2)
            if following {
                NXTag(text: "Following", tint: NXColor.success)
            } else {
                NXSecondaryButton(title: "Follow", systemName: "plus", action: onFollow)
            }
        }
        .padding(.vertical, NXSpacing.x3)
    }

    // subscriberText comes from the response's `videoCountText` — see
    // ChannelSearchParser for why that is not a mistake.
    private var byline: String {
        [result.subscriberText, result.handle]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let url = result.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(NXColor.surface2(scheme))
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(NXColor.surface2(scheme))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 15))
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
        }
    }
}

private struct DiscoverHeader: View {
    @Binding var query: String
    let importing: Bool
    let onAddToNexa: (String) -> Void
    let onSubmitSearch: (String) -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? NXSpacing.x3 : NXSpacing.x4) {
            HStack {
                Text("DISCOVER")
                    .font(NXFont.label)
                    .foregroundStyle(NXColor.primary)
                Spacer()
                if !compact {
                    Text("Public sources stay here until you add them.")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: compact ? NXSpacing.x1 : NXSpacing.x2) {
                Text(compact ? "Find a source to think through." : "Find something worth thinking through.")
                    .font(compact ? .system(size: 20, weight: .semibold) : NXFont.pageTitle)
                    .foregroundStyle(NXColor.text(scheme))
                if !compact {
                    Text("Search topics, people, questions, channels, or paste a link. Nexa decides whether to discover, add, upload, or answer.")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: NXSpacing.x3) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(focused ? NXColor.primary : NXColor.textTertiary(scheme))
                TextField("Search a topic, speaker, source, question, or link", text: $query)
                    .font(NXFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(submitQuery)
                if looksLikeSourceURL(query) {
                    NXPrimaryButton(
                        title: importing ? "Adding" : "Add",
                        systemName: importing ? "clock" : nil,
                        disabled: importing,
                        action: submitQuery
                    )
                    .fixedSize(horizontal: true, vertical: false)
                }
                if !compact {
                    Image(systemName: "command")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NXColor.textTertiary(scheme))
                    Text("K")
                        .font(NXFont.label)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
            }
            .padding(.horizontal, compact ? NXSpacing.x3 : NXSpacing.x4)
            .frame(height: compact ? 48 : 52)
            .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
            .modifier(NXFocusModifier(focused: focused))
        }
    }

    private func submitQuery() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if looksLikeSourceURL(trimmed) {
            onAddToNexa(trimmed)
        } else {
            onSubmitSearch(trimmed)
        }
    }
}

private struct DiscoverChannelFilters: View {
    let subscriptions: [Subscription]
    @Binding var selectedChannelId: String?
    let onAddChannel: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NXSpacing.x2) {
                DiscoverFilterButton(title: "All", systemName: "line.3.horizontal.decrease", selected: selectedChannelId == nil) {
                    selectedChannelId = nil
                }
                ForEach(subscriptions) { subscription in
                    DiscoverFilterButton(
                        title: subscription.title,
                        systemName: "play.rectangle",
                        selected: selectedChannelId == subscription.channelId
                    ) {
                        selectedChannelId = subscription.channelId
                    }
                }
                DiscoverFilterButton(title: "Add channel", systemName: "plus", selected: false, action: onAddChannel)
            }
        }
    }
}

private struct DiscoverFilterButton: View {
    let title: String
    let systemName: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: NXSpacing.x2) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(NXFont.control)
            }
            .foregroundStyle(selected ? NXColor.text(scheme) : NXColor.textSecondary(scheme))
            .frame(height: 32)
            .padding(.horizontal, NXSpacing.x2)
            .background(selected ? NXColor.primary.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: NXRadius.control))
        }
        .buttonStyle(.plain)
    }
}

private struct AddChannelSheet: View {
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
                    title: working ? "Adding" : "Add channel",
                    systemName: working ? "clock" : "plus",
                    disabled: working || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submit)
                Spacer()
            }
            .padding(NXSpacing.x4)
            .navigationTitle("Add channel")
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

private struct DiscoverList: View {
    let items: [DiscoverEntry]
    @Binding var selectedEntry: DiscoverEntry?
    let autoSelectFirst: Bool
    let onClear: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "From your channels")
            if items.isEmpty {
                NXEmptyState(
                    title: "Nothing matches",
                    message: "Try a broader search, or pick a different channel.",
                    actionTitle: "Clear search",
                    action: onClear)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        DiscoverListItem(
                            item: item,
                            selected: item == selectedEntry || (autoSelectFirst && selectedEntry == nil && item == items.first),
                            action: { selectedEntry = item })
                        if item.id != items.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
            }
        }
    }
}

private struct DiscoverListItem: View {
    let item: DiscoverEntry
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: NXSpacing.x3) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? NXColor.primary : NXColor.textTertiary(scheme))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text(item.title)
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineLimit(2)
                    Text(DiscoverFormat.byline(item))
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(1)
                    if let summary = item.summary {
                        Text(summary)
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textTertiary(scheme))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, NXSpacing.x3)
            .padding(.leading, selected ? NXSpacing.x3 : 0)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(selected ? NXColor.primary : Color.clear)
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoverPreview: View {
    let entry: DiscoverEntry
    let importing: Bool
    let onAddToNexa: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                Text(entry.title)
                    .font(NXFont.sectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(DiscoverFormat.byline(entry))
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                if let summary = entry.summary {
                    Text(summary)
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NXPrimaryButton(
                title: importing ? "Adding" : "Add to Nexa",
                systemName: importing ? "clock" : "plus",
                disabled: importing,
                action: onAddToNexa)

            Text("Transcript, chapters, and discussion become available after you add it.")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(compact ? 0 : NXSpacing.x4)
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: NXRadius.surface)
                    .fill(NXColor.surface1(scheme))
            }
        }
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: NXRadius.surface)
                    .stroke(NXColor.border(scheme), lineWidth: 1)
            }
        }
    }
}

// Byline for a feed entry. Duration is deliberately absent — the RSS feed has
// no duration tag, so there is nothing truthful to show until after import.
enum DiscoverFormat {
    static func byline(_ entry: DiscoverEntry) -> String {
        var parts = [entry.channelTitle, relativeDate(entry.published)]
        if let views = entry.viewCount {
            parts.append("\(views.formatted(.number.notation(.compactName))) views")
        }
        return parts.joined(separator: " · ")
    }

    static func relativeDate(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

private struct DiscoverRightRail: View {
    let onOpenDiscover: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            Text("Discover")
                .font(NXFont.subsectionTitle)
                .foregroundStyle(NXColor.text(scheme))
            PanelSection(title: "How this works") {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    Text("New videos from the channels you follow stay in Discover until you choose Add to Nexa.")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    NXTextButton(title: "Browse Discover", systemName: "sparkle.magnifyingglass", action: onOpenDiscover)
                }
            }
            Spacer()
        }
        .padding(NXSpacing.x4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NXColor.surface1(scheme))
    }
}

private struct LibraryMain: View {
    let episodes: [EpisodeDTO]
    let progress: ImportViewModel.ImportProgress?
    let importError: String?
    let backendBaseURL: URL
    let onDiscover: () -> Void
    let onAddSource: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x8) {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                Text("LIBRARY")
                    .font(NXFont.label)
                    .foregroundStyle(NXColor.primary)
                Text("Sources you chose to think through.")
                    .font(NXFont.pageTitle)
                    .foregroundStyle(NXColor.text(scheme))
                Text("Discover stays separate. Library only contains content added to Nexa or uploaded by you.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            }

            if let progress {
                LibraryProcessingState(progress: progress)
            } else if let importError {
                NXErrorState(message: cleanedImportError(importError), retry: onAddSource)
            }

            if episodes.isEmpty {
                NXEmptyState(
                    title: "No sources in Library yet",
                    message: "Add a public source from Discover, paste a link, or upload a file. Processing runs in the background.",
                    actionTitle: "Open Discover",
                    action: onDiscover
                )
            } else {
                DashboardSection(title: "Sources") {
                    VStack(spacing: 0) {
                        ForEach(episodes) { episode in
                            SourceListItem(episode: episode)
                            if episode.id != episodes.last?.id {
                                Divider().overlay(NXColor.border(scheme))
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct LibraryProcessingState: View {
    let progress: ImportViewModel.ImportProgress
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            HStack(alignment: .top, spacing: NXSpacing.x3) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NXColor.primary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text("Added to Nexa")
                        .font(NXFont.subsectionTitle)
                        .foregroundStyle(NXColor.text(scheme))
                    Text("You can keep browsing. Playback, transcript, chapters, and discussion context will appear here when processing finishes.")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NXProgressIndicator(value: progress.percent, label: processingStageTitle(progress.stage))
            ProcessingStageList(currentStage: progress.stage)
        }
        .padding(NXSpacing.x4)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }
}

private struct ProcessingStageList: View {
    let currentStage: String
    @Environment(\.colorScheme) private var scheme

    private let stages: [(key: String, title: String)] = [
        ("uploading", "Uploading"),
        ("parsing", "Parsing source"),
        ("transcribing", "Generating transcript"),
        ("chapters", "Generating chapters"),
        ("ready", "Ready to discuss")
    ]

    private var currentIndex: Int {
        let normalized = normalizedProcessingStage(currentStage)
        return stages.firstIndex { $0.key == normalized } ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            ForEach(stages.indices, id: \.self) { index in
                HStack(spacing: NXSpacing.x2) {
                    Image(systemName: iconName(for: index))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint(for: index))
                        .frame(width: 16)
                    Text(stages[index].title)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(index == currentIndex ? NXColor.text(scheme) : NXColor.textTertiary(scheme))
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func iconName(for index: Int) -> String {
        if index < currentIndex { return "checkmark.circle.fill" }
        if index == currentIndex { return "circle.fill" }
        return "circle"
    }

    private func tint(for index: Int) -> Color {
        if index < currentIndex { return NXColor.success }
        if index == currentIndex { return NXColor.primary }
        return NXColor.textTertiary(scheme)
    }
}

private struct DashboardMain: View {
    let episodes: [EpisodeDTO]
    let importing: Bool
    let onImport: () -> Void
    var onImportDraft: (String) -> Void = { _ in }
    var onResync: (Int) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var latestEpisode: EpisodeDTO? { episodes.first }
    private var focusEpisodes: [EpisodeDTO] { Array(episodes.prefix(3)) }
    private var recentEpisodes: [EpisodeDTO] { Array(episodes.dropFirst().prefix(4)) }
    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? NXSpacing.x6 : NXSpacing.x8) {
            VStack(alignment: .leading, spacing: compact ? NXSpacing.x3 : NXSpacing.x4) {
                TopBar()
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text(greeting())
                        .font(compact ? .system(size: 22, weight: .semibold) : NXFont.pageTitle)
                        .foregroundStyle(NXColor.text(scheme))
                    Text("What would you like to explore?")
                        .font(compact ? NXFont.body : .system(size: 20, weight: .regular))
                        .foregroundStyle(NXColor.textSecondary(scheme))
                }
                GlobalCommandInput(importing: importing, onSubmit: onImportDraft)
                QuickActions(onImport: onImport)
            }

            if let latestEpisode {
                ContinueThinking(episode: latestEpisode)
                    .contextMenu { resyncButton(latestEpisode.id) }
            } else {
                DashboardEmptyState(onImport: onImport)
            }

            if !focusEpisodes.isEmpty {
                DashboardSection(title: "Today's focus") {
                    VStack(spacing: 0) {
                        ForEach(focusEpisodes) { episode in
                            ContentListItem(episode: episode)
                                .contextMenu { resyncButton(episode.id) }
                            if episode.id != focusEpisodes.last?.id {
                                Divider().overlay(NXColor.border(scheme))
                            }
                        }
                    }
                }
            }

            if !recentEpisodes.isEmpty {
                DashboardSection(title: "Recent conversations") {
                    VStack(spacing: NXSpacing.x3) {
                        ForEach(recentEpisodes) { episode in
                            ConversationListItem(episode: episode)
                                .contextMenu { resyncButton(episode.id) }
                        }
                    }
                }
            }

            if let latestEpisode {
                DashboardSection(title: "Insights") {
                    VStack(spacing: NXSpacing.x4) {
                        InsightItem(text: "Review the strongest claims and turn them into durable notes.", source: latestEpisode.title ?? "Latest source")
                        InsightItem(text: "Collect useful references as you discuss the source with AI.", source: "Workspace")
                    }
                }
            }

            if !episodes.isEmpty {
                DashboardSection(title: "Sources") {
                    VStack(spacing: 0) {
                        ForEach(episodes.prefix(5)) { episode in
                            SourceListItem(episode: episode)
                                .contextMenu { resyncButton(episode.id) }
                            if episode.id != episodes.prefix(5).last?.id {
                                Divider().overlay(NXColor.border(scheme))
                            }
                        }
                    }
                }
            }
        }
    }

    // Long-press affordance to re-pull corrected content (subtitles/translation)
    // and re-download the audio, without cluttering the study screen.
    @ViewBuilder private func resyncButton(_ episodeId: Int) -> some View {
        Button {
            onResync(episodeId)
        } label: {
            Label("重新同步内容和音频", systemImage: "arrow.triangle.2.circlepath")
        }
    }

    private func greeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }
}

private struct TopBar: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            Text("HOME")
                .font(NXFont.label)
                .foregroundStyle(NXColor.primary)
            Spacer()
            Text(Date.now.formatted(date: .abbreviated, time: .omitted))
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
    }
}

private struct GlobalCommandInput: View {
    let importing: Bool
    let onSubmit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        HStack(spacing: compact ? NXSpacing.x2 : NXSpacing.x3) {
            Image(systemName: "link.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(focused ? NXColor.primary : NXColor.textTertiary(scheme))
                .frame(width: 22)
            TextField(compact ? "Paste link or ask" : "Paste a link, add audio, or ask about a source", text: $draft)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focused)
                .onSubmit { onSubmit(draft) }
            NXPrimaryButton(
                title: importing ? "Adding" : "Add",
                systemName: importing ? "clock" : (compact ? nil : "plus"),
                disabled: importing,
                action: { onSubmit(draft) }
            )
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, NXSpacing.x4)
        .padding(.trailing, compact ? NXSpacing.x3 : NXSpacing.x2)
        .frame(height: 56)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .modifier(NXFocusModifier(focused: focused))
        .accessibilityElement(children: .contain)
    }
}

private struct QuickActions: View {
    let onImport: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            NXTextButton(title: compact ? "Podcast" : "Find a podcast", systemName: "waveform", action: onImport)
            NXTextButton(title: compact ? "Video" : "Add a video", systemName: "play.rectangle", action: onImport)
            NXTextButton(title: compact ? "Thought" : "Start a thought", systemName: "square.and.pencil") {}
            Spacer(minLength: 0)
        }
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: title)
            content
        }
    }
}

private struct DashboardEmptyState: View {
    let onImport: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? NXSpacing.x3 : NXSpacing.x4) {
            HStack(alignment: .top, spacing: NXSpacing.x3) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NXColor.primary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text("Start with one source")
                        .font(NXFont.subsectionTitle)
                        .foregroundStyle(NXColor.text(scheme))
                    Text("Add a podcast, video, or long-form audio. Nexa Insight will prepare it for questions, references, and notes.")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            NXTextButton(title: "Add source", systemName: "plus", action: onImport)
                .padding(.leading, compact ? 32 : 36)
        }
        .padding(.vertical, compact ? NXSpacing.x2 : NXSpacing.x4)
    }
}

private struct ContinueThinking: View {
    let episode: EpisodeDTO
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Continue thinking")
            NavigationLink(value: episode.id) {
                VStack(alignment: .leading, spacing: NXSpacing.x4) {
                    HStack(alignment: .top, spacing: NXSpacing.x4) {
                        SourceThumbnail(episode: episode, size: 56)
                        VStack(alignment: .leading, spacing: NXSpacing.x2) {
                            Text(episode.title ?? "Untitled")
                                .font(NXFont.subsectionTitle)
                                .foregroundStyle(NXColor.text(scheme))
                                .lineLimit(2)
                            Text(episode.channel ?? sourceHost(episode.sourceUrl))
                                .font(NXFont.auxiliary)
                                .foregroundStyle(NXColor.textSecondary(scheme))
                            Text("Last stop: source review and follow-up questions")
                                .font(NXFont.body)
                                .foregroundStyle(NXColor.textSecondary(scheme))
                                .padding(.top, NXSpacing.x1)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(NXColor.textTertiary(scheme))
                    }
                    NXProgressIndicator(value: episode.status == "ready" ? 100 : 36, label: episode.status == "ready" ? "Ready" : episode.status)
                }
                .padding(NXSpacing.x4)
                .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
                .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ContentListItem: View {
    let episode: EpisodeDTO
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationLink(value: episode.id) {
            HStack(alignment: .center, spacing: NXSpacing.x3) {
                SourceThumbnail(episode: episode, size: 36)
                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    Text(episode.title ?? "Untitled")
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineLimit(1)
                    Text("\(episode.channel ?? sourceHost(episode.sourceUrl)) · \(durationText(episode.durationMs))")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(1)
                }
                Spacer()
                StatusPill(status: episode.status)
            }
            .padding(.vertical, NXSpacing.x3)
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationListItem: View {
    let episode: EpisodeDTO
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationLink(value: episode.id) {
            HStack(alignment: .top, spacing: NXSpacing.x3) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NXColor.primary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    Text("Questions around \(episode.title ?? "Untitled")")
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineLimit(1)
                    Text("Source review · just now")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                }
                Spacer()
            }
            .padding(.vertical, NXSpacing.x1)
        }
        .buttonStyle(.plain)
    }
}

private struct InsightItem: View {
    let text: String
    let source: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            HStack(spacing: NXSpacing.x2) {
                NXTag(text: "Insight", tint: NXColor.insight)
                Text(source)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .lineLimit(1)
            }
            Text(text)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, NXSpacing.x3)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(NXColor.insight.opacity(0.75))
                .frame(width: 2)
        }
    }
}

private struct SourceListItem: View {
    let episode: EpisodeDTO
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationLink(value: episode.id) {
            HStack(spacing: NXSpacing.x3) {
                SourceThumbnail(episode: episode, size: 32)
                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    Text(episode.title ?? "Untitled")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineLimit(1)
                    Text(episode.channel ?? sourceHost(episode.sourceUrl))
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(1)
                }
                Spacer()
                Text(durationText(episode.durationMs))
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .monospacedDigit()
            }
            .padding(.vertical, NXSpacing.x3)
        }
        .buttonStyle(.plain)
    }
}

private struct ContextPanel: View {
    let episodes: [EpisodeDTO]
    let progress: ImportViewModel.ImportProgress?
    let importError: String?
    let backendBaseURL: URL
    let onImport: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            HStack {
                Text("Context")
                    .font(NXFont.subsectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                Spacer()
            }

            if let progress {
                PanelSection(title: "Add to Nexa") {
                    NXProgressIndicator(value: progress.percent, label: progress.stage)
                }
            } else if let importError {
                NXErrorState(message: importError)
            } else {
                PanelSection(title: "Add source") {
                    VStack(alignment: .leading, spacing: NXSpacing.x3) {
                        Text("Ready to add a new source.")
                            .font(NXFont.body)
                            .foregroundStyle(NXColor.textSecondary(scheme))
                        NXSecondaryButton(title: "Open Discover", systemName: "sparkle.magnifyingglass", action: onImport)
                    }
                }
            }

            PanelSection(title: "Connection") {
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text(backendBaseURL.absoluteString)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(2)
                    HStack(spacing: NXSpacing.x2) {
                        Circle().fill(NXColor.success).frame(width: 6, height: 6)
                        Text("Backend configured")
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textTertiary(scheme))
                    }
                }
            }

            if let latest = episodes.first {
                PanelSection(title: "Suggested questions") {
                    VStack(alignment: .leading, spacing: NXSpacing.x3) {
                        SuggestedQuestion(text: "What are the strongest claims?")
                        SuggestedQuestion(text: "Where does the speaker rely on assumptions?")
                        SuggestedQuestion(text: "Turn this into three personal takeaways.")
                    }
                }

                PanelSection(title: "Latest source") {
                    VStack(alignment: .leading, spacing: NXSpacing.x3) {
                        SourceThumbnail(episode: latest, size: 72)
                        Text(latest.title ?? "Untitled")
                            .font(NXFont.bodyMedium)
                            .foregroundStyle(NXColor.text(scheme))
                            .lineLimit(3)
                        Text(latest.channel ?? sourceHost(latest.sourceUrl))
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textSecondary(scheme))
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(NXSpacing.x4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(NXColor.surface1(scheme))
    }
}

private struct MobileSourceStatus: View {
    let progress: ImportViewModel.ImportProgress?
    let importError: String?
    let backendBaseURL: URL
    let onImport: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Source status")

            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                if let progress {
                    StatusLine(
                        systemName: "sparkles",
                        tint: NXColor.primary,
                        title: "Preparing source",
                        detail: progress.stage.capitalized
                    )
                    NXProgressIndicator(value: progress.percent, label: progress.stage)
                } else if let importError {
                    StatusLine(
                        systemName: "exclamationmark.triangle",
                        tint: NXColor.error,
                        title: "Add failed",
                        detail: cleanedImportError(importError)
                    )
                } else {
                    StatusLine(
                        systemName: "tray.and.arrow.down",
                        tint: NXColor.primary,
                        title: "Ready for a source",
                        detail: "Find something in Discover, paste a link, or add audio when you are ready."
                    )
                }

                Divider().overlay(NXColor.border(scheme))

                StatusLine(
                    systemName: "server.rack",
                    tint: NXColor.success,
                    title: "Backend",
                    detail: backendBaseURL.absoluteString
                )

                if importError != nil {
                    NXTextButton(title: "Try another source", systemName: "plus", action: onImport)
                }
            }
            .padding(.vertical, NXSpacing.x2)
        }
    }
}

private struct StatusLine: View {
    let systemName: String
    let tint: Color
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(title)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                Text(detail)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            Text(title)
                .font(NXFont.label)
                .foregroundStyle(NXColor.textTertiary(scheme))
            content
        }
    }
}

private struct SuggestedQuestion: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {} label: {
            Text(text)
                .font(NXFont.body)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, NXSpacing.x2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StatusPill: View {
    let status: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(status.capitalized)
            .font(NXFont.label)
            .foregroundStyle(status == "ready" ? NXColor.success : NXColor.textTertiary(scheme))
    }
}

private struct SourceThumbnail: View {
    let episode: EpisodeDTO
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NXRadius.control)
                .fill(NXColor.surface2(scheme))
            if let url = episode.thumbnailUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: NXRadius.control))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.control).stroke(NXColor.border(scheme), lineWidth: 1))
    }

    private var fallback: some View {
        Image(systemName: "waveform")
            .font(.system(size: max(14, size * 0.34), weight: .medium))
            .foregroundStyle(NXColor.textTertiary(scheme))
    }
}

struct ImportSheet: View {
    @ObservedObject var vm: ImportViewModel
    @Binding var urlDraft: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @State private var didTrySubmit = false

    private var trimmedURL: String {
        urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedURL: String {
        ImportViewModel.normalizedYouTubeURL(urlDraft)
    }

    private var canSubmit: Bool {
        !trimmedURL.isEmpty && !vm.importing
    }

    private var urlHost: String? {
        guard
            !trimmedURL.isEmpty,
            let host = URL(string: normalizedURL)?.host()
        else { return nil }
        return host
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                ImportSheetHeader(onClose: { dismiss() })
                ImportURLPanel(
                    urlDraft: $urlDraft,
                    focused: $focused,
                    host: urlHost,
                    backendBaseURL: vm.backendBaseURL,
                    showEmptyHint: didTrySubmit && trimmedURL.isEmpty,
                    onSubmit: startImport
                )
                ImportStatusPanel(
                    importing: vm.importing,
                    progress: vm.progress,
                    error: vm.importError,
                    backendBaseURL: vm.backendBaseURL
                )
                Spacer(minLength: NXSpacing.x4)
                ImportSheetActions(
                    importing: vm.importing,
                    canSubmit: canSubmit,
                    onCancel: { dismiss() },
                    onSubmit: startImport
                )
            }
            .padding(NXSpacing.x6)
            .background(NXColor.background(scheme))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { focused = true }
        }
    }

    private func startImport() {
        didTrySubmit = true
        guard canSubmit else { return }
        let url = urlDraft
        Task {
            await vm.startImport(urlString: url)
            if vm.importError == nil && vm.progress == nil { dismiss() }
        }
    }
}

private struct ImportSheetHeader: View {
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x4) {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                NXTag(text: "New source", tint: NXColor.primary)
                Text("Add source")
                    .font(NXFont.pageTitle)
                    .foregroundStyle(NXColor.text(scheme))
                Text("Paste a source link. Nexa Insight will prepare transcript, chapters, audio, and references for discussion.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            NXIconButton(systemName: "xmark", accessibilityLabel: "Close add source", action: onClose)
        }
    }
}

private struct ImportURLPanel: View {
    @Binding var urlDraft: String
    var focused: FocusState<Bool>.Binding
    let host: String?
    let backendBaseURL: URL
    let showEmptyHint: Bool
    let onSubmit: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            Text("Source URL")
                .font(NXFont.label)
                .foregroundStyle(NXColor.textTertiary(scheme))

            HStack(spacing: NXSpacing.x3) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .frame(width: 24)

                TextField("https://www.youtube.com/watch?v=...", text: $urlDraft)
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.text(scheme))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused(focused)
                    .onSubmit(onSubmit)
            }
            .padding(.horizontal, NXSpacing.x3)
            .frame(height: 52)
            .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
            .modifier(NXFocusModifier(focused: focused.wrappedValue))

            HStack(alignment: .center, spacing: NXSpacing.x3) {
                ImportMetaItem(systemName: "play.rectangle", text: host ?? "YouTube or media URL")
                ImportMetaItem(systemName: "server.rack", text: backendBaseURL.host() ?? backendBaseURL.absoluteString)
            }

            if showEmptyHint {
                    Text("Paste a link before adding the source.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.error)
            }
        }
        .padding(NXSpacing.x4)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }
}

private struct ImportMetaItem: View {
    let systemName: String
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x1) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
            Text(text)
                .font(NXFont.auxiliary)
                .lineLimit(1)
        }
        .foregroundStyle(NXColor.textTertiary(scheme))
    }
}

private struct ImportStatusPanel: View {
    let importing: Bool
    let progress: ImportViewModel.ImportProgress?
    let error: String?
    let backendBaseURL: URL
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            if let progress {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    HStack(spacing: NXSpacing.x2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NXColor.primary)
                        Text("Preparing source")
                            .font(NXFont.subsectionTitle)
                            .foregroundStyle(NXColor.text(scheme))
                    }
                    NXProgressIndicator(value: progress.percent, label: progress.stage)
                    ImportSkeleton()
                }
            } else if importing {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    HStack(spacing: NXSpacing.x2) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NXColor.primary)
                        Text("Connecting to Nexa")
                            .font(NXFont.subsectionTitle)
                            .foregroundStyle(NXColor.text(scheme))
                    }
                    Text("Sending the source to \(backendBaseURL.host() ?? backendBaseURL.absoluteString).")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                    ImportSkeleton()
                }
            } else if let error {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    HStack(spacing: NXSpacing.x2) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NXColor.error)
                        Text("Add failed")
                            .font(NXFont.subsectionTitle)
                            .foregroundStyle(NXColor.text(scheme))
                    }
                    Text(error)
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Check that the phone can reach \(backendBaseURL.absoluteString), then try again.")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    ImportReadinessRow(systemName: "text.quote", title: "Transcript", detail: "Sentences and timing")
                    ImportReadinessRow(systemName: "list.bullet.rectangle", title: "Chapters", detail: "Navigation and context")
                    ImportReadinessRow(systemName: "bubble.left.and.bubble.right", title: "Discussion", detail: "Questions and insight capture")
                }
            }
        }
        .padding(NXSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NXColor.surface2(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }
}

private struct ImportReadinessRow: View {
    let systemName: String
    let title: String
    let detail: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
                .frame(width: 20)
            Text(title)
                .font(NXFont.control)
                .foregroundStyle(NXColor.text(scheme))
            Spacer(minLength: NXSpacing.x3)
            Text(detail)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
                .lineLimit(1)
        }
    }
}

private struct ImportSkeleton: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Capsule()
                .fill(NXColor.borderStrong(scheme))
                .frame(width: 220, height: 8)
            Capsule()
                .fill(NXColor.border(scheme))
                .frame(width: 156, height: 8)
        }
        .accessibilityHidden(true)
    }
}

private struct ImportSheetActions: View {
    let importing: Bool
    let canSubmit: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            NXSecondaryButton(title: "Cancel", action: onCancel)
            Spacer()
            NXPrimaryButton(
                title: importing ? "Adding" : "Add to Nexa",
                systemName: importing ? "clock" : "plus",
                disabled: !canSubmit,
                action: onSubmit
            )
        }
    }
}

private func sourceHost(_ urlString: String) -> String {
    URL(string: urlString)?.host() ?? "Source"
}

private func looksLikeSourceURL(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains(" ") else { return false }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
        return URL(string: trimmed)?.host() != nil
    }
    return trimmed.contains(".") && URL(string: "https://\(trimmed)")?.host() != nil
}

private func cleanedImportError(_ message: String) -> String {
    message
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first
        .map(String.init) ?? "Add failed. Check the source URL and backend connection."
}

private func processingStageTitle(_ stage: String) -> String {
    switch normalizedProcessingStage(stage) {
    case "upload", "uploading":
        return "Uploading"
    case "parsing":
        return "Parsing source"
    case "transcribing":
        return "Generating transcript"
    case "chapters":
        return "Generating chapters"
    case "translation", "translating":
        return "Preparing bilingual context"
    case "ready":
        return "Ready to discuss"
    default:
        return stage.isEmpty ? "Processing" : stage.capitalized
    }
}

private func normalizedProcessingStage(_ stage: String) -> String {
    switch stage.lowercased() {
    case "upload", "uploading":
        return "uploading"
    case "download", "downloading", "parse", "parsing", "metadata", "extracting":
        return "parsing"
    case "transcript", "transcribing", "transcription", "asr":
        return "transcribing"
    case "chapters", "chaptering", "analysis", "analyzing", "summarizing":
        return "chapters"
    case "translation", "translating":
        return "translation"
    case "complete", "completed", "ready":
        return "ready"
    default:
        return stage.lowercased()
    }
}

private func durationText(_ durationMs: Int?) -> String {
    guard let durationMs, durationMs > 0 else { return "No duration" }
    let totalSeconds = durationMs / 1000
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}
#endif
