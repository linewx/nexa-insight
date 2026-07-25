import XCTest
@testable import NexaInsightCore

@MainActor
final class ImportViewModelTests: XCTestCase {
    func testProgressPercentFromJob() {
        let job = JobDTO(id: 1, episodeId: 1, stage: "translation", status: "running", progress: 72, error: nil)
        let progress = ImportViewModel.progress(from: job)
        XCTAssertEqual(progress.stage, "translation")
        XCTAssertEqual(progress.percent, 72)
    }

    func testAudioURLPathIsStableAndRelativePathDerivable() {
        let url = AudioFiles.audioURL(forEpisode: 42)
        XCTAssertTrue(url.path.hasSuffix("audio/42.mp3"))
        XCTAssertEqual(AudioFiles.relativePath(forEpisode: 42), "audio/42.mp3")
    }

    func testReloadReadsFromStore() throws {
        let store = try EpisodeStore(inMemory: true)
        _ = try store.saveBundle(
            BundleDTO(episode: EpisodeDTO(id: 1, sourceUrl: "u", youtubeId: nil, title: "Local", channel: nil, durationMs: nil, thumbnailUrl: nil, audioPath: nil, status: "ready", error: nil),
                      chapters: [], sentences: [], hasAudio: false),
            localAudioPath: nil)
        let vm = ImportViewModel(client: BackendClient(baseURL: URL(string: "http://localhost:8000")!), store: store)
        vm.reload()
        XCTAssertEqual(vm.episodes.first?.title, "Local")
    }

    func testBackendClientCanBeUpdatedAfterSettingsChange() throws {
        let store = try EpisodeStore(inMemory: true)
        let vm = ImportViewModel(client: BackendClient(baseURL: URL(string: "http://localhost:8000")!), store: store)
        vm.updateClient(BackendClient(baseURL: URL(string: "http://100.64.0.1:8000")!))
        XCTAssertEqual(vm.backendBaseURL.absoluteString, "http://100.64.0.1:8000")
    }

    func testNormalizeYouTubeURLAddsHTTPSWhenSchemeIsMissing() {
        XCTAssertEqual(
            ImportViewModel.normalizedYouTubeURL("youtube.com/watch?v=9IMwRIei-Xc&t=347s"),
            "https://youtube.com/watch?v=9IMwRIei-Xc&t=347s")
        XCTAssertEqual(
            ImportViewModel.normalizedYouTubeURL("https://www.youtube.com/watch?v=9IMwRIei-Xc&t=347s"),
            "https://www.youtube.com/watch?v=9IMwRIei-Xc&t=347s")
    }
}
