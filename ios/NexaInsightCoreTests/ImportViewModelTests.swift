import XCTest
@testable import NexaInsightCore

@MainActor
final class ImportViewModelTests: XCTestCase {
    func testTaskStoreKeepsTasksForSeparateEpisodes() {
        var tasks = ImportTaskStore()
        tasks.upsert(ImportTask(
            episode: episode(id: 1, youtubeId: "first"),
            job: JobDTO(id: 11, episodeId: 1, stage: "metadata", status: "queued", progress: 0, error: nil),
            kind: .importing))
        tasks.upsert(ImportTask(
            episode: episode(id: 2, youtubeId: "second"),
            job: JobDTO(id: 22, episodeId: 2, stage: "transcribing", status: "running", progress: 42, error: nil),
            kind: .reprocessing))

        XCTAssertEqual(tasks.task(for: 1)?.jobId, 11)
        XCTAssertEqual(tasks.task(for: 2)?.progress, 42)
        XCTAssertEqual(tasks.ordered.map(\.episodeId), [1, 2])
    }

    // A Discover card knows its videoId and nothing about episode ids, so this set is the
    // only way it can tell that IT is the one being fetched. Before it existed both call
    // sites passed `importing: false` unconditionally: the ➕ changed nothing on tap, and a
    // failure had nowhere to appear — success and failure looked identical.
    func testImportingYouTubeIdsCoversOnlyWorkStillInFlight() {
        var tasks = ImportTaskStore()
        tasks.upsert(ImportTask(
            episode: episode(id: 1, youtubeId: "running"),
            job: JobDTO(id: 11, episodeId: 1, stage: "transcribing", status: "running", progress: 40, error: nil),
            kind: .importing))
        tasks.upsert(ImportTask(
            episode: episode(id: 2, youtubeId: "queued"),
            job: JobDTO(id: 22, episodeId: 2, stage: "metadata", status: "queued", progress: 0, error: nil),
            kind: .importing))
        // Finished and failed both stop the clock glyph: one becomes a tick, the other has
        // to be tappable again rather than stuck showing progress forever.
        tasks.upsert(ImportTask(
            episode: episode(id: 3, youtubeId: "done"),
            job: JobDTO(id: 33, episodeId: 3, stage: "complete", status: "complete", progress: 100, error: nil),
            kind: .importing))
        tasks.upsert(ImportTask(
            episode: episode(id: 4, youtubeId: "broken"),
            job: JobDTO(id: 44, episodeId: 4, stage: "transcribing", status: "failed", progress: 12, error: "boom"),
            kind: .importing))

        XCTAssertEqual(tasks.importingYouTubeIds, ["running", "queued"])
    }

    func testTaskStoreRemovesOnlyCompletedEpisode() {
        var tasks = ImportTaskStore()
        tasks.upsert(ImportTask(
            episode: episode(id: 1, youtubeId: "first"),
            job: JobDTO(id: 11, episodeId: 1, stage: "metadata", status: "queued", progress: 0, error: nil),
            kind: .importing))
        tasks.upsert(ImportTask(
            episode: episode(id: 2, youtubeId: "second"),
            job: JobDTO(id: 22, episodeId: 2, stage: "metadata", status: "queued", progress: 0, error: nil),
            kind: .importing))

        tasks.remove(episodeId: 1)

        XCTAssertNil(tasks.task(for: 1))
        XCTAssertEqual(tasks.task(for: 2)?.jobId, 22)
    }

    func testSyntheticFailedReprocessTaskIsIdentifiableForRequestRetry() {
        let task = ImportTask(
            episode: episode(id: 1, youtubeId: "first"),
            job: JobDTO(id: -1, episodeId: 1, stage: "reprocessing", status: "failed", progress: 0, error: "Offline"),
            kind: .reprocessing)

        XCTAssertTrue(task.isFailed)
        XCTAssertLessThan(task.jobId, 0)
    }

    func testCompleteJobIsATerminalStateDistinctFromInProgress() {
        // The card used to read "Preparing learning material · Ready to discuss"
        // with two 100% labels for the whole bundle+audio download, because
        // "complete" fell through to the in-progress branch.
        let task = ImportTask(
            episode: episode(id: 1, youtubeId: "first"),
            job: JobDTO(id: 30, episodeId: 1, stage: "complete", status: "complete", progress: 100, error: nil),
            kind: .importing)

        XCTAssertTrue(task.isComplete)
        XCTAssertFalse(task.isQueued)
        XCTAssertFalse(task.isFailed)
    }

    func testRunningJobIsNotReportedComplete() {
        let task = ImportTask(
            episode: episode(id: 1, youtubeId: "first"),
            job: JobDTO(id: 31, episodeId: 1, stage: "learning", status: "running", progress: 98, error: nil),
            kind: .importing)

        XCTAssertFalse(task.isComplete)
    }

    func testPlaybackTargetEmbedsYouTubeAndUsesSourcePageOtherwise() {
        XCTAssertEqual(
            LibraryPlaybackTarget.forEpisode(episode(id: 1, youtubeId: "abcdefghijk")),
            .youtube(videoId: "abcdefghijk"))
        XCTAssertEqual(
            LibraryPlaybackTarget.forEpisode(episode(id: 2, youtubeId: nil)),
            .web(URL(string: "https://example.com/talk")!))
    }

    func testPlaybackTargetRejectsAnInvalidSourceURL() {
        var invalid = episode(id: 1, youtubeId: nil)
        invalid = EpisodeDTO(id: invalid.id, sourceUrl: "not a URL", youtubeId: nil,
                             title: invalid.title, channel: invalid.channel,
                             durationMs: invalid.durationMs, thumbnailUrl: invalid.thumbnailUrl,
                             audioPath: invalid.audioPath, status: invalid.status,
                             error: invalid.error)
        XCTAssertEqual(LibraryPlaybackTarget.forEpisode(invalid), .unavailable)
    }

    func testTaskExposesProgressFromItsJob() {
        let job = JobDTO(id: 1, episodeId: 1, stage: "translation", status: "running", progress: 72, error: nil)
        let task = ImportTask(episode: episode(id: 1, youtubeId: nil), job: job, kind: .importing)
        XCTAssertEqual(task.job.stage, "translation")
        XCTAssertEqual(task.progress, 72)
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

    private func episode(id: Int, youtubeId: String?) -> EpisodeDTO {
        EpisodeDTO(id: id, sourceUrl: "https://example.com/talk", youtubeId: youtubeId,
                   title: "Episode \(id)", channel: "Channel", durationMs: 60_000,
                   thumbnailUrl: nil, audioPath: nil, status: "ready", error: nil)
    }
}
