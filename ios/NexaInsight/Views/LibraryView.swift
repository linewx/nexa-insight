#if os(iOS)
import SwiftUI

struct LibraryView: View {
    let store: EpisodeStore
    @ObservedObject var settings: AppSettings
    @StateObject private var vm: ImportViewModel
    @StateObject private var discover: DiscoverViewModel
    // One store shared by Discover and every channel screen. Following on a
    // channel screen has to show up in the channel list, so they cannot each
    // hold their own instance.
    @StateObject private var subscriptions: SubscriptionStore
    @State private var selectedSection: AppSection = .discover
    @State private var showImport = false
    @State private var urlDraft = ""
    // One navigation path PER TAB. A single shared stack would mean opening a
    // channel from Discover, switching to Library, and coming back to find the
    // channel screen pushed onto the wrong tab — each tab has to remember its own
    // place, which is what makes a tab bar feel native.
    @State private var discoverPath = NavigationPath()
    @State private var channelsPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @Environment(\.colorScheme) private var colorScheme

    init(store: EpisodeStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        _vm = StateObject(wrappedValue: ImportViewModel(
            client: BackendClient(baseURL: URL(string: settings.backendBaseURL) ?? URL(string: "http://localhost:8000")!),
            store: store))
        let subscriptionStore = SubscriptionStore()
        _subscriptions = StateObject(wrappedValue: subscriptionStore)
        _discover = StateObject(wrappedValue: DiscoverViewModel(
            store: subscriptionStore,
            service: DiscoverFeedService(),
            api: Self.youtubeAPI(),
            // Ranking reads local playback data: what was finished, how long was
            // listened. No network cost, and a truer signal than the follow list.
            episodesProvider: { store.downloadedEpisodes() },
            // Read on each access so the Settings toggle takes effect immediately.
            bylineLocale: { settings.bylineLocale }))
    }

    var body: some View {
        TabView(selection: $selectedSection) {
            // Opens on content rather than on a description of the app.
            tab(.discover, path: $discoverPath) {
                // No padding here: each screen owns its own insets, so the brand
                // row and the content below it can share one margin. Applied at
                // this level it was added ON TOP of the row's, making the header
                // twice as inset as the list.
                DiscoverView(
                    vm: discover,
                    importing: vm.importing,
                    onAddToNexa: addToNexa,
                    onOpenChannel: { channelId, title in
                        discoverPath.append(ChannelTarget(channelId: channelId, title: title))
                    },
                    importedVideoIds: { Set(store.downloadedEpisodes().compactMap(\.youtubeId)) })
            }

            // Channels was a segmented control inside Discover — a tab within a
            // tab, meaning two positions to remember at once. Promoting it here
            // removed Discover's internal switch entirely.
            tab(.channels, path: $channelsPath, scroll: false) {
                ChannelsView(
                    vm: discover,
                    onOpenChannel: { channelId, title in
                        channelsPath.append(ChannelTarget(channelId: channelId, title: title))
                    })
            }

            tab(.library, path: $libraryPath) {
                LibraryMain(
                    episodes: vm.episodes,
                    progress: vm.progress,
                    importError: vm.importError,
                    backendBaseURL: vm.backendBaseURL,
                    onDiscover: { selectedSection = .discover },
                    onAddSource: { showImport = true },
                    onResync: { id in Task { await vm.resyncContent(episodeId: id) } })
            }

            // Settings was a sheet behind a gear icon. A sheet is for finishing one
            // task and dismissing; settings is somewhere you return to — and the
            // channel screen now sends you here to add an API key.
            NavigationStack {
                SettingsView(settings: settings)
            }
            .tag(AppSection.settings)
            .tabItem { Label(AppSection.settings.title, systemImage: AppSection.settings.icon) }
        }
        .tint(NXColor.primary)
        // One header per screen: the brand row above. Left visible, the navigation
        // bar drew a second band behind it in a different tone.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showImport) {
            ImportSheet(vm: vm, urlDraft: $urlDraft)
                .presentationDetents([.large])
        }
        .onAppear {
            syncBackendClient()
            vm.reload()
        }
        .onChange(of: settings.backendBaseURL) { _, _ in syncBackendClient() }
    }

    // Each tab carries its own stack and the same two destinations, so a channel
    // opened from Discover and one opened from Channels each stay on their own tab.
    @ViewBuilder
    private func tab<Content: View>(
        _ section: AppSection,
        path: Binding<NavigationPath>,
        scroll: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack(path: path) {
            // Each screen supplies its own brand row and then its own scrolling
            // area, so the row cannot be dragged up under the status bar — which is
            // what made the wordmark unreadable mid-scroll.
            content()
            .background(NXColor.background(colorScheme))            .navigationDestination(for: Int.self) { id in
                StudyView(episodeId: id, store: store, backendBaseURL: vm.backendBaseURL)
            }
            .navigationDestination(for: ChannelTarget.self) { target in
                ChannelDetailView(
                    vm: ChannelDetailViewModel(
                        channelId: target.channelId,
                        fallbackTitle: target.title,
                        store: subscriptions,
                        service: DiscoverFeedService(),
                        // Read at navigation time, not at app launch: a key added
                        // in Settings then takes effect on the next channel you
                        // open, with no restart.
                        api: Self.youtubeAPI(),
                        // The one place this round still reads youtubeId. When
                        // that field becomes source_id, this moves with it.
                        importedVideoIds: { Set(store.downloadedEpisodes().compactMap(\.youtubeId)) }),
                    importing: vm.importing,
                    onImport: addToNexa)
            }
        }
        .tag(section)
        .tabItem { Label(section.title, systemImage: section.icon) }
    }

    private func syncBackendClient() {
        let url = URL(string: settings.backendBaseURL) ?? URL(string: "http://localhost:8000")!
        vm.updateClient(BackendClient(baseURL: url))
    }

    // Stays where you are. Switching to Library used to tear down whatever screen
    // you imported from — tapping Add on video 400 of a channel dropped you into
    // Library, and coming back reloaded the catalog from page one, losing eight
    // pages of scrolling. Import already runs in the background, so the only thing
    // that jump bought was showing you a progress bar you did not ask for.
    private func addToNexa(_ url: String) {
        Task { await vm.startImport(urlString: url) }
    }

    // nil when no key is stored, which is the normal state for a user who has not
    // set one up — every caller degrades to the RSS feed rather than erroring.
    private static func youtubeAPI() -> YouTubeAPIFetching? {
        guard let key = KeychainStore().get(.youtubeAPIKey),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return YouTubeAPIClient(apiKey: key)
    }
}

// The tab bar. Home is gone: it was a paste field plus several paragraphs
// describing the app, and pasting a link is an action (Library's +) rather than a
// destination you return to. Every tab here is somewhere you come back to.
private enum AppSection: String, CaseIterable {
    case discover
    case channels
    case library
    case settings

    var title: String {
        switch self {
        case .discover: return "Discover"
        case .channels: return "Channels"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .discover: return "sparkle.magnifyingglass"
        case .channels: return "person.2"
        case .library: return "rectangle.stack"
        case .settings: return "gearshape"
        }
    }
}

private struct LibraryMain: View {
    let episodes: [EpisodeDTO]
    let progress: ImportViewModel.ImportProgress?
    let importError: String?
    let backendBaseURL: URL
    let onDiscover: () -> Void
    let onAddSource: () -> Void
    var onResync: (Int) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader {
                Button(action: onAddSource) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                }
                .accessibilityLabel("Add a source by link")
            }
            ScrollView {
                list
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NXSpacing.x4)
                    .padding(.top, NXSpacing.x2)
            }
        }
    }

    // The eyebrow, a restatement of what Library is, and a note that Discover is
    // separate took three lines before the first item. The tab bar says where you are.
    private var list: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            if let progress {
                LibraryProcessingState(progress: progress)
            } else if let importError {
                NXErrorState(message: cleanedImportError(importError), retry: onAddSource)
            }

            if episodes.isEmpty {
                NXEmptyState(
                    title: "Nothing added yet",
                    message: "Find something in Discover, or paste a link with the + button.",
                    actionTitle: "Open Discover",
                    action: onDiscover
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(episodes) { episode in
                        SourceListItem(episode: episode)
                            .contextMenu { resyncButton(episode.id) }
                        if episode.id != episodes.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
            }
        }
    }

    // Long-press to re-pull corrected content and re-download the audio. Lives
    // here rather than on the study screen, which has no room for maintenance.
    @ViewBuilder private func resyncButton(_ episodeId: Int) -> some View {
        Button {
            onResync(episodeId)
        } label: {
            Label("重新同步内容和音频", systemImage: "arrow.triangle.2.circlepath")
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
                    // The stage list directly below already shows what is
                    // happening; naming every artifact again said nothing new.
                    Text("You can keep browsing while this finishes.")
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

private struct SourceListItem: View {
    let episode: EpisodeDTO
    @Environment(\.colorScheme) private var scheme

    // Where you got to, when you got somewhere. An untouched or finished episode
    // shows its plain duration instead — a 0% bar on everything would be noise.
    private var progressFraction: Double? {
        Resume.progressFraction(savedMs: episode.positionMs, durationMs: episode.durationMs)
    }

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
                    if let progressFraction {
                        progressBar(progressFraction)
                    }
                }
                Spacer()
                // The remaining time is what decides whether to start now, so a
                // part-heard episode shows position/total rather than just total.
                Text(Resume.progressText(savedMs: episode.positionMs, durationMs: episode.durationMs)
                        ?? durationText(episode.durationMs))
                    .font(NXFont.auxiliary)
                    .foregroundStyle(progressFraction == nil ? NXColor.textTertiary(scheme) : NXColor.primary)
                    .monospacedDigit()
            }
            .padding(.vertical, NXSpacing.x3)
        }
        .buttonStyle(.plain)
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(NXColor.border(scheme))
                Capsule().fill(NXColor.primary).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .padding(.top, 2)
        .accessibilityHidden(true)   // the position/total text already says this
    }
}

// Also the study header's mark (see WorkspaceTopBar), which is why this is not
// private: the same episode should be recognisable by the same image in the row
// you tapped and on the screen it opens.
struct SourceThumbnail: View {
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
                // The field below is a URL field with a placeholder — restating
                // that, then listing what the pipeline produces, was the third
                // place this app explained itself to someone already using it.
                Text("Podcasts, talks, and long-form video.")
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

func looksLikeSourceURL(_ value: String) -> Bool {
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
