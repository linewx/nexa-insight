import Foundation

struct DashScopePracticeResult: Codable, Equatable {
    let overall: Int
    let clarity: Int
    let stressRhythm: Int
    let completeness: Int
    let advice: String

    private enum CodingKeys: String, CodingKey {
        case overall, clarity, completeness, advice
        case stressRhythm = "stress_rhythm"
    }

    static func parse(_ text: String) throws -> Self {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try JSONDecoder().decode(Self.self, from: Data(withoutFence.utf8))
        guard [result.overall, result.clarity, result.stressRhythm, result.completeness].allSatisfy({ (0...100).contains($0) }),
              !result.advice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DashScopePracticeError.invalidResult
        }
        return result
    }
}

enum DashScopePracticeError: LocalizedError {
    case missingConfiguration
    case invalidEndpoint
    case invalidResult
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration: return "请先在设置中填写 DashScope API Key 和 Workspace ID。"
        case .invalidEndpoint: return "DashScope Workspace ID 无效。"
        case .invalidResult: return "评测结果格式无效，请重试。"
        case .requestFailed(let message): return message
        }
    }
}

struct DashScopePracticeClient {
    let apiKey: String
    let workspaceId: String

    func evaluate(example: String, audioURL: URL) async throws -> DashScopePracticeResult {
        guard !apiKey.isEmpty, !workspaceId.isEmpty else { throw DashScopePracticeError.missingConfiguration }
        guard let endpoint = URL(string: "https://\(workspaceId).cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            throw DashScopePracticeError.invalidEndpoint
        }
        let audio = try Data(contentsOf: audioURL)
        guard audio.count <= 10_000_000 else {
            throw DashScopePracticeError.requestFailed("录音超过 10 MB，请缩短后重试。")
        }

        let prompt = """
        Compare the learner's spoken English with this target example: \(example)
        Return only JSON: {"overall":0,"clarity":0,"stress_rhythm":0,"completeness":0,"advice":"one concise Chinese improvement tip"}. Each score must be 0-100. This is informal practice feedback, not a formal pronunciation assessment.
        """
        let payload: [String: Any] = [
            "model": "qwen3.5-omni-plus",
            "stream": true,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64,\(audio.base64EncodedString())", "format": "wav"]],
                ],
            ]],
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DashScopePracticeError.requestFailed("评测服务没有响应。") }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DashScopePracticeError.requestFailed("评测失败（\(http.statusCode)）：\(detail.prefix(180))")
        }
        let output = Self.streamedContent(from: data)
        return try DashScopePracticeResult.parse(output)
    }

    private static func streamedContent(from data: Data) -> String {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        var output = ""
        for line in lines where line.hasPrefix("data: ") {
            let event = line.dropFirst(6)
            guard event != "[DONE]", let json = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            output += content
        }
        return output.isEmpty ? String(decoding: data, as: UTF8.self) : output
    }
}
