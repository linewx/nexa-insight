import Foundation

@MainActor
final class LiveClassSession: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    struct Readiness { let configured: Bool; let message: String? }

    @Published var notice = ""
    @Published var error: String?
    @Published var connected = false
    @Published var controller: ClassroomController?

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

    func start(at anchorMs: Int? = nil) async {
        error = nil
        let key = keychain.get(.dashscopeKey)
        let workspace = keychain.get(.dashscopeWorkspaceId)
        let readiness = Self.readiness(dashscopeKey: key, workspaceId: workspace)
        guard readiness.configured, let key, let workspace else { error = readiness.message; return }
        loadFromStore()
        let startMs = anchorMs ?? classroomCursorPosition(playback.currentMs, nil, 0)
        let instructions = buildInitialInstructions(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, startMs: startMs)
        let transport = QwenRealtimeTransport()
        self.transport = transport
        let controller = ClassroomController(
            sentences: sentences, playback: playback, transport: transport,
            onNotice: { [weak self] in self?.notice = $0 },
            onContextRefresh: { [weak self] position in
                guard let self else { return }
                transport.updateContext(self.contextFor(position))
            })
        self.controller = controller
        controller.freeze(startMs, reason: .paused)
        do {
            try await transport.connect(instructions: instructions, apiKey: key, workspaceId: workspace,
                                        region: region, model: model) { [weak controller] event in
                Task { @MainActor in controller?.handleRealtimeEvent(event) }
            }
            connected = true
        } catch {
            self.error = error.localizedDescription
            connected = false
        }
    }

    func end() {
        connected = false
        controller = nil
        transport = nil
    }
#endif
}
