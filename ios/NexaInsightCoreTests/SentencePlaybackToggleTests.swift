import XCTest
@testable import NexaInsightCore

final class SentencePlaybackToggleTests: XCTestCase {
    private func sentence(id: Int, startMs: Int) -> SentenceDTO {
        SentenceDTO(
            id: id, episodeId: 1, chapterId: nil, position: id, startMs: startMs,
            endMs: startMs + 3000, speaker: nil, sourceText: "line \(id)", chinese: "句 \(id)")
    }

    func testFirstTapPlaysFromTheSentenceStart() {
        let line = sentence(id: 7, startMs: 411_000)
        XCTAssertEqual(
            SentencePlaybackToggle.action(tapped: line, playingId: nil, isPlaying: false),
            .play(fromMs: 411_000))
    }

    func testSecondTapOnThePlayingSentenceStops() {
        let line = sentence(id: 7, startMs: 411_000)
        XCTAssertEqual(
            SentencePlaybackToggle.action(tapped: line, playingId: 7, isPlaying: true),
            .stop)
    }

    func testTappingADifferentSentenceMovesThereRatherThanStopping() {
        // Reading down the page would otherwise need a stop before every play.
        let other = sentence(id: 9, startMs: 422_000)
        XCTAssertEqual(
            SentencePlaybackToggle.action(tapped: other, playingId: 7, isPlaying: true),
            .play(fromMs: 422_000))
    }

    func testTappingThePausedSentenceResumesInsteadOfStopping() {
        // The cursor still sits inside this line, but nothing is advancing. Treating
        // that as "stop" would make the tap after a pause appear to do nothing.
        let line = sentence(id: 7, startMs: 411_000)
        XCTAssertEqual(
            SentencePlaybackToggle.action(tapped: line, playingId: 7, isPlaying: false),
            .play(fromMs: 411_000))
    }

    func testPlayingFromTheVeryStartIsNotConfusedWithNoPosition() {
        let first = sentence(id: 1, startMs: 0)
        XCTAssertEqual(
            SentencePlaybackToggle.action(tapped: first, playingId: 1, isPlaying: true),
            .stop)
        XCTAssertEqual(
            SentencePlaybackToggle.action(tapped: first, playingId: nil, isPlaying: true),
            .play(fromMs: 0))
    }
}
