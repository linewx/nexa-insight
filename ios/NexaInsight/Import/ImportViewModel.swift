import Foundation

@MainActor
final class ImportViewModel: ObservableObject {
    struct ImportProgress: Equatable { let stage: String; let percent: Int }

    @Published var episodes: [EpisodeDTO] = []
    @Published var importing = false
    @Published var importError: String?
    @Published var progress: ImportProgress?

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

    static func progress(from job: JobDTO) -> ImportProgress {
        ImportProgress(stage: job.stage, percent: job.progress)
    }

    func reload() { episodes = store.downloadedEpisodes() }

    static func normalizedYouTubeURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    func startImport(urlString: String) async {
        importing = true; importError = nil; progress = nil
        defer { importing = false }
        let sourceURL = Self.normalizedYouTubeURL(urlString)
        do {
            let (episode, job) = try await client.importEpisode(url: sourceURL)
            await pollUntilReady(episodeId: episode.id, jobId: job.id)
        } catch {
            importError = "\(error.localizedDescription)\nBackend: \(client.baseURL.absoluteString)\nURL: \(sourceURL)"
        }
    }

    func pollUntilReady(episodeId: Int, jobId: Int) async {
        while true {
            do {
                let job = try await client.episodeJob(episodeId)
                progress = Self.progress(from: job)
                if job.status == "complete" {
                    try await finishDownload(episodeId: episodeId)
                    return
                }
                if job.status == "failed" {
                    importError = job.error ?? "Add failed"
                    return
                }
            } catch {
                importError = error.localizedDescription
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func finishDownload(episodeId: Int) async throws {
        let bundle = try await client.bundle(episodeId)
        var localPath: String? = nil
        if bundle.hasAudio {
            let destination = AudioFiles.audioURL(forEpisode: episodeId)
            try await client.downloadAudio(episodeId, to: destination)
            localPath = AudioFiles.relativePath(forEpisode: episodeId)
        }
        _ = try store.saveBundle(bundle, localAudioPath: localPath)
        reload()
        progress = nil
    }

    func retry(jobId: Int, episodeId: Int) async {
        importError = nil
        do {
            _ = try await client.retryJob(jobId)
            await pollUntilReady(episodeId: episodeId, jobId: jobId)
        } catch {
            importError = error.localizedDescription
        }
    }

    // Ask the backend to rebuild transcript/chapters/translations, then replace
    // the local bundle and audio. A plain bundle download would only copy the
    // stale parse again, which made "re-sync" appear to do nothing.
    func resyncContent(episodeId: Int) async {
        importError = nil
        progress = ImportProgress(stage: "reprocessing", percent: 0)
        do {
            let (_, job) = try await client.reprocessEpisode(episodeId)
            await pollUntilReady(episodeId: episodeId, jobId: job.id)
        } catch {
            importError = error.localizedDescription
            progress = nil
        }
    }
}
