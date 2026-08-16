import Foundation

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var episodes: [EpisodeDTO] = []
    @Published private(set) var tasks = ImportTaskStore()
    @Published private(set) var submissionError: String?

    private var client: BackendClient
    private let store: EpisodeStore

    init(client: BackendClient, store: EpisodeStore) {
        self.client = client; self.store = store
        reload()
    }

    var backendBaseURL: URL { client.baseURL }

    func updateClient(_ client: BackendClient) {
        self.client = client
    }

    func reload() { episodes = store.downloadedEpisodes() }

    func task(for episodeId: Int) -> ImportTask? { tasks.task(for: episodeId) }

    var hasTasks: Bool { !tasks.ordered.isEmpty }

    static func normalizedYouTubeURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    @discardableResult
    func startImport(urlString: String) async -> Bool {
        submissionError = nil
        let sourceURL = Self.normalizedYouTubeURL(urlString)
        do {
            let (episode, job) = try await client.importEpisode(url: sourceURL)
            start(task: ImportTask(episode: episode, job: job, kind: .importing))
            return true
        } catch {
            submissionError = "\(error.localizedDescription)\nBackend: \(client.baseURL.absoluteString)\nURL: \(sourceURL)"
            return false
        }
    }

    private func start(task: ImportTask) {
        tasks.upsert(task)
        Task { await poll(task: task) }
    }

    private func poll(task: ImportTask) async {
        var policy = ImportPollPolicy()
        var latest = task
        while true {
            var delay = ImportPollPolicy.baseRetryDelay
            do {
                let job = try await client.episodeJob(task.episodeId)
                policy.afterSuccess()
                latest = ImportTask(episode: task.episode, job: job, kind: task.kind)
                tasks.upsert(latest)
                if job.status == "complete" {
                    // Only the download may throw here, and giving up on it would
                    // freeze the card at its last percentage with no way into the
                    // episode, so it retries under the same policy.
                    do {
                        try await finishDownload(episodeId: task.episodeId)
                        tasks.remove(episodeId: task.episodeId)
                        return
                    } catch {
                        NSLog("[import] finishDownload threw: %@ (status %@)",
                              String(describing: error),
                              Self.httpStatus(of: error).map(String.init) ?? "none")
                        if policy.afterError(status: Self.httpStatus(of: error)) == .giveUp {
                            markFailed(latest, error: error.localizedDescription)
                            return
                        }
                        delay = policy.retryDelay
                    }
                } else if job.status == "failed" {
                    // The backend saying so is the only real failure.
                    markFailed(latest, error: job.error ?? "Processing failed")
                    return
                }
            } catch {
                if policy.afterError(status: Self.httpStatus(of: error)) == .giveUp {
                    markFailed(latest, error: error.localizedDescription)
                    return
                }
                delay = policy.retryDelay
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func markFailed(_ task: ImportTask, error: String) {
        tasks.upsert(ImportTask(
            episode: task.episode,
            job: JobDTO(id: task.jobId, episodeId: task.episodeId, stage: task.job.stage,
                        status: "failed", progress: task.progress, error: error),
            kind: task.kind))
    }

    /// BackendClient throws NSError(domain: "Backend", code: <status>); transport
    /// failures carry a URLError domain instead, which has no HTTP status.
    private static func httpStatus(of error: Error) -> Int? {
        let nsError = error as NSError
        return nsError.domain == "Backend" ? nsError.code : nil
    }

    private func finishDownload(episodeId: Int) async throws {
        // TEMPORARY: which of the four steps the stuck "Saving to your library" is in.
        NSLog("[import] finishDownload %d: fetching bundle", episodeId)
        let bundle = try await client.bundle(episodeId)
        NSLog("[import] bundle ok: sentences=%d hasAudio=%@",
              bundle.sentences.count, bundle.hasAudio ? "yes" : "no")
        var localPath: String? = nil
        if bundle.hasAudio {
            let destination = AudioFiles.audioURL(forEpisode: episodeId)
            NSLog("[import] downloading audio to %@", destination.path)
            try await client.downloadAudio(episodeId, to: destination)
            NSLog("[import] audio saved")
            localPath = AudioFiles.relativePath(forEpisode: episodeId)
        }
        NSLog("[import] saving bundle to the store")
        _ = try store.saveBundle(bundle, localAudioPath: localPath)
        NSLog("[import] finishDownload %d complete", episodeId)
        reload()
    }

    func retry(task: ImportTask) async {
        // A reprocess request can fail before the server creates a job. Its
        // synthetic negative ID must retry the request itself, not /jobs/{id}.
        if task.kind == .reprocessing, task.jobId < 0 {
            tasks.remove(episodeId: task.episodeId)
            await resyncContent(episodeId: task.episodeId)
            return
        }
        do {
            let job = try await client.retryJob(task.jobId)
            start(task: ImportTask(episode: task.episode, job: job, kind: task.kind))
        } catch {
            tasks.upsert(ImportTask(
                episode: task.episode,
                job: JobDTO(id: task.jobId, episodeId: task.episodeId, stage: task.job.stage,
                            status: "failed", progress: task.progress,
                            error: error.localizedDescription),
                kind: task.kind))
        }
    }

    // Ask the backend to rebuild transcript/chapters/translations, then replace
    // the local bundle and audio. A plain bundle download would only copy the
    // stale parse again, which made "re-sync" appear to do nothing.
    func resyncContent(episodeId: Int) async {
        guard tasks.task(for: episodeId) == nil,
              let episode = episodes.first(where: { $0.id == episodeId })
        else { return }
        do {
            let (_, job) = try await client.reprocessEpisode(episodeId)
            start(task: ImportTask(episode: episode, job: job, kind: .reprocessing))
        } catch {
            tasks.upsert(ImportTask(
                episode: episode,
                job: JobDTO(id: -episodeId, episodeId: episodeId, stage: "reprocessing",
                            status: "failed", progress: 0, error: error.localizedDescription),
                kind: .reprocessing))
        }
    }
}
