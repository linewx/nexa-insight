import XCTest
@testable import NexaInsightCore

final class AudioRouteLogicTests: XCTestCase {
    // Live keeps the mic open while the teacher talks, so it is only safe when the
    // teacher's voice cannot reach the mic. On a speaker it self-triggers the VAD
    // into an endless answer loop.
    func testLiveOnlyOnHeadphones() {
        XCTAssertTrue(liveModeAvailable(.headphones))
        XCTAssertFalse(liveModeAvailable(.speaker))
    }

    // An unreported route must gate Live OFF: guessing "probably headphones" is
    // what would reintroduce the loop.
    func testUnknownRouteIsTreatedAsUnsafe() {
        XCTAssertFalse(liveModeAvailable(.unknown))
    }

    // The refusal has to name the cause and the alternative, not just say no.
    func testUnavailableMessageNamesCauseAndAlternative() {
        let message = liveUnavailableMessage(.speaker)
        XCTAssertTrue(message.contains("耳机"))
        XCTAssertTrue(message.contains("按住说话"))
    }
}
