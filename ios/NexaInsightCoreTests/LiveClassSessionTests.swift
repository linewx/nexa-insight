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

    func testNoticeClearsItself() async throws {
        let session = LiveClassSession(store: try EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        session.noticeLifetime = .milliseconds(60)
        session.showNotice("Paused at 1:20")
        XCTAssertEqual(session.notice, "Paused at 1:20")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.notice, "", "a playback notice is transient")
    }

    // A later notice must not be cleared early by the previous one's timer.
    func testLatestNoticeOwnsItsFullLifetime() async throws {
        let session = LiveClassSession(store: try EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        session.noticeLifetime = .milliseconds(120)
        session.showNotice("Paused at 1:20")
        try await Task.sleep(for: .milliseconds(80))
        session.showNotice("Podcast playing")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(session.notice, "Podcast playing", "the first timer must not clear the second notice")
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

    // Liveness and reconnecting live behind `#if os(iOS)` because they read the WebRTC
    // transport, so these only compile there. The tests run on macOS too, hence the
    // guard rather than a move.
#if os(iOS)
    // A session that never connected cannot carry a turn. The interesting half is the
    // test below: `connected` alone was the old check, and it stays true after the
    // server drops an idle stream.
    func testAFreshSessionCannotCarryATurn() throws {
        let session = LiveClassSession(store: try EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        XCTAssertFalse(session.canCarryATurn)
    }

    // Reconnecting with no credentials must fail loudly rather than leave the caller
    // waiting: this is the path a hold takes after the 300s idle timeout, and silence
    // there is what made the feature look broken in the first place.
    func testReconnectWithoutCredentialsReportsWhyRatherThanHanging() async throws {
        let session = LiveClassSession(store: try EpisodeStore(inMemory: true), keychain: KeychainStore(),
                                       episodeId: 1, playback: FakePlayback())
        await session.reconnectIfNeeded()
        XCTAssertFalse(session.canCarryATurn)
        XCTAssertNotNil(session.error, "a failed reconnect has to say something")
    }
#endif
}
