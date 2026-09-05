import XCTest
@testable import NexaInsightCore

final class FakePlayback: Playback {
    var currentMs: Int = 0
    var isReady: Bool = true
    var playbackState: PlaybackState = .paused
    private(set) var seeks: [Int] = []
    private(set) var didPlay = false
    private(set) var didPause = false
    // Counted, not just flagged: some assertions need "was NOT paused again after
    // this point", which a latching Bool can't express.
    private(set) var pauses = 0
    private(set) var rates: [Double] = []
    func seek(_ ms: Int) { seeks.append(ms); currentMs = ms }
    func pause() { didPause = true; pauses += 1; playbackState = .paused }
    func play() { didPlay = true; playbackState = .playing }
    func speed(_ rate: Double) { rates.append(rate) }
}

class FakeTransport: ClassroomTransport {
    var isAlive = true
    private(set) var stoppedSpeaking = 0
    private(set) var toolResults: [(String?, Bool, String?)] = []
    private(set) var contextUpdates: [String] = []
    private(set) var contextScenes: [ClassroomScene] = []
    private(set) var injectedTexts: [String] = []
    private(set) var spoken: [String] = []
    private(set) var responseRequests = 0
    private(set) var turnModes: [TurnMode] = []
    private(set) var beganListening = 0
    private(set) var stoppedListening = 0
    private(set) var endedTurns = 0
    private(set) var cancelledTurns = 0
    func stopSpeaking() { stoppedSpeaking += 1 }
    func sendToolResult(callId: String?, ok: Bool, text: String?) {
        toolResults.append((callId, ok, text))
    }
    func updateContext(_ context: String, scene: ClassroomScene) {
        contextUpdates.append(context)
        contextScenes.append(scene)
    }
    func injectUserText(_ text: String) { injectedTexts.append(text) }
    func speak(_ text: String) { spoken.append(text) }
    func requestResponse() { responseRequests += 1 }
    func setTurnMode(_ mode: TurnMode) { turnModes.append(mode) }
    func beginListening() { beganListening += 1 }
    func stopListening() { stoppedListening += 1 }
    func endTurnAndRespond() { endedTurns += 1 }
    func cancelTurn() { cancelledTurns += 1 }
}

private func s(_ id: Int, _ start: Int) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: start + 900, speaker: nil, sourceText: "e\(id)", chinese: "c\(id)")
}

@MainActor
final class ClassroomControllerTests: XCTestCase {
    final class Box {
        var notices: [String] = []
        var refreshes: [Int] = []
        var refreshScenes: [ClassroomScene] = []
        var saved: [(NoteRequest, SentenceDTO?)] = []
    }

    func make() -> (ClassroomController, FakePlayback, FakeTransport, Box) {
        let playback = FakePlayback()
        let transport = FakeTransport()
        let box = Box()
        let controller = ClassroomController(
            sentences: [s(0, 0), s(1, 1000), s(2, 2000), s(3, 3000)],
            playback: playback, transport: transport,
            onNotice: { box.notices.append($0) },
            onContextRefresh: { position, scene in
                box.refreshes.append(position)
                box.refreshScenes.append(scene)
            },
            onSaveNote: { request, sentence in box.saved.append((request, sentence)) })
        return (controller, playback, transport, box)
    }

    func testSpeechStartedFreezesAndRefreshes() {
        let (c, playback, _, box) = make()
        playback.currentMs = 2100
        c.handleRealtimeEvent(.speechStarted)
        XCTAssertEqual(c.frozenPositionMs, 2100)
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(box.refreshes, [2100])
    }

    // MARK: - Floor handoff (redesign)

    func testPressQuickAskGrantsUserFloorAndPausesPlayback() {
        let (c, playback, transport, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        XCTAssertEqual(c.floor, .user)
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(transport.beganListening, 1)
    }

    func testSilentHoldTimerCannotCancelLiveAfterModeSwitch() async throws {
        let (c, _, transport, _) = make()
        c.pressQuickAsk()
        c.releaseQuickAsk()
        c.enterLive()
        let cancelled = transport.cancelledTurns
        try await Task.sleep(for: .milliseconds(1650))
        XCTAssertEqual(transport.cancelledTurns, cancelled)
        c.handleRealtimeEvent(.speechStarted)
        c.handleRealtimeEvent(.responseCreated)
        XCTAssertEqual(c.floor, .teacher)
        XCTAssertEqual(c.scene, .live)
    }

    func testEndedControllerIgnoresLateNetworkEvents() {
        let (c, playback, _, _) = make()
        c.enterLive()
        c.end()
        c.handleRealtimeEvent(.speechStarted)
        c.handleRealtimeEvent(.responseCreated)
        c.handleRealtimeEvent(.toolCall(name: .resume_playback, args: ToolArguments(), callId: "late"))
        XCTAssertEqual(c.floor, .idle)
        XCTAssertFalse(playback.didPlay)
    }


    func testReleaseQuickAskGrantsTeacherFloorAndRequests() {
        let (c, _, transport, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)   // something was actually said
        c.releaseQuickAsk()
        // The mic stays open until the server takes the turn — it ends turns by
        // hearing trailing silence, which arrives after the finger lifts.
        XCTAssertEqual(c.floor, .user)
        c.handleRealtimeEvent(.inputAudioCommitted)
        XCTAssertEqual(c.floor, .teacher)
        XCTAssertEqual(transport.endedTurns, 1)
    }

    // The mic must not close on release, or the server never hears the trailing
    // silence that ends the turn and no response is ever generated.
    func testMicStaysOpenUntilServerCommitsTheTurn() {
        let (c, _, transport, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        let closedBefore = transport.stoppedListening
        c.releaseQuickAsk()
        XCTAssertEqual(transport.stoppedListening, closedBefore)  // still listening
        c.handleRealtimeEvent(.inputAudioCommitted)
        XCTAssertGreaterThan(transport.stoppedListening, closedBefore)  // now closed
    }

    // The server can commit mid-hold (a pause while thinking). That must not cut
    // the learner off — the finger is still down, so keep listening.
    func testCommitWhileStillHoldingKeepsTheFloorAndMic() {
        let (c, _, transport, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        let closedBefore = transport.stoppedListening
        c.handleRealtimeEvent(.inputAudioCommitted)   // finger still down
        XCTAssertEqual(c.floor, .user)
        XCTAssertEqual(transport.stoppedListening, closedBefore)
        // Releasing after that commit hands off immediately: no second commit is
        // coming, so waiting for one would strand the floor with the mic open.
        c.releaseQuickAsk()
        XCTAssertEqual(c.floor, .teacher)
    }

    // The teacher starting to answer must close the mic in quick-ask, so we stop
    // accepting new speech mid-answer and the podcast/teacher audio can't bleed
    // in and self-trigger a phantom turn. Regression guard for the bug where the
    // podcast resumed with a live mic and VAD fired on its own.
    func testResponseCreatedClosesMicInQuickAsk() {
        let (c, _, transport, _) = make()
        c.pressQuickAsk()
        c.releaseQuickAsk()
        let before = transport.stoppedListening
        c.handleRealtimeEvent(.responseCreated)
        XCTAssertEqual(transport.stoppedListening, before + 1)
    }

    // Live keeps the mic open on the teacher's answer — voice barge-in is the point.
    func testResponseCreatedKeepsMicOpenInLive() {
        let (c, _, transport, _) = make()
        c.enterLive()
        let before = transport.stoppedListening
        c.handleRealtimeEvent(.responseCreated)
        XCTAssertEqual(transport.stoppedListening, before)
    }

    // The core fix: when the teacher finishes, the floor hands off on its own.
    // Quick-ask resumes the podcast from where it was frozen; nothing used to do
    // this, so the floor stayed on .teacher and playback never came back.
    // The podcast no longer resumes when an answer ends. `response.done` means the SERVER finished
    // GENERATING — the audio is still draining out of the WebRTC track — so resuming there started
    // the podcast over the last seconds of every reply. WebRTC offers no playout-complete callback,
    // so there is nothing exact to wait for instead, and pressing play is one tap.
    func testResponseDoneLeavesThePodcastPausedSoTheAnswerCanFinish() {
        let (c, playback, _, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)   // something was actually said
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)   // server takes the turn
        XCTAssertEqual(c.floor, .teacher)
        c.handleRealtimeEvent(.responseDone)
        XCTAssertEqual(c.floor, .idle, "nobody speaks over the tail of the answer")
        XCTAssertFalse(playback.didPlay, "the learner presses play when they are ready")
        // The position is still held, so pressing play lands where they left off.
        XCTAssertEqual(c.frozenPositionMs, 2100)
    }

    // Tap-to-interrupt: cut the teacher off and return to normal without starting
    // a new turn. Quick-ask resumes the podcast.
    // Pressing to talk IS the interrupt: it cuts the teacher off and starts
    // listening, in one gesture. There is no separate interrupt action.
    func testPressWhileTeacherAnsweringInterruptsAndListens() {
        let (c, playback, transport, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)   // server takes the turn
        XCTAssertEqual(c.floor, .teacher)
        let before = transport.stoppedSpeaking
        c.pressQuickAsk()                                  // press mid-answer
        XCTAssertGreaterThan(transport.stoppedSpeaking, before)  // teacher silenced
        XCTAssertEqual(c.floor, .user)                     // learner now holds the floor
        XCTAssertEqual(transport.beganListening, 2)        // mic reopened for the new turn
    }

    // Pressing mid-answer must resume from where the podcast was interrupted, not
    // from the stopped player's position.
    func testPressMidAnswerKeepsFrozenPosition() {
        let (c, playback, _, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        playback.currentMs = 0            // player is paused; a live read would be wrong
        c.pressQuickAsk()
        XCTAssertEqual(c.frozenPositionMs, 2100)
    }

    // A press with nothing said gets no response, so handing the floor to the
    // teacher would strand it there. Hold position instead — but only after giving the
    // server a chance to disagree, because speech_started can arrive after the finger lifts.
    func testReleaseWithoutSpeechHoldsInsteadOfWaitingForTeacher() async throws {
        let (c, playback, transport, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.releaseQuickAsk()               // released without any speechStarted
        // Not cancelled yet: the audio is still in the server's buffer, and throwing it away
        // here is what left the UI on "Live 等你开口" with the turn already gone.
        XCTAssertEqual(transport.cancelledTurns, 0, "verdict is deferred, not immediate")
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(c.floor, .idle)
        XCTAssertEqual(transport.endedTurns, 0)   // no turn committed
        XCTAssertEqual(transport.cancelledTurns, 1)
        XCTAssertEqual(c.frozenPositionMs, 2100)  // stays put
        XCTAssertFalse(playback.didPlay)          // does not resume on its own
    }

    // The case that broke it: the server's speech_started lands AFTER the finger lifts, which
    // the code's own comment says happens for speech_stopped and committed. Cancelling on
    // release threw the audio away, so the commit never came and .inputAudioCommitted — which
    // exists to reconcile exactly this — could never fire.
    func testALateCommitStillReachesTheTeacher() async throws {
        let (c, playback, transport, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.releaseQuickAsk()                       // no speechStarted yet
        c.handleRealtimeEvent(.speechStarted)     // ...arrives late
        c.handleRealtimeEvent(.inputAudioCommitted)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(transport.cancelledTurns, 0, "a real turn must not be cancelled")
        XCTAssertEqual(c.floor, .teacher, "the answer is coming, so the floor is the teacher's")
    }

    // The transport controls used to call playback.play() directly, so starting
    // playback while the teacher was answering left BOTH talking — the floor never
    // moved, so nothing silenced the teacher.
    func testUserStartedPlaybackSilencesTheTeacher() {
        let (c, playback, transport, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        XCTAssertEqual(c.floor, .teacher)
        let before = transport.stoppedSpeaking
        c.userStartedPlayback()
        XCTAssertGreaterThan(transport.stoppedSpeaking, before)
        XCTAssertEqual(c.floor, .player)
        XCTAssertTrue(playback.didPlay)
    }

    // Tapping a subtitle line seeks there and plays, still via the floor.
    func testUserStartedPlaybackSeeksWhenGivenAPosition() {
        let (c, playback, _, _) = make()
        c.userStartedPlayback(seekTo: 5000)
        XCTAssertEqual(playback.seeks.last, 5000)
        XCTAssertEqual(c.floor, .player)
    }

    // Pausing gives the floor to nobody: podcast stops, teacher stays quiet, and
    // the position is frozen so the discussion stays anchored where they stopped.
    func testUserPausedPlaybackHoldsTheFloorIdleAndFreezes() {
        let (c, playback, transport, _) = make()
        playback.currentMs = 3300
        let before = transport.stoppedSpeaking
        c.userPausedPlayback()
        XCTAssertEqual(c.floor, .idle)
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(c.frozenPositionMs, 3300)
        XCTAssertGreaterThan(transport.stoppedSpeaking, before)
    }

    // A voice "pause" must silence the teacher too. This used to set `floor`
    // directly, skipping the rule in silenced(by: .idle); it only looked correct
    // because runPlaybackTool calls stopSpeaking() up top.
    func testPausePlaybackToolSilencesTeacherAndGoesIdle() {
        let (c, playback, _, _) = make()
        playback.currentMs = 4200
        c.runPlaybackTool(.pause_playback, ToolArguments())
        XCTAssertEqual(c.floor, .idle)
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(c.frozenPositionMs, 4200)
    }

    // A Live answer must close out: the floor goes to the teacher while they talk
    // and back to .idle when done. Live used to skip the .turnCommitted step, which
    // left the floor on .user for the whole answer and made .responseDone's
    // `guard floor == .teacher` always break — so playback state after an answer was
    // undefined, and the podcast could stay paused when the learner asked to resume.
    func testLiveAnswerTakesAndReleasesTheFloor() {
        let (c, _, _, _) = make()
        c.enterLive()
        c.handleRealtimeEvent(.speechStarted)
        XCTAssertEqual(c.floor, .user)
        c.handleRealtimeEvent(.responseCreated)
        XCTAssertEqual(c.floor, .teacher)
        c.handleRealtimeEvent(.responseDone)
        XCTAssertEqual(c.floor, .idle)   // Live waits for the learner, not the podcast
    }

    // Live keeps the mic open in EVERY floor state — barge-in is the whole point.
    // Regression guard: gating the mic on `holder == .user` alone silenced Live
    // while the teacher talked, which made interjecting impossible.
    func testLiveKeepsMicOpenWhileTeacherTalks() {
        let (c, _, transport, _) = make()
        c.enterLive()
        let closedBefore = transport.stoppedListening
        c.handleRealtimeEvent(.speechStarted)
        c.handleRealtimeEvent(.responseCreated)   // teacher now holds the floor
        XCTAssertEqual(transport.stoppedListening, closedBefore)
    }

    // "Resume playback" during a Live answer must actually play. The tool call takes
    // the floor for the podcast; the answer finishing must not then pause it again.
    func testResumeToolDuringLiveAnswerKeepsPlaying() {
        let (c, playback, _, _) = make()
        c.enterLive()
        c.handleRealtimeEvent(.speechStarted)
        c.handleRealtimeEvent(.responseCreated)
        c.runPlaybackTool(.resume_playback, ToolArguments())
        XCTAssertEqual(c.floor, .player)
        XCTAssertTrue(playback.didPlay)
        let pausesBefore = playback.pauses
        c.handleRealtimeEvent(.responseDone)      // answer ends after the tool ran
        XCTAssertEqual(c.floor, .player)          // still the podcast's floor
        XCTAssertEqual(playback.pauses, pausesBefore)  // and it was not re-paused
    }

    // In Live the VAD hearing speech is what takes the floor — nothing else does,
    // so without this the UI would still say "just start speaking".
    func testLiveSpeechTakesTheFloor() {
        let (c, _, _, _) = make()
        c.enterLive()
        XCTAssertEqual(c.floor, .idle)
        c.handleRealtimeEvent(.speechStarted)
        XCTAssertEqual(c.floor, .user)
    }

    func testCancelQuickAskDropsTurnAndResumesPodcast() {
        let (c, playback, transport, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.cancelQuickAsk()
        // Floor returns to the podcast, resuming from where it was frozen — no
        // teacher turn, no commit/response.
        XCTAssertEqual(c.floor, .player)
        XCTAssertEqual(transport.cancelledTurns, 1)
        XCTAssertEqual(transport.endedTurns, 0)
        XCTAssertTrue(playback.didPlay)
        XCTAssertEqual(playback.seeks.last, 2100)
    }

    func testEnterLivePausesAndGoesIdleContinuous() {
        let (c, playback, transport, _) = make()
        c.enterLive()
        XCTAssertEqual(c.floor, .idle)
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(transport.turnModes.last, .continuous)
        // Live is always-on-mic: the mic starts disabled (self-study default), so
        // entering Live must open it explicitly, or the model never hears anything.
        XCTAssertEqual(transport.beganListening, 1)
    }

    func testLivePlaybackRequestGrantsPlayerFloorAndStopsTeacher() {
        let (c, playback, transport, _) = make()
        c.enterLive()
        c.runPlaybackTool(.resume_playback, ToolArguments())
        XCTAssertEqual(c.floor, .player)
        XCTAssertTrue(playback.didPlay)
        XCTAssertGreaterThan(transport.stoppedSpeaking, 0)
    }

    func testExitLiveResumesAndReturnsToPushToTalk() {
        let (c, playback, transport, _) = make()
        c.enterLive()
        c.exitLive()
        XCTAssertEqual(c.floor, .player)
        XCTAssertTrue(playback.didPlay)
        XCTAssertEqual(transport.turnModes.last, .pushToTalk)
    }

    func testResumeToolPlaysAndClearsFrozen() {
        let (c, playback, transport, box) = make()
        c.freeze(2000, reason: .paused)
        c.runPlaybackTool(.resume_playback, ToolArguments())
        XCTAssertNil(c.frozenPositionMs)
        XCTAssertTrue(playback.didPlay)
        XCTAssertGreaterThan(transport.stoppedSpeaking, 0)
        XCTAssertEqual(box.notices.last, "Podcast playing")
    }

    func testSeekToolSeeksResumesAndRefreshesContext() {
        let (c, playback, transport, box) = make()
        c.runPlaybackTool(.seek_to_timestamp, ToolArguments(numbers: ["seconds": 3]))
        XCTAssertEqual(playback.seeks.last, 3000)
        XCTAssertTrue(playback.didPlay)
        XCTAssertEqual(box.refreshes.last, 3000)
        // The mic must be gated off when the podcast resumes, or its audio bleeds
        // into the live mic and the server VAD self-triggers a phantom turn
        // (stops the podcast, teacher talks over nothing). Regression guard.
        XCTAssertGreaterThan(transport.stoppedListening, 0)
    }

    func testNextSentenceUsesActiveIndex() {
        let (c, playback, _, _) = make()
        playback.currentMs = 1050
        c.runPlaybackTool(.next_sentence, ToolArguments())
        XCTAssertEqual(playback.seeks.last, 2000)
    }

    // Bringing the teacher in must NOT interrupt the source: a fresh controller
    // starts in podcastPlaying with a live cursor, and touches playback not at
    // all. Only the learner speaking freezes it (see testSpeechStartedFreezes...).
    // Regression guard — an earlier version froze the podcast at connect time.
    func testFreshControllerLeavesPlaybackAlone() {
        let (c, playback, _, _) = make()
        XCTAssertEqual(c.state.phase, .podcastPlaying)
        XCTAssertNil(c.frozenPositionMs)
        XCTAssertFalse(playback.didPause, "joining must not pause the source")
        XCTAssertFalse(playback.didPlay)
        XCTAssertTrue(playback.seeks.isEmpty, "joining must not move playback")
    }

    func testToolCallEventRunsToolAndAcks() {
        let (c, playback, transport, _) = make()
        c.handleRealtimeEvent(.toolCall(name: .pause_playback, args: ToolArguments(), callId: "abc"))
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(transport.toolResults.last?.0, "abc")
        XCTAssertEqual(transport.toolResults.last?.1, true)
    }

    // Same call_id arriving twice (dedicated event + echoed in response.done)
    // must run the tool once. Guards against a seek/pause firing twice.
    func testDuplicateToolCallIdRunsOnce() {
        let (c, playback, _, _) = make()
        c.handleRealtimeEvent(.toolCall(name: .seek_to_timestamp, args: ToolArguments(numbers: ["seconds": 3]), callId: "dup"))
        c.handleRealtimeEvent(.toolCall(name: .seek_to_timestamp, args: ToolArguments(numbers: ["seconds": 3]), callId: "dup"))
        XCTAssertEqual(playback.seeks.filter { $0 == 3000 }.count, 1)
    }

    func testTextDirectCommandRunsToolNoDiscussion() {
        // "resume" is whitelisted by isActionableTranscript AND matches a direct
        // command, so it runs the tool with no spoken monologue.
        let (c, playback, transport, _) = make()
        c.sendText("resume")
        XCTAssertTrue(playback.didPlay)
        XCTAssertEqual(transport.spoken.count, 0)
        XCTAssertEqual(transport.responseRequests, 0)  // no discussion round-trip
    }

    func testTypedChinesePlaybackCommandRunsTool() {
        // Playback commands must bypass the short-transcript filler filter.
        let (c, playback, transport, _) = make()
        c.sendText("继续")
        XCTAssertTrue(playback.didPlay)
        XCTAssertEqual(c.transcript.count, 1)
        XCTAssertEqual(transport.responseRequests, 0)
    }

    func testSpokenResumeSurvivesLateResponseAndRelease() {
        let (c, playback, transport, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.handleRealtimeEvent(.inputTranscriptionCompleted("继续吧。"))
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        c.handleRealtimeEvent(.responseCreated)
        c.handleRealtimeEvent(.responseDone)
        XCTAssertEqual(playback.playbackState, .playing)
        XCTAssertEqual(playback.currentMs, 2100)
        XCTAssertEqual(c.floor, .player)
        XCTAssertEqual(transport.endedTurns, 0)
        XCTAssertGreaterThan(transport.stoppedListening, 0)
    }

    func testSpokenNextSentenceDoesNotRunAgainAsModelTool() {
        let (c, playback, _, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.inputTranscriptionCompleted("下一句"))
        c.handleRealtimeEvent(.toolCall(name: .next_sentence, args: ToolArguments(), callId: "next"))
        XCTAssertEqual(playback.seeks, [1000])
    }

    func testModelNextSentenceBeforeTranscriptionMovesOnlyOnce() {
        let (c, playback, _, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.responseCreated)
        c.handleRealtimeEvent(.toolCall(name: .next_sentence, args: ToolArguments(), callId: "next"))
        c.handleRealtimeEvent(.inputTranscriptionCompleted("下一句"))
        XCTAssertEqual(playback.seeks, [1000])
        XCTAssertEqual(playback.playbackState, .playing)
    }

    func testQuestionAfterSpokenCommandCanReceiveAnswer() {
        let (c, playback, _, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.inputTranscriptionCompleted("继续"))
        c.releaseQuickAsk()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.inputTranscriptionCompleted("继续解释这个观点"))
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.responseCreated)
        c.handleRealtimeEvent(.responseAudioTranscriptDone("Here is the explanation."))
        XCTAssertEqual(c.floor, .teacher)
        XCTAssertEqual(playback.playbackState, .paused)
        XCTAssertEqual(c.transcript.last?.role, .assistant)
    }

    func testSpokenPauseInLiveRemainsPausedAfterLateResponse() {
        let (c, playback, _, _) = make()
        c.enterLive()
        c.handleRealtimeEvent(.speechStarted)
        c.handleRealtimeEvent(.inputTranscriptionCompleted("暂停"))
        c.handleRealtimeEvent(.responseCreated)
        XCTAssertEqual(c.floor, .idle)
        XCTAssertEqual(playback.playbackState, .paused)
    }

    func testTextDiscussionInjectsAndRequestsResponse() {
        let (c, _, transport, _) = make()
        c.sendText("what do you think about the host's argument here")
        XCTAssertEqual(transport.responseRequests, 1)
        XCTAssertEqual(transport.injectedTexts.count, 1)
    }

    func testEmptyOrFillerTextIgnored() {
        let (c, _, transport, _) = make()
        c.sendText("嗯")
        XCTAssertEqual(transport.responseRequests, 0)
        XCTAssertEqual(c.transcript.count, 0)
    }

    func testInputTranscriptAndAssistantTranscriptAppendTurns() {
        let (c, _, _, _) = make()
        c.handleRealtimeEvent(.inputTranscriptionCompleted("hello teacher"))
        c.handleRealtimeEvent(.responseAudioTranscriptDone("hello learner"))
        XCTAssertEqual(c.transcript.map(\.role), [.user, .assistant])
    }

    // MARK: - Reading

    // The whole reason the scene enum exists. Reading must leave the podcast where it
    // was: the answer ending is an invitation to follow up, and starting playback over
    // the reply is the opposite of that. Under `inLive: Bool` there was no way to say
    // this without also claiming Live's always-open mic.
    func testReadingDoesNotResumePlaybackAfterAnswer() {
        let (c, playback, _, _) = make()
        c.pressReadingAsk(atMs: 2000)
        c.handleRealtimeEvent(.speechStarted)
        c.releaseReadingAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        XCTAssertEqual(c.floor, .teacher)
        c.handleRealtimeEvent(.responseDone)
        XCTAssertFalse(playback.didPlay, "reading must not start playing on its own")
        XCTAssertNotEqual(c.floor, .player)
    }

    // Self-study is the only scene that resumes, and this is the counterpart to the
    // test above: the same event sequence, the other scene, the opposite outcome.
    // Renamed with the behaviour: self-study used to be the one scene that resumed, and now no
    // scene does. Kept as a test that the floor still settles rather than sticking on .teacher —
    // that was a real bug once, where the podcast never came back at all.
    func testSelfStudyLeavesTheFloorIdleRatherThanStuckOnTheTeacher() {
        let (c, playback, _, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        c.handleRealtimeEvent(.responseDone)
        XCTAssertFalse(playback.didPlay, "no scene resumes automatically any more")
        XCTAssertEqual(c.floor, .idle, "but the floor must not stay on .teacher")
    }

    // The reading instructions are only worth anything if the scene reaches the
    // transport, which is where they get composed. A refresh that reported .selfStudy
    // would leave the teacher Socratic in reading and the prompt tests would still pass.
    func testContextRefreshReportsTheReadingScene() {
        let (c, _, _, box) = make()
        c.pressReadingAsk(atMs: 3000)
        XCTAssertEqual(box.refreshScenes.last, .reading)
    }

    func testContextRefreshReportsSelfStudyForAQuickAsk() {
        let (c, _, _, box) = make()
        c.pressQuickAsk()
        XCTAssertEqual(box.refreshScenes.last, .selfStudy)
    }

    // The question is about the paragraph under the finger, not wherever playback got
    // to. In reading those routinely differ — you read ahead, or nothing is playing.
    func testReadingAnchorsContextToTheParagraphNotTheCursor() {
        let (c, playback, _, box) = make()
        playback.currentMs = 500          // audio sits early
        c.pressReadingAsk(atMs: 3000)     // finger is on a much later line
        XCTAssertEqual(box.refreshes.last, 3000)
        XCTAssertEqual(c.frozenPositionMs, 3000)
    }

    // A follow-up keeps answering about the same paragraph: the anchor survives the
    // first answer, so the second turn does not drift to wherever the cursor is.
    func testFollowUpKeepsTheSameAnchor() {
        let (c, playback, _, box) = make()
        playback.currentMs = 500
        c.pressReadingAsk(atMs: 3000)
        c.handleRealtimeEvent(.speechStarted)
        c.releaseReadingAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        c.handleRealtimeEvent(.responseDone)
        c.pressReadingAsk(atMs: 3000)     // follow up on the same paragraph
        XCTAssertEqual(box.refreshes.last, 3000)
        XCTAssertEqual(c.frozenPositionMs, 3000)
    }

    // Abandoning a reading question must not start playback. Quick-ask's cancel
    // resumes, because there the podcast was playing and the press interrupted it;
    // reading was not playing, so resuming would be a surprise.
    func testCancelReadingAskDoesNotResumePlayback() {
        let (c, playback, transport, _) = make()
        c.pressReadingAsk(atMs: 2000)
        c.handleRealtimeEvent(.speechStarted)
        let cancels = transport.cancelledTurns
        c.cancelReadingAsk()
        XCTAssertGreaterThan(transport.cancelledTurns, cancels, "the turn must be dropped")
        XCTAssertFalse(playback.didPlay, "an abandoned question must not start playback")
    }

    // Reading closes the mic once the server has the turn, exactly as quick-ask does.
    // Only Live holds it open; if reading inherited that, the teacher's own voice
    // would trip the VAD and chain another answer (the speaker-mode failure).
    func testReadingClosesMicAfterCommit() {
        let (c, _, transport, _) = make()
        c.pressReadingAsk(atMs: 2000)
        c.handleRealtimeEvent(.speechStarted)
        c.releaseReadingAsk()
        let stops = transport.stoppedListening
        c.handleRealtimeEvent(.inputAudioCommitted)
        XCTAssertGreaterThan(transport.stoppedListening, stops, "reading must close the mic")
    }

    // MARK: - Saving notes

    private func saveNote(_ c: ClassroomController, callId: String? = "n1") {
        c.handleRealtimeEvent(.toolCall(
            name: .save_note,
            args: ToolArguments(texts: ["text": "e2", "meaning": "释义"]),
            callId: callId))
    }

    // Nothing about the podcast changes because a note was written. Every other tool
    // moves, pauses or resumes something; this one must not.
    func testSavingANoteLeavesPlaybackAlone() {
        let (c, playback, transport, box) = make()
        playback.currentMs = 2100
        playback.play()
        let floorBefore = c.floor
        let pausesBefore = playback.pauses
        let stoppedBefore = transport.stoppedSpeaking

        saveNote(c)

        XCTAssertEqual(box.saved.count, 1)
        XCTAssertEqual(c.floor, floorBefore, "saving must not move the floor")
        XCTAssertEqual(playback.pauses, pausesBefore, "saving must not pause the podcast")
        XCTAssertTrue(playback.seeks.isEmpty, "saving must not seek")
        // The teacher is normally mid-explanation when asked to keep something, so
        // cutting them off to file a card would make the save feel like an interruption.
        XCTAssertEqual(transport.stoppedSpeaking, stoppedBefore, "saving must not silence the teacher")
    }

    // The note lands on the line being played, decided here rather than reported by the
    // model — asking it for a sentence id invites it to invent one.
    func testTheNoteIsAnchoredToTheLineBeingPlayed() {
        let (c, playback, _, box) = make()
        playback.currentMs = 2100          // inside sentence id 2
        saveNote(c)
        XCTAssertEqual(box.saved.first?.1?.id, 2)
    }

    // Same dedupe as the playback tools, and it matters more here: a repeated seek is
    // harmless, a repeated save is a duplicate card.
    func testTheSameSaveRunsOnce() {
        let (c, _, _, box) = make()
        saveNote(c, callId: "dup")
        saveNote(c, callId: "dup")
        XCTAssertEqual(box.saved.count, 1)
    }

    // An incomplete call must say so. In an explicit mode, silence after "记一下" is
    // indistinguishable from not having been heard.
    func testAnIncompleteSaveIsReportedRatherThanSwallowed() {
        let (c, _, _, box) = make()
        c.handleRealtimeEvent(.toolCall(
            name: .save_note, args: ToolArguments(texts: ["text": "e2"]), callId: "bad"))
        XCTAssertTrue(box.saved.isEmpty, "nothing usable, so nothing saved")
        XCTAssertFalse(box.notices.isEmpty, "but the learner has to be told")
    }

    // The confirmation names the word, so a mis-heard save is visible as one.
    func testTheConfirmationNamesTheSavedWord() {
        let (c, _, _, box) = make()
        saveNote(c)
        XCTAssertEqual(box.notices.last?.contains("e2"), true)
    }

    func testSavingAnAnswerAlsoReachesTheStore() {
        let (c, _, _, box) = make()
        c.handleRealtimeEvent(.toolCall(
            name: .save_answer,
            args: ToolArguments(texts: ["question": "为什么", "answer": "因为"]),
            callId: "a1"))
        guard case .answer = box.saved.first?.0.kind else {
            return XCTFail("expected an answer card, got \(box.saved)")
        }
    }

    // Asking for something to be kept is an invitation to add more — a correction, a
    // second word, "also the phrase before it". Self-study normally resumes the podcast
    // the moment the teacher stops, which here meant playback started over the learner
    // immediately after the save was confirmed.
    func testAskingForANoteHoldsThePodcastAfterTheAnswer() {
        let (c, playback, _, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        saveNote(c)                                  // "记一下这个词"
        c.handleRealtimeEvent(.responseDone)

        XCTAssertFalse(playback.didPlay, "the podcast must wait for what you say next")
        XCTAssertNotEqual(c.floor, .player)
    }

    // The counterpart: an ordinary answer with no note still resumes, which is what
    // listening should do. Without this pair, holding could be made unconditional and
    // both tests would still pass individually.
    // Was "an ordinary answer still resumes", from when saving a note was the only thing that held
    // playback. Nothing resumes now, so what this checks is that an ordinary answer is not treated
    // as a special case either.
    func testAnOrdinaryAnswerAlsoLeavesThePodcastPaused() {
        let (c, playback, _, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        c.handleRealtimeEvent(.responseDone)

        XCTAssertFalse(playback.didPlay)
        XCTAssertEqual(c.floor, .idle)
    }

    func testATeacherToolMidAnswerDoesNotCutTheAnswerOff() {
        // "老师的话还是被截断了" — and the truncation had nothing to do with resuming playback, which
        // is what I changed first. `runPlaybackTool` called `stopSpeaking()` unconditionally, which
        // mutes the remote audio track and cancels the in-flight response. Right for an interrupt;
        // fatal for a tool the TEACHER called while explaining, because it silences its own voice.
        //
        // save_note was already exempted with a comment saying the teacher "is normally mid-sentence
        // when asked to keep something". The exemption never covered the other tools.
        let (c, playback, transport, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        XCTAssertEqual(c.floor, .teacher, "the teacher is speaking")
        let stopsBefore = transport.stoppedSpeaking

        // A seek the teacher decided on while answering.
        c.handleRealtimeEvent(.toolCall(name: .seek_to_timestamp,
                                        args: ToolArguments(numbers: ["seconds": 30, "play": 0]),
                                        callId: "seek1"))

        XCTAssertEqual(transport.stoppedSpeaking, stopsBefore,
                       "the teacher keeps speaking through its own tool call")
        XCTAssertEqual(playback.seeks.last, 30_000, "but the position still moves")
        // And it must not grab the player floor either: silenced(by: .player) is stopTeacher: true,
        // so resuming would cut the answer by a different route.
        XCTAssertEqual(c.floor, .teacher)
        XCTAssertFalse(playback.didPlay, "the learner presses play, as after every answer")
    }

    func testTheLearnersOwnCommandStillCutsTheTeacherOff() {
        // The other half. Typed and spoken commands from the learner must take effect at once — a
        // "pause" while the teacher rambles is exactly a request to be interrupted.
        let (c, _, transport, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        let stopsBefore = transport.stoppedSpeaking

        c.runPlaybackTool(.pause_playback, ToolArguments())

        XCTAssertGreaterThan(transport.stoppedSpeaking, stopsBefore,
                             "the learner's own command silences the teacher")
    }

    func testContentSeekPlaysUnlessExplicitlyLocatingForExplanation() {
        let (c, playback, _, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.responseCreated)
        c.handleRealtimeEvent(.toolCall(name: .seek_to_timestamp,
            args: RealtimeEventParser.safeArgs(#"{"seconds": 30, "play": true}"#), callId: "content-seek"))
        c.handleRealtimeEvent(.responseDone)
        XCTAssertEqual(playback.currentMs, 30_000)
        XCTAssertEqual(playback.playbackState, .playing)
        XCTAssertEqual(c.floor, .player)
    }

    func testShortResumeVariantsPlayInBothScenes() {
        for live in [false, true] {
            for text in ["继续", "继续吧", "继续啊。", "继 续", "繼續", "继续……", "接着听"] {
                let (c, playback, _, _) = make()
                if live { c.enterLive() } else { c.pressQuickAsk() }
                c.handleRealtimeEvent(.speechStarted)
                c.handleRealtimeEvent(.inputTranscriptionCompleted(text))
                if !live { c.releaseQuickAsk() }
                c.handleRealtimeEvent(.responseCreated)
                XCTAssertEqual(playback.playbackState, .playing, text)
                XCTAssertEqual(c.floor, .player, text)
            }
        }
    }

    func testContinueExplanationDoesNotPlay() {
        for text in ["继续解释", "继续讲", "接着讲", "不要继续", "先别继续播放"] {
            XCTAssertNil(matchDirectCommand(text), text)
        }
    }

    func testResponseWithoutSpeechStartedCancelsSilentHoldTimeout() async throws {
        let (c, _, transport, _) = make()
        c.pressQuickAsk()
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.responseCreated)
        let cancelled = transport.cancelledTurns
        try await Task.sleep(for: .milliseconds(1650))
        XCTAssertEqual(transport.cancelledTurns, cancelled)
        XCTAssertEqual(c.floor, .teacher)
    }

    func testFindInEpisodeAnswersWithoutMovingThePlayer() {
        // A search ANSWERS; every other tool ACTS. Routing it through runPlaybackTool would put it
        // through the floor machinery for an operation with no position — and it would fall into the
        // seeking `default` branch, sending the learner to 0.
        let (c, playback, transport, _) = make()
        c.handleRealtimeEvent(.toolCall(name: .find_in_episode,
                                        args: ToolArguments(texts: ["query": "hello"]),
                                        callId: "find1"))

        XCTAssertTrue(playback.seeks.isEmpty, "a search moves nothing")
        XCTAssertFalse(playback.didPlay)
        // And the result has to come BACK, or the teacher has nothing to seek to.
        let last = try? XCTUnwrap(transport.toolResults.last)
        XCTAssertEqual(last?.0, "find1")
        XCTAssertNotNil(last?.2, "the hits are returned as text")
    }

    func testTheDockSaysThePodcastIsWaitingForYou() throws {
        // `.idle` now means two different things. In Live the teacher is waiting for you to speak;
        // in self-study it is where an answer leaves things, because the podcast no longer resumes
        // on `response.done`. Reporting "Live · 等你开口" there would be simply false, and would
        // leave the learner with a paused podcast and no idea it was theirs to restart.
        let source = try String(contentsOfFile: "NexaInsight/Views/StudyView.swift", encoding: .utf8)
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // 已暂停，按播放继续
        XCTAssertTrue(code.contains(#"\u{5df2}\u{6682}\u{505c}"#),
                      "self-study idle must say the podcast is paused")
        XCTAssertTrue(code.contains(#"case .idle: return live ?"#),
                      "and it must distinguish Live from self-study")
    }

    // The saved-note hold is per TURN, not sticky. Nothing resumes automatically now, so what this
    // pins is that `savedNoteThisTurn` is cleared — a flag left set would be invisible today and
    // wrong the moment anything reads it again.
    func testTheSavedNoteFlagIsClearedAfterTheTurn() {
        let (c, playback, _, _) = make()
        playback.currentMs = 2100
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        saveNote(c, callId: "n1")
        c.handleRealtimeEvent(.responseDone)
        XCTAssertFalse(playback.didPlay)

        // A second turn, this one just a question.
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        c.handleRealtimeEvent(.responseDone)
        XCTAssertFalse(playback.didPlay, "no answer resumes, saved note or not")
        XCTAssertEqual(c.floor, .idle, "and the floor settles either way")
    }

    // "Analyse this passage and keep what matters" is one request and several cards. Each
    // has its own call_id, so the dedupe must not collapse them into one.
    func testSeveralNotesInOneTurnAllReachTheStore() {
        let (c, _, _, box) = make()
        for (index, word) in ["e2", "e1", "e3"].enumerated() {
            c.handleRealtimeEvent(.toolCall(
                name: .save_note,
                args: ToolArguments(texts: ["text": word, "meaning": "释义"]),
                callId: "n\(index)"))
        }
        XCTAssertEqual(box.saved.count, 3)
    }

    // And the floor comes back afterwards. Losing the turn end left the UI saying the
    // teacher was still speaking while nothing happened — the second symptom of the same
    // dropped-event bug.
    func testTheFloorIsReleasedAfterSavingSeveralNotes() {
        let (c, _, _, _) = make()
        c.pressQuickAsk()
        c.handleRealtimeEvent(.speechStarted)
        c.releaseQuickAsk()
        c.handleRealtimeEvent(.inputAudioCommitted)
        XCTAssertEqual(c.floor, .teacher)

        saveNote(c, callId: "n1")
        saveNote(c, callId: "n2")
        c.handleRealtimeEvent(.responseDone)

        XCTAssertNotEqual(c.floor, .teacher, "the teacher must stop holding the floor")
    }

    // Saving works in every scene: that is the requirement — 精听, Live and 精读 alike.
    func testSavingWorksInEveryScene() {
        for enter in [{ (c: ClassroomController) in c.pressQuickAsk() },
                      { c in c.enterLive() },
                      { c in c.pressReadingAsk(atMs: 2000) }] {
            let (c, _, _, box) = make()
            enter(c)
            saveNote(c)
            XCTAssertEqual(box.saved.count, 1, "a note must be savable in scene \(c.scene)")
        }
    }
}
