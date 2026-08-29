import Foundation

struct BackendClient {
    let baseURL: URL
    /// Bounded, unlike `URLSession.shared`.
    ///
    /// The shared session's resource timeout is SEVEN DAYS. A half-open connection to the backend
    /// therefore never fails — it just never returns — which is what left an import sitting on
    /// "Saving to your library" until the app was killed. The work had already finished server
    /// side, so reopening the app found the episode ready and the hang looked like a UI bug.
    ///
    /// The probe button was given its own short-timeout session for exactly this reason and this,
    /// the path that actually moves data, was left on the default.
    ///
    /// Generous rather than short: an episode's audio is tens of megabytes over a home connection.
    /// The point is that it CANNOT hang forever, not that it must be quick.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // Per-hop silence, not total duration: a stalled transfer fails, a slow one continues.
        config.timeoutIntervalForRequest = 30
        // The whole transfer, including a large audio file.
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }

    var session: URLSession = BackendClient.makeSession()

    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    func url(path: String) -> URL { baseURL.appendingPathComponent(path) }

    func formatApiError(_ data: Data, _ status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = obj["detail"] {
            if let text = detail as? String { return text }
            if let items = detail as? [[String: Any]] {
                return items.map { item in
                    let loc = (item["loc"] as? [Any] ?? []).map { "\($0)" }.joined(separator: ".")
                    let msg = item["msg"] as? String ?? "Invalid value"
                    return "\(loc): \(msg)"
                }.joined(separator: "; ")
            }
        }
        return "Request failed (\(status))"
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await send(URLRequest(url: url(path: path)))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw NSError(domain: "Backend", code: status, userInfo: [NSLocalizedDescriptionKey: formatApiError(data, status)]) }
        return try Self.jsonDecoder.decode(T.self, from: data)
    }

    /// Contacts the backend and reports what came back.
    ///
    /// Never throws: every outcome is a verdict the settings screen renders, and "it failed"
    /// is the most useful one. Uses its own short-timeout session because `URLSession.shared`
    /// defaults to a seven-day resource timeout — long enough that a half-open connection
    /// would leave the button spinning until the app was killed.
    func probe() async -> BackendReachability {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = BackendProbe.timeout
        config.timeoutIntervalForResource = BackendProbe.timeout
        let probeSession = URLSession(configuration: config)
        do {
            let (data, response) = try await probeSession.data(for: URLRequest(url: url(path: "/api/episodes")))
            let status = (response as? HTTPURLResponse)?.statusCode
            let episodes = try? Self.jsonDecoder.decode([EpisodeDTO].self, from: data)
            return BackendProbe.verdict(status: status, decodedEpisodes: episodes?.count, error: nil)
        } catch {
            return BackendProbe.verdict(status: nil, decodedEpisodes: nil,
                                        error: error.localizedDescription)
        }
    }

    func listEpisodes() async throws -> [EpisodeDTO] { try await get("/api/episodes") }

    func importEpisode(url urlString: String) async throws -> (episode: EpisodeDTO, job: JobDTO) {
        struct ImportView: Decodable { let episode: EpisodeDTO; let job: JobDTO }
        var request = URLRequest(url: url(path: "/api/episodes/import"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["url": urlString])
        let view: ImportView = try await send(request)
        return (view.episode, view.job)
    }

    func episodeJob(_ id: Int) async throws -> JobDTO { try await get("/api/episodes/\(id)/job") }

    func retryJob(_ id: Int) async throws -> JobDTO {
        var request = URLRequest(url: url(path: "/api/jobs/\(id)/retry"))
        request.httpMethod = "POST"
        return try await send(request)
    }

    func reprocessEpisode(_ id: Int) async throws -> (episode: EpisodeDTO, job: JobDTO) {
        struct ImportView: Decodable { let episode: EpisodeDTO; let job: JobDTO }
        var request = URLRequest(url: url(path: "/api/episodes/\(id)/reprocess"))
        request.httpMethod = "POST"
        let view: ImportView = try await send(request)
        return (view.episode, view.job)
    }

    func bundle(_ id: Int) async throws -> BundleDTO { try await get("/api/episodes/\(id)/bundle") }

    func downloadAudio(_ id: Int, to destination: URL) async throws {
        let audioURL = url(path: "/api/episodes/\(id)/audio")
        print("[NexaAudio] downloading \(audioURL.absoluteString)")
        let (temp, response) = try await session.download(from: audioURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "Backend",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "Audio download from \(audioURL.host ?? "backend") failed (HTTP \(status))."]
            )
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temp, to: destination)
        print("[NexaAudio] saved \(destination.lastPathComponent)")
    }
}
