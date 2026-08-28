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

extension BackendReachabilityTests {
    func testOnlyAddressesWorthProbingArePassedThrough() {
        // URL(string:) is far more permissive than it looks. Each of these produces a URL, so
        // a bare nil-check let a typo through and reported the resulting failure as
        // "unreachable" — blaming the network for a missing scheme.
        for bad in ["", "hello", "localhost:8000", "http://", "not a url", "ftp://host"] {
            XCTAssertNil(BackendProbe.usable(bad), bad)
        }
        XCTAssertNotNil(BackendProbe.usable("http://localhost:8000"))
        XCTAssertNotNil(BackendProbe.usable("https://nexa.example.com"))
        // Trailing whitespace is what a paste from a terminal leaves behind.
        XCTAssertNotNil(BackendProbe.usable("  http://100.64.0.1:8000 "))
    }
}
