import Foundation

/// Extracts study notes for one sentence, on the device, when the learner asks.
///
/// Talks straight to DashScope with the learner's own key — the same path
/// shadowing feedback takes. The backend transcodes and translates; a note must
/// not wait on it, because the moment you want one is mid-listen, possibly with
/// no route to the Mac.
///
/// Automatic extraction still runs in the pipeline over the whole transcript.
/// This is the other entry to the same idea: same types, same reject list, same
/// text-anchoring rule, one sentence at a time and steerable by a request.
struct OnDemandExtractionClient {
    let apiKey: String
    let workspaceId: String
    /// Injected so tests can drive the parsing and validation without a network.
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    func extract(
        sentence: String,
        materialKind: String,
        request userRequest: String?
    ) async throws -> [ExtractedExpression] {
        guard !apiKey.isEmpty, !workspaceId.isEmpty else { throw DashScopePracticeError.missingConfiguration }
        guard let endpoint = URL(string: "https://\(workspaceId).cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            throw DashScopePracticeError.invalidEndpoint
        }

        let instruction = ExtractionPrompt.instruction(materialKind: materialKind, request: userRequest)
        let payload: [String: Any] = [
            "model": "qwen-plus",
            "stream": true,
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": "Sentence: \(sentence)"],
            ],
            // The prompt asks for JSON; asking the API for it too removes the
            // fenced-prose failure mode rather than only parsing around it.
            "response_format": ["type": "json_object"],
        ]

        var httpRequest = URLRequest(url: endpoint)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await send(httpRequest)
        guard let http = response as? HTTPURLResponse else {
            throw DashScopePracticeError.requestFailed("\u{62bd}\u{53d6}\u{670d}\u{52a1}\u{6ca1}\u{6709}\u{54cd}\u{5e94}\u{3002}")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DashScopePracticeError.requestFailed("\u{62bd}\u{53d6}\u{5931}\u{8d25}\u{ff08}\(http.statusCode)\u{ff09}\u{ff1a}\(detail.prefix(180))")
        }
        return try ExtractionResponse.parse(Self.streamedContent(from: data), host: sentence)
    }

    /// Extracts from a spoken question.
    ///
    /// The recording goes to the model as audio — no transcription step, because
    /// the omni model accepts `input_audio` directly and every added layer is
    /// another chance to mishear "what-clause" as something else.
    ///
    /// - Parameter candidates: lines around the learner's position, numbered. A
    ///   spoken question refers to the transcript loosely ("that clause a moment
    ///   ago"), so the model is given the neighbourhood and picks.
    func extract(
        audioURL: URL,
        candidates: [String],
        materialKind: String
    ) async throws -> [ExtractedExpression] {
        let data = try await sendSpokenQuestion(
            audioURL: audioURL, candidates: candidates, materialKind: materialKind)
        return try ExtractionResponse.parse(Self.streamedContent(from: data), candidates: candidates)
    }

    /// The shared request for a spoken question. Both entry points send exactly
    /// this; they differ only in how they read the reply.
    private func sendSpokenQuestion(
        audioURL: URL,
        candidates: [String],
        materialKind: String
    ) async throws -> Data {
        guard !apiKey.isEmpty, !workspaceId.isEmpty else { throw DashScopePracticeError.missingConfiguration }
        guard let endpoint = URL(string: "https://\(workspaceId).cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            throw DashScopePracticeError.invalidEndpoint
        }
        let audio = try Data(contentsOf: audioURL)
        guard audio.count <= 10_000_000 else {
            throw DashScopePracticeError.requestFailed("\u{5f55}\u{97f3}\u{592a}\u{957f}\u{ff0c}\u{8bf7}\u{7f29}\u{77ed}\u{540e}\u{91cd}\u{8bd5}\u{3002}")
        }

        let numbered = candidates.enumerated()
            .map { "\($0.offset). \($0.element)" }
            .joined(separator: "\n")
        let instruction = ExtractionPrompt.instruction(
            materialKind: materialKind, request: nil, spokenQuestion: true)

        let payload: [String: Any] = [
            // The omni model, not qwen-plus: this one takes audio.
            "model": "qwen3.5-omni-plus",
            "stream": true,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": "\(instruction)\n\nLines:\n\(numbered)"],
                    ["type": "input_audio",
                     "input_audio": ["data": "data:audio/wav;base64,\(audio.base64EncodedString())", "format": "wav"]],
                ],
            ]],
        ]

        var httpRequest = URLRequest(url: endpoint)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await send(httpRequest)
        guard let http = response as? HTTPURLResponse else {
            throw DashScopePracticeError.requestFailed("\u{62bd}\u{53d6}\u{670d}\u{52a1}\u{6ca1}\u{6709}\u{54cd}\u{5e94}\u{3002}")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw DashScopePracticeError.requestFailed("\u{62bd}\u{53d6}\u{5931}\u{8d25}\u{ff08}\(http.statusCode)\u{ff09}\u{ff1a}\(detail.prefix(180))")
        }
        return data
    }

    /// Same request, routed rather than assumed to be vocabulary.
    ///
    /// This is what a held paragraph uses: the question could be about a phrase, or
    /// about what the passage means, and only the reply says which.
    func ask(
        audioURL: URL,
        candidates: [String],
        materialKind: String
    ) async throws -> ExtractionOutcome {
        let data = try await sendSpokenQuestion(
            audioURL: audioURL, candidates: candidates, materialKind: materialKind)
        return try ExtractionResponse.outcome(Self.streamedContent(from: data), candidates: candidates)
    }

    /// Reassembles a server-sent-event stream into the model's full reply. Shared
    /// shape with the practice client: DashScope streams deltas even for a single
    /// JSON object.
    static func streamedContent(from data: Data) -> String {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        var output = ""
        for line in lines where line.hasPrefix("data: ") {
            let event = line.dropFirst(6)
            guard event != "[DONE]",
                  let json = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String else { continue }
            output += content
        }
        // A non-streamed reply arrives as one JSON body, so falling back to the raw
        // data keeps that case working instead of returning nothing.
        return output.isEmpty ? String(decoding: data, as: UTF8.self) : output
    }
}
