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

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // Off by default: a ja-JP device would otherwise show "3\u{65e5}\u{524d}" next to
    // English titles.
    func testLocalizedBylinesDefaultsOff() {
        let settings = AppSettings(defaults: isolatedDefaults("AppSettingsTests.bylineOff"))
        XCTAssertFalse(settings.localizedBylines)
        XCTAssertEqual(settings.bylineLocale.identifier, DiscoverFormat.defaultLocale.identifier)
    }

    func testLocalizedBylinesOnUsesCurrentLocale() {
        let settings = AppSettings(defaults: isolatedDefaults("AppSettingsTests.bylineOn"))
        settings.localizedBylines = true
        XCTAssertEqual(settings.bylineLocale.identifier, Locale.current.identifier)
    }

    func testLocalizedBylinesPersists() {
        let d = isolatedDefaults("AppSettingsTests.bylinePersist")
        AppSettings(defaults: d).localizedBylines = true
        XCTAssertTrue(AppSettings(defaults: d).localizedBylines)
    }
}
