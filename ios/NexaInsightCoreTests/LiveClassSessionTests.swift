import XCTest
@testable import NexaInsightCore

@MainActor
final class LiveClassSessionTests: XCTestCase {
    func testReadinessRequiresKeyAndWorkspace() {
        XCTAssertFalse(LiveClassSession.readiness(dashscopeKey: nil, workspaceId: "w").configured)
        XCTAssertFalse(LiveClassSession.readiness(dashscopeKey: "k", workspaceId: "").configured)
        let ok = LiveClassSession.readiness(dashscopeKey: "k", workspaceId: "w")
        XCTAssertTrue(ok.configured)
        XCTAssertNil(ok.message)
        let bad = LiveClassSession.readiness(dashscopeKey: nil, workspaceId: nil)
        XCTAssertEqual(bad.message, "Configure DashScope API Key and Workspace ID to start live class")
    }

    func testInitialInstructionsEmbedMaterial() throws {
        let session = LiveClassSession(store: try EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        let text = session.buildInitialInstructions(
            episodeTitle: "T", channel: "C",
            chapters: [ChapterDTO(id: 1, title: "Intro", summary: "s", startMs: 0, endMs: 1000)],
            sentences: [SentenceDTO(id: 0, episodeId: 1, chapterId: 1, position: 0, startMs: 0, endMs: 500, speaker: nil, sourceText: "Hi", chinese: "嗨")],
            startMs: 0)
        XCTAssertTrue(text.contains("Episode: T · C"))
        XCTAssertTrue(text.contains("Classroom material:"))
    }

    func testContextForBuildsWindowAtPosition() throws {
        let session = LiveClassSession(store: try EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        session.loadContent(
            episodeTitle: "T", channel: "C",
            chapters: [ChapterDTO(id: 1, title: "C1", summary: "s", startMs: 0, endMs: 5000)],
            sentences: [SentenceDTO(id: 0, episodeId: 1, chapterId: 1, position: 0, startMs: 2000, endMs: 3000, speaker: nil, sourceText: "Mid", chinese: "中")])
        XCTAssertTrue(session.contextFor(2500).contains("Mid / 中"))
    }
}
