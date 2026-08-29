import XCTest
@testable import NexaInsightCore

// Why the client does not use URLSession.shared.
//
// An import would sit on "Saving to your library" forever, and reopening the app found the episode
// ready — because the server had finished and only the app was stuck. The cause was the shared
// session's SEVEN-DAY resource timeout: a half-open connection never fails, it just never returns.
//
// The probe button was given its own short-timeout session for exactly this reason. The path that
// actually moves data — fetching the bundle, downloading the audio — was left on the default.
final class BackendSessionTimeoutTests: XCTestCase {
    func testTheClientSessionCannotHangForever() {
        let config = BackendClient.makeSession().configuration
        // The shared session's default is 604800. Anything near that is the bug.
        XCTAssertLessThanOrEqual(config.timeoutIntervalForResource, 900,
                                 "a stuck transfer must fail rather than hang")
        XCTAssertGreaterThan(config.timeoutIntervalForResource, 120,
                             "but an episode's audio is tens of megabytes — do not make it flaky")
        // Per-hop silence, so a slow download continues while a stalled one dies.
        XCTAssertLessThanOrEqual(config.timeoutIntervalForRequest, 60)
    }

    func testTheDefaultSessionIsNotTheSharedOne() {
        // `var session: URLSession = .shared` was the whole defect. A test on makeSession() alone
        // would pass while the client kept using the shared instance.
        XCTAssertNotEqual(BackendClient(baseURL: URL(string: "http://localhost:8000")!).session,
                          URLSession.shared)
    }

    func testATimeoutRetriesRatherThanGivingUp() {
        // The server has already done the work, so the right response to a timed-out download is to
        // try again — not to strand the card at its last percentage with no way into the episode.
        //
            // A URLError carries no HTTP status, so it takes the transport-failure path.
        var policy = ImportPollPolicy()
        XCTAssertEqual(policy.afterError(status: nil), .retry)
        XCTAssertEqual(policy.afterError(status: 500), .retry, "a restart is what this rides out")
        // But a rejected request cannot be fixed by asking again.
        XCTAssertEqual(policy.afterError(status: 422), .giveUp)
    }
}
