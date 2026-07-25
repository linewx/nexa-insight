#if os(iOS)
import SwiftUI

struct StudyView: View {
    let episodeId: Int
    let store: EpisodeStore
    let backendBaseURL: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = StudyViewModel()
    @StateObject private var player: LocalAudioPlayback
    @State private var audioRefreshState: AudioRefreshState = .idle
    @State private var query = ""
    @State private var shadowingSentence: SentenceDTO?
    @State private var liveSession: LiveClassSession?
    @State private var discussionAnchor: SentenceDTO?
    @State private var insightNotice: String?
    private let sentences: [SentenceDTO]
    private let chapters: [ChapterDTO]
    private let episode: EpisodeDTO?

    init(episodeId: Int, store: EpisodeStore, backendBaseURL: URL) {
        self.episodeId = episodeId
        self.store = store
        self.backendBaseURL = backendBaseURL
        self.sentences = store.sentences(for: episodeId)
        self.chapters = store.chapters(for: episodeId)
        self.episode = store.downloadedEpisodes().first { $0.id == episodeId }
        let relative = store.localAudioPath(for: episodeId) ?? "audio/\(episodeId).mp3"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        _player = StateObject(wrappedValue: LocalAudioPlayback(fileURL: base.appendingPathComponent(relative)))
    }

    var visible: [SentenceDTO] { vm.search(query, in: sentences) }
    var current: SentenceDTO? { vm.currentSentence(sentences: sentences, cursorMs: player.currentMs) }

    var body: some View {
        StudyWorkspace(
            episode: episode,
            chapters: chapters,
            sentences: sentences,
            visible: visible,
            current: current,
            selected: discussionAnchor,
            query: $query,
            audioRefreshState: audioRefreshState,
            following: vm.following,
            player: player,
            onSentenceTap: { sentence in
                discussionAnchor = sentence
                player.seek(sentence.startMs)
                player.play()
            },
            onShadow: { sentence in shadowingSentence = sentence },
            onSync: { vm.syncNow() },
            onRefreshAudio: { Task { await refreshAudio() } },
            onTalk: { startDiscussion(anchor: discussionAnchor ?? current) },
            discussionSession: liveSession,
            onStartDiscussion: { startDiscussion(anchor: $0) },
            onSaveInsight: saveInsight,
            onEndDiscussion: endDiscussion
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(edgeSwipeBackGesture)
        .sheet(item: $shadowingSentence) { s in
            NavigationStack {
                ShadowingView(episodeId: episodeId, sentenceId: s.id, sentenceText: s.sourceText, store: store)
            }
        }
        .overlay(alignment: .bottom) {
            if let insightNotice {
                Text(insightNotice)
                    .font(NXFont.control)
                    .foregroundStyle(NXColor.text(.dark))
                    .padding(.horizontal, NXSpacing.x4)
                    .padding(.vertical, NXSpacing.x3)
                    .background(NXColor.surface1(.dark), in: RoundedRectangle(cornerRadius: NXRadius.popover))
                    .overlay(RoundedRectangle(cornerRadius: NXRadius.popover).stroke(NXColor.border(.dark), lineWidth: 1))
                    .padding(.bottom, NXSpacing.x6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var edgeSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                let startsAtLeadingEdge = value.startLocation.x <= 24
                let avoidsHeaderScrubber = value.startLocation.y > 96
                let movesRight = value.translation.width > 72
                let staysMostlyHorizontal = abs(value.translation.height) < 56
                let hasBackIntent = value.predictedEndTranslation.width > 112

                if startsAtLeadingEdge, avoidsHeaderScrubber, movesRight, staysMostlyHorizontal, hasBackIntent {
                    dismiss()
                }
            }
    }

    private func startDiscussion(anchor: SentenceDTO?) {
        let selected = anchor ?? sentences.first
        guard let selected else { return }
        discussionAnchor = selected
        player.seek(selected.startMs)
        player.pause()
        liveSession = LiveClassSession(store: store, keychain: KeychainStore(), episodeId: episodeId, playback: player)
    }

    private func endDiscussion() {
        liveSession?.end()
        liveSession = nil
    }

    private func saveInsight(_ body: String, _ anchor: SentenceDTO) {
        let title = body.split(separator: "\n").first.map(String.init) ?? "Insight at \(formatTime(anchor.startMs))"
        do {
            _ = try store.addInsight(episodeId: episodeId, title: String(title.prefix(96)), body: body, sourceText: anchor.sourceText, startMs: anchor.startMs, endMs: anchor.endMs)
            insightNotice = "Saved to Insights"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                insightNotice = nil
            }
        } catch {
            insightNotice = "Could not save insight"
        }
    }

    private func refreshAudio() async {
        audioRefreshState = .refreshing
        print("[NexaAudio] refresh started for episode \(episodeId), backend \(backendBaseURL.absoluteString)")
        do {
            let client = BackendClient(baseURL: backendBaseURL)
            var bundle = try await client.bundle(episodeId)
            print("[NexaAudio] bundle fetched, hasAudio=\(bundle.hasAudio)")
            if !bundle.hasAudio {
                guard let sourceURL = episode?.sourceUrl else {
                    audioRefreshState = .failed("This source has no original URL, so audio cannot be prepared again.")
                    return
                }
                let (_, job) = try await client.importEpisode(url: sourceURL)
                audioRefreshState = .processing(job.stage, job.progress)
                bundle = try await waitForPreparedAudio(client: client)
            }
            try await downloadAudio(bundle: bundle, client: client)
        } catch {
            print("[NexaAudio] refresh failed: \(error.localizedDescription)")
            audioRefreshState = .failed(audioRefreshFailureMessage(for: error))
        }
    }

    private func audioRefreshFailureMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet,
                    .networkConnectionLost, .timedOut:
                return "Could not reach the Nexa backend at \(backendBaseURL.host ?? backendBaseURL.absoluteString). Your source is still safe. Connect to Tailscale, then try Refresh audio again."
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private func waitForPreparedAudio(client: BackendClient) async throws -> BundleDTO {
        for _ in 0..<120 {
            let job = try await client.episodeJob(episodeId)
            audioRefreshState = .processing(job.stage, job.progress)
            if job.status == "failed" {
                throw NSError(domain: "AudioRefresh", code: 1, userInfo: [NSLocalizedDescriptionKey: job.error ?? "Audio preparation failed."])
            }
            let bundle = try await client.bundle(episodeId)
            if bundle.hasAudio {
                return bundle
            }
            if job.status == "complete" {
                throw NSError(domain: "AudioRefresh", code: 2, userInfo: [NSLocalizedDescriptionKey: "Processing completed, but the backend did not expose an audio file. Try Add to Nexa again."])
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw NSError(domain: "AudioRefresh", code: 3, userInfo: [NSLocalizedDescriptionKey: "Audio preparation is still running. You can leave this page and refresh again later."])
    }

    private func downloadAudio(bundle: BundleDTO, client: BackendClient) async throws {
        let destination = AudioFiles.audioURL(forEpisode: episodeId)
        try await client.downloadAudio(episodeId, to: destination)
        _ = try store.saveBundle(bundle, localAudioPath: AudioFiles.relativePath(forEpisode: episodeId))
        player.reloadFromDisk()
        audioRefreshState = .ready
    }
}

private enum AudioRefreshState: Equatable {
    case idle
    case refreshing
    case processing(String, Int)
    case waiting(String)
    case ready
    case failed(String)
}

private struct StudyWorkspace: View {
    let episode: EpisodeDTO?
    let chapters: [ChapterDTO]
    let sentences: [SentenceDTO]
    let visible: [SentenceDTO]
    let current: SentenceDTO?
    let selected: SentenceDTO?
    @Binding var query: String
    let audioRefreshState: AudioRefreshState
    let following: Bool
    @ObservedObject var player: LocalAudioPlayback
    let onSentenceTap: (SentenceDTO) -> Void
    let onShadow: (SentenceDTO) -> Void
    let onSync: () -> Void
    let onRefreshAudio: () -> Void
    let onTalk: () -> Void
    let discussionSession: LiveClassSession?
    let onStartDiscussion: (SentenceDTO?) -> Void
    let onSaveInsight: (String, SentenceDTO) -> Void
    let onEndDiscussion: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceTopBar(
                episode: episode,
                current: current,
                player: player,
                durationMs: episode?.durationMs,
                audioRefreshState: audioRefreshState,
                onRefreshAudio: onRefreshAudio
            )
            studySurface
        }
        .background(NXColor.background(scheme))
    }

    private var studySurface: some View {
        ZStack(alignment: .bottomLeading) {
            transcriptScrollArea(
                horizontalPadding: compact ? NXSpacing.x4 : NXSpacing.x8,
                contentMaxWidth: compact ? .infinity : 1_080,
                bottomInset: discussionSession == nil ? 88 : 128
            )

            if let discussionSession, let anchor = selected ?? current {
                DiscussionMiniDock(
                    session: discussionSession,
                    anchor: anchor,
                    cursorMs: player.currentMs,
                    onEnd: onEndDiscussion
                )
                .padding(.horizontal, compact ? NXSpacing.x3 : NXSpacing.x6)
                .padding(.bottom, compact ? NXSpacing.x3 : NXSpacing.x4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                FloatingDiscussionButton(onJoin: onTalk)
                    .padding(.leading, compact ? NXSpacing.x3 : NXSpacing.x6)
                    .padding(.bottom, compact ? NXSpacing.x3 : NXSpacing.x4)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: discussionSession != nil)
    }

    private func transcriptScrollArea(horizontalPadding: CGFloat, contentMaxWidth: CGFloat, bottomInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                transcriptContent
                    .frame(maxWidth: contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, NXSpacing.x8)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity)
            }
            .onChange(of: current?.id) { _, newValue in
                if following, let newValue {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            SearchInput(query: $query)
            TranscriptBlock(
                sentences: visible,
                current: current,
                onSentenceTap: onSentenceTap,
                onShadow: onShadow
            )
            if !following {
                NXSecondaryButton(title: "Back to current", systemName: "scope", action: onSync)
            }
        }
    }
}

private struct WorkspaceTopBar: View {
    let episode: EpisodeDTO?
    let current: SentenceDTO?
    @ObservedObject var player: LocalAudioPlayback
    let durationMs: Int?
    let audioRefreshState: AudioRefreshState
    let onRefreshAudio: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private var compact: Bool { horizontalSizeClass == .compact }
    private var playing: Bool { player.playbackState == .playing }
    private var progress: Double {
        guard let durationMs, durationMs > 0 else { return 0 }
        return min(1, max(0, Double(player.currentMs) / Double(durationMs)))
    }
    private var displayedMs: Int {
        guard let durationMs, durationMs > 0, isScrubbing else { return player.currentMs }
        return Int(scrubValue * Double(durationMs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            HStack(alignment: .center, spacing: NXSpacing.x3) {
                NXIconButton(systemName: "chevron.left", accessibilityLabel: "Back") { dismiss() }

                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    HStack(spacing: NXSpacing.x2) {
                        NXTag(text: "Source", tint: NXColor.primary)
                        Text(formatTime(displayedMs))
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textTertiary(scheme))
                            .monospacedDigit()
                    }
                    Text(episode?.title ?? "Study")
                        .font(compact ? NXFont.subsectionTitle : NXFont.sectionTitle)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineLimit(compact ? 2 : 1)
                    if let channel = episode?.channel {
                        Text(channel)
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textSecondary(scheme))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: NXSpacing.x3)

                Button {
                    playing ? player.pause() : player.play()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NXColor.text(scheme))
                        .frame(width: 28, height: 28)
                        .background(NXColor.surface2(scheme), in: RoundedRectangle(cornerRadius: NXRadius.small))
                        .overlay(RoundedRectangle(cornerRadius: NXRadius.small).stroke(NXColor.border(scheme), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause" : "Play")
            }

            if shouldShowCompactStatus {
                CompactAudioStatus(audioRefreshState: audioRefreshState, player: player, onRefreshAudio: onRefreshAudio)
            }
        }
        .padding(.horizontal, compact ? NXSpacing.x4 : NXSpacing.x6)
        .padding(.top, compact ? NXSpacing.x3 : NXSpacing.x4)
        .padding(.bottom, (compact ? NXSpacing.x3 : NXSpacing.x4) + 9)
        .background(NXColor.surface1(scheme))
        .overlay(alignment: .bottom) {
            HeaderScrubber(
                progress: isScrubbing ? scrubValue : progress,
                enabled: (durationMs ?? 0) > 0,
                onScrub: { next in
                    scrubValue = next
                    isScrubbing = true
                },
                onCommit: { next in
                    scrubValue = next
                    isScrubbing = false
                    if let durationMs {
                        player.seek(Int(next * Double(durationMs)))
                    }
                }
            )
            .padding(.bottom, -9)
        }
        .onChange(of: player.currentMs) { _, _ in
            if !isScrubbing { scrubValue = progress }
        }
    }

    private var shouldShowCompactStatus: Bool {
        switch audioRefreshState {
        case .idle:
            return player.errorMessage != nil || !player.hasLocalFile
        case .ready:
            return false
        case .refreshing, .processing, .waiting, .failed:
            return true
        }
    }
}

private struct HeaderScrubber: View {
    let progress: Double
    let enabled: Bool
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(1, max(0, progress))
            let width = geometry.size.width
            let x = width * clamped

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.clear)
                Rectangle()
                    .fill(NXColor.border(scheme))
                    .frame(height: 1)
                Rectangle()
                    .fill(NXColor.primary.opacity(enabled ? 0.78 : 0.24))
                    .frame(width: max(0, x), height: 1)
                Circle()
                    .fill(NXColor.primary.opacity(enabled ? 1 : 0.35))
                    .frame(width: dragging ? 8 : 6, height: dragging ? 8 : 6)
                    .offset(x: min(max(0, x - (dragging ? 4 : 3)), max(0, width - (dragging ? 8 : 6))))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled, width > 0 else { return }
                        dragging = true
                        onScrub(min(1, max(0, value.location.x / width)))
                    }
                    .onEnded { value in
                        guard enabled, width > 0 else {
                            dragging = false
                            return
                        }
                        let next = min(1, max(0, value.location.x / width))
                        onCommit(next)
                        dragging = false
                    }
            )
        }
        .frame(height: 18)
        .padding(.horizontal, 0)
        .accessibilityLabel("Playback progress")
    }
}

private struct CompactAudioStatus: View {
    let audioRefreshState: AudioRefreshState
    @ObservedObject var player: LocalAudioPlayback
    let onRefreshAudio: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch audioRefreshState {
        case .refreshing:
            statusText("Checking audio")
        case .processing(let stage, let progress):
            statusText("\(stageDisplayName(stage)) \(progress)%")
        case .waiting:
            actionStatus("Audio preparing")
        case .failed:
            actionStatus("Audio failed")
        case .ready:
            EmptyView()
        case .idle:
            if player.errorMessage != nil || !player.hasLocalFile {
                actionStatus("Audio unavailable")
            } else {
                EmptyView()
            }
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(NXFont.auxiliary)
            .foregroundStyle(NXColor.textTertiary(scheme))
            .lineLimit(1)
    }

    private func actionStatus(_ text: String) -> some View {
        HStack(spacing: NXSpacing.x2) {
            Text(text)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
                .lineLimit(1)
            Button("Refresh", action: onRefreshAudio)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.primary)
                .buttonStyle(.plain)
        }
    }
}

private struct FloatingDiscussionButton: View {
    let onJoin: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onJoin) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 46, height: 46)
                .background(NXColor.primary, in: RoundedRectangle(cornerRadius: NXRadius.popover))
                .overlay(RoundedRectangle(cornerRadius: NXRadius.popover).stroke(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.28 : 0.14), radius: 14, y: 6)
                .contentShape(RoundedRectangle(cornerRadius: NXRadius.popover))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Join discussion")
    }
}

private struct DiscussionMiniDock: View {
    @ObservedObject var session: LiveClassSession
    let anchor: SentenceDTO
    let cursorMs: Int
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if let controller = session.controller {
                DiscussionMiniContent(
                    controller: controller,
                    notice: session.notice,
                    connected: session.connected,
                    cursorMs: cursorMs,
                    onEnd: endSession
                )
            } else {
                DiscussionMiniLoading(error: session.error, onEnd: endSession)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .task(id: session.id) { await session.start(at: anchor.startMs) }
    }

    private func endSession() {
        session.end()
        onEnd()
    }
}

private struct DiscussionMiniContent: View {
    @ObservedObject var controller: ClassroomController
    let notice: String
    let connected: Bool
    let cursorMs: Int
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: NXSpacing.x3) {
            VoiceActivityIcon(state: controller.state, connected: connected)

            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                HStack(spacing: NXSpacing.x2) {
                    Text(compactStateText)
                        .font(NXFont.label)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                    Text(formatTime(cursorMs))
                        .font(NXFont.label)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .monospacedDigit()
                }
                Text(primaryText)
                    .font(NXFont.control)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: NXSpacing.x2)

            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End discussion")
        }
        .padding(.leading, NXSpacing.x3)
        .padding(.trailing, NXSpacing.x2)
        .padding(.vertical, NXSpacing.x2)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.popover))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.popover).stroke(NXColor.borderStrong(scheme), lineWidth: 1))
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.22 : 0.10), radius: 16, y: 8)
    }

    private var compactStateText: String {
        switch controller.state.phase {
        case .userSpeaking:
            return "You"
        case .teacherSpeaking, .discussing:
            return "AI"
        case .podcastPlaying, .resuming:
            return "Listening"
        case .connecting:
            return "Connecting"
        default:
            return connected ? "Discussion" : "Offline"
        }
    }

    private var primaryText: String {
        if let latest = latestTurnText {
            return latest
        }
        if !notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return notice
        }
        switch controller.state.phase {
        case .podcastPlaying:
            return "Listening. Speak when you want to discuss."
        case .userSpeaking:
            return "Capturing your point..."
        case .discussing:
            return "Thinking..."
        case .teacherSpeaking:
            return "Responding..."
        case .resuming:
            return "Resuming playback..."
        default:
            return "Ready to discuss."
        }
    }

    private var latestTurnText: String? {
        controller.transcript.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

private struct DiscussionMiniLoading: View {
    let error: String?
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            VoiceActivityIcon(state: ClassroomState(phase: error == nil ? .connecting : .ended, pausedAtMs: nil), connected: false)
            Text(error ?? "Connecting...")
                .font(NXFont.control)
                .foregroundStyle(error == nil ? NXColor.text(scheme) : NXColor.error)
                .lineLimit(2)
            Spacer(minLength: NXSpacing.x2)
            Button(action: onEnd) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close discussion")
        }
        .padding(.leading, NXSpacing.x3)
        .padding(.trailing, NXSpacing.x2)
        .padding(.vertical, NXSpacing.x2)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.popover))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.popover).stroke(NXColor.borderStrong(scheme), lineWidth: 1))
        .shadow(color: Color.black.opacity(scheme == .dark ? 0.22 : 0.10), radius: 16, y: 8)
    }
}

private struct VoiceActivityIcon: View {
    let state: ClassroomState
    let connected: Bool
    @State private var active = false

    private var speaking: Bool {
        switch state.phase {
        case .userSpeaking, .teacherSpeaking, .discussing, .connecting:
            return true
        default:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(barColor)
                    .frame(width: 3, height: barHeight(index))
                    .animation(.easeOut(duration: 0.18), value: active)
                    .animation(.easeOut(duration: 0.18), value: state.phase)
            }
        }
        .frame(width: 28, height: 28)
        .background(NXColor.primary.opacity(speaking ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: NXRadius.small))
        .onAppear { active = true }
        .onDisappear { active = false }
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        connected || speaking ? NXColor.primary : NXColor.textTertiary(.dark).opacity(0.55)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard speaking else { return 8 }
        let high: [CGFloat] = [16, 10, 18]
        let low: [CGFloat] = [9, 18, 11]
        return active ? high[index] : low[index]
    }
}

private struct AudioPlayerBar: View {
    @ObservedObject var player: LocalAudioPlayback
    let durationMs: Int?
    let audioRefreshState: AudioRefreshState
    let following: Bool
    let onSync: () -> Void
    let onRefreshAudio: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    private var compact: Bool { horizontalSizeClass == .compact }
    private var playing: Bool { player.playbackState == .playing }
    private var progress: Double {
        guard let durationMs, durationMs > 0 else { return 0 }
        return min(1, max(0, Double(player.currentMs) / Double(durationMs)))
    }
    private var displayedMs: Int {
        guard let durationMs, durationMs > 0, isScrubbing else { return player.currentMs }
        return Int(scrubValue * Double(durationMs))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            if shouldShowAudioStatus {
                audioStatus
            }

            HStack(spacing: compact ? NXSpacing.x2 : NXSpacing.x3) {
                controlButton(systemName: "gobackward.15", label: "Back 15 seconds") {
                    player.seek(max(0, player.currentMs - 15_000))
                }

                Button {
                    playing ? player.pause() : player.play()
                } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(NXColor.primary, in: RoundedRectangle(cornerRadius: NXRadius.control))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playing ? "Pause" : "Play")

                controlButton(systemName: "goforward.15", label: "Forward 15 seconds") {
                    guard let durationMs else { return }
                    player.seek(min(durationMs, player.currentMs + 15_000))
                }

                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    HStack {
                        Text(formatTime(displayedMs))
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textSecondary(scheme))
                            .monospacedDigit()
                        Spacer()
                        Text(durationMs.map(formatTime) ?? "--:--")
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textTertiary(scheme))
                            .monospacedDigit()
                    }
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubValue : progress },
                            set: { scrubValue = $0; isScrubbing = true }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if !editing, let durationMs {
                                player.seek(Int(scrubValue * Double(durationMs)))
                            }
                        }
                    )
                    .tint(NXColor.primary)
                    .disabled((durationMs ?? 0) <= 0)
                }

                if !following {
                    NXSecondaryButton(title: compact ? "Current" : "Back to current", systemName: "scope", action: onSync)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .onChange(of: player.currentMs) { _, _ in
            if !isScrubbing { scrubValue = progress }
        }
        .padding(compact ? NXSpacing.x3 : NXSpacing.x4)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }

    private var shouldShowAudioStatus: Bool {
        switch audioRefreshState {
        case .idle:
            return player.errorMessage != nil || !player.hasLocalFile
        case .ready:
            return false
        case .refreshing, .processing, .waiting, .failed:
            return true
        }
    }

    @ViewBuilder
    private var audioStatus: some View {
        switch audioRefreshState {
        case .refreshing:
            StudyStatusLine(systemName: "arrow.triangle.2.circlepath", tint: NXColor.primary, title: "Checking audio", detail: "Looking for a prepared audio file on the backend.")
        case .processing(let stage, let progress):
            StudyStatusLine(systemName: "waveform.badge.magnifyingglass", tint: NXColor.primary, title: "Preparing audio", detail: "\(stageDisplayName(stage)) · \(progress)%")
        case .waiting(let message):
            AudioActionStatusLine(systemName: "clock", tint: NXColor.insight, title: "Audio is still preparing", detail: message, actionTitle: "Refresh audio", busy: false, action: onRefreshAudio)
        case .ready:
            StudyStatusLine(systemName: "checkmark.circle", tint: NXColor.success, title: "Audio ready", detail: "Playback is using the local audio file on this device.")
        case .failed(let message):
            AudioActionStatusLine(systemName: "exclamationmark.triangle", tint: NXColor.error, title: "Audio refresh failed", detail: message, actionTitle: "Try again", busy: false, action: onRefreshAudio)
        case .idle:
            if let message = player.errorMessage {
                AudioActionStatusLine(systemName: "exclamationmark.triangle", tint: NXColor.error, title: "Playback unavailable", detail: message, actionTitle: "Refresh audio", busy: false, action: onRefreshAudio)
            } else if player.hasLocalFile {
                StudyStatusLine(systemName: "waveform", tint: NXColor.success, title: "Audio ready", detail: "Use the player while the transcript stays synced to your position.")
            } else {
                AudioActionStatusLine(systemName: "clock", tint: NXColor.insight, title: "Audio not on this device", detail: "The transcript is available, but the local audio file has not been downloaded yet.", actionTitle: "Refresh audio", busy: false, action: onRefreshAudio)
            }
        }
    }

    private func controlButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(NXColor.textSecondary(scheme))
                .frame(width: compact ? 34 : 36, height: compact ? 34 : 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct AudioActionStatusLine: View {
    let systemName: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: String
    let busy: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            StudyStatusLine(systemName: systemName, tint: tint, title: title, detail: detail)
            Spacer(minLength: NXSpacing.x3)
            NXSecondaryButton(title: actionTitle, systemName: "arrow.clockwise", action: action)
                .disabled(busy)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SearchInput: View {
    @Binding var query: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(focused ? NXColor.primary : NXColor.textTertiary(scheme))
            TextField("Search transcript", text: $query)
                .font(NXFont.body)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, NXSpacing.x3)
        .frame(height: 40)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
        .modifier(NXFocusModifier(focused: focused))
    }
}

private struct TranscriptBlock: View {
    let sentences: [SentenceDTO]
    let current: SentenceDTO?
    let onSentenceTap: (SentenceDTO) -> Void
    let onShadow: (SentenceDTO) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Transcript")
            if sentences.isEmpty {
                Text("No transcript matches this search.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .padding(.vertical, NXSpacing.x4)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sentences) { sentence in
                        TranscriptRow(
                            sentence: sentence,
                            selected: sentence.id == current?.id,
                            onTap: { onSentenceTap(sentence) },
                            onShadow: { onShadow(sentence) }
                        )
                        .id(sentence.id)
                        if sentence.id != sentences.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
            }
        }
    }
}

private struct TranscriptRow: View {
    let sentence: SentenceDTO
    let selected: Bool
    let onTap: () -> Void
    let onShadow: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                HStack(spacing: NXSpacing.x2) {
                    Text(formatTime(sentence.startMs))
                        .font(NXFont.auxiliary)
                        .foregroundStyle(selected ? NXColor.primary : NXColor.textTertiary(scheme))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text(sentence.sourceText)
                        .font(NXFont.body)
                        .fontWeight(selected ? .medium : .regular)
                        .foregroundStyle(NXColor.text(scheme))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !sentence.chinese.isEmpty {
                        Text(sentence.chinese)
                            .font(NXFont.body)
                            .foregroundStyle(NXColor.textSecondary(scheme))
                            .lineSpacing(2)
                    }
                }
            }
            .padding(.vertical, NXSpacing.x4)
            .padding(.leading, NXSpacing.x4)
            .padding(.trailing, NXSpacing.x2)
            .background(selected ? NXColor.primary.opacity(0.045) : Color.clear)
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

private struct StudyContextPanel: View {
    let episode: EpisodeDTO?
    let chapters: [ChapterDTO]
    let current: SentenceDTO?
    let sentenceCount: Int
    let following: Bool
    let onSync: () -> Void
    let onTalk: () -> Void
    let onSeek: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            if !compact {
                Text("Context")
                    .font(NXFont.subsectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
            }

            StudyPanelSection(title: "Source") {
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text(episode?.channel ?? "Saved source")
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                    Text("\(sentenceCount) transcript lines")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                    if !following {
                        NXSecondaryButton(title: "Back to current", systemName: "scope", action: onSync)
                    }
                }
            }

            if !chapters.isEmpty {
                StudyPanelSection(title: "Chapters") {
                    VStack(alignment: .leading, spacing: NXSpacing.x3) {
                        ForEach(chapters.prefix(compact ? 4 : 8)) { chapter in
                            ChapterItem(
                                chapter: chapter,
                                active: current.map { chapter.startMs <= $0.startMs && $0.startMs < chapter.endMs } ?? false,
                                onTap: { onSeek(chapter.startMs) }
                            )
                        }
                    }
                }
            }

            StudyPanelSection(title: "Ask next") {
                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    SuggestedPrompt(text: "What is the core argument?", action: onTalk)
                    SuggestedPrompt(text: "Challenge this claim.", action: onTalk)
                    SuggestedPrompt(text: "Save this as an insight.", action: onTalk)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(compact ? 0 : NXSpacing.x4)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(compact ? Color.clear : NXColor.surface1(scheme))
    }
}

private struct StudyPanelSection<Content: View>: View {
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

private struct QuoteBlock: View {
    let sentence: SentenceDTO
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Text(formatTime(sentence.startMs))
                .font(NXFont.label)
                .foregroundStyle(NXColor.primary)
                .monospacedDigit()
            Text(sentence.sourceText)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .lineSpacing(2)
            if !sentence.chinese.isEmpty {
                Text(sentence.chinese)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .lineSpacing(2)
            }
        }
        .padding(.leading, NXSpacing.x3)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(NXColor.primary.opacity(0.72))
                .frame(width: 2)
        }
    }
}

private struct ChapterItem: View {
    let chapter: ChapterDTO
    let active: Bool
    let onTap: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: NXSpacing.x2) {
                Text(formatTime(chapter.startMs))
                    .font(NXFont.label)
                    .foregroundStyle(active ? NXColor.primary : NXColor.textTertiary(scheme))
                    .monospacedDigit()
                Text(chapter.title)
                    .font(NXFont.control)
                    .foregroundStyle(active ? NXColor.text(scheme) : NXColor.textSecondary(scheme))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SuggestedPrompt: View {
    let text: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: NXSpacing.x2) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .padding(.top, 2)
                Text(text)
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StudyStatusLine: View {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private func stageDisplayName(_ stage: String) -> String {
    switch stage {
    case "metadata":
        return "Reading source"
    case "audio", "audio_backfill":
        return "Preparing audio"
    case "transcription":
        return "Generating transcript"
    case "translation":
        return "Translating"
    case "indexing":
        return "Preparing discussion"
    case "complete":
        return "Complete"
    default:
        return stage.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
#endif
