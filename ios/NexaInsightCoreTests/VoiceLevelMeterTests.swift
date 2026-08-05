import XCTest
@testable import NexaInsightCore

final class VoiceLevelMeterTests: XCTestCase {
    func testSilenceMapsToTheFloor() {
        XCTAssertEqual(VoiceLevelMeter.normalized(-60), 0)
        XCTAssertEqual(VoiceLevelMeter.normalized(VoiceLevelMeter.silenceFloor), 0)
    }

    func testFullScaleMapsToOne() {
        XCTAssertEqual(VoiceLevelMeter.normalized(0), 1, accuracy: 0.001)
    }

    func testInfiniteReadingIsTreatedAsSilenceRatherThanCrashing() {
        // AVAudioRecorder reports -inf before the first buffer arrives.
        XCTAssertEqual(VoiceLevelMeter.normalized(-.infinity), 0)
        XCTAssertEqual(VoiceLevelMeter.normalized(.nan), 0)
    }

    func testConversationalSpeechIsSpreadAcrossTheScale() {
        // The reason for the curve: these are the levels ordinary speech sits at,
        // and a linear map would bunch them all above 0.7 where bars look static.
        let quiet = VoiceLevelMeter.normalized(-30)
        let normal = VoiceLevelMeter.normalized(-15)
        let loud = VoiceLevelMeter.normalized(-5)

        XCTAssertLessThan(quiet, normal)
        XCTAssertLessThan(normal, loud)
        // Each step must be visible, not a few percent apart.
        XCTAssertGreaterThan(normal - quiet, 0.1)
        XCTAssertGreaterThan(loud - normal, 0.1)
    }

    func testSamplesAreCappedToTheBarCount() {
        var samples: [Float] = []
        for _ in 0..<(VoiceLevelMeter.barCount * 2) {
            samples = VoiceLevelMeter.appending(-10, to: samples)
        }
        XCTAssertEqual(samples.count, VoiceLevelMeter.barCount)
    }

    func testOldestSampleIsDroppedFirst() {
        var samples = VoiceLevelMeter.appending(0, to: [])
        for _ in 0..<VoiceLevelMeter.barCount {
            samples = VoiceLevelMeter.appending(-50, to: samples)
        }
        // The full-scale first reading has scrolled off.
        XCTAssertFalse(samples.contains(1))
    }

    func testSilentTakeIsRejectedBeforeSpendingARequest() {
        let silence = Array(repeating: Float(0), count: VoiceLevelMeter.barCount)
        XCTAssertFalse(VoiceLevelMeter.carriesSpeech(silence))
    }

    func testTakeWithSpeechIsAccepted() {
        var samples = Array(repeating: Float(0), count: 10)
        samples.append(VoiceLevelMeter.normalized(-12))
        XCTAssertTrue(VoiceLevelMeter.carriesSpeech(samples))
    }

    func testRoomNoiseAloneDoesNotCountAsSpeech() {
        // Just above the floor, the level a quiet room reads at. Note this is 0.20
        // after normalisation, not 0.02 — the square-root curve lifts the quiet end,
        // which is why the threshold is calibrated against the curve rather than
        // guessed as a small-looking number.
        let noise = (0..<12).map { _ in VoiceLevelMeter.normalized(-48) }
        XCTAssertFalse(VoiceLevelMeter.carriesSpeech(noise))
    }

    func testTheSpeechGateSitsBetweenRoomNoiseAndSpeech() {
        // Pins the calibration: anything a learner says toward the phone passes,
        // anything the room produces on its own does not.
        XCTAssertLessThan(VoiceLevelMeter.normalized(-48), VoiceLevelMeter.speechThreshold)
        XCTAssertLessThan(VoiceLevelMeter.normalized(-40), VoiceLevelMeter.speechThreshold)
        XCTAssertGreaterThan(VoiceLevelMeter.normalized(-30), VoiceLevelMeter.speechThreshold)
        XCTAssertGreaterThan(VoiceLevelMeter.normalized(-15), VoiceLevelMeter.speechThreshold)
    }
}
