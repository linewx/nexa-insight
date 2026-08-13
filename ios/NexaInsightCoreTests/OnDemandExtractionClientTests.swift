import XCTest
@testable import NexaInsightCore

final class OnDemandExtractionClientTests: XCTestCase {
    private let lines = ["We need to rethink how we work.", "Bye now"]

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

    private let exchange = "LEARNER: rethink 是什么意思\nTEACHER: 重新思考。"

    func testKeepsWhatTheReviewReturned() async {
        let json = #"{"points":[{"kind":"question","question":"rethink 是什么意思","answer":"重新思考。"}]}"#
        let points = await client(body: streamed(json)).knowledgePoints(
            conversation: exchange, candidates: lines, materialKind: "native")
        XCTAssertEqual(points, [.question(question: "rethink 是什么意思", answer: "重新思考。")])
    }

    // DashScope streams deltas even for a single JSON object, but not always. When there
    // are no `data:` events, `streamedContent` falls back to the raw body.
    func testHandlesANonStreamedBody() async {
        let json = #"{"points":[{"kind":"question","question":"q","answer":"a"}]}"#
        let points = await client(body: json).knowledgePoints(
            conversation: exchange, candidates: lines, materialKind: "native")
        XCTAssertEqual(points, [.question(question: "q", answer: "a")])
    }

    // The whole exchange is sent, roles and all, because who said what decides which
    // half is the question and which is the conclusion.
    func testSendsTheExchangeAndTheNumberedLines() async {
        var body: String?
        _ = await client(body: streamed(#"{"points":[]}"#), capture: { request in
            body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        }).knowledgePoints(conversation: exchange, candidates: lines, materialKind: "native")

        let sent = try? XCTUnwrap(body)
        XCTAssertEqual(sent?.contains("LEARNER"), true)
        XCTAssertEqual(sent?.contains("TEACHER"), true)
        XCTAssertEqual(sent?.contains("0. We need to rethink"), true)
        // No audio: the realtime session already transcribed both sides, so there is
        // nothing to upload and no second chance to mishear.
        XCTAssertEqual(sent?.contains("input_audio"), false)
        XCTAssertEqual(sent?.contains("qwen-plus"), true)
    }

    // MARK: - Failing quietly

    // Every failure yields nothing rather than throwing. By this point the learner has
    // already heard and read the answer on screen; a dialog would only interrupt to
    // report that a background judgement did not happen.

    func testMissingCredentialsYieldNothing() async {
        var client = OnDemandExtractionClient(apiKey: "", workspaceId: "")
        var attempted = false
        client.send = { request in
            attempted = true
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let points = await client.knowledgePoints(
            conversation: exchange, candidates: lines, materialKind: "native")
        XCTAssertTrue(points.isEmpty)
        XCTAssertFalse(attempted, "no key means no request at all")
    }

    func testHTTPFailureYieldsNothing() async {
        let points = await client(status: 500, body: "upstream exploded").knowledgePoints(
            conversation: exchange, candidates: lines, materialKind: "native")
        XCTAssertTrue(points.isEmpty)
    }

    func testAnEmptyExchangeIsNotSentAtAll() async {
        var attempted = false
        var client = OnDemandExtractionClient(apiKey: "sk-test", workspaceId: "llm-test")
        client.send = { request in
            attempted = true
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let points = await client.knowledgePoints(
            conversation: "", candidates: lines, materialKind: "native")
        XCTAssertTrue(points.isEmpty)
        XCTAssertFalse(attempted)
    }

    // The judgement that there was nothing worth keeping is a normal answer, and must
    // not read as a failure. This is the case the old path threw on.
    func testKeepingNothingIsASuccess() async {
        let points = await client(body: streamed(#"{"points":[]}"#)).knowledgePoints(
            conversation: exchange, candidates: lines, materialKind: "native")
        XCTAssertTrue(points.isEmpty)
    }
}
