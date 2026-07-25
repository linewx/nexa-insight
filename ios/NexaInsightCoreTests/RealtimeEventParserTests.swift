import XCTest
@testable import NexaInsightCore

final class RealtimeEventParserTests: XCTestCase {
    func testSpeechStarted() {
        let e = RealtimeEventParser.parse(["type": "input_audio_buffer.speech_started"])
        guard case .speechStarted = e else { return XCTFail("expected speechStarted") }
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
        XCTAssertTrue(args.isEmpty)
    }

    func testUnknownToolNameIgnored() {
        let e = RealtimeEventParser.parse([
            "type": "response.done",
            "response": ["output": [["type": "function_call", "name": "delete_everything", "arguments": "{}"]]]])
        guard case .responseDone = e else { return XCTFail("unknown tool -> plain responseDone") }
    }

    func testUnrelatedEventReturnsNil() {
        XCTAssertNil(RealtimeEventParser.parse(["type": "response.created"]))
    }
}
