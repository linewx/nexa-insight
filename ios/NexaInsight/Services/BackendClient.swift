import Foundation

struct BackendClient {
    let baseURL: URL
    var session: URLSession = .shared

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
