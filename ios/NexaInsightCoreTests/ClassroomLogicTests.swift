import XCTest
@testable import NexaInsightCore

final class ClassroomLogicTests: XCTestCase {
    func testReducerSpeechFreezesCursorAndKeepsFirstPause() {
        var st = ClassroomState(phase: .podcastPlaying, pausedAtMs: nil)
        st = classroomReducer(st, .speechStarted(atMs: 5000))
        XCTAssertEqual(st.phase, .userSpeaking)
        XCTAssertEqual(st.pausedAtMs, 5000)
        st = classroomReducer(st, .speechStarted(atMs: 9000))
        XCTAssertEqual(st.pausedAtMs, 5000)
    }

    func testReducerResumeClearsPause() {
        let st = classroomReducer(ClassroomState(phase: .discussing, pausedAtMs: 5000), .resumed)
        XCTAssertEqual(st.phase, .resuming)
        XCTAssertNil(st.pausedAtMs)
    }

    func testCursorPrefersFrozenThenLiveThenInitial() {
        XCTAssertEqual(classroomCursorPosition(3000, 5000, 0), 5000)
        XCTAssertEqual(classroomCursorPosition(3000, nil, 0), 3000)
        XCTAssertEqual(classroomCursorPosition(0, nil, 1200), 1200)
    }

    func testDirectCommandResumeVariantsAndFillers() {
        XCTAssertEqual(matchDirectCommand("继续")?.name, .resume_playback)
        XCTAssertEqual(matchDirectCommand("我觉得有道理，我们继续吧")?.name, .resume_playback)
        XCTAssertEqual(matchDirectCommand("ok let's continue")?.name, .resume_playback)
        XCTAssertEqual(matchDirectCommand("pause")?.name, .pause_playback)
        XCTAssertEqual(matchDirectCommand("next sentence")?.name, .next_sentence)
    }

    func testDirectCommandBailsOnDiscussSignal() {
        XCTAssertNil(matchDirectCommand("回到播客里那个观点是什么意思"))
        XCTAssertNil(matchDirectCommand("explain that"))
    }

    func testActionableTranscriptRejectsFillers() {
        XCTAssertFalse(isActionableTranscript(""))
        XCTAssertFalse(isActionableTranscript("嗯"))
        XCTAssertTrue(isActionableTranscript("pause"))
        XCTAssertTrue(isActionableTranscript("what do you think about this argument"))
    }

    func testPlaybackTargetPosition() {
        let starts = [0, 1000, 2000, 3000]
        XCTAssertEqual(playbackTargetPosition(.seek_to_timestamp, ["seconds": 10], 0, 1, starts), 10_000)
        XCTAssertEqual(playbackTargetPosition(.seek_relative, ["seconds": -5], 8000, 1, starts), 3000)
        XCTAssertEqual(playbackTargetPosition(.previous_sentence, [:], 2500, 2, starts), 1000)
        XCTAssertEqual(playbackTargetPosition(.next_sentence, [:], 2500, 2, starts), 3000)
        XCTAssertEqual(playbackTargetPosition(.repeat_current_sentence, [:], 2500, 2, starts), 2000)
    }

    func testPlaybackNotice() {
        XCTAssertEqual(playbackNotice(.resume_playback, 0), "Podcast playing")
        XCTAssertEqual(playbackNotice(.pause_playback, 65_000), "Paused at 1:05")
        XCTAssertEqual(playbackNotice(.next_sentence, 0), "Next sentence · paused")
    }

    // WebRTC transport ONLY supports server-side VAD — manual turn control
    // (commit + response.create) is not honored over WebRTC. So both modes use
    // identical VAD config with create_response: true; the model's VAD always
    // drives the response. Push-to-talk is a mic gate on top of this, not a
    // different turn_detection. (Alibaba Model Studio realtime docs.)
    func testTurnDetectionConfigIsServerVADInBothModes() {
        for cfg in [turnDetectionConfig(.continuous), turnDetectionConfig(.pushToTalk)] {
            XCTAssertEqual(cfg["type"] as? String, "semantic_vad")
            XCTAssertEqual(cfg["threshold"] as? Double, 0.5)
            XCTAssertEqual(cfg["silence_duration_ms"] as? Int, 800)
            XCTAssertEqual(cfg["create_response"] as? Bool, true)
        }
    }

    func testFloorReducerTransitions() {
        XCTAssertEqual(floorReducer(.player, .userTookFloor), .user)
        XCTAssertEqual(floorReducer(.user, .turnCommitted), .teacher)
        XCTAssertEqual(floorReducer(.user, .nothingSaid), .idle)
        XCTAssertEqual(floorReducer(.teacher, .teacherFinished(resumePlayback: true)), .player)
        XCTAssertEqual(floorReducer(.teacher, .teacherFinished(resumePlayback: false)), .idle)
        XCTAssertEqual(floorReducer(.idle, .playbackRequested), .player)
        XCTAssertEqual(floorReducer(.player, .playbackHeld), .idle)
        XCTAssertEqual(floorReducer(.user, .sessionEnded), .idle)
    }

    // Releasing the button must NOT yield the floor: the mic gate derives from the
    // floor, and the server only ends a turn after hearing trailing silence, which
    // arrives after the finger lifts. Yielding here would close the mic and the
    // turn would never be committed.
    func testReleaseKeepsTheFloorUntilCommitted() {
        XCTAssertEqual(floorReducer(.user, .userReleased), .user)
        XCTAssertEqual(floorReducer(.idle, .userReleased), .idle)
    }

    func testSilencedRuleIsSingleVoice() {
        XCTAssertEqual(silenced(by: .player).pausePlayer, false)
        XCTAssertEqual(silenced(by: .player).stopTeacher, true)
        XCTAssertEqual(silenced(by: .user).pausePlayer, true)
        XCTAssertEqual(silenced(by: .user).stopTeacher, true)
        XCTAssertEqual(silenced(by: .teacher).pausePlayer, true)
        XCTAssertEqual(silenced(by: .teacher).stopTeacher, false)
    }

    // MARK: - Saving notes

    func testSaveNoteReadsAVocabularyCard() {
        let request = NoteRequest.from(tool: .save_note, args: ToolArguments(texts: [
            "text": "worked out", "meaning": "解决了", "note_type": "phrase",
            "example": "It worked out fine.", "why": "常用", "request": "记一下这个词",
        ]))
        guard case let .expression(text, type)? = request?.kind else {
            return XCTFail("expected an expression, got \(String(describing: request))")
        }
        XCTAssertEqual(text, "worked out")
        XCTAssertEqual(type, .phrase)
        XCTAssertEqual(request?.body, "解决了")
        XCTAssertEqual(request?.example, "It worked out fine.")
        XCTAssertEqual(request?.request, "记一下这个词", "the card must remember why it was wanted")
    }

    // Losing a note the learner explicitly ASKED for is much worse than showing it
    // plainly, so an unknown type falls back rather than dropping the whole card. The
    // type only decides which fields the card renders.
    func testAnUnknownNoteTypeFallsBackRatherThanDropping() {
        for raw in ["nonsense", ""] {
            let request = NoteRequest.from(tool: .save_note, args: ToolArguments(texts: [
                "text": "kind of", "meaning": "有点儿", "note_type": raw,
            ]))
            guard case let .expression(_, type)? = request?.kind else {
                return XCTFail("dropped the note for note_type=\(raw)")
            }
            XCTAssertEqual(type, .word)
        }
    }

    func testANoteTypeIsCaseInsensitive() {
        let request = NoteRequest.from(tool: .save_note, args: ToolArguments(texts: [
            "text": "hang on", "meaning": "等一下", "note_type": "IDIOM",
        ]))
        guard case let .expression(_, type)? = request?.kind else { return XCTFail() }
        XCTAssertEqual(type, .idiom)
    }

    // A card with no gloss teaches nothing, so an incomplete call is refused. The caller
    // says so out loud rather than saving something empty.
    func testAnIncompleteSaveIsRefused() {
        XCTAssertNil(NoteRequest.from(tool: .save_note, args: ToolArguments(texts: ["text": "kind of"])))
        XCTAssertNil(NoteRequest.from(tool: .save_note, args: ToolArguments(texts: ["meaning": "有点儿"])))
        XCTAssertNil(NoteRequest.from(tool: .save_note, args: ToolArguments()))
    }

    func testSaveAnswerReadsAQuestionCard() {
        let request = NoteRequest.from(tool: .save_answer, args: ToolArguments(texts: [
            "question": "为什么用被动", "answer": "强调结果而不是施动者。",
        ]))
        guard case let .answer(question)? = request?.kind else {
            return XCTFail("expected an answer, got \(String(describing: request))")
        }
        XCTAssertEqual(question, "为什么用被动")
        XCTAssertEqual(request?.body, "强调结果而不是施动者。")
    }

    func testAnIncompleteAnswerIsRefused() {
        XCTAssertNil(NoteRequest.from(tool: .save_answer, args: ToolArguments(texts: ["question": "q"])))
        XCTAssertNil(NoteRequest.from(tool: .save_answer, args: ToolArguments(texts: ["answer": "a"])))
    }

    // A playback tool is not a note, and reading one as a note would file a card every
    // time the learner asked to skip forward.
    func testPlaybackToolsAreNotNotes() {
        for tool in [PlaybackTool.pause_playback, .seek_to_timestamp, .next_sentence] {
            XCTAssertFalse(tool.savesANote, "\(tool) must not save")
            XCTAssertNil(NoteRequest.from(tool: tool, args: ToolArguments(texts: ["text": "x", "meaning": "y"])))
        }
        XCTAssertTrue(PlaybackTool.save_note.savesANote)
        XCTAssertTrue(PlaybackTool.save_answer.savesANote)
    }

    // The confirmation names what was saved. "已记下" alone cannot tell a correct save
    // from one that kept a mis-heard word, which in an explicit mode is the whole point.
    func testTheNoticeNamesWhatWasSaved() {
        let expression = NoteRequest(kind: .expression(text: "kind of", type: .phrase), body: "有点儿")
        XCTAssertTrue(noteNotice(expression).contains("kind of"))
        let answer = NoteRequest(kind: .answer(question: "q"), body: "a")
        XCTAssertFalse(noteNotice(answer).isEmpty)
    }
}
