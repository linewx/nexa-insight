import XCTest
@testable import NexaInsightCore

// Seeking by content: "jump to the part about Salesforce" rather than "seek to 12 minutes".
//
// The classroom context is ±6 sentences plus chapter titles, so the teacher cannot otherwise know
// where a topic is discussed. And the chapter outline is not a substitute — measured on ep11, the
// chapter TITLED for Salesforce opens with Nvidia and the real discussion starts three minutes later.
final class EpisodeSearchTests: XCTestCase {
    private func line(_ ms: Int, _ text: String, chinese: String = "") -> SentenceDTO {
        SentenceDTO(id: ms, episodeId: 11, chapterId: nil, position: ms / 1000,
                    startMs: ms, endMs: ms + 3000, speaker: nil,
                    sourceText: text, chinese: chinese)
    }

    func testADiscussionOutranksAPassingMention() {
        // The real shape of the problem: 25 scattered mentions across an episode, of which only one
        // cluster is the segment about it. Returning them in time order would hand the teacher a
        // name-drop from the intro.
        var sentences = [
            line(60_000, "we'll talk a little bit about Salesforce later"),
            line(120_000, "anyway, back to chips"),
        ]
        for i in 0..<6 {
            sentences.append(line(600_000 + i * 8_000, "Salesforce margins and the SaaS story \(i)"))
        }
        let hits = EpisodeSearch.find("salesforce", in: sentences)

        XCTAssertEqual(hits.first?.atMs, 600_000, "the discussion, not the trailer for it")
        XCTAssertGreaterThan(hits.first!.density, 1)
        // Both are still offered, so the teacher can choose.
        XCTAssertTrue(hits.contains { $0.atMs == 60_000 })
    }

    func testMentionsWithinTheSameStretchAreOneAnswer() {
        // Twenty-five mentions are not twenty-five places to jump to.
        let sentences = (0..<10).map { line(300_000 + $0 * 5_000, "Salesforce again \($0)") }
        let hits = EpisodeSearch.find("salesforce", in: sentences)
        XCTAssertEqual(hits.count, 1, "one discussion, one hit")
        XCTAssertEqual(hits.first?.density, 10)
    }

    func testAQueryInChineseFindsEnglishAudio() {
        // The common case here: the learner asks in Chinese about an English episode. Matching only
        // the source text would answer "not found" for a topic that is plainly discussed.
        let sentences = [line(90_000, "Nvidia had a historic quarter", chinese: "英伟达创下历史性季度")]
        XCTAssertEqual(EpisodeSearch.find("英伟达", in: sentences).first?.atMs, 90_000)
        XCTAssertEqual(EpisodeSearch.find("nvidia", in: sentences).first?.atMs, 90_000)
    }

    func testCaseAndAccentsDoNotMatter() {
        let sentences = [line(30_000, "SALESFORCE and Slack")]
        XCTAssertFalse(EpisodeSearch.find("salesforce", in: sentences).isEmpty)
    }

    func testHitsCarryEnoughContextToChooseBetween() {
        // A timestamp alone is not enough: the teacher has to be able to tell a discussion from an
        // aside, and it only sees what this returns.
        let sentences = [
            line(0, "before"),
            line(10_000, "the Salesforce number was the surprise"),
            line(20_000, "after"),
        ]
        let context = try! XCTUnwrap(EpisodeSearch.find("salesforce", in: sentences).first).context
        XCTAssertTrue(context.contains("before") && context.contains("after"))
    }

    func testNothingFoundSaysSoRatherThanReturningZero() {
        // A model handed an empty result invents a plausible timestamp. The description tells it to
        // say so instead — the alternative is seeking the learner somewhere arbitrary.
        let described = EpisodeSearch.describe(EpisodeSearch.find("bitcoin", in: [line(0, "chips")]))
        XCTAssertTrue(described.contains("Not found"))
        XCTAssertTrue(described.contains("rather than guessing"))
    }

    func testAOneCharacterQueryIsRejected() {
        // "a" matches everything, and the first hit would be sentence one.
        XCTAssertTrue(EpisodeSearch.find("a", in: [line(0, "a talk about chips")]).isEmpty)
    }

    func testTheDescriptionGivesSecondsTheTeacherCanSeekTo() {
        let hits = EpisodeSearch.find("salesforce", in: [line(721_000, "Salesforce earnings")])
        let described = EpisodeSearch.describe(hits)
        // seek_to_timestamp takes seconds, and the human form is for the teacher to say out loud.
        XCTAssertTrue(described.contains("721s"), described)
        XCTAssertTrue(described.contains("12m01s"), described)
    }
}
