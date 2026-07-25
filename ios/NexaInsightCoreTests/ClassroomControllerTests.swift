import XCTest
@testable import NexaInsightCore

final class FakePlayback: Playback {
    var currentMs: Int = 0
    var isReady: Bool = true
    var playbackState: PlaybackState = .paused
    private(set) var seeks: [Int] = []
    private(set) var didPlay = false
    private(set) var didPause = false
    private(set) var rates: [Double] = []
    func seek(_ ms: Int) { seeks.append(ms); currentMs = ms }
    func pause() { didPause = true; playbackState = .paused }
    func play() { didPlay = true; playbackState = .playing }
    func speed(_ rate: Double) { rates.append(rate) }
}

final class FakeTransport: ClassroomTransport {
    private(set) var stoppedSpeaking = 0
    private(set) var toolResults: [(String?, Bool)] = []
    private(set) var contextUpdates: [String] = []
    private(set) var injectedTexts: [String] = []
    private(set) var spoken: [String] = []
    private(set) var responseRequests = 0
    private(set) var turnModes: [TurnMode] = []
    private(set) var beganListening = 0
    private(set) var endedTurns = 0
    func stopSpeaking() { stoppedSpeaking += 1 }
    func sendToolResult(callId: String?, ok: Bool) { toolResults.append((callId, ok)) }
    func updateContext(_ context: String) { contextUpdates.append(context) }
    func injectUserText(_ text: String) { injectedTexts.append(text) }
    func speak(_ text: String) { spoken.append(text) }
    func requestResponse() { responseRequests += 1 }
    func setTurnMode(_ mode: TurnMode) { turnModes.append(mode) }
    func beginListening() { beganListening += 1 }
    func endTurnAndRespond() { endedTurns += 1 }
}

private func s(_ id: Int, _ start: Int) -> SentenceDTO {
    SentenceDTO(id: id, episodeId: 1, chapterId: nil, position: id, startMs: start, endMs: start + 900, speaker: nil, sourceText: "e\(id)", chinese: "c\(id)")
}

@MainActor
final class ClassroomControllerTests: XCTestCase {
    final class Box { var notices: [String] = []; var refreshes: [Int] = [] }

    func make() -> (ClassroomController, FakePlayback, FakeTransport, Box) {
        let playback = FakePlayback()
        let transport = FakeTransport()
        let box = Box()
        let controller = ClassroomController(
            sentences: [s(0, 0), s(1, 1000), s(2, 2000), s(3, 3000)],
            playback: playback, transport: transport,
            onNotice: { box.notices.append($0) },
            onContextRefresh: { box.refreshes.append($0) })
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

    func testResumeToolPlaysAndClearsFrozen() {
        let (c, playback, transport, box) = make()
        c.freeze(2000, reason: .paused)
        c.runPlaybackTool(.resume_playback, [:])
        XCTAssertNil(c.frozenPositionMs)
        XCTAssertTrue(playback.didPlay)
        XCTAssertGreaterThan(transport.stoppedSpeaking, 0)
        XCTAssertEqual(box.notices.last, "Podcast playing")
    }

    func testSeekToolSeeksResumesAndRefreshesContext() {
        let (c, playback, _, box) = make()
        c.runPlaybackTool(.seek_to_timestamp, ["seconds": 3])
        XCTAssertEqual(playback.seeks.last, 3000)
        XCTAssertTrue(playback.didPlay)
        XCTAssertEqual(box.refreshes.last, 3000)
    }

    func testNextSentenceUsesActiveIndex() {
        let (c, playback, _, _) = make()
        playback.currentMs = 1050
        c.runPlaybackTool(.next_sentence, [:])
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
        c.handleRealtimeEvent(.toolCall(name: .pause_playback, args: [:], callId: "abc"))
        XCTAssertTrue(playback.didPause)
        XCTAssertEqual(transport.toolResults.last?.0, "abc")
        XCTAssertEqual(transport.toolResults.last?.1, true)
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

    func testTypedChineseFillerIsNoOp() {
        // Fidelity: nexa_insight's isActionableTranscript deliberately rejects
        // short spoken fillers like "继续"/"暂停" as text — playback control for
        // those comes from the realtime model hearing the audio, not the text path.
        let (c, playback, transport, _) = make()
        c.sendText("继续")
        XCTAssertFalse(playback.didPlay)
        XCTAssertEqual(c.transcript.count, 0)
        XCTAssertEqual(transport.responseRequests, 0)
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
}
