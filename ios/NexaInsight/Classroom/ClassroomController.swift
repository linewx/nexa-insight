import Foundation

@MainActor
protocol ClassroomTransport: AnyObject {
    func stopSpeaking()
    func sendToolResult(callId: String?, ok: Bool)
    func updateContext(_ context: String)
    func injectUserText(_ text: String)
    func speak(_ text: String)
    func requestResponse()

    // Turn control. Continuous mode is the model-driven VAD flow; push-to-talk
    // hands turn boundaries to the caller (press/release). See TurnMode.
    func setTurnMode(_ mode: TurnMode)
    // Open the mic for a push-to-talk turn (enable the local track; clear any
    // stale input buffer so the turn starts clean).
    func beginListening()
    // End a push-to-talk turn: commit the captured audio and request exactly
    // one response, then close the mic.
    func endTurnAndRespond()
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

    // Tool calls can arrive twice: once as response.function_call_arguments.done
    // and again echoed in response.done's output. Run each call_id once.
    private var handledToolCallIds: Set<String> = []

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
            // Dedupe by call_id so a call echoed in both the dedicated event and
            // response.done runs once. A nil call_id can't be tracked, so it runs
            // (rare, and better than dropping a real command).
            if let callId {
                guard !handledToolCallIds.contains(callId) else { return }
                handledToolCallIds.insert(callId)
            }
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

    // MARK: - Push-to-talk

    // The finger, not the model's VAD, marks the turn boundary. Press mirrors
    // the .speechStarted path — freeze at the interrupted position and refresh
    // the model's context to there — and additionally opens the mic. The reducer
    // is unchanged: this drives the same events VAD would.
    func beginUserTurn() {
        transport.beginListening()
        freeze(cursor(), reason: .speechStarted)
        onContextRefresh(frozenPositionMs ?? cursor())
    }

    // Release: close the mic, commit the captured audio, and request exactly one
    // response. The learner's transcription and the answer still arrive as the
    // usual .inputTranscriptionCompleted / .responseAudioTranscriptDone events.
    func endUserTurn() {
        state = classroomReducer(state, .discussionStarted)
        transport.endTurnAndRespond()
    }

    // Slide-to-lock: hand turn-taking to the model's VAD (continuous live mode).
    // One-way — a locked session is exited by ending it, not by relocking.
    func switchToContinuous() {
        transport.setTurnMode(.continuous)
    }
}
