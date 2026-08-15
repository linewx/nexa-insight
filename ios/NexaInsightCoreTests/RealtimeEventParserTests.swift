import XCTest
@testable import NexaInsightCore

final class RealtimeEventParserTests: XCTestCase {
    func testSpeechStarted() {
        let e = RealtimeEventParser.parse(["type": "input_audio_buffer.speech_started"])
        guard case .speechStarted = e else { return XCTFail("expected speechStarted") }
    }

    func testResponseCreated() {
        let e = RealtimeEventParser.parse(["type": "response.created"])
        guard case .responseCreated = e else { return XCTFail("expected responseCreated") }
    }

    func testInputTranscriptionCompleted() {
        let e = RealtimeEventParser.parse([
            "type": "conversation.item.input_audio_transcription.completed",
            "transcript": "hello teacher"])
        guard case let .inputTranscriptionCompleted(text) = e else { return XCTFail() }
        XCTAssertEqual(text, "hello teacher")
    }

    func testResponseAudioTranscriptDone() {
        let e = RealtimeEventParser.parse(["type": "response.audio_transcript.done", "transcript": "hi"])
        guard case let .responseAudioTranscriptDone(text) = e else { return XCTFail() }
        XCTAssertEqual(text, "hi")
    }

    func testResponseDoneWithFunctionCallEmitsToolCall() {
        let e = RealtimeEventParser.parse([
            "type": "response.done",
            "response": ["output": [[
                "type": "function_call", "name": "seek_to_timestamp",
                "arguments": "{\"seconds\": 12}", "call_id": "c1"]]]])
        guard case let .toolCall(name, args, callId) = e else { return XCTFail() }
        XCTAssertEqual(name, .seek_to_timestamp)
        XCTAssertEqual(args["seconds"], 12)
        XCTAssertEqual(callId, "c1")
    }

    // WebRTC's real path: the tool call arrives as its own event with name/
    // call_id/arguments on the event itself. This is what was being dropped,
    // so playback control never fired.
    func testFunctionCallArgumentsDoneEventEmitsToolCall() {
        let e = RealtimeEventParser.parse([
            "type": "response.function_call_arguments.done",
            "name": "seek_to_timestamp",
            "arguments": "{\"seconds\": 42}",
            "call_id": "fc1"])
        guard case let .toolCall(name, args, callId) = e else { return XCTFail("expected toolCall") }
        XCTAssertEqual(name, .seek_to_timestamp)
        XCTAssertEqual(args["seconds"], 42)
        XCTAssertEqual(callId, "fc1")
    }

    func testFunctionCallArgumentsDoneUnknownToolIsIgnored() {
        let e = RealtimeEventParser.parse([
            "type": "response.function_call_arguments.done",
            "name": "delete_everything", "arguments": "{}", "call_id": "fc2"])
        XCTAssertNil(e, "unknown tool on the dedicated event -> nil, not a bogus toolCall")
    }

    func testResponseDoneWithoutToolCallIsResponseDone() {
        let e = RealtimeEventParser.parse(["type": "response.done", "response": ["output": []]])
        guard case .responseDone = e else { return XCTFail("expected responseDone") }
    }

    func testMalformedToolArgumentsFallBackToEmpty() {
        let e = RealtimeEventParser.parse([
            "type": "response.done",
            "response": ["output": [[
                "type": "function_call", "name": "resume_playback",
                "arguments": "not json", "call_id": "c2"]]]])
        guard case let .toolCall(name, args, _) = e else { return XCTFail() }
        XCTAssertEqual(name, .resume_playback)
        XCTAssertEqual(args, ToolArguments(), "unparseable arguments must yield nothing, not a partial guess")
    }

    func testUnknownToolNameIgnored() {
        let e = RealtimeEventParser.parse([
            "type": "response.done",
            "response": ["output": [["type": "function_call", "name": "delete_everything", "arguments": "{}"]]]])
        guard case .responseDone = e else { return XCTFail("unknown tool -> plain responseDone") }
    }

    func testUnrelatedEventReturnsNil() {
        XCTAssertNil(RealtimeEventParser.parse(["type": "response.output_item.added"]))
    }

    // MARK: - Several calls in one frame

    // Asked to analyse a passage and keep what matters, the teacher saves three words in
    // one response. The single-event parser returned on the FIRST function_call and dropped
    // the rest, so one card appeared and the others vanished with no error anywhere.
    func testEveryToolCallInAFrameIsReturned() {
        let events = RealtimeEventParser.parseAll([
            "type": "response.done",
            "response": ["output": [
                ["type": "function_call", "name": "save_note",
                 "arguments": #"{"text":"one","meaning":"一"}"#, "call_id": "a"],
                ["type": "function_call", "name": "save_note",
                 "arguments": #"{"text":"two","meaning":"二"}"#, "call_id": "b"],
                ["type": "function_call", "name": "save_note",
                 "arguments": #"{"text":"three","meaning":"三"}"#, "call_id": "c"],
            ]]])

        let saved = events.compactMap { event -> String? in
            guard case let .toolCall(_, args, _) = event else { return nil }
            return args.text("text")
        }
        XCTAssertEqual(saved, ["one", "two", "three"])
    }

    // And the turn still ends. `.responseDone` is the only thing that hands the floor back
    // from the teacher, so losing it left the UI reading "the teacher is speaking" forever
    // with nothing happening — the same bug, its second symptom.
    func testTheTurnEndArrivesAfterTheCalls() {
        let events = RealtimeEventParser.parseAll([
            "type": "response.done",
            "response": ["output": [
                ["type": "function_call", "name": "save_note",
                 "arguments": #"{"text":"one","meaning":"一"}"#, "call_id": "a"],
            ]]])

        XCTAssertEqual(events.count, 2)
        guard case .toolCall = events.first else { return XCTFail("calls come first") }
        guard case .responseDone = events.last else {
            return XCTFail("the turn must end, and only after the saves")
        }
    }

    func testAFrameWithNoCallsIsJustTheTurnEnding() {
        let events = RealtimeEventParser.parseAll(["type": "response.done",
                                                  "response": ["output": []]])
        XCTAssertEqual(events.count, 1)
        guard case .responseDone = events.first else { return XCTFail() }
    }

    // Everything that is not response.done carries exactly one event, and parseAll must
    // not change how those behave.
    func testOtherFramesStillYieldASingleEvent() {
        XCTAssertEqual(RealtimeEventParser.parseAll(["type": "input_audio_buffer.committed"]).count, 1)
        XCTAssertTrue(RealtimeEventParser.parseAll(["type": "response.output_item.added"]).isEmpty)
    }

    // MARK: - Tool arguments

    // Strings used to be dropped silently. Nothing noticed because every playback
    // argument is a number; saving a note is the first tool that carries text.
    func testTextArgumentsSurvive() {
        let args = RealtimeEventParser.safeArgs(#"{"text":"kind of","meaning":"有点儿"}"#)
        XCTAssertEqual(args.text("text"), "kind of")
        XCTAssertEqual(args.text("meaning"), "有点儿")
    }

    // The regression that matters: playbackTargetPosition reads `numbers`, so adding the
    // text half must leave the numeric half byte-for-byte as it was.
    func testNumericArgumentsAreUnchanged() {
        let args = RealtimeEventParser.safeArgs(#"{"seconds":90.5,"rate":2}"#)
        XCTAssertEqual(args.numbers, ["seconds": 90.5, "rate": 2])
        XCTAssertEqual(args["seconds"], 90.5)
    }

    // A model asked for a number sometimes sends "30". Kept in both, so the playback path
    // still sees a number rather than reading it as text and ignoring it.
    func testAQuotedNumberIsStillANumber() {
        let args = RealtimeEventParser.safeArgs(#"{"seconds":"30"}"#)
        XCTAssertEqual(args["seconds"], 30)
        XCTAssertEqual(args.text("seconds"), "30")
    }

    func testBlankTextIsNotCarried() {
        let args = RealtimeEventParser.safeArgs(#"{"text":"   ","meaning":""}"#)
        XCTAssertNil(args.text("text"))
        XCTAssertNil(args.text("meaning"))
    }

    func testTextIsTrimmed() {
        XCTAssertEqual(RealtimeEventParser.safeArgs(#"{"text":"  kind of \n"}"#).text("text"),
                       "kind of")
    }

    // One call can carry both halves, and neither leaks into the other: a note's text
    // must not appear as a number, and a real number must not appear as text.
    func testMixedArgumentsSplitCleanly() {
        let args = RealtimeEventParser.safeArgs(#"{"text":"work out","seconds":12}"#)
        XCTAssertEqual(args.text("text"), "work out")
        XCTAssertEqual(args["seconds"], 12)
        XCTAssertNil(args["text"], "prose is not a number")
        XCTAssertNil(args.text("seconds"), "a real number is not text")
    }
}
