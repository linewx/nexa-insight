import Foundation

/// The result of actually contacting the backend, as something the UI can render.
///
/// The existing indicator said "Backend URL looks valid" after parsing the STRING — it never
/// sent a request. A green dot beside a URL that cannot be reached is worse than no dot,
/// because it answers the question the learner was asking ("is this right?") with the wrong
/// question ("is this a URL?").
enum BackendReachability: Equatable {
    /// Not asked yet, or the URL changed since the last check.
    case untested
    case checking
    /// The backend answered and looks like our backend.
    case reachable(episodeCount: Int)
    /// Something answered, but not our API — usually a proxy, a captive portal, or the wrong
    /// port. Worth distinguishing: the URL is fine and the target is not.
    case wrongService(String)
    case unreachable(String)

    var isChecking: Bool { self == .checking }
}

/// Turns a probe outcome into a verdict. Pure, so the mapping is testable without a server.
enum BackendProbe {
    /// How long to wait. `URLSession.shared` defaults to a 7-day resource timeout, so a
    /// half-open connection would leave the button spinning until the app was killed — the
    /// same trap that made an import hang on "Saving to your library".
    static let timeout: TimeInterval = 6

    /// - Parameters:
    ///   - status: HTTP status, or nil when the request never completed.
    ///   - decodedEpisodes: episode count if the body parsed as our API's response.
    ///   - error: transport-level failure description, if any.
    static func verdict(status: Int?, decodedEpisodes: Int?, error: String?) -> BackendReachability {
        if let error { return .unreachable(error) }
        guard let status else { return .unreachable("No response") }
        guard (200..<300).contains(status) else {
            // A 404 on /api/episodes means something is serving that host and port, but it is
            // not this backend. Saying "unreachable" would send the learner to check their
            // network when the address is the problem.
            return .wrongService("Reached the server, but it returned \(status)")
        }
        guard let decodedEpisodes else {
            return .wrongService("Reached the server, but the response was not the Nexa API")
        }
        return .reachable(episodeCount: decodedEpisodes)
    }
}
