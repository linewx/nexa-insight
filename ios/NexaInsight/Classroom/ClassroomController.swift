import Foundation

// Debug channel for device runs. Writes to stderr (unbuffered) so
// `devicectl process launch --console` captures it live.
//
// DEBUG-only: the voice floor is timing-dependent and effectively only
// diagnosable from device logs (every bug so far — phantom turns, the
// self-triggering loop, the commit-after-release ordering — was found this way),
// so the calls stay in the source. But realtime frames carry transcripts of what
// the learner said, which must not stream to stderr in a shipped build. In
// Release the whole thing compiles to nothing: the @autoclosure means the
// interpolated strings are never even built.
enum NexaLog {
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        FileHandle.standardError.write(Data(("[Nexa] " + message() + "\n").utf8))
        #endif
    }
}

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
    // Close the mic (disable the local track). Called whenever the podcast takes
    // the floor: a live mic + playing podcast means the podcast bleeds into the
    // mic and the server VAD self-triggers a phantom turn. Pressing to talk
    // (beginListening) reopens it.
    func stopListening()
    // End a push-to-talk turn: commit the captured audio and request exactly
    // one response, then close the mic.
    func endTurnAndRespond()
    // Abandon a push-to-talk turn: close the mic and drop the captured audio
    // without committing or requesting a response (slide-up-to-cancel).
    func cancelTurn()
}

enum FreezeReason { case paused, speechStarted }

enum RealtimeEvent {
    case speechStarted
    case inputAudioCommitted
    case responseCreated
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

    // Who currently holds the floor. Drives visuals; every grant enforces the
    // single-voice rule. Starts on the podcast (self-study, source playing).
    @Published var floor: FloorHolder = .player
    // Which way the learner is working right now. Was `inLive: Bool`, which could
    // only express two of the three: it made "resume when the teacher finishes" mean
    // "not Live", so reading — where the podcast must stay put — had no way to say so
    // without also inheriting Live's open mic.
    private(set) var scene: ClassroomScene = .selfStudy
    // Whether the server VAD actually heard speech during the current push-to-talk
    // hold. A press with nothing said must not hand the floor to the teacher —
    // there will be no response, so the floor would stick on .teacher forever.
    private var heardSpeechThisTurn = false
    // True while the finger is down in quick-ask. The server can commit a turn
    // mid-hold (it commits on trailing silence, e.g. a pause while thinking); that
    // must NOT hand the floor over and close the mic, or the rest of the sentence
    // is lost. The handoff waits for the finger to lift.
    private var holdingQuickAsk = false
    // Whether the server already committed a turn during this hold. If it did, the
    // release must hand the floor over itself — no further commit is coming, so
    // waiting for one would leave the floor on .user with the mic open, which is
    // exactly the self-triggering state.
    private var committedThisTurn = false

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

    // Routed through grantFloor so the single-voice rule and the mic gate are
    // applied in ONE place. It used to hand-roll the same three steps (quiet the
    // teacher, close the mic, play) and set `floor` directly, which meant the mic
    // was closed even in Live — where it must stay open for barge-in.
    func resume() {
        applyFloorEvent(.playbackRequested)
        state = classroomReducer(state, .resumed)
        NexaLog.log("RESUME floor=\(self.floor) playing=\(self.playback.playbackState == .playing) at=\(self.playback.currentMs)ms")
        onNotice("Podcast playing")
    }

    // The transport controls (play/pause button, scrubber, tapping a subtitle) go
    // through here so they obey the single-voice rule. They used to call
    // playback.play() straight, which is why starting playback while the teacher
    // was answering left BOTH talking — the floor never moved, so nothing silenced
    // the teacher. Pressing play means "I want the podcast now", which is exactly
    // grantFloor(to: .player).
    func userStartedPlayback(seekTo positionMs: Int? = nil) {
        applyFloorEvent(.playbackRequested, resumeAtMs: positionMs)
        state = classroomReducer(state, .resumed)
    }

    // Pausing hands the floor to nobody: the podcast stops, the teacher stays
    // quiet, and the mic follows the mode's gate (closed in quick-ask). Freezing
    // here keeps the discussion anchored at the spot the learner stopped on.
    func userPausedPlayback() {
        freeze(cursor(), reason: .paused)
        applyFloorEvent(.playbackHeld)
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
            // Through grantFloor, not a direct assignment: silenced(by: .idle) says
            // the teacher must be stopped too, and setting `floor` by hand skipped
            // that. It only looked correct because runPlaybackTool happens to call
            // stopSpeaking() up top — move that call and the bug appears.
            freeze(target, reason: .paused)
            applyFloorEvent(.playbackHeld)
        case .set_playback_speed:
            playback.speed(args["rate"] ?? 1)
        case .exit_class:
            break
        default:
            playback.seek(target)
            resume()
        }
        onNotice(playbackNotice(name, target))
        if Self.movers.contains(name) {
            let subtitleAt = activeSentence(sentences, target)
            NexaLog.log("SYNC target=\(target)ms playerNow=\(playback.currentMs)ms subtitle#\(subtitleAt?.position ?? -1)@\(subtitleAt?.startMs ?? -1)ms ctxPos=\(target)ms")
            onContextRefresh(target)
        }
    }

    func handleRealtimeEvent(_ event: RealtimeEvent) {
        switch event {
        case .speechStarted:
            // Real speech was detected, so a response is coming — release may hand
            // the floor to the teacher.
            heardSpeechThisTurn = true
            freeze(frozenPositionMs ?? cursor(), reason: .speechStarted)
            onContextRefresh(frozenPositionMs ?? cursor())
            // In Live nothing else claims the floor when the learner starts
            // talking, so it would stay .idle and the UI would still read "just
            // start speaking" while they already are. The press-driven scenes
            // (quick-ask, reading) already took the floor on press.
            if scene == .live { grantFloor(to: .user, resumeAtMs: nil) }
        case .inputAudioCommitted:
            // The server has taken this turn, so the mic has done its job. In
            // quick-ask close it now — the finger is already up, and leaving it
            // open is what let the teacher's own voice trip the VAD and chain
            // another response. Live keeps it open by design (barge-in).
            //
            // Also reconcile the no-speech guess: the server may commit a turn even
            // when our local VAD never reported speech_started (seen on device), in
            // which case a response IS coming and the floor must be the teacher's,
            // not held at .idle.
            guard !scene.holdsMicOpen else { break }
            // Still holding: the server committed on a mid-sentence pause. Keep the
            // mic open and the floor with the learner — the rest of what they say
            // becomes another turn. Handing off here would cut them off.
            guard !holdingQuickAsk else {
                heardSpeechThisTurn = true
                // Record that the server already has a turn for this hold, so the
                // release knows not to wait for a commit that won't come again.
                committedThisTurn = true
                break
            }
            // Finger is up and the server has the audio, so a response is coming:
            // hand the floor to the teacher, which closes the mic via the gate in
            // grantFloor. Covers both the normal release (which defers the handoff
            // to here) and the case where the server committed a turn our local VAD
            // never reported, so the floor was being held at .idle.
            if floor == .user || floor == .idle {
                heardSpeechThisTurn = true
                applyFloorEvent(.turnCommitted)
            } else {
                // The floor is already where it belongs (.player or .teacher), so
                // only the mic needs attention: quick-ask must shut it now that the
                // server has the audio. Deliberately NOT re-granting the same floor
                // to get there — grantFloor(.player) also re-seeks, calls play() and
                // clears frozenPositionMs, which would restart playback here.
                applyMicGate()
            }
        case let .inputTranscriptionCompleted(text) where !text.trimmingCharacters(in: .whitespaces).isEmpty:
            transcript.append(TutorTurn(role: .user, text: text))
        case .inputTranscriptionCompleted:
            break
        case .responseCreated:
            // The teacher is starting to answer, so the floor is theirs. Going
            // through grantFloor applies the mic gate for the current mode: shut in
            // quick-ask (one turn at a time; an open mic would let the teacher's own
            // voice trip the VAD and chain another response), open in Live where
            // barge-in is the point — so taking .teacher here does NOT cost Live its
            // open mic.
            //
            // Live used to skip this entirely, which left the floor on .user for the
            // whole answer. That made `guard floor == .teacher` in .responseDone
            // always break, so a Live turn had no close-out at all: the floor never
            // returned to .idle and playback state after an answer was undefined.
            applyFloorEvent(.turnCommitted)
        case let .responseAudioTranscriptDone(text):
            transcript.append(TutorTurn(role: .assistant, text: text))
            state = classroomReducer(state, .teacherStarted)
        case .responseDone:
            state = classroomReducer(state, .teacherFinished)
            // Teacher finished. Hand the floor on automatically — the earlier bug
            // was that nothing did, so the floor stayed on .teacher and the
            // podcast never came back. A tool call during the answer may already
            // have taken the floor (e.g. a seek resumed playback); if so, leave it.
            guard floor == .teacher else { break }
            // Only self-study resumes. Live waits for the learner; reading leaves the
            // podcast where it was, because the answer ending is an invitation to
            // follow up — starting playback over the reply is the opposite of that.
            // This branch IS the reducer's resumePlayback flag.
            let resumes = scene.resumesPlaybackAfterAnswer
            applyFloorEvent(.teacherFinished(resumePlayback: resumes),
                            resumeAtMs: resumes ? frozenPositionMs : nil)
        case let .toolCall(name, args, callId):
            // Dedupe by call_id so a call echoed in both the dedicated event and
            // response.done runs once. A nil call_id can't be tracked, so it runs
            // (rare, and better than dropping a real command).
            if let callId {
                guard !handledToolCallIds.contains(callId) else { return }
                handledToolCallIds.insert(callId)
            }
            NexaLog.log("TOOL \(name.rawValue) args=\(args) floor=\(self.floor) scene=\(self.scene)")
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

    // MARK: - Floor handoff

    // The one place the single-voice rule is enforced. Granting the floor to a
    // holder silences the other two per silenced(by:); when the podcast takes
    // the floor it also (optionally seeks and) resumes.
    private func grantFloor(to holder: FloorHolder, resumeAtMs: Int?) {
        let rule = silenced(by: holder)
        if rule.stopTeacher { transport.stopSpeaking() }
        if rule.pausePlayer { playback.pause() }
        // The mic is a FUNCTION of (mode, floor), not a state anyone maintains by
        // hand. The two modes have OPPOSITE needs, so they can't share one rule:
        //
        //  - Live: mic open throughout, in every floor state. Open-mouth barge-in
        //    while the teacher talks is the entire point of Live; closing it on
        //    .teacher is exactly what broke interjecting.
        //  - Quick-ask: mic open ONLY while the learner holds the floor (finger
        //    down). It must be shut once the turn is released, or the teacher's own
        //    voice / room noise trips the server VAD, which commits a turn and
        //    generates the next response — the self-triggering loop seen on device.
        //
        // Deriving it here means no path can leave the mic in a state its mode
        // doesn't allow, which is what every phantom-turn bug so far came down to.
        floor = holder
        applyMicGate()
        if holder == .player {
            if let resumeAtMs { playback.seek(resumeAtMs) }
            frozenPositionMs = nil
            playback.play()
        }
    }

    // The mic is a FUNCTION of (mode, floor) — never a state maintained by hand.
    // Kept as its own method so the one path that needs the gate WITHOUT the rest of
    // grantFloor's side effects (see .inputAudioCommitted) can reuse the same rule
    // instead of poking the transport directly.
    private func applyMicGate() {
        if scene.holdsMicOpen || floor == .user {
            transport.beginListening()
        } else {
            transport.stopListening()
        }
    }

    // Event-driven entry: the reducer decides WHO gets the floor, grantFloor applies
    // what that means (silence the others, gate the mic, resume playback). Callers
    // say what happened, not what state to move to — so the transition table lives
    // in one testable place (floorReducer) instead of being re-derived at each call
    // site, which is how the floor and the mic drifted apart before.
    private func applyFloorEvent(_ event: FloorEvent, resumeAtMs: Int? = nil) {
        let next = floorReducer(floor, event)
        // `.userReleased` deliberately keeps the floor, and re-granting the same
        // holder would pointlessly reopen the mic. Skip only THAT case: other
        // events carry an action (seek + play) that must still run when the holder
        // happens to be unchanged — e.g. tapping a line while already playing.
        if case .userReleased = event, next == floor { return }
        grantFloor(to: next, resumeAtMs: resumeAtMs)
    }

    // MARK: - Quick ask (long-press)

    // Press: freeze at the interrupted position, refresh context there, and take
    // the floor — which pauses the podcast, quiets the teacher, and opens the mic
    // (all three derived in grantFloor).
    // Pressing to talk IS the interrupt: grantFloor(to: .user) silences both the
    // podcast and the teacher (see silenced(by:)), so a press mid-answer cuts the
    // teacher off and starts listening. There is no separate interrupt button.
    func pressQuickAsk() {
        NexaLog.log("pressQuickAsk cursor=\(self.cursor())")
        scene = .selfStudy
        heardSpeechThisTurn = false
        committedThisTurn = false
        holdingQuickAsk = true
        // Freeze at the position the podcast was at. When the press interrupts the
        // teacher, the podcast is already paused and frozenPositionMs already holds
        // the spot it was interrupted at — keep that one rather than re-reading a
        // stopped player, so resuming later lands where the learner left off.
        freeze(frozenPositionMs ?? cursor(), reason: .speechStarted)
        onContextRefresh(frozenPositionMs ?? cursor())
        applyFloorEvent(.userTookFloor)
    }

    // Release: end the turn and let the server take it. The floor moves to the
    // teacher once the server confirms (.inputAudioCommitted), not here.
    func releaseQuickAsk() {
        let alreadyCommitted = committedThisTurn
        holdingQuickAsk = false
        // Nothing was said during the hold: there will be no response, so handing
        // the floor to the teacher would strand it there (the .responseDone that
        // normally hands it back never arrives). Just stop where we are — podcast
        // stays paused at the frozen spot, waiting for the learner.
        guard heardSpeechThisTurn else {
            NexaLog.log("releaseQuickAsk with no speech -> holding at \(self.frozenPositionMs ?? -1)ms")
            transport.cancelTurn()
            applyFloorEvent(.nothingSaid)
            return
        }
        state = classroomReducer(state, .discussionStarted)
        transport.endTurnAndRespond()
        // Normally the mic must stay OPEN past this point: the server ends a turn by
        // hearing trailing silence, and on device speech_stopped/committed both
        // arrive AFTER the finger lifts. Closing here would lose the turn, so the
        // handoff waits for .inputAudioCommitted.
        //
        // But if the commit already landed mid-hold, no further one is coming for
        // this turn — hand off now or the floor would sit on .user with the mic open,
        // which is the self-triggering state.
        if alreadyCommitted {
            NexaLog.log("releaseQuickAsk after commit -> floor to teacher now")
            applyFloorEvent(.turnCommitted)
        } else {
            NexaLog.log("releaseQuickAsk -> waiting for server commit, mic still open")
            applyFloorEvent(.userReleased)   // no-op by design; keeps the mic open
        }
    }

    // NOTE: there is no interruptTeacher(). Interrupting is not its own action —
    // pressing to talk is the interrupt, because grantFloor(to: .user) silences
    // the teacher per silenced(by:). See pressQuickAsk.

    // Slide-up cancel: drop the captured audio without a response and hand the
    // floor back to the podcast, resuming from where it was interrupted — as if
    // the learner never pressed. No teacher turn, no transcript entry.
    func cancelQuickAsk() {
        holdingQuickAsk = false
        heardSpeechThisTurn = false
        committedThisTurn = false
        let resumeAt = frozenPositionMs
        transport.cancelTurn()
        applyFloorEvent(.playbackRequested, resumeAtMs: resumeAt)
    }

    // MARK: - Reading (hold a paragraph)

    /// Hold a paragraph in reading mode: same push-to-talk turn as quick-ask, but the
    /// question is about the line under the finger rather than wherever playback is.
    ///
    /// `atMs` is that paragraph's own start, not the cursor. In reading the two are
    /// usually different — you scroll ahead of the audio, or the audio is not playing
    /// at all — and the teacher answers about whichever line the context window is
    /// centred on. Anchoring to the cursor would answer about a line you are not
    /// looking at.
    func pressReadingAsk(atMs: Int) {
        NexaLog.log("pressReadingAsk atMs=\(atMs)")
        scene = .reading
        heardSpeechThisTurn = false
        committedThisTurn = false
        holdingQuickAsk = true
        // Freeze at the paragraph, so a follow-up in the same conversation keeps
        // answering about the same place even after several turns.
        freeze(atMs, reason: .speechStarted)
        onContextRefresh(atMs)
        applyFloorEvent(.userTookFloor)
    }

    /// Release a reading hold. Identical to `releaseQuickAsk` — the difference between
    /// the two scenes is not how a turn ends but what happens after the answer, which
    /// `scene.resumesPlaybackAfterAnswer` decides in `.responseDone`.
    func releaseReadingAsk() { releaseQuickAsk() }

    /// Abandon a reading hold. Unlike quick-ask's cancel, this does NOT resume the
    /// podcast: reading was not playing it in the first place, and starting playback
    /// because a question was abandoned would be a surprise.
    func cancelReadingAsk() {
        holdingQuickAsk = false
        heardSpeechThisTurn = false
        committedThisTurn = false
        transport.cancelTurn()
        applyFloorEvent(.nothingSaid)
    }

    // MARK: - Live (tap)

    // Enter: hand turns to the model's VAD (continuous), pause the podcast, and
    // sit idle waiting for the learner to speak or ask for playback. Live is the
    // always-on-mic scene, so open the mic explicitly — it's disabled by default
    // (self-study keeps it closed so the podcast can't self-trigger the VAD).
    func enterLive() {
        scene = .live
        transport.setTurnMode(.continuous)
        freeze(cursor(), reason: .paused)
        // The scene is already .live, so grantFloor opens the mic for us — Live keeps
        // it open in every floor state. Entering Live holds playback: nobody has
        // the floor until the learner speaks.
        applyFloorEvent(.playbackHeld)
    }

    // Exit: back to self-study — resume the podcast from where it was held and
    // return the transport to push-to-talk (the default outside Live).
    func exitLive() {
        let resumeAt = frozenPositionMs
        scene = .selfStudy
        transport.setTurnMode(.pushToTalk)
        applyFloorEvent(.playbackRequested, resumeAtMs: resumeAt)
    }
}
