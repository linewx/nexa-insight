import Foundation

/// Reviews a finished reading conversation, on the device, and says what it was worth.
///
/// Talks straight to DashScope with the learner's own key — the same path shadowing
/// feedback takes. The backend transcodes and translates; sedimenting a knowledge point
/// must not wait on it, because the moment one exists is mid-reading, possibly with no
/// route to the Mac.
///
/// It used to also extract from a sentence or a recorded question over HTTP: one hold,
/// one stateless request, one card. The realtime session replaced all of that — it can
/// answer aloud, be followed up, and show what it heard, none of which a one-shot
/// request could do. What remains is the step realtime does NOT do: deciding what, if
/// anything, the exchange is worth keeping.
///
/// Automatic extraction still runs in the pipeline over the whole transcript. This is
/// the other entry to the same idea, and it shares the reject list and the
/// text-anchoring rule with it.
struct OnDemandExtractionClient {
    let apiKey: String
    let workspaceId: String
    /// Injected so tests can drive the parsing and validation without a network.
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    /// Reviews a finished reading conversation and returns what is worth keeping.
    ///
    /// Text in, not audio: the realtime session already transcribed both sides, so
    /// this reads what was said instead of listening again. `qwen-plus` rather than the
    /// omni model for the same reason — no audio to accept.
    ///
    /// Never throws. An empty result is the common, correct answer (most talk about a
    /// paragraph leaves nothing durable), and a failure is also empty: the learner has
    /// already read the answer on screen, so there is nothing to report and nothing a
    /// dialog would improve. That is the deliberate difference from `ask`, whose
    /// `noUsableExpression` became a failure alert for what was often a sound judgement.
    func knowledgePoints(
        conversation: String,
        candidates: [String],
        materialKind: String
    ) async -> [KnowledgePoint] {
        guard !apiKey.isEmpty, !workspaceId.isEmpty, !conversation.isEmpty else { return [] }
        guard let endpoint = URL(string: "https://\(workspaceId).cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            return []
        }

        let numbered = candidates.enumerated()
            .map { "\($0.offset). \($0.element)" }
            .joined(separator: "\n")
        let payload: [String: Any] = [
            "model": "qwen-plus",
            "stream": true,
            "messages": [
                ["role": "system", "content": ExtractionPrompt.conversationRules(materialKind: materialKind)],
                ["role": "user", "content": "Lines:\n\(numbered)\n\nExchange:\n\(conversation)"],
            ],
            "response_format": ["type": "json_object"],
        ]

        var httpRequest = URLRequest(url: endpoint)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (data, response) = try? await send(httpRequest),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else { return [] }
        return KnowledgePointExtractor.points(
            Self.streamedContent(from: data), candidates: candidates)
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
