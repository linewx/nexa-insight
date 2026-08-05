import XCTest
@testable import NexaInsightCore

/// Mirrors the backend's locate_expression cases. On-demand extraction anchors on
/// the device and batch extraction anchors in the pipeline, so any divergence
/// here shows up as highlights that move when a note syncs.
final class ExpressionLocatorTests: XCTestCase {
    private func located(_ text: String, in host: String) -> String? {
        guard let range = ExpressionLocator.locate(text, in: host) else { return nil }
        let chars = Array(host)
        return String(chars[range.lowerBound..<range.upperBound])
    }

    func testFindsExactExpression() {
        XCTAssertEqual(
            ExpressionLocator.locate("rethink how", in: "We need to rethink how we work."),
            11..<22)
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(located("frontier models", in: "Frontier models are capable."), "Frontier models")
    }

    func testToleratesDoubleSpacesInTheTranscript() {
        // Transcripts carry runs of whitespace the model silently normalizes.
        XCTAssertEqual(located("work out", in: "It will  work  out fine."), "work  out")
    }

    func testSuffixedFormStillMatchesTheLemma() {
        XCTAssertEqual(located("work out", in: "It worked out fine."), "worked out")
    }

    func testDoesNotMatchInsideALongerWord() {
        // The case the lookaround exists for: without it, "work out" matched
        // "network outside" and highlighted the middle of two unrelated words.
        XCTAssertNil(ExpressionLocator.locate("work out", in: "The network outside failed."))
    }

    func testAbsentExpressionGetsNoHighlightRatherThanAWrongOne() {
        XCTAssertNil(ExpressionLocator.locate("thanks so much", in: "Okay, Patrick, let us begin."))
    }

    func testEmptyInputsAreRejected() {
        XCTAssertNil(ExpressionLocator.locate("", in: "Some sentence."))
        XCTAssertNil(ExpressionLocator.locate("   ", in: "Some sentence."))
        XCTAssertNil(ExpressionLocator.locate("word", in: ""))
    }

    // Verified against the Python implementation on the same inputs: both return
    // 11..<22 for "rethink how" in "We need to rethink how we work.", both match
    // "work  out" and "worked out", and both refuse "network outside".
    //
    // They diverge on one input class, and it is unfixable by aligning the port:
    // a ZWJ sequence like 👨‍👩‍👧 is ONE Character in Swift but FIVE code points in
    // Python, so the same match reports 5..<16 here and (9, 20) there. Offsets
    // therefore travel with the text that produced them — a manual note anchors
    // locally, and re-anchors from text if it ever comes back from the backend,
    // rather than trusting stored offsets across the boundary.
    func testGraphemeClustersMakeOffsetsLocalToThisImplementation() {
        let host = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} we rethink how it works."
        guard let range = ExpressionLocator.locate("rethink how", in: host) else {
            return XCTFail("expected a match")
        }
        // One grapheme for the family, so the match starts at 5 — not at 9 as the
        // code-point count gives.
        XCTAssertEqual(range, 5..<16)
        XCTAssertEqual(located("rethink how", in: host), "rethink how")
    }

    func testOffsetsCountCharactersNotUTF16Units() {
        // An emoji before the match would shift every following offset if these
        // were UTF-16 units, putting the highlight one position off for the rest
        // of the line.
        let host = "\u{1F600} we rethink how it works."
        guard let range = ExpressionLocator.locate("rethink how", in: host) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(located("rethink how", in: host), "rethink how")
        let chars = Array(host)
        XCTAssertEqual(String(chars[range.lowerBound..<range.upperBound]), "rethink how")
    }
}
