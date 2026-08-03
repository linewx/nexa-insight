import XCTest
@testable import NexaInsightCore

final class DashScopePracticeClientTests: XCTestCase {
    func testParsesScoreFromStreamedJSON() throws {
        let result = try DashScopePracticeResult.parse("""
        ```json
        {"overall":86,"clarity":88,"stress_rhythm":82,"completeness":90,"advice":"注意 how 的重音。"}
        ```
        """)

        XCTAssertEqual(result.overall, 86)
        XCTAssertEqual(result.stressRhythm, 82)
        XCTAssertEqual(result.advice, "注意 how 的重音。")
    }

    func testRejectsScoresOutsideAllowedRange() {
        XCTAssertThrowsError(try DashScopePracticeResult.parse("""
        {"overall":101,"clarity":88,"stress_rhythm":82,"completeness":90,"advice":"tip"}
        """))
    }
}
