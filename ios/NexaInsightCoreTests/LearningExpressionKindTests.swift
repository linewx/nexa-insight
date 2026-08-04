import XCTest
@testable import NexaInsightCore

/// The backend now normalizes `kind`, but an older server (or a stale local
/// bundle) can still hold a value the enum has no case for. Decoding must
/// survive that: one unknown value used to fail the whole bundle, which the UI
/// reported as "The data couldn't be read because it is missing".
final class LearningExpressionKindTests: XCTestCase {
    private func decodeKind(_ raw: String) throws -> LearningExpressionKind {
        let json = """
        {"kind": "\(raw)"}
        """.data(using: .utf8)!
        struct Holder: Codable { let kind: LearningExpressionKind }
        return try JSONDecoder().decode(Holder.self, from: json).kind
    }

    func testDecodesKnownKinds() throws {
        XCTAssertEqual(try decodeKind("word"), .word)
        XCTAssertEqual(try decodeKind("phrase"), .phrase)
        XCTAssertEqual(try decodeKind("pattern"), .pattern)
    }

    func testUnknownKindFallsBackInsteadOfThrowing() throws {
        // Real values observed from qwen-plus across two imports.
        XCTAssertEqual(try decodeKind("phrasal verb"), .phrase)
        XCTAssertEqual(try decodeKind("collocation"), .phrase)
        XCTAssertEqual(try decodeKind("fixed expression"), .phrase)
        XCTAssertEqual(try decodeKind("compound noun (YC term)"), .phrase)
        XCTAssertEqual(try decodeKind("transferable sentence pattern"), .pattern)
        XCTAssertEqual(try decodeKind("technical word"), .word)
        XCTAssertEqual(try decodeKind("acronym"), .word)
    }

    func testBundleWithUnknownKindStillDecodes() throws {
        let json = """
        {
          "episode": {
            "id": 1, "source_url": "https://y", "youtube_id": null, "title": null,
            "channel": null, "duration_ms": null, "thumbnail_url": null,
            "audio_path": null, "stream_url": null, "stream_url_expires_at": null,
            "status": "ready", "error": null, "created_at": "2026-08-04T00:00:00"
          },
          "chapters": [],
          "sentences": [],
          "has_audio": true,
          "has_learning_pack": true,
          "learning_expressions": [
            {"id": 1, "text": "ramp up", "kind": "phrasal verb", "chinese": "加速",
             "pronunciation": null, "example": "Ramp up.", "example_chinese": "加速。",
             "occurrences": []}
          ]
        }
        """.data(using: .utf8)!

        let bundle = try BackendClient.jsonDecoder.decode(BundleDTO.self, from: json)

        XCTAssertEqual(bundle.learningExpressions.count, 1)
        XCTAssertEqual(bundle.learningExpressions[0].kind, .phrase)
    }
}
