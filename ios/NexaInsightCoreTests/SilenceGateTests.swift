import XCTest
@testable import NexaInsightCore

final class SilenceGateTests: XCTestCase {
    /// Feeds samples at 20 Hz, the rate the recorder meters at, and returns when the gate
    /// first decides — so a test reads as "they spoke for a second, then stopped".
    private func run(_ script: [(power: Float, seconds: TimeInterval)]) -> (SilenceGate.Decision, TimeInterval) {
        var gate = SilenceGate()
        var elapsed: TimeInterval = 0
        let step: TimeInterval = 0.05
        for phase in script {
            var remaining = phase.seconds
            while remaining > 0 {
                let decision = gate.observe(power: phase.power, elapsed: elapsed)
                if decision != .keepGoing { return (decision, elapsed) }
                elapsed += step
                remaining -= step
            }
        }
        return (.keepGoing, elapsed)
    }

    private let speech: Float = -20
    private let quiet: Float = -55

    func testATakeEndsWhenTheLearnerStopsSpeaking() {
        let (decision, at) = run([(speech, 2.0), (quiet, 3.0)])
        XCTAssertEqual(decision, .finished)
        // Ends shortly after the silence threshold is met, not at the end of the script.
        XCTAssertEqual(at, 2.0 + SilenceGate.silenceDuration, accuracy: 0.15)
    }

    func testAPauseBetweenClausesDoesNotEndTheTake() {
        // "I have you here ... for two nights" — a real frame with a real pause in it.
        //
        // Asserting only `.finished` proves nothing: a threshold short enough to fire INSIDE
        // the pause also reports finished, just at the wrong moment. The time is the test.
        let (decision, at) = run([(speech, 1.0), (quiet, 0.6), (speech, 1.0), (quiet, 3.0)])
        XCTAssertEqual(decision, .finished)
        XCTAssertEqual(at, 2.6 + SilenceGate.silenceDuration, accuracy: 0.15,
                       "the take must end after the SECOND clause, not inside the pause")
    }

    func testSilenceBeforeAnySpeechIsNotATake() {
        // Opened by accident, or the learner never spoke: there is nothing to score, and
        // reporting a take would send an empty recording for evaluation.
        let (decision, at) = run([(quiet, 10)])
        XCTAssertEqual(decision, .nothingSaid)
        XCTAssertEqual(at, SilenceGate.noSpeechTimeout, accuracy: 0.15)
    }

    func testAQuietStartIsStillWaitedOut() {
        // A beat of hesitation before speaking must not be read as "nothing said".
        let (decision, _) = run([(quiet, 2.0), (speech, 1.0), (quiet, 3.0)])
        XCTAssertEqual(decision, .finished)
    }

    func testAnEndlessTakeIsCutOffAndStillScored() {
        let (decision, at) = run([(speech, 60)])
        XCTAssertEqual(decision, .finished, "something was said, so it is worth scoring")
        XCTAssertEqual(at, SilenceGate.maxDuration, accuracy: 0.15)
    }

    func testEndlessNoiseWithNoSpeechIsNotATake() {
        // Sustained sound below the speech threshold — a fan, a bus — must not become a take.
        let (decision, at) = run([(SilenceGate.silenceThreshold - 1, 60)])
        XCTAssertEqual(decision, .nothingSaid)
        XCTAssertEqual(at, SilenceGate.noSpeechTimeout, accuracy: 0.15)
    }
}
