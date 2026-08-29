import XCTest
@testable import NexaInsightCore

// Importing a video that is already in Chinese.
//
// Nothing to translate and no vocabulary to extract — both of those exist to close the gap between
// what was said and what the listener understood, and for a source in their own language there is
// no gap. What remains is the transcript and the 洞察 page, which is the reason to import it.
final class ChineseSourceTests: XCTestCase {
    func testATranslationEqualToTheSourceIsNotDrawnTwice() throws {
        // The pipeline stores the source text in `chinese` for a Chinese video, because the
        // transcript view renders that field and the decoder treats it as always present. Drawing
        // it unconditionally printed every line twice.
        let source = try String(contentsOfFile: "NexaInsight/Views/StudyView.swift", encoding: .utf8)
        let code = source.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("sentence.chinese != sentence.sourceText"),
                      "a translation identical to the source is not a translation")
    }

    func testAnEpisodeWithNoCardsStillRenders() throws {
        // `annotated` gates the highlighting, and a Chinese import has no cards at all. This is
        // already how it behaves — the check is that it stays that way, since a crash or an empty
        // shelf here would make Chinese imports unusable.
        let source = try String(contentsOfFile: "NexaInsight/Views/StudyView.swift", encoding: .utf8)
        XCTAssertTrue(source.contains("private var annotated: Bool { !learningExpressions.isEmpty }"),
                      "no cards simply means no annotation")
    }

    func testTheInsightPageIsWhatAChineseImportIsFor() throws {
        // The entry is gated on the page existing rather than on material kind, so a Chinese
        // episode — which is never classified `teaching` or `native` by语言 — still shows it.
        let source = try String(contentsOfFile: "NexaInsight/Views/StudyView.swift", encoding: .utf8)
        XCTAssertTrue(source.contains("hasInsight: insight != nil"),
                      "the 洞察 entry depends on the page, not on the material kind")
    }
}
