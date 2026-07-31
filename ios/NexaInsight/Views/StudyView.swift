#if os(iOS)
import AVFoundation
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
    // How far the screen is dragged during a back-swipe. Drives the follow-the-finger
    // offset so the gesture has the visual feedback the system one would give.
    @State private var backSwipeOffset: CGFloat = 0
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
            onSentenceTap: { sentence in playIntent(seekTo: sentence.startMs) },
            onShadow: { sentence in shadowingSentence = sentence },
            onSync: { vm.syncNow() },
            onRefreshAudio: { Task { await refreshAudio() } },
            onTalk: startDiscussion,
            onSeekIntent: { ms in playIntent(seekTo: ms) },
            discussionSession: liveSession,
            onEndDiscussion: endDiscussion
        )
        .navigationBarTitleDisplayMode(.inline)
        // Hidden, not merely transparent. Every attempt to keep the bar present for
        // the sake of the system pop gesture cost more than it bought: transparent
        // still reserved its height (an empty strip above the screen's own header),
        // and reclaiming that height via .ignoresSafeArea pulled content under the
        // notch instead. The bar is hidden and back-swipe is handled below.
        .toolbar(.hidden, for: .navigationBar)
        .task { startDiscussion() }
        // Hiding the bar also disables interactivePopGestureRecognizer, so the
        // back-swipe is re-implemented here. Interactive (tracks the finger, snaps
        // back if released short) rather than the earlier .onEnded-only version,
        // which gave no feedback and silently failed on any vertical drift.
        .offset(x: backSwipeOffset)
        .simultaneousGesture(edgeSwipeBackGesture)
        .sheet(item: $shadowingSentence) { s in
            NavigationStack {
                ShadowingView(episodeId: episodeId, sentenceId: s.id, sentenceText: s.sourceText, store: store)
            }
        }
    }

    // Interactive edge-swipe back. Only the horizontal component is read, so a
    // little vertical drift no longer cancels the gesture the way the original
    // `staysMostlyHorizontal` check did. The finger is tracked live and the screen
    // snaps back when released short, which is the feedback that tells the learner
    // the gesture exists at all.
    private var edgeSwipeBackGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                // Start only from the leading edge, and below the header so the
                // scrubber keeps its own drag.
                guard value.startLocation.x <= 32, value.startLocation.y > 96 else { return }
                backSwipeOffset = max(0, value.translation.width)
            }
            .onEnded { value in
                guard value.startLocation.x <= 32, value.startLocation.y > 96 else { return }
                let committed = value.translation.width > 90
                    || value.predictedEndTranslation.width > 160
                if committed {
                    dismiss()
                    backSwipeOffset = 0
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        backSwipeOffset = 0
                    }
                }
            }
    }

    // Joining does not interrupt the source: the session connects while the
    // podcast keeps playing, and the model is told where playback currently is.
    // The learner speaking is what pauses it (see ClassroomController).
    //
    // Because nothing audible changes at this moment, the tap needs a haptic to
    // land — otherwise "the teacher is here now" is a claim only the dock makes.
    // Auto-connects when the study screen appears: the bar is always present and
    // has no connect step, so the session comes up in the background and is ready
    // by the time the learner holds to talk.
    private func startDiscussion() {
        guard liveSession == nil else { return }
        liveSession = LiveClassSession(store: store, keychain: KeychainStore(), episodeId: episodeId, playback: player)
    }

    // Playback driven by the learner (play button, scrubber, tapping a line).
    // With a class connected this MUST go through the controller: taking the floor
    // for the podcast is what silences the teacher. Calling player.play() directly
    // left both playing at once, because the floor never moved.
    private func playIntent(seekTo positionMs: Int?) {
        guard let controller = liveSession?.controller else {
            if let positionMs { player.seek(positionMs) }
            player.play()
            return
        }
        controller.userStartedPlayback(seekTo: positionMs)
    }

    // No pauseIntent here: pausing is only reachable from the dock, which has the
    // controller and calls userPausedPlayback() directly.

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
    // Seeking is the only playback action routed from here (the scrubber in the top
    // bar). Play/pause live in the dock, which talks to the controller directly.
    // Still an intent rather than a raw player call so a connected class moves the
    // floor (see ClassroomController.userStartedPlayback).
    var onSeekIntent: (Int) -> Void = { _ in }
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
                onRefreshAudio: onRefreshAudio,
                onSeekIntent: onSeekIntent
            )
            studySurface
        }
        .background(NXColor.background(scheme))
    }

    // The join affordance and the discussion dock both float OVER the transcript
    // rather than pushing it: the transcript keeps one fixed bottom inset, so
    // joining never reflows what the learner is reading.
    private var studySurface: some View {
        ZStack(alignment: .bottom) {
            transcriptScrollArea(
                horizontalPadding: compact ? NXSpacing.x4 : NXSpacing.x8,
                contentMaxWidth: compact ? .infinity : 1_080,
                // Clears the persistent bottom bar plus breathing room, so
                // scrolling to the end never strands text beneath it.
                bottomInset: 140
            )

            if let discussionSession {
                // Edge-to-edge, pinned to the bottom: the bar is part of the page
                // chrome, not a card floating on top of it. No outer padding.
                DiscussionBar(session: discussionSession, player: player)
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
    // Only seeking lives up here now (the scrubber). Play/pause moved to the dock,
    // so this bar no longer starts or stops playback. Seeks still go through an
    // intent rather than the player so a connected class moves the floor.
    var onSeekIntent: (Int) -> Void = { _ in }
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

                // No play button up here: the dock at the bottom owns playback now
                // (it's within thumb reach, and it routes through the classroom
                // floor). The dock is always present — StudyView starts the class
                // on appear — so playback is never left without a control.
                Spacer(minLength: NXSpacing.x3)
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
                        onSeekIntent(Int(next * Double(durationMs)))
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

// Touch needs to be acknowledged: a plain button gives no feedback at all, which
// on a phone reads as "did that register?"
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// The persistent bottom bar (Doubao-style). Always present over the transcript,
// no connect step and no close button — the session auto-connects in the
// background and stays for the life of the screen. States: connecting → ready
// (a large hold-to-talk button + a Live entry) → error.
private struct DiscussionBar: View {
    @ObservedObject var session: LiveClassSession
    @ObservedObject var player: LocalAudioPlayback

    var body: some View {
        Group {
            if let controller = session.controller {
                ConnectedBarContent(
                    controller: controller,
                    notice: session.notice,
                    connected: session.connected,
                    livePositionMs: player.currentMs,
                    // Live is gated on headphones; read the route at tap time
                    // rather than caching it, since it changes when a cable or
                    // AirPods come and go.
                    liveAvailable: { liveModeAvailable(player.currentRoute()) },
                    onLiveUnavailable: {
                        session.showNotice(liveUnavailableMessage(player.currentRoute()))
                    },
                    playing: player.playbackState == .playing,
                    // A class is connected here, so playback goes through the
                    // controller: taking the floor for the podcast is what
                    // silences the teacher.
                    onPlayIntent: { controller.userStartedPlayback() },
                    onPauseIntent: { controller.userPausedPlayback() }
                )
            } else {
                ConnectingBar(error: session.error)
            }
        }
        // Content stays readable-width and centered on wide screens, but the
        // panel surface itself runs edge-to-edge (see bottomPanel).
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .modifier(BottomPanelChrome())
        // No anchor: the session starts at wherever playback currently is, and
        // playback is NOT interrupted by connecting.
        .task(id: session.id) { await session.start() }
    }
}

// The bottom bar reads as part of the page, not a card floating on it: a full-
// width panel pinned to the bottom edge, rounded only on top, separated from the
// transcript by the same hairline the transcript uses between rows plus a soft
// upward shadow. Content padding respects the horizontal margin and the home
// indicator safe area.
private struct BottomPanelChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, NXSpacing.x3)
            .padding(.top, NXSpacing.x3)
            .padding(.bottom, NXSpacing.x2)
            .frame(maxWidth: .infinity)
            // The surface extends under the home indicator so the panel reaches
            // the screen edge, but the content above keeps its safe-area inset —
            // the controls never touch the indicator. Only the background ignores
            // the safe area, not the content.
            .background(
                NXColor.surface1(scheme)
                    .overlay(alignment: .top) {
                        Rectangle().fill(NXColor.border(scheme)).frame(height: 1)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: NXRadius.surface, topTrailingRadius: NXRadius.surface))
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.28 : 0.06), radius: 8, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
    }
}

private struct ConnectedBarContent: View {
    @ObservedObject var controller: ClassroomController
    let notice: String
    let connected: Bool
    let livePositionMs: Int
    // Evaluated at tap time: headphones can be plugged or unplugged at any point.
    var liveAvailable: () -> Bool = { false }
    var onLiveUnavailable: () -> Void = {}
    // Playback state and intents for the in-dock play button.
    var playing: Bool = false
    var onPlayIntent: () -> Void = {}
    var onPauseIntent: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    // `live` = in continuous Live mode; the big button becomes a passive
    // indicator and the Live pill is the way back out. `talking` = a
    // hold-to-talk press is in progress.
    @State private var live = false
    @State private var talking = false
    // Unplugging headphones mid-Live would drop straight into the feedback loop
    // (teacher's voice → mic → VAD → another answer), so leaving the headphone
    // route exits Live automatically.
    private let routeChanged = NotificationCenter.default.publisher(
        for: AVAudioSession.routeChangeNotification)
    // Slide-up-to-cancel: armed once the press drags up past the threshold.
    // Releasing while armed drops the turn instead of sending it.
    @State private var cancelArmed = false

    // Slender: the copy is small throughout, so a shorter capsule reads as one
    // long, calm control rather than a chunky button.
    private let controlHeight: CGFloat = 50

    var body: some View {
        // Surface, edge, and shadow now come from BottomPanelChrome; this is just
        // the content.
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            statusLine
            controlRow
        }
        // Headphones gone (unplugged, AirPods out) while Live is running: exit
        // immediately. Staying in Live on the speaker means the teacher's voice
        // trips the mic into an endless self-answer loop.
        .onReceive(routeChanged) { _ in
            guard live, !liveAvailable() else { return }
            controller.exitLive()
            live = false
            onLiveUnavailable()
        }
    }

    // One centered status line above the controls: whose turn it is right now.
    private var statusLine: some View {
        HStack(spacing: NXSpacing.x2) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(line)
                .font(NXFont.control)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, NXSpacing.x2)
    }

    // One capsule with the hold-to-talk label centered on the WHOLE dock, and the
    // Live icon floating at the left edge (ChatGPT style). Holding anywhere on the
    // capsule talks; the Live glyph is a small tap target layered on top, so it
    // stays independently tappable without pushing the label off-center.
    // Playback on the LEFT, Live on the RIGHT, hold-to-talk filling the middle.
    // The play button lives down here because the one in the top bar is a thumb
    // stretch away on a tall phone.
    //
    // These are laid out side by side rather than layered over the talk area on
    // purpose: a tap target inside a long-press target means a press held 0.2s too
    // long starts a turn instead of toggling playback. Mis-firing playback just
    // starts audio; mis-firing a turn interrupts the teacher, takes the floor and
    // sends a stray turn to the server. So each gesture gets its own region.
    private var controlRow: some View {
        HStack(spacing: 0) {
            // Present in Live too. Voice can drive playback there ("continue",
            // "pause", "go to 10:30"), but that's a slower path when the learner just
            // wants to stop the audio — and it depends on the model actually calling
            // the tool. The tap stays as the direct, always-works route.
            playSegment
            seam
            talkSegment
            seam
            liveSegment
        }
        .frame(height: controlHeight)
        .background(talkFill, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(live ? 0 : 0.18), lineWidth: 1))
        .scaleEffect(talking ? 1.01 : 1)
        .animation(.easeOut(duration: 0.14), value: talking)
        .animation(.easeOut(duration: 0.14), value: controller.floor)
    }

    // Hairline divider between regions, so the three targets read as separate
    // controls inside one capsule rather than one wide button.
    private var seam: some View {
        Rectangle()
            .fill(seamColor)
            .frame(width: 1, height: controlHeight - 20)
    }

    // Play/pause, mirroring the top bar's button but within thumb reach. Goes
    // through the intent closures, so with a class connected it moves the floor
    // (starting playback silences the teacher) instead of poking the player.
    private var playSegment: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            playing ? onPauseIntent() : onPlayIntent()
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(live ? NXColor.text(scheme) : Color.white)
                .frame(width: 52, height: controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(playing ? "暂停" : "播放")
    }

    // Icon-only, no label — the waveform/stop glyph carries the meaning, matching
    // the reference apps. Tapping it toggles Live.
    private var liveSegment: some View {
        Button(action: toggleLive) {
            Image(systemName: live ? "stop.fill" : "waveform")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(live ? NXColor.text(scheme) : Color.white)
                .frame(width: 52, height: controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(live ? "退出 Live" : "进入 Live")
    }

    // The middle action. It takes the space between the play and Live buttons and
    // centers its label in THAT, not in the whole capsule — with a 52pt button on
    // each end, centering on the capsule would read as off-center.
    // Two mutually-exclusive modes:
    //  - Live: passive indicator (no gesture), shows the floor message.
    //  - otherwise (normal / talking): hold-to-talk, which also interrupts the
    //    teacher (pressing to talk IS the interrupt).
    private var talkSegment: some View {
        Text(talkLabel)
            .font(NXFont.controlEmphasis)
            // Only Live uses a surface fill; every other state (including while the
            // teacher answers) is the primary fill, which needs white text.
            .foregroundStyle(live ? NXColor.text(scheme) : Color.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: controlHeight)
            .contentShape(Rectangle())
            .gesture(centerGesture)
            .accessibilityLabel(centerAccessibilityLabel)
            .accessibilityHint(centerAccessibilityHint)
    }

    // Which gesture the center strip carries, by state. nil in Live (passive).
    // Outside Live it is ALWAYS hold-to-talk — including while the teacher is
    // answering, because pressing to talk is itself the interrupt (see
    // pressQuickAsk). No separate interrupt button.
    private var centerGesture: AnyGesture<Void>? {
        if live { return nil }
        return AnyGesture(holdToTalk.map { _ in () })
    }

    // True while the teacher holds the floor outside Live. Only affects wording —
    // the gesture stays hold-to-talk, since a press cuts the teacher off.
    private var teacherAnswering: Bool { !live && controller.floor == .teacher }

    private var seamColor: Color {
        live ? NXColor.border(scheme) : Color.white.opacity(0.22)
    }

    private var talkLabel: String {
        if live { return floorMessage }
        if talking { return cancelArmed ? "松开 取消" : "上滑取消 · 松开发送" }
        // The teacher is talking, but the control is still hold-to-talk: pressing
        // cuts them off and listens. Say so instead of offering a second button.
        if teacherAnswering { return "老师在说 · 按住打断" }
        return "按住 说话"
    }

    // Stays the primary (actionable) fill while the teacher answers — it IS
    // pressable then, so greying it out would read as disabled.
    private var talkFill: Color {
        if live { return NXColor.surface2(scheme) }
        if cancelArmed { return NXColor.error }
        return talking ? NXColor.primary.opacity(0.85) : NXColor.primary
    }

    private var centerAccessibilityLabel: String {
        if live { return "Live 进行中" }
        if teacherAnswering { return "按住 打断老师并说话" }
        return "按住 说话"
    }

    private var centerAccessibilityHint: String {
        if live { return "随时开口;点 Live 退出" }
        if teacherAnswering { return "按住会立刻停下老师并开始听你说,松开发送" }
        return "按住说话,松开发送"
    }

    // A real hold (0.18s) before a turn starts, so a stray tap sends nothing.
    // Release sends and asks for one answer.
    // Drag up past this far (points) to arm cancel. Comfortably above finger
    // jitter, reachable without lifting.
    private let cancelThreshold: CGFloat = 60

    private var holdToTalk: some Gesture {
        LongPressGesture(minimumDuration: 0.18)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case let .second(true, drag) = value else { return }
                if !talking {
                    talking = true
                    cancelArmed = false
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    controller.pressQuickAsk()
                }
                // Negative height = dragging up. Toggle the armed state on
                // threshold crossings, with a light tick each way as feedback.
                let armed = (drag?.translation.height ?? 0) < -cancelThreshold
                if armed != cancelArmed {
                    cancelArmed = armed
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            .onEnded { _ in
                guard talking else { return }
                talking = false
                if cancelArmed {
                    controller.cancelQuickAsk()
                } else {
                    controller.releaseQuickAsk()
                }
                cancelArmed = false
            }
    }

    // Live is only offered on headphones. On the speaker the teacher's own voice
    // reaches the mic and self-triggers the VAD into an endless answer loop, and
    // the mic can't be closed to stop it because an open mic is what Live is (see
    // AudioRouteLogic). Refuse with the reason instead of entering a broken mode.
    private func toggleLive() {
        if live {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            controller.exitLive()
            live = false
            return
        }
        guard liveAvailable() else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            onLiveUnavailable()
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        controller.enterLive()
        live = true
    }

    private var statusDotColor: Color {
        switch controller.floor {
        case .user: return NXColor.primary
        case .teacher: return .orange
        case .player: return .green
        case .idle: return NXColor.textTertiary(scheme)
        }
    }

    // Frozen while the learner holds the floor, so the timestamp stops ticking
    // at the line they interrupted instead of chasing live playback.
    private var cursorMs: Int {
        classroomCursorPosition(livePositionMs, controller.frozenPositionMs, 0)
    }

    private var trimmedNotice: String {
        notice.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var latestTurn: TutorTurn? {
        controller.transcript.last.flatMap {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
    }

    // One line, tiered: a playback action just taken wins (transient,
    // self-clearing), then the latest thing either party said, then a status
    // message. In Live the fallback names the floor holder so a glance tells the
    // learner whose turn it is; outside Live it's the classroom state message.
    private var line: String {
        if !trimmedNotice.isEmpty { return trimmedNotice }
        if let latestTurn { return latestTurn.text }
        return statusMessage
    }

    // Ambient status for the line above the controls — names whose turn it is
    // WITHOUT repeating the button's own instruction (the button already says
    // "按住 说话" / "Live"). In self-study it just reports the mode.
    private var statusMessage: String {
        switch controller.floor {
        case .user: return "在听你说…"
        case .teacher: return "老师在说…"
        case .player: return live ? "播客播放中" : "自学中 · 播客播放中"
        case .idle: return "Live · 等你开口"
        }
    }

    // The big button's label while in Live (it turns passive there). Terse — it
    // sits inside a capsule next to the waveform, so no room for a full sentence.
    private var floorMessage: String {
        switch controller.floor {
        case .user: return "在听你说…"
        case .teacher: return "老师在说…"
        case .player: return "播放中 · 开口插话"
        case .idle: return "直接开口说话"
        }
    }
}

// While the session comes up, or if it failed. No close button — the bar is
// persistent and retries on the next screen visit.
private struct ConnectingBar: View {
    let error: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Surface, edge, and shadow now come from BottomPanelChrome; this is just
        // the content. Kept at the same height as the connected control row so the
        // panel doesn't resize when the session finishes connecting.
        HStack(spacing: NXSpacing.x2) {
            VoiceActivityIcon(phase: error == nil ? .connecting : .ended, connected: false)
            Text(error ?? "正在接通语音老师…")
                .font(NXFont.control)
                .foregroundStyle(error == nil ? NXColor.textSecondary(scheme) : NXColor.error)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 58)
        .padding(.horizontal, NXSpacing.x2)
    }
}

// Three bars whose rhythm says who holds the floor. Driven by the classroom
// phase rather than real audio levels: the phase already carries that fact, and
// the realtime transport stays a pure event pipe.
private struct VoiceActivityIcon: View {
    let phase: ClassroomPhase
    let connected: Bool
    var showsChip: Bool = true
    var tint: Color? = nil
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
        .frame(width: showsChip ? 28 : 22, height: 28)
        .background(showsChip ? NXColor.primary.opacity(rhythm == nil ? 0.08 : 0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: NXRadius.small))
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }

    private var barColor: Color {
        if let tint { return tint.opacity(rhythm == nil ? 0.6 : 1) }
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
