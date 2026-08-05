import XCTest
@testable import NexaInsightCore

final class CredentialSummaryTests: XCTestCase {
    private func services(
        dashscope: String = "", workspace: String = "", youtube: String = "", openAI: String = ""
    ) -> [CredentialSummary.Service] {
        CredentialSummary.services(
            dashscopeKey: dashscope, workspaceId: workspace, youtubeAPIKey: youtube, openAIKey: openAI)
    }

    func testServiceNeedingTwoFieldsIsNotConfiguredWithOnlyOne() {
        // Reporting the classroom ready on the key alone sent you to a Talk button
        // that could not connect.
        let partial = services(dashscope: "sk-live").first { $0.id == "dashscope" }
        XCTAssertEqual(partial?.isConfigured, false)

        let complete = services(dashscope: "sk-live", workspace: "llm-123").first { $0.id == "dashscope" }
        XCTAssertEqual(complete?.isConfigured, true)
    }

    func testWhitespaceOnlyValueDoesNotCountAsConfigured() {
        let padded = services(youtube: "   ").first { $0.id == "youtube" }
        XCTAssertEqual(padded?.isConfigured, false)
    }

    func testRootSummaryCountsConfiguredServices() {
        XCTAssertEqual(CredentialSummary.rootSummary(services()), "\u{672a}\u{914d}\u{7f6e}")
        XCTAssertEqual(
            CredentialSummary.rootSummary(services(youtube: "yt")),
            "1/3 \u{5df2}\u{914d}\u{7f6e}")
        XCTAssertEqual(
            CredentialSummary.rootSummary(services(dashscope: "d", workspace: "w", youtube: "y", openAI: "o")),
            "\u{5168}\u{90e8}\u{5df2}\u{914d}\u{7f6e}")
    }

    func testPartlyFilledServiceDoesNotInflateTheRootCount() {
        // The workspace id is missing, so the classroom must not be counted.
        XCTAssertEqual(
            CredentialSummary.rootSummary(services(dashscope: "d", youtube: "y")),
            "1/3 \u{5df2}\u{914d}\u{7f6e}")
    }

    func testFieldStateDistinguishesSavedFromEmpty() {
        XCTAssertEqual(CredentialSummary.fieldState("sk-live"), .saved)
        XCTAssertEqual(CredentialSummary.fieldState(""), .empty)
        XCTAssertEqual(CredentialSummary.fieldState("  "), .empty)
    }
}
