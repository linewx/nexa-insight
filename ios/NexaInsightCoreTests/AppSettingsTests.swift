import XCTest
@testable import NexaInsightCore

final class AppSettingsTests: XCTestCase {
    func testDefaultBackendBaseURLMatchesRuntimeEnvironment() {
        #if targetEnvironment(simulator)
        XCTAssertEqual(AppSettings.defaultBackendBaseURL, "http://localhost:8000")
        #else
        XCTAssertEqual(AppSettings.defaultBackendBaseURL, "http://100.64.0.1:8000")
        #endif
    }

    func testResolveBackendBaseURLKeepsTailnetHTTPHost() {
        XCTAssertEqual(
            AppSettings.resolveBackendBaseURL("http://mac-mini-2.tail.ganlin1981.online:8000"),
            "http://mac-mini-2.tail.ganlin1981.online:8000")
    }

    func testResolveBackendBaseURLKeepsCustomValue() {
        XCTAssertEqual(
            AppSettings.resolveBackendBaseURL("https://example.com"),
            "https://example.com")
    }
}
