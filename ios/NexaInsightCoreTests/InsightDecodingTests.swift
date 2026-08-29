import XCTest
@testable import NexaInsightCore

// Decoding the 洞察 page, and the two things about it that are easy to get silently wrong.
final class InsightDecodingTests: XCTestCase {
    private func decodeBundle(_ json: String) throws -> BundleDTO {
        let decoder = JSONDecoder()
        // The real client's configuration. Getting this wrong is why bundles once failed
        // wholesale with "missing key": snake_case keys arrive already converted.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(BundleDTO.self, from: Data(json.utf8))
    }

    private let episode = """
    {"id":8,"source_url":"u","youtube_id":null,"title":"t","channel":"c","duration_ms":5400000,
     "thumbnail_url":null,"audio_path":null,"status":"ready","error":null}
    """

    func testAPageDecodesWithItsEvidenceAndDisputeIntact() throws {
        let bundle = try decodeBundle("""
        {"episode":\(episode),"chapters":[],"sentences":[],"has_audio":true,
         "insight":{"thesis":"这集在争论 AI 监管是真安全还是商业策略",
           "claims":[{"claim":"风险叙事服务于监管套利","evidence":"没有给出方法论",
                      "dispute":"另一位主播认为动机真诚","at_ms":2480000}],
           "facts":[{"fact":"预测 50% 岗位消失","sourced":false,"at_ms":1200000}],
           "takeaways":["真实战场是标准制定权"],
           "anchors":[{"at_ms":2480000,"why":"交锋处"}]}}
        """)
        let insight = try XCTUnwrap(bundle.insight)
        // evidence and dispute are the reason this page is not a summary: a claim without its
        // grounds is a model's word, and a conversation flattened to one voice misleads.
        XCTAssertEqual(insight.claims.first?.evidence, "没有给出方法论")
        XCTAssertEqual(insight.claims.first?.dispute, "另一位主播认为动机真诚")
        XCTAssertEqual(insight.facts.first?.sourced, false)
        XCTAssertEqual(insight.anchors.first?.atMs, 2_480_000)
    }

    func testABundleWithoutAPageStillDecodes() throws {
        // Teaching material never gets one, and native episodes imported before this existed do
        // not have one either. A missing page must not fail the bundle.
        let bundle = try decodeBundle("""
        {"episode":\(episode),"chapters":[],"sentences":[],"has_audio":true}
        """)
        XCTAssertNil(bundle.insight)
    }

    func testAPageWithOnlyAThesisDecodes() throws {
        // Every list is optional server-side, and takeaways are deliberately empty when the model
        // could only restate. Requiring them here would reject a legitimate page.
        let bundle = try decodeBundle("""
        {"episode":\(episode),"chapters":[],"sentences":[],"has_audio":true,
         "insight":{"thesis":"这集讨论监管与竞争"}}
        """)
        let insight = try XCTUnwrap(bundle.insight)
        XCTAssertEqual(insight.thesis, "这集讨论监管与竞争")
        XCTAssertTrue(insight.claims.isEmpty)
        XCTAssertTrue(insight.takeaways.isEmpty)
    }

    func testAtMsSurvivesTheSnakeCaseConversion() throws {
        // `at_ms` -> `atMs` happens in the decoder, not in the CodingKeys. Spelling the key as
        // snake_case is the mistake that made every bundle unreadable once.
        let bundle = try decodeBundle("""
        {"episode":\(episode),"chapters":[],"sentences":[],"has_audio":true,
         "insight":{"thesis":"这集讨论监管","facts":[{"fact":"三家公司主导草案","sourced":true,"at_ms":90000}]}}
        """)
        XCTAssertEqual(try XCTUnwrap(bundle.insight).facts.first?.atMs, 90_000)
    }
}
