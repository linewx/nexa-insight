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
    @State private var selectedSection: AppSection = .library
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
            // A closure, not a value: this initialiser runs once for the life of the
            // screen, so capturing the client meant a key entered in Settings did
            // nothing until the app was relaunched.
            apiProvider: { Self.youtubeAPI() },
            // Ranking reads local playback data: what was finished, how long was
            // listened. No network cost, and a truer signal than the follow list.
            episodesProvider: { store.downloadedEpisodes() },
            // Read on each access so the Settings toggle takes effect immediately.
            bylineLocale: { settings.bylineLocale }))
    }

    var body: some View {
        TabView(selection: $selectedSection) {
            // First, and the tab the app opens on. Coming back to the app almost always
            // means returning to something already added — Discover is for the rarer act
            // of finding something new, so it no longer gets the first position.
            tab(.library, path: $libraryPath) {
                LibraryMain(
                    episodes: vm.episodes,
                    tasks: vm.tasks.ordered,
                    onDiscover: { selectedSection = .discover },
                    onAddSource: { showImport = true },
                    onStudy: { id in libraryPath.append(id) },
                    onResync: { id in Task { await vm.resyncContent(episodeId: id) } },
                    onRetry: { task in Task { await vm.retry(task: task) } })
            }

            // Opens on content rather than on a description of the app.
            tab(.discover, path: $discoverPath) {
                // No padding here: each screen owns its own insets, so the brand
                // row and the content below it can share one margin. Applied at
                // this level it was added ON TOP of the row's, making the header
                // twice as inset as the list.
                DiscoverView(
                    vm: discover,
                    importing: false,
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
        // Coming back from an episode has to re-sort the list. StudyView is pushed onto
        // this same stack, so returning does NOT re-fire the .onAppear above — without
        // this the episode you just studied would keep its old place until the app was
        // relaunched, which for a list sorted by recency looks like the sorting is broken.
        .onChange(of: libraryPath.count) { old, new in
            if new < old { vm.reload() }
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
                StudyView(episodeId: id, store: store, backendBaseURL: vm.backendBaseURL, settings: settings)
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
                    importing: false,
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
    // set one up. Callers decide whether to stay API-only or use another source.
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
/// The sections. Bar order comes from the order the `tab(...)` calls appear in the
/// TabView, NOT from this list — the two are kept aligned only for readability.
private enum AppSection: String, CaseIterable {
    case library
    case discover
    case channels
    case settings

    var title: String {
        switch self {
        // "Home", not "Library": it is the first tab and the one the app opens on, and a
        // shelf is somewhere you visit while a home is where you start.
        case .library: return "Home"
        case .discover: return "Discover"
        case .channels: return "Channels"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        // A house rather than a stack of cards, for the same reason as the title.
        case .library: return "house"
        case .discover: return "sparkle.magnifyingglass"
        case .channels: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

private struct LibraryMain: View {
    let episodes: [EpisodeDTO]
    let tasks: [ImportTask]
    let onDiscover: () -> Void
    let onAddSource: () -> Void
    let onStudy: (Int) -> Void
    var onResync: (Int) -> Void = { _ in }
    var onRetry: (ImportTask) -> Void = { _ in }
    @Environment(\.colorScheme) private var scheme
    @State private var playingEpisodeId: Int?

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

    private var list: some View {
        let storedIds = Set(episodes.map(\.id))
        let newTasks = tasks.filter { !storedIds.contains($0.episodeId) }
        return LazyVStack(alignment: .leading, spacing: NXSpacing.x4) {
            ForEach(newTasks) { task in
                LibraryVideoCard(
                    episode: task.episode, task: task,
                    playing: playingEpisodeId == task.episodeId,
                    onTogglePlayback: { togglePlayback(task.episodeId) },
                    onStudy: { onStudy(task.episodeId) },
                    onReprocess: {}, onRetry: { onRetry(task) })
            }

            if episodes.isEmpty && newTasks.isEmpty {
                NXEmptyState(
                    title: "Nothing added yet",
                    message: "Find something in Discover, or paste a link with the + button.",
                    actionTitle: "Open Discover",
                    action: onDiscover
                )
            } else {
                ForEach(episodes) { episode in
                    let task = tasks.first { $0.episodeId == episode.id }
                    LibraryVideoCard(
                        episode: episode, task: task,
                        playing: playingEpisodeId == episode.id,
                        onTogglePlayback: { togglePlayback(episode.id) },
                        onStudy: { onStudy(episode.id) },
                        onReprocess: { onResync(episode.id) },
                        onRetry: { if let task { onRetry(task) } })
                }
            }
        }
    }

    private func togglePlayback(_ episodeId: Int) {
        playingEpisodeId = playingEpisodeId == episodeId ? nil : episodeId
    }
}

private struct LibraryVideoCard: View {
    let episode: EpisodeDTO
    let task: ImportTask?
    let playing: Bool
    let onTogglePlayback: () -> Void
    let onStudy: () -> Void
    let onReprocess: () -> Void
    let onRetry: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var playerFailure: String?

    private var progressFraction: Double? {
        Resume.progressFraction(savedMs: episode.positionMs, durationMs: episode.durationMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            player

            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                Text(episode.title ?? episode.sourceUrl)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(2)
                Text(episode.channel ?? sourceHost(episode.sourceUrl))
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .lineLimit(1)

                if let task {
                    taskStatus(task)
                } else {
                    if let progressFraction {
                        progressBar(progressFraction)
                    }
                    Text(Resume.progressText(savedMs: episode.positionMs, durationMs: episode.durationMs)
                            ?? durationText(episode.durationMs))
                        .font(NXFont.auxiliary)
                        .foregroundStyle(progressFraction == nil ? NXColor.textTertiary(scheme) : NXColor.primary)
                        .monospacedDigit()
                }
            }

            if let task, task.isFailed {
                NXSecondaryButton(title: "Retry parsing", systemName: "arrow.clockwise", action: onRetry)
            } else if task == nil {
                HStack(spacing: NXSpacing.x3) {
                    NXPrimaryButton(
                        title: progressFraction == nil ? "Start learning" : "Continue learning",
                        systemName: progressFraction == nil ? "play.fill" : "arrow.right.circle.fill",
                        action: onStudy)
                    NXSecondaryButton(title: "Reprocess", systemName: "arrow.triangle.2.circlepath", action: onReprocess)
                }
            }
        }
        .padding(NXSpacing.x3)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }

    @ViewBuilder private var player: some View {
        ZStack(alignment: .topTrailing) {
            if playing {
                playbackView
                Button(action: onTogglePlayback) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
                .padding(NXSpacing.x2)
                .accessibilityLabel("Close original video")
            } else {
                LibraryThumbnail(episode: episode)
                    .onTapGesture {
                        guard LibraryPlaybackTarget.forEpisode(episode) != .unavailable else { return }
                        onTogglePlayback()
                    }
                    .accessibilityLabel("Play original video: \(episode.title ?? "source")")
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: NXRadius.surface))
    }

    @ViewBuilder private var playbackView: some View {
        if let playerFailure {
            VStack(spacing: NXSpacing.x3) {
                Image(systemName: "play.slash")
                    .font(.system(size: 26))
                Text("This source cannot play here.")
                    .font(NXFont.bodyMedium)
                Button("Open in Safari") { openURL(URL(string: episode.sourceUrl)!) }
                    .font(NXFont.controlEmphasis)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .accessibilityLabel(playerFailure)
        } else {
            switch LibraryPlaybackTarget.forEpisode(episode) {
            case .youtube(let videoId):
                if let url = YouTubeWeb.embed(videoId: videoId) {
                    WebPage(url: url, onLoadFailure: { playerFailure = $0 }, wrapInFrame: true)
                        .background(Color.black)
                }
            case .web(let url):
                WebPage(url: url, onLoadFailure: { playerFailure = $0 })
                    .background(NXColor.surface2(scheme))
            case .unavailable:
                Color.black.overlay(Image(systemName: "play.slash").foregroundStyle(.white))
            }
        }
    }

    @ViewBuilder private func taskStatus(_ task: ImportTask) -> some View {
        if task.isFailed {
            Text(task.job.error ?? "Processing failed. You can retry this source.")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.error)
                .fixedSize(horizontal: false, vertical: true)
        } else if task.isQueued {
            Label("Waiting to parse", systemImage: "clock")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
        } else if task.isComplete {
            // The backend is finished; the local bundle + audio download is what
            // is left. Saying "preparing learning material" here, next to a full
            // bar, described a finished import as a stuck one.
            Label("Saving to your library", systemImage: "arrow.down.circle")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.primary)
        } else {
            // The indicator prints the percentage itself, so the label carries the
            // stage instead — passing the percentage here showed it twice.
            NXProgressIndicator(value: task.progress, label: processingStageTitle(task.job.stage))
        }
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

private struct LibraryThumbnail: View {
    let episode: EpisodeDTO
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let url = episode.thumbnailUrl.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
            if let duration = episode.durationMs, duration > 0 {
                Text(durationText(duration))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .padding(NXSpacing.x2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        ZStack {
            NXColor.surface2(scheme)
            Image(systemName: "play.rectangle")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
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
    @State private var submitting = false

    private var trimmedURL: String {
        urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedURL: String {
        ImportViewModel.normalizedYouTubeURL(urlDraft)
    }

    private var canSubmit: Bool {
        !trimmedURL.isEmpty && !submitting
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
                if let error = vm.submissionError {
                    ImportSubmissionError(message: cleanedImportError(error))
                }
                Spacer(minLength: NXSpacing.x4)
                ImportSheetActions(
                    importing: submitting,
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
            submitting = true
            let accepted = await vm.startImport(urlString: url)
            submitting = false
            if accepted { dismiss() }
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

private struct ImportSubmissionError: View {
    let message: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(NXColor.error)
            Text(message)
                .font(NXFont.body)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NXSpacing.x3)
        .background(NXColor.error.opacity(0.08), in: RoundedRectangle(cornerRadius: NXRadius.control))
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
