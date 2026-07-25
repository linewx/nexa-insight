import XCTest
@testable import NexaInsightCore

final class BackendClientTests: XCTestCase {
    func testFormatApiErrorReadsDetailString() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        let data = #"{"detail":"This episode has already been imported"}"#.data(using: .utf8)!
        XCTAssertEqual(client.formatApiError(data, 409), "This episode has already been imported")
    }

    func testFormatApiErrorReadsValidationArray() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        let data = #"{"detail":[{"loc":["body","url"],"msg":"field required"}]}"#.data(using: .utf8)!
        XCTAssertEqual(client.formatApiError(data, 422), "body.url: field required")
    }

    func testFormatApiErrorFallback() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        XCTAssertEqual(client.formatApiError(Data(), 500), "Request failed (500)")
    }

    func testBundleURLConstruction() {
        let client = BackendClient(baseURL: URL(string: "http://localhost:8000")!)
        XCTAssertEqual(client.url(path: "/api/episodes/3/bundle").absoluteString,
                       "http://localhost:8000/api/episodes/3/bundle")
    }

    func testDecoderConvertsSnakeCase() throws {
        let json = #"{"id":1,"source_url":"u","youtube_id":null,"title":"T","channel":null,"duration_ms":null,"thumbnail_url":null,"audio_path":null,"status":"ready","error":null}"#.data(using: .utf8)!
        let episode = try BackendClient.jsonDecoder.decode(EpisodeDTO.self, from: json)
        XCTAssertEqual(episode.sourceUrl, "u")
        XCTAssertEqual(episode.status, "ready")
    }
}
