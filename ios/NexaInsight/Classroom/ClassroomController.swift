import Foundation

@MainActor
protocol ClassroomTransport: AnyObject {
    func stopSpeaking()
    func sendToolResult(callId: String?, ok: Bool)
    func updateContext(_ context: String)
    func injectUserText(_ text: String)
    func speak(_ text: String)
    func requestResponse()
}

enum FreezeReason { case paused, speechStarted }

enum RealtimeEvent {
    case speechStarted
    case inputTranscriptionCompleted(String)
    case responseAudioTranscriptDone(String)
    case responseDone
    case toolCall(name: PlaybackTool, args: [String: Double], callId: String?)
}

@MainActor
final class ClassroomController: ObservableObject {
    @Published var state = ClassroomState(phase: .idle, pausedAtMs: nil)
    @Published var transcript: [TutorTurn] = []
    @Published var frozenPositionMs: Int?

    private let sentences: [SentenceDTO]
    private let playback: Playback
    private let transport: ClassroomTransport
    private let onNotice: (String) -> Void
    private let onContextRefresh: (Int) -> Void

    // Position-moving tools jump the podcast, so the model's context must refresh
    // to the new spot (ports the PLAYS_AUDIO / moved sets from useClassroomTeacher).
    private static let movers: Set<PlaybackTool> = [.seek_to_timestamp, .seek_relative, .previous_sentence, .next_sentence, .repeat_current_sentence]

    init(sentences: [SentenceDTO], playback: Playback, transport: ClassroomTransport,
         onNotice: @escaping (String) -> Void, onContextRefresh: @escaping (Int) -> Void) {
        self.sentences = sentences; self.playback = playback; self.transport = transport
        self.onNotice = onNotice; self.onContextRefresh = onContextRefresh
        self.state = classroomReducer(ClassroomState(phase: .idle, pausedAtMs: nil), .connected)
    }

    func cursor() -> Int { classroomCursorPosition(playback.currentMs, frozenPositionMs, 0) }

    func freeze(_ positionMs: Int, reason: FreezeReason) {
        let frozen = max(0, positionMs)
        frozenPositionMs = frozen
        playback.pause()
        state = classroomReducer(state, reason == .speechStarted ? .speechStarted(atMs: frozen) : .paused(atMs: frozen))
    }

    func resume() {
        frozenPositionMs = nil
        transport.stopSpeaking()
        playback.play()
        state = classroomReducer(state, .resumed)
        onNotice("Podcast playing")
    }

    func runPlaybackTool(_ name: PlaybackTool, _ args: [String: Double]) {
        transport.stopSpeaking()
        let positionMs = cursor()
        let at = activeSentence(sentences, positionMs) ?? sentences.first
        let index = max(0, sentences.firstIndex(where: { $0.id == at?.id }) ?? 0)
        let starts = sentences.map(\.startMs)
        let target = playbackTargetPosition(name, args, positionMs, index, starts)
        switch name {
        case .resume_playback, .finish_discussion:
            resume()
        case .pause_playback:
            playback.pause()
            freeze(target, reason: .paused)
        case .set_playback_speed:
            playback.speed(args["rate"] ?? 1)
        case .exit_class:
            break
        default:
            playback.seek(target)
            resume()
        }
        onNotice(playbackNotice(name, target))
        if Self.movers.contains(name) { onContextRefresh(target) }
    }

    func handleRealtimeEvent(_ event: RealtimeEvent) {
        switch event {
        case .speechStarted:
            freeze(cursor(), reason: .speechStarted)
            onContextRefresh(frozenPositionMs ?? cursor())
        case let .inputTranscriptionCompleted(text) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
            transcript.append(TutorTurn(role: .user, text: text))
        case .inputTranscriptionCompleted:
            break
        case let .responseAudioTranscriptDone(text):
            transcript.append(TutorTurn(role: .assistant, text: text))
            state = classroomReducer(state, .teacherStarted)
        case .responseDone:
            state = classroomReducer(state, .teacherFinished)
        case let .toolCall(name, args, callId):
            runPlaybackTool(name, args)
            transport.sendToolResult(callId: callId, ok: true)
        }
    }

    func sendText(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActionableTranscript(trimmed) else { return }
        if let direct = matchDirectCommand(trimmed) {
            transcript.append(TutorTurn(role: .user, text: trimmed))
            runPlaybackTool(direct.name, direct.args)
            return
        }
        // Discussion on the Omni-direct path: freeze if needed, inject the learner
        // turn, and let the spoken model respond.
        if frozenPositionMs == nil { freeze(cursor(), reason: .paused) }
        state = classroomReducer(state, .discussionStarted)
        transcript.append(TutorTurn(role: .user, text: trimmed))
        transport.injectUserText(trimmed)
        transport.requestResponse()
    }
}
