import Foundation

@MainActor
final class LiveClassSession: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    struct Readiness { let configured: Bool; let message: String? }

    @Published var notice = ""
    @Published var error: String?
    @Published var connected = false
    @Published var controller: ClassroomController?

    // A playback notice is a transient confirmation of an action just taken, not
    // a status field: it clears itself so the dock falls back to showing the
    // conversation. Overridable so tests need not wait out the real duration.
    var noticeLifetime: Duration = .milliseconds(2600)
    private var noticeExpiry: Task<Void, Never>?

    private let store: EpisodeStore
    private let keychain: KeychainStore
    private let episodeId: Int
    private let playback: Playback

    // Loaded content for context building.
    private var episodeTitle: String?
    private var channel: String?
    private var chapters: [ChapterDTO] = []
    private var sentences: [SentenceDTO] = []

    // Configurable model/region (defaults mirror the backend settings).
    var region = "cn-beijing"
    var model = "qwen3.5-omni-plus-realtime"

    init(store: EpisodeStore, keychain: KeychainStore, episodeId: Int, playback: Playback) {
        self.store = store; self.keychain = keychain; self.episodeId = episodeId; self.playback = playback
    }

    static func readiness(dashscopeKey: String?, workspaceId: String?) -> Readiness {
        let ok = !(dashscopeKey ?? "").isEmpty && !(workspaceId ?? "").isEmpty
        return Readiness(configured: ok, message: ok ? nil : "Configure DashScope API Key and Workspace ID to start live class")
    }

    func showNotice(_ message: String) {
        noticeExpiry?.cancel()
        notice = message
        let lifetime = noticeLifetime
        noticeExpiry = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.notice = ""
        }
    }

    func loadContent(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO]) {
        self.episodeTitle = episodeTitle; self.channel = channel; self.chapters = chapters; self.sentences = sentences
    }

    private func loadFromStore() {
        let episode = store.downloadedEpisodes().first { $0.id == episodeId }
        loadContent(episodeTitle: episode?.title, channel: episode?.channel,
                    chapters: store.chapters(for: episodeId), sentences: store.sentences(for: episodeId))
    }

    func buildInitialInstructions(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO], startMs: Int) -> String {
        let material = classroomContext(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, atMs: startMs)
        return baseClassroomInstructions(material: material)
    }

    func contextFor(_ positionMs: Int) -> String {
        classroomContext(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, atMs: positionMs)
    }

#if os(iOS)
    private var transport: QwenRealtimeTransport?

    // Starts wherever playback currently is. There is no anchor parameter by
    // design: discussion is always about the moment the learner is in.
    func start() async {
        error = nil
        let key = keychain.get(.dashscopeKey)
        let workspace = keychain.get(.dashscopeWorkspaceId)
        let readiness = Self.readiness(dashscopeKey: key, workspaceId: workspace)
        guard readiness.configured, let key, let workspace else { error = readiness.message; return }
        loadFromStore()
        // The mic opens while the source is still playing, so the audio session
        // has to allow recording with echo cancellation before we connect.
        playback.configureAudioSession(voiceMode: true)
        let startMs = classroomCursorPosition(playback.currentMs, nil, 0)
        let instructions = buildInitialInstructions(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, startMs: startMs)
        let transport = QwenRealtimeTransport()
        self.transport = transport
        let controller = ClassroomController(
            sentences: sentences, playback: playback, transport: transport,
            onNotice: { [weak self] in self?.showNotice($0) },
            onContextRefresh: { [weak self] position in
                guard let self else { return }
                transport.updateContext(self.contextFor(position))
            })
        self.controller = controller
        // Deliberately no freeze here: joining brings the teacher in while the
        // source keeps playing. The learner speaking is what pauses it, and the
        // model is told the position it was interrupted at.
        do {
            try await transport.connect(instructions: instructions, apiKey: key, workspaceId: workspace,
                                        region: region, model: model) { [weak controller] event in
                Task { @MainActor in controller?.handleRealtimeEvent(event) }
            }
            connected = true
            // Default to push-to-talk: a hold starts a turn, release ends it.
            // Sliding to lock later flips this to continuous.
            transport.setTurnMode(.pushToTalk)
        } catch {
            self.error = error.localizedDescription
            connected = false
        }
    }

    func end() {
        connected = false
        controller = nil
        transport = nil
        noticeExpiry?.cancel()
        notice = ""
        // Give the source its full-fidelity playback session back.
        playback.configureAudioSession(voiceMode: false)
    }
#endif
}
