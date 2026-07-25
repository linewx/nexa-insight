#if os(iOS)
import SwiftUI
import UIKit

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
    private let sentences: [SentenceDTO]
    private let episode: EpisodeDTO?

    init(episodeId: Int, store: EpisodeStore, backendBaseURL: URL) {
        self.episodeId = episodeId
        self.store = store
        self.backendBaseURL = backendBaseURL
        self.sentences = store.sentences(for: episodeId)
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
            visible: visible,
            current: current,
            query: $query,
            audioRefreshState: audioRefreshState,
            following: vm.following,
            player: player,
            onSentenceTap: { sentence in
                player.seek(sentence.startMs)
                player.play()
            },
            onShadow: { sentence in shadowingSentence = sentence },
            onSync: { vm.syncNow() },
            onRefreshAudio: { Task { await refreshAudio() } },
            onTalk: startDiscussion,
            discussionSession: liveSession,
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

    // Joining does not interrupt the source: the session connects while the
    // podcast keeps playing, and the model is told where playback currently is.
    // The learner speaking is what pauses it (see ClassroomController).
    //
    // Because nothing audible changes at this moment, the tap needs a haptic to
    // land — otherwise "the teacher is here now" is a claim only the dock makes.
    private func startDiscussion() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        liveSession = LiveClassSession(store: store, keychain: KeychainStore(), episodeId: episodeId, playback: player)
    }

    private func endDiscussion() {
        liveSession?.end()
        liveSession = nil
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
    let visible: [SentenceDTO]
    let current: SentenceDTO?
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

    // The join affordance and the discussion dock both float OVER the transcript
    // rather than pushing it: the transcript keeps one fixed bottom inset, so
    // joining never reflows what the learner is reading.
    private var studySurface: some View {
        ZStack(alignment: .bottomLeading) {
            transcriptScrollArea(
                horizontalPadding: compact ? NXSpacing.x4 : NXSpacing.x8,
                contentMaxWidth: compact ? .infinity : 1_080,
                // Clears the tallest floating element (the two-line dock) plus
                // breathing room, so scrolling to the end never leaves text
                // stranded underneath either the button or the dock.
                bottomInset: 132
            )

            if let discussionSession {
                DiscussionDock(session: discussionSession, player: player, onEnd: onEndDiscussion)
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

    // A circle, not a rounded rect: it reads as a single-action affordance and
    // stays formally distinct from the rounded dock it expands into. Solid fill
    // is deliberate — a surface-coloured version was tried and vanished into the
    // white transcript rows behind it.
    var body: some View {
        Button(action: onJoin) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 52, height: 52)
                .background(NXColor.primary, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .nxFloatingShadow(scheme)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Join discussion")
        .accessibilityHint("Brings in the voice teacher without interrupting playback")
    }
}

// Touch needs to be acknowledged: a plain button gives no feedback at all, which
// on a phone reads as "did that register?"
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DiscussionDock: View {
    @ObservedObject var session: LiveClassSession
    @ObservedObject var player: LocalAudioPlayback
    let onEnd: () -> Void

    var body: some View {
        Group {
            if let controller = session.controller {
                DiscussionDockContent(
                    controller: controller,
                    notice: session.notice,
                    connected: session.connected,
                    livePositionMs: player.currentMs,
                    onEnd: endSession
                )
            } else {
                DiscussionDockConnecting(error: session.error, onEnd: endSession)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        // No anchor: the session starts at wherever playback currently is, and
        // playback is NOT interrupted by joining.
        .task(id: session.id) { await session.start() }
    }

    private func endSession() {
        session.end()
        onEnd()
    }
}

private struct DiscussionDockContent: View {
    @ObservedObject var controller: ClassroomController
    let notice: String
    let connected: Bool
    let livePositionMs: Int
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    // Frozen while the learner holds the floor, so the timestamp stops ticking
    // at the line they interrupted instead of chasing live playback.
    private var cursorMs: Int {
        classroomCursorPosition(livePositionMs, controller.frozenPositionMs, 0)
    }

    var body: some View {
        HStack(alignment: .center, spacing: NXSpacing.x3) {
            VoiceActivityIcon(phase: controller.state.phase, connected: connected)

            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                HStack(spacing: NXSpacing.x2) {
                    if let speaker = speakerLabel {
                        Text(speaker)
                            .font(NXFont.label)
                            .foregroundStyle(NXColor.primary)
                    }
                    Text(formatTime(cursorMs))
                        .font(NXFont.label)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .monospacedDigit()
                }
                Text(line)
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
        .modifier(DiscussionDockChrome())
    }

    private var trimmedNotice: String {
        notice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var latestTurn: TutorTurn? {
        controller.transcript.last.flatMap {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
    }

    // One line, three tiers: a playback action just taken wins (it is transient
    // and self-clearing), then the latest thing either party said, then the
    // state message that tells the learner what the classroom is waiting for.
    private var line: String {
        if !trimmedNotice.isEmpty { return trimmedNotice }
        if let latestTurn { return latestTurn.text }
        return classroomStatusMessage(controller.state, cursorMs)
    }

    // Only labelled when the line is somebody's words; an action or a status
    // message belongs to the classroom, not to a speaker.
    private var speakerLabel: String? {
        guard trimmedNotice.isEmpty, let latestTurn else { return nil }
        switch latestTurn.role {
        case .user: return "You"
        case .assistant: return "AI"
        case .system: return nil
        }
    }
}

private struct DiscussionDockConnecting: View {
    let error: String?
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            VoiceActivityIcon(phase: error == nil ? .connecting : .ended, connected: false)
            // An error here is the first thing most learners will hit, so it gets
            // the room to be read in full rather than being clipped to two lines.
            Text(error ?? classroomStatusMessage(ClassroomState(phase: .connecting, pausedAtMs: nil), 0))
                .font(NXFont.control)
                .foregroundStyle(error == nil ? NXColor.text(scheme) : NXColor.error)
                .fixedSize(horizontal: false, vertical: true)
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
        .modifier(DiscussionDockChrome())
    }
}

// The dock floats over the transcript, so it needs an opaque surface and a
// stronger edge than an inline panel would.
private struct DiscussionDockChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.leading, NXSpacing.x3)
            .padding(.trailing, NXSpacing.x2)
            .padding(.vertical, NXSpacing.x2)
            .frame(minHeight: 52)
            .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.popover))
            .overlay(RoundedRectangle(cornerRadius: NXRadius.popover).stroke(NXColor.borderStrong(scheme), lineWidth: 1))
            .nxFloatingShadow(scheme)
    }
}

// Three bars whose rhythm says who holds the floor. Driven by the classroom
// phase rather than real audio levels: the phase already carries that fact, and
// the realtime transport stays a pure event pipe.
private struct VoiceActivityIcon: View {
    let phase: ClassroomPhase
    let connected: Bool
    @State private var pulsing = false

    private struct Rhythm {
        let period: Double
        let rest: CGFloat
        let peaks: [CGFloat]
    }

    private var rhythm: Rhythm? {
        switch phase {
        case .userSpeaking:
            return Rhythm(period: 0.28, rest: 7, peaks: [17, 11, 19])
        case .discussing, .teacherSpeaking:
            return Rhythm(period: 0.5, rest: 8, peaks: [14, 18, 12])
        case .connecting, .resuming:
            return Rhythm(period: 0.8, rest: 6, peaks: [12, 12, 12])
        default:
            // Listening to the source, or ended: at rest, waiting to be interrupted.
            return nil
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(barColor)
                    .frame(width: 3, height: height(index))
                    .animation(animation(index), value: pulsing)
                    .animation(.easeOut(duration: 0.2), value: phase)
            }
        }
        .frame(width: 28, height: 28)
        .background(NXColor.primary.opacity(rhythm == nil ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: NXRadius.small))
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        guard connected || rhythm != nil else { return NXColor.textTertiary(.dark).opacity(0.55) }
        return NXColor.primary.opacity(rhythm == nil ? 0.55 : 1)
    }

    private func height(_ index: Int) -> CGFloat {
        guard let rhythm else { return 8 }
        return pulsing ? rhythm.peaks[index] : rhythm.rest
    }

    private func animation(_ index: Int) -> Animation? {
        guard let rhythm else { return nil }
        return .easeInOut(duration: rhythm.period)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * rhythm.period / 3)
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
