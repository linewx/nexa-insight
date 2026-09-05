import Foundation

@MainActor
final class LiveClassSession: ObservableObject, Identifiable {
    nonisolated let id = UUID()
    struct Readiness { let configured: Bool; let message: String? }

    @Published var notice = ""
    @Published var error: String?
    @Published var connected = false
    @Published private(set) var connecting = false
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var transport: (any ClassroomConnection)?
    private let makeTransport: @MainActor () -> any ClassroomConnection
    private let readCredential: (SecretKey) -> String?
    /// Bumped on every saved note. The study screen watches it to rebuild the card
    /// indexes: a card written to the database that the rows never re-read stays
    /// invisible until the episode is reopened, which is exactly how the delete bug
    /// looked before it was fixed.
    @Published var savedNotes = 0
    @Published var controller: ClassroomController?

    // A playback notice is a transient confirmation of an action just taken, not
    // a status field: it clears itself so the dock falls back to showing the
    // conversation. Overridable so tests need not wait out the real duration.
    var noticeLifetime: Duration = .milliseconds(2600)
    private var noticeExpiry: Task<Void, Never>?

    private let store: EpisodeStore
    private let episodeId: Int
    private let playback: Playback

    // Loaded content for context building.
    private var episodeTitle: String?
    private var channel: String?
    /// "native" or "teaching", classified at import from the first 60 lines. Decides what a
    /// saved card should CONTAIN: the two material types fail the learner in different ways,
    /// so the same note-taking guidance cannot serve both.
    private var materialKind = "native"
    private var chapters: [ChapterDTO] = []
    private var sentences: [SentenceDTO] = []

    // Configurable model/region (defaults mirror the backend settings).
    var region = "cn-beijing"
    var model = "qwen3.5-omni-plus-realtime"

    init(store: EpisodeStore, keychain: KeychainStore, episodeId: Int, playback: Playback,
         makeTransport: @escaping @MainActor () -> any ClassroomConnection = { QwenRealtimeTransport() },
         readCredential: ((SecretKey) -> String?)? = nil) {
        self.store = store; self.episodeId = episodeId; self.playback = playback
        self.makeTransport = makeTransport
        self.readCredential = readCredential ?? { keychain.get($0) }
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

    func loadContent(episodeTitle: String?, channel: String?, chapters: [ChapterDTO],
                     sentences: [SentenceDTO], materialKind: String = "native") {
        self.episodeTitle = episodeTitle; self.channel = channel; self.chapters = chapters; self.sentences = sentences
        self.materialKind = materialKind
    }

    private func loadFromStore() {
        let episode = store.downloadedEpisodes().first { $0.id == episodeId }
        loadContent(episodeTitle: episode?.title, channel: episode?.channel,
                    chapters: store.chapters(for: episodeId), sentences: store.sentences(for: episodeId),
                    materialKind: episode?.materialKind ?? "native")
    }

    func buildInitialInstructions(episodeTitle: String?, channel: String?, chapters: [ChapterDTO], sentences: [SentenceDTO], startMs: Int) -> String {
        let material = classroomContext(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, atMs: startMs)
        return baseClassroomInstructions(material: material, materialKind: materialKind,
                                         episodeMaterial: episodeTranscriptContext(sentences))
    }

    /// Set while the 洞察 page is open, so a question asked there is answered about the PAGE.
    ///
    /// The context refresh is driven by a playback position, which is the right anchor on the
    /// transcript and the wrong one here: the reader is looking at claims and figures, and "this
    /// point" means something on screen rather than a moment in the audio.
    var insightForContext: InsightDTO?

    func contextFor(_ positionMs: Int) -> String {
        if let insightForContext {
            return insightContext(episodeTitle: episodeTitle, channel: channel, insight: insightForContext)
        }
        return classroomContext(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, atMs: positionMs)
    }

    // Starts wherever playback currently is. There is no anchor parameter by
    // design: discussion is always about the moment the learner is in.
    func start() async {
        guard !Task.isCancelled else { return }
        guard !canCarryATurn else { return }
        if let connectionTask {
            await connectionTask.value
            return
        }
        controller?.end()
        transport?.disconnect()
        connected = false
        let generation = UUID()
        connectionGeneration = generation
        connecting = true
        let task = Task { await self.connect(generation: generation) }
        connectionTask = task
        await task.value
        guard connectionGeneration == generation else { return }
        connectionTask = nil
        connecting = false
    }

    private func connect(generation: UUID) async {
        guard !Task.isCancelled, connectionGeneration == generation else { return }
        error = nil
        let key = readCredential(.dashscopeKey)
        let workspace = readCredential(.dashscopeWorkspaceId)
        let readiness = Self.readiness(dashscopeKey: key, workspaceId: workspace)
        guard readiness.configured, let key, let workspace else { error = readiness.message; return }
        loadFromStore()
        // The mic opens while the source is still playing, so the audio session
        // has to allow recording with echo cancellation before we connect.
        configureVoiceAudio(true)
        let startMs = classroomCursorPosition(playback.currentMs, nil, 0)
        let instructions = buildInitialInstructions(episodeTitle: episodeTitle, channel: channel, chapters: chapters, sentences: sentences, startMs: startMs)
        let transport = makeTransport()
        self.transport = transport
        transport.onFailure = { [weak self] message in
            guard let self, self.connectionGeneration == generation else { return }
            self.connected = false
            self.error = message
            self.controller?.end()
            self.configureVoiceAudio(false)
        }
        let controller = ClassroomController(
            sentences: sentences, playback: playback, transport: transport,
            onNotice: { [weak self] in self?.showNotice($0) },
            onContextRefresh: { [weak self] position, scene in
                guard let self else { return }
                transport.updateContext(self.contextFor(position), scene: scene)
            },
            onSaveNote: { [weak self] request, sentence in
                self?.save(request, on: sentence)
            })
        self.controller = controller
        // Deliberately no freeze here: joining brings the teacher in while the
        // source keeps playing. The learner speaking is what pauses it, and the
        // model is told the position it was interrupted at.
        do {
            transport.setTurnMode(.pushToTalk)
            try await transport.connect(instructions: instructions, apiKey: key, workspaceId: workspace,
                                        region: region, model: model) { [weak self, weak controller] event in
                guard let self, self.connectionGeneration == generation else { return }
                controller?.handleRealtimeEvent(event)
            }
            guard !Task.isCancelled, connectionGeneration == generation else {
                transport.disconnect()
                return
            }
            connected = true
            // Default to push-to-talk: a hold starts a turn, release ends it.
            // Sliding to lock later flips this to continuous.
            transport.setTurnMode(.pushToTalk)
        } catch {
            guard connectionGeneration == generation else { return }
            controller.end()
            transport.disconnect()
            self.error = error.localizedDescription
            connected = false
            configureVoiceAudio(false)
        }
    }

    func end() {
        connectionGeneration = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        connecting = false
        connected = false
        controller?.end()
        transport?.disconnect()
        controller = nil
        transport = nil
        noticeExpiry?.cancel()
        notice = ""
        // Give the source its full-fidelity playback session back.
        configureVoiceAudio(false)
    }

    private func configureVoiceAudio(_ enabled: Bool) {
#if os(iOS)
        playback.configureAudioSession(voiceMode: enabled)
#endif
    }

    /// Writes a note the teacher was asked to keep.
    ///
    /// Lives here rather than in the controller because this is the layer that owns the
    /// store; the controller stays pure logic plus a transport. Published on
    /// `savedNotes` so the study screen can refresh its indexes — a card written into the
    /// database that the rows never re-read would not appear until the episode was
    /// reopened, which was the shape of an earlier bug.
    func save(_ request: NoteRequest, on sentence: SentenceDTO?) {
        guard let sentence else { return }
        do {
            switch request.kind {
            case let .expression(text, type):
                // The existing optional fields are reused rather than new columns added:
                // `restored` carries the sense group (it already means "what this really
                // is, spelled out"), `heardAs` the everyday misreading (it already means
                // "what you thought you got"), `whenToUse` the usage frame. No migration,
                // and the card's existing layout renders all three.
                //
                // `whyHard` is deliberately left nil. It asked the model to explain why
                // something is difficult — which the learner already knows, having just
                // stopped to ask — and one sentence only ever produced a label like
                // "弱读脱落". Nothing fills it now, so the card stops showing it.
                let dto = LearningExpressionDTO(
                    id: 0, text: text, kind: type.impliedKind, type: type,
                    chinese: request.body, pronunciation: nil,
                    // The transcript line is the example when the teacher did not give
                    // one, or gave one that is not actually in the text.
                    example: request.example ?? sentence.sourceText,
                    exampleChinese: request.example == nil ? sentence.chinese : "",
                    heardAs: request.literal,
                    restored: request.senseGroup,
                    whenToUse: request.usage,
                    source: "manual", request: request.request)
                _ = try store.addManualExpression(
                    episodeId: episodeId, sentenceId: sentence.id, expression: dto,
                    request: request.request)
            case let .answer(question):
                try store.addParagraphNote(
                    episodeId: episodeId, sentenceId: sentence.id,
                    question: question, answer: request.body)
            }
            savedNotes += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Whether a turn can actually be carried right now.
    ///
    /// `connected` alone is not enough: it records that connecting SUCCEEDED, and stays
    /// true after the server ends an idle stream at 300s. So a hold five minutes after
    /// the last one went through every motion against a closed channel and produced
    /// nothing — no answer, no error, no explanation.
    var canCarryATurn: Bool { connected && (transport?.isAlive ?? false) }

    /// Rebuilds a session the server has dropped, leaving a live one alone.
    ///
    /// Called before a turn rather than on a timer: the timeout only matters at the
    /// moment someone asks something, and reconnecting in the background would keep a
    /// mic-capable session alive for a screen nobody is talking to.
    func reconnectIfNeeded() async {
        if let connectionTask {
            await connectionTask.value
            return
        }
        guard !canCarryATurn else { return }
        end()
        await start()
    }
}
