import XCTest
@testable import NexaInsightCore

/// A poll that gave up on the first thrown error reported a failed import while
/// the backend ran to completion — and when the throw landed mid-download the
/// card simply froze at its last percentage, so the episode could never be
/// opened. Only the backend saying `status == "failed"` is a real failure.
final class ImportPollPolicyTests: XCTestCase {
    func testTransientErrorRetriesInsteadOfFailing() {
        var policy = ImportPollPolicy()

        XCTAssertEqual(policy.afterError(status: nil), .retry)
        XCTAssertEqual(policy.afterError(status: nil), .retry)
    }

    func testMissingJobIsTreatedAsNotReadyYet() {
        var policy = ImportPollPolicy()

        // POST /import can return before the job row is visible to GET /job.
        XCTAssertEqual(policy.afterError(status: 404), .retry)
        XCTAssertEqual(policy.consecutiveFailures, 0, "404 is not a failure, it is a wait")
    }

    func testGivesUpOnlyAfterRepeatedFailures() {
        var policy = ImportPollPolicy(failureThreshold: 3)

        XCTAssertEqual(policy.afterError(status: nil), .retry)
        XCTAssertEqual(policy.afterError(status: nil), .retry)
        XCTAssertEqual(policy.afterError(status: nil), .giveUp)
    }

    func testSuccessResetsTheFailureRun() {
        var policy = ImportPollPolicy(failureThreshold: 3)

        XCTAssertEqual(policy.afterError(status: nil), .retry)
        XCTAssertEqual(policy.afterError(status: nil), .retry)
        policy.afterSuccess()
        XCTAssertEqual(policy.consecutiveFailures, 0)

        // A blip earlier in the import must not count toward a later one.
        XCTAssertEqual(policy.afterError(status: nil), .retry)
        XCTAssertEqual(policy.afterError(status: nil), .retry)
        XCTAssertEqual(policy.afterError(status: nil), .giveUp)
    }

    func testClientErrorsOtherThan404FailImmediately() {
        var policy = ImportPollPolicy()

        // A 422 will not fix itself by waiting.
        XCTAssertEqual(policy.afterError(status: 422), .giveUp)
    }

    func testServerErrorsAreRetriedBecauseTheyAreOftenRestarts() {
        var policy = ImportPollPolicy(failureThreshold: 3)

        XCTAssertEqual(policy.afterError(status: 502), .retry)
        XCTAssertEqual(policy.afterError(status: 503), .retry)
    }

    func testBackoffGrowsbutIsCapped() {
        var policy = ImportPollPolicy(failureThreshold: 10)

        _ = policy.afterError(status: nil)
        let first = policy.retryDelay
        _ = policy.afterError(status: nil)
        let second = policy.retryDelay

        XCTAssertGreaterThan(second, first)
        for _ in 0..<20 { _ = policy.afterError(status: nil) }
        XCTAssertLessThanOrEqual(policy.retryDelay, ImportPollPolicy.maxRetryDelay)
    }
}
