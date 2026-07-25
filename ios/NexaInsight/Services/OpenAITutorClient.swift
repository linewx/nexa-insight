import Foundation

struct OpenAITutorClient {
    let apiKey: String
    let baseURL: URL
    let transcriptionModel: String
    let textModel: String
    var session: URLSession = .shared

    init(apiKey: String, baseURL: URL = URL(string: "https://api.openai.com/v1")!,
         transcriptionModel: String = "gpt-4o-transcribe", textModel: String = "gpt-4.1-mini") {
        self.apiKey = apiKey; self.baseURL = baseURL
        self.transcriptionModel = transcriptionModel; self.textModel = textModel
    }

    enum TutorError: LocalizedError, Equatable {
        case missingKey
        var errorDescription: String? { "Add your OpenAI API key in Settings to get feedback." }
    }

    func shadowingFeedback(sentence: String, recordingURL: URL) async throws -> String {
        if apiKey.isEmpty { throw TutorError.missingKey }
        let transcript = try await transcribe(recordingURL)
        return try await feedback(sentence: sentence, learnerTranscript: transcript)
    }

    private func transcribe(_ fileURL: URL) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", transcriptionModel)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"take.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: fileURL))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["text"] as? String ?? ""
    }

    private func feedback(sentence: String, learnerTranscript: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let instructions = "Give concise qualitative shadowing feedback about rhythm, stress and linking. Name one highest-impact improvement. Do not give a numeric score."
        let payload: [String: Any] = [
            "model": textModel,
            "instructions": instructions,
            "input": "Original: \(sentence)\nLearner transcript: \(learnerTranscript)",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["output_text"] as? String
            ?? "Feedback unavailable (unexpected response shape)."
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "OpenAI", code: status, userInfo: [NSLocalizedDescriptionKey: "OpenAI request failed (\(status))"])
        }
    }
}
