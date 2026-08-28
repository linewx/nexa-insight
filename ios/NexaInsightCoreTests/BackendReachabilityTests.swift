import XCTest
@testable import NexaInsightCore

final class BackendReachabilityTests: XCTestCase {
    func testAnAnsweringBackendIsReachable() {
        let verdict = BackendProbe.verdict(status: 200, decodedEpisodes: 7, error: nil)
        XCTAssertEqual(verdict, .reachable(episodeCount: 7))
    }

    func testAnEmptyLibraryIsStillReachable() {
        // Zero episodes is a working backend with nothing imported, not a failure.
        XCTAssertEqual(BackendProbe.verdict(status: 200, decodedEpisodes: 0, error: nil),
                       .reachable(episodeCount: 0))
    }

    func testSomethingElseAnsweringIsNotUnreachable() {
        // A proxy, a captive portal, or the right host on the wrong port. Calling this
        // "unreachable" sends the learner to check their network when the ADDRESS is wrong.
        guard case .wrongService = BackendProbe.verdict(status: 404, decodedEpisodes: nil, error: nil) else {
            return XCTFail("a 404 means the address is wrong, not the network")
        }
        guard case .wrongService = BackendProbe.verdict(status: 200, decodedEpisodes: nil, error: nil) else {
            return XCTFail("200 with an unparseable body is not our API")
        }
    }

    func testATransportFailureIsUnreachable() {
        guard case let .unreachable(message) = BackendProbe.verdict(
            status: nil, decodedEpisodes: nil, error: "Could not connect to the server.") else {
            return XCTFail("expected unreachable")
        }
        XCTAssertEqual(message, "Could not connect to the server.")
    }

    func testNoResponseAndNoErrorIsStillUnreachable() {
        // Belt and braces: neither a status nor an error means nothing came back.
        guard case .unreachable = BackendProbe.verdict(status: nil, decodedEpisodes: nil, error: nil) else {
            return XCTFail("expected unreachable")
        }
    }

    func testTheProbeHasATimeoutAtAll() {
        // URLSession.shared defaults to a SEVEN DAY resource timeout, which is how an import
        // once hung on "Saving to your library" forever. A test button with no timeout would
        // spin until the app was killed.
        XCTAssertLessThanOrEqual(BackendProbe.timeout, 10)
        XCTAssertGreaterThan(BackendProbe.timeout, 1)
    }
}
