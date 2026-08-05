import XCTest
@testable import NexaInsightCore

final class OnDemandExtractionClientTests: XCTestCase {
    private let host = "We need to rethink how we work."

    private func client(
        status: Int = 200,
        body: String,
        capture: ((URLRequest) -> Void)? = nil
    ) -> OnDemandExtractionClient {
        var client = OnDemandExtractionClient(apiKey: "sk-test", workspaceId: "llm-test")
        client.send = { request in
            capture?(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
        return client
    }

    private func streamed(_ content: String) -> String {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "data: {\"choices\":[{\"delta\":{\"content\":\"\(escaped)\"}}]}\ndata: [DONE]\n"
    }

    func testExtractsFromAStreamedReply() async throws {
        let json = """
            {"expressions":[{"text":"rethink how","type":"syntax",
            "chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}\u{5982}\u{4f55}",
            "why_hard":"\u{4ece}\u{53e5}\u{5bb9}\u{6613}\u{8bfb}\u{9519}\u{3002}"}]}
            """
        let result = try await client(body: streamed(json))
            .extract(sentence: host, materialKind: "native", request: nil)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "rethink how")
        XCTAssertEqual(result[0].type, .syntax)
    }

    func testHandlesANonStreamedBody() async throws {
        // Falling back to the raw body keeps a plain JSON reply working rather than
        // silently returning nothing.
        let json = """
            {"expressions":[{"text":"rethink how","type":"idiom","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}"}]}
            """
        let result = try await client(body: json)
            .extract(sentence: host, materialKind: "native", request: nil)
        XCTAssertEqual(result.count, 1)
    }

    func testSendsTheLearnerRequestInTheInstruction() async throws {
        var sentBody: String?
        let json = """
            {"expressions":[{"text":"rethink how","type":"idiom","chinese":"\u{91cd}\u{65b0}\u{601d}\u{8003}"}]}
            """
        _ = try await client(body: streamed(json), capture: { request in
            sentBody = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        }).extract(sentence: host, materialKind: "native", request: "\u{53ea}\u{8bb2}\u{65f6}\u{6001}")

        let body = try XCTUnwrap(sentBody)
        XCTAssertTrue(body.contains("\\u53ea") || body.contains("\u{53ea}\u{8bb2}\u{65f6}\u{6001}"),
                      "the request must reach the model")
        XCTAssertTrue(body.contains("Sentence:"))
    }

    func testMissingCredentialsFailBeforeAnyRequest() async {
        var client = OnDemandExtractionClient(apiKey: "", workspaceId: "")
        var called = false
        client.send = { request in
            called = true
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        do {
            _ = try await client.extract(sentence: host, materialKind: "native", request: nil)
            XCTFail("expected a configuration error")
        } catch {
            XCTAssertEqual(error as? DashScopePracticeError, .missingConfiguration)
        }
        XCTAssertFalse(called, "must not spend a request without a key")
    }

    func testHTTPFailureIsSurfacedWithItsStatus() async {
        do {
            _ = try await client(status: 429, body: "rate limited")
                .extract(sentence: host, materialKind: "native", request: nil)
            XCTFail("expected a request failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("429"), error.localizedDescription)
        }
    }

    // MARK: - Spoken questions

    private func wavFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-test-\(UUID().uuidString).wav")
        try Data(repeating: 0x11, count: 2048).write(to: url)
        return url
    }

    func testSpokenQuestionSendsAudioAndTheNumberedLines() async throws {
        let audio = try wavFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        var sentBody: String?
        let json = """
            {"expressions":[{"text":"what they wrote","type":"syntax",
            "chinese":"\u{4ed6}\u{4eec}\u{5199}\u{7684}","sentence_position":1}]}
            """
        let result = try await client(body: streamed(json), capture: { request in
            sentBody = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        }).extract(
            audioURL: audio,
            candidates: ["They both signed up.", "What they wrote is not what shipped."],
            materialKind: "native")

        let body = try XCTUnwrap(sentBody)
        // Audio goes as audio: no transcription step to mishear the question.
        XCTAssertTrue(body.contains("input_audio"))
        XCTAssertTrue(body.contains("qwen3.5-omni-plus"), "the audio model, not qwen-plus")
        // The lines are numbered so sentence_position can index them.
        XCTAssertTrue(body.contains("1. What they wrote"))
        XCTAssertEqual(result[0].sentencePosition, 1)
    }

    func testSpokenQuestionIsToldNotToTranscribeItself() async throws {
        let audio = try wavFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        var sentBody: String?
        let json = """
            {"expressions":[{"text":"signed up","type":"phrase","chinese":"\u{540c}\u{610f}"}]}
            """
        _ = try await client(body: streamed(json), capture: { request in
            sentBody = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        }).extract(audioURL: audio, candidates: ["They both signed up."], materialKind: "native")

        let body = try XCTUnwrap(sentBody)
        // Both shapes must be on offer: asking for vocabulary alone is what made
        // every question about meaning or grammar come back as a failure.
        XCTAssertTrue(body.contains("vocabulary"))
        XCTAssertTrue(body.contains("comprehension"))
        XCTAssertTrue(body.contains("sentence_position"))
        XCTAssertTrue(body.contains("never repeat the audio"))
    }

    func testAskRoutesAComprehensionAnswer() async throws {
        let audio = try wavFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let json = """
            {"intent":"comprehension","question":"\u{8fd9}\u{6bb5}\u{5728}\u{8bb2}\u{4ec0}\u{4e48}",
             "answer":"\u{5199}\u{7684}\u{548c}\u{505a}\u{7684}\u{4e0d}\u{4e00}\u{6837}\u{3002}","sentence_position":0}
            """
        let outcome = try await client(body: streamed(json)).ask(
            audioURL: audio, candidates: ["What they wrote is not what shipped."],
            materialKind: "native")

        guard case .answer(let note) = outcome else { return XCTFail("expected an answer") }
        XCTAssertEqual(note.sentencePosition, 0)
        XCTAssertFalse(note.answer.isEmpty)
    }

    func testAskRoutesVocabularyWhenThatIsWhatWasAsked() async throws {
        let audio = try wavFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let json = """
            {"intent":"vocabulary","expressions":[
              {"text":"what they wrote","type":"syntax","chinese":"\u{4ed6}\u{4eec}\u{5199}\u{7684}"}]}
            """
        let outcome = try await client(body: streamed(json)).ask(
            audioURL: audio, candidates: ["What they wrote is not what shipped."],
            materialKind: "native")

        guard case .vocabulary(let items) = outcome else { return XCTFail("expected vocabulary") }
        XCTAssertEqual(items.first?.text, "what they wrote")
    }

    func testOversizedRecordingIsRefusedBeforeUpload() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-big-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 10_000_001).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var called = false
        var c = OnDemandExtractionClient(apiKey: "sk", workspaceId: "llm")
        c.send = { request in
            called = true
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        do {
            _ = try await c.extract(audioURL: url, candidates: ["A line."], materialKind: "native")
            XCTFail("expected a size refusal")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("\u{5f55}\u{97f3}"), error.localizedDescription)
        }
        XCTAssertFalse(called, "must not upload 10MB to be rejected remotely")
    }

    func testMissingRecordingFileSurfacesAsAnError() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).wav")
        do {
            _ = try await client(body: "{}").extract(
                audioURL: missing, candidates: ["A line."], materialKind: "native")
            XCTFail("expected a read failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testASentenceWithNothingWorthNotingReportsThatClearly() async {
        do {
            _ = try await client(body: streamed("{\"expressions\":[]}"))
                .extract(sentence: host, materialKind: "native", request: nil)
            XCTFail("expected noUsableExpression")
        } catch {
            XCTAssertEqual(error as? ExtractionParseError, .noUsableExpression)
        }
    }
}

extension DashScopePracticeError: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
