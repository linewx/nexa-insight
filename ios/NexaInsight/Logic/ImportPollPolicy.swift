import Foundation

/// Decides whether a failed poll of an import job is worth retrying.
///
/// The poll used to mark the import failed on the first thrown error and stop.
/// Restarting the backend, or asking for a job row the moment before it became
/// visible, was enough to abandon an import that then ran to completion — and a
/// throw during the download stage left the card frozen at its last percentage
/// with no way to open the episode. A real failure only ever arrives as
/// `job.status == "failed"` from the backend, which the caller handles before
/// consulting this type.
struct ImportPollPolicy {
    enum Decision: Equatable {
        case retry
        case giveUp
    }

    static let baseRetryDelay: TimeInterval = 2
    static let maxRetryDelay: TimeInterval = 15

    /// How many consecutive failures to absorb before surfacing one.
    let failureThreshold: Int
    private(set) var consecutiveFailures = 0

    init(failureThreshold: Int = 5) {
        self.failureThreshold = max(1, failureThreshold)
    }

    /// Seconds to wait before polling again, growing with the failure run so a
    /// backend that is down does not get hammered every 2s.
    var retryDelay: TimeInterval {
        guard consecutiveFailures > 0 else { return Self.baseRetryDelay }
        let grown = Self.baseRetryDelay * pow(2, Double(consecutiveFailures - 1))
        return min(grown, Self.maxRetryDelay)
    }

    mutating func afterSuccess() {
        consecutiveFailures = 0
    }

    /// - Parameter status: HTTP status when the error carried one, else nil for
    ///   transport-level failures (connection refused, timeout, offline).
    mutating func afterError(status: Int?) -> Decision {
        // The job row is not visible yet. Waiting is the whole remedy, and this
        // must not count toward the failure run or a slow-to-commit import would
        // still be abandoned.
        if status == 404 { return .retry }

        // Anything else in 4xx is a rejected request; polling again cannot fix
        // the URL or the payload. 5xx and transport errors are usually a restart
        // or a blip, which is exactly what this policy exists to ride out.
        if let status, (400..<500).contains(status) {
            consecutiveFailures = failureThreshold
            return .giveUp
        }

        consecutiveFailures += 1
        return consecutiveFailures >= failureThreshold ? .giveUp : .retry
    }
}
