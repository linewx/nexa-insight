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
}
