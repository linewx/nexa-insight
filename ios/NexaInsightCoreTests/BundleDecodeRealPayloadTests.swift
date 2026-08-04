import XCTest
@testable import NexaInsightCore

/// Decodes the exact JSON shape the backend serves for /api/episodes/{id}/bundle.
final class BundleDecodeRealPayloadTests: XCTestCase {
    private let payload = """
    {
      "episode": {
        "id": 1, "source_url": "https://y", "youtube_id": "abc", "title": "T",
        "channel": "C", "duration_ms": 1000, "thumbnail_url": null,
        "audio_path": "episodes/1/source.mp3", "stream_url": null,
        "stream_url_expires_at": null, "status": "ready", "error": null,
        "created_at": "2026-08-04T00:00:00"
      },
      "chapters": [
        {"id": 1, "title": "Intro", "summary": "s", "start_ms": 0, "end_ms": 1000}
      ],
      "sentences": [
        {"id": 1, "episode_id": 1, "chapter_id": 1, "position": 0, "start_ms": 0,
         "end_ms": 500, "speaker": null, "source_text": "Ramp up fast.", "chinese": "快速加速。"}
      ],
      "has_audio": true,
      "has_stream": false,
      "has_learning_pack": true,
      "learning_expressions": [
        {"id": 1, "text": "ramp up", "kind": "phrasal verb", "chinese": "加速",
         "pronunciation": null, "example": "Ramp up.", "example_chinese": "加速。",
         "occurrences": [{"sentence_id": 1, "start_offset": 0, "end_offset": 7}]}
      ]
    }
    """.data(using: .utf8)!

    func testDecodesBackendBundlePayload() throws {
        let bundle = try BackendClient.jsonDecoder.decode(BundleDTO.self, from: payload)

        XCTAssertTrue(bundle.hasAudio)
        XCTAssertTrue(bundle.hasLearningPack)
        XCTAssertEqual(bundle.sentences.first?.sourceText, "Ramp up fast.")
        XCTAssertEqual(bundle.learningExpressions.count, 1)
        XCTAssertEqual(bundle.learningExpressions.first?.kind, .phrase)
        XCTAssertEqual(bundle.learningExpressions.first?.occurrences.first?.sentenceId, 1)
    }
}
