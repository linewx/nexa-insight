import XCTest
@testable import NexaInsightCore

final class FakeRecorder: ShadowingRecording {
    private(set) var started: [URL] = []
    private(set) var stopped = 0
    func start(to url: URL) throws { started.append(url) }
    @discardableResult func stop() -> URL? { stopped += 1; return started.last }
}

@MainActor
final class ShadowingViewModelTests: XCTestCase {
    private func seededStore() throws -> EpisodeStore {
        let store = try EpisodeStore(inMemory: true)
        _ = try store.saveBundle(
            BundleDTO(episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: nil, title: "T", channel: nil, durationMs: nil, thumbnailUrl: nil, audioPath: nil, status: "ready", error: nil),
                      chapters: [], sentences: [SentenceDTO(id: 10, episodeId: 1, chapterId: nil, position: 0, startMs: 0, endMs: 500, speaker: nil, sourceText: "Hi", chinese: "嗨")], hasAudio: false),
            localAudioPath: nil)
        return store
    }

    func testCanRequestFeedbackRequiresKey() {
        XCTAssertFalse(ShadowingViewModel.canRequestFeedback(hasKey: false))
        XCTAssertTrue(ShadowingViewModel.canRequestFeedback(hasKey: true))
    }

    func testRecordStartStopPersists() throws {
        let store = try seededStore()
        let recorder = FakeRecorder()
        let vm = ShadowingViewModel(store: store, keychain: KeychainStore(), recorder: recorder)
        vm.startRecording(episodeId: 1, sentenceId: 10)
        XCTAssertTrue(vm.isRecording)
        XCTAssertEqual(recorder.started.count, 1)
        vm.stopRecording(episodeId: 1, sentenceId: 10)
        XCTAssertFalse(vm.isRecording)
        XCTAssertEqual(recorder.stopped, 1)
        XCTAssertEqual(vm.recordings.count, 1)
    }

    func testOrderedRecordingsBestFirst() throws {
        let store = try seededStore()
        let vm = ShadowingViewModel(store: store, keychain: KeychainStore(), recorder: FakeRecorder())
        _ = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "a.m4a")
        let b = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "b.m4a")
        try store.markBest(recordingId: b.persistentModelID)
        vm.reload(sentenceId: 10)
        XCTAssertTrue(vm.orderedRecordings().first?.isBest ?? false)
    }

    func testFeedbackMissingKeyReportsError() async throws {
        let store = try seededStore()
        let vm = ShadowingViewModel(store: store, keychain: KeychainStore(), recorder: FakeRecorder())
        let rec = try store.addRecording(episodeId: 1, sentenceId: 10, localFilePath: "a.m4a")
        vm.reload(sentenceId: 10)
        // With no OpenAI key stored, requesting feedback must surface the guidance
        // error rather than attempt a network call.
        KeychainStore().delete(.openAIKey)
        await vm.requestFeedback(recording: rec, sentenceText: "Hi", sentenceId: 10)
        XCTAssertNotNil(vm.feedbackError)
    }
}

final class OpenAITutorClientTests: XCTestCase {
    func testMissingKeyThrowsBeforeNetwork() async {
        let client = OpenAITutorClient(apiKey: "")
        do {
            _ = try await client.shadowingFeedback(sentence: "Hi", recordingURL: URL(fileURLWithPath: "/tmp/none.m4a"))
            XCTFail("expected missingKey error")
        } catch let error as OpenAITutorClient.TutorError {
            XCTAssertEqual(error, .missingKey)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
