import XCTest
@testable import NexaInsightCore

final class ModelAudioTests: XCTestCase {
    func testATranscriptSentenceIsBoundedToItsOwnSpan() {
        // The reason synthesis was chosen first: the hotel vlog averages 11.5s per segment and
        // runs to 33s. Bounding playback to the segment is what makes the real voice usable —
        // otherwise tapping one line plays the paragraph around it.
        let audio = ModelAudio.original(startMs: 110_799, endMs: 122_960)
        let window = audio.playbackWindow
        XCTAssertEqual(window?.start, 110_799 - ModelAudio.leadInMs)
        XCTAssertEqual(window?.end, 122_960 + ModelAudio.tailMs)
    }

    func testPlaybackStopsAtTheEndOfTheSentence() {
        let audio = ModelAudio.original(startMs: 1_000, endMs: 3_000)
        XCTAssertFalse(audio.hasReachedEnd(at: 2_999))
        XCTAssertFalse(audio.hasReachedEnd(at: 3_100), "the tail padding is still part of it")
        XCTAssertTrue(audio.hasReachedEnd(at: 3_000 + ModelAudio.tailMs))
        XCTAssertTrue(audio.hasReachedEnd(at: 9_999))
    }

    func testPaddingCannotSeekBeforeTheStartOfTheFile() {
        // The first sentence of an episode starts at or near zero.
        let audio = ModelAudio.original(startMs: 40, endMs: 2_000)
        XCTAssertEqual(audio.playbackWindow?.start, 0)
    }

    func testSynthesisHasNoWindowAndNeverEnds() {
        // A card example is written, not spoken in the episode, and a pattern is a frame
        // nobody said verbatim — there is no span to bound.
        let audio = ModelAudio.synthesised
        XCTAssertNil(audio.playbackWindow)
        XCTAssertFalse(audio.hasReachedEnd(at: 999_999),
                       "the synthesiser reports its own completion")
    }
}
