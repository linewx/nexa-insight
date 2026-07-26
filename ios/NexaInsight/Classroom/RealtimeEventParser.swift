import Foundation

enum RealtimeEventParser {
    static func parse(_ json: [String: Any]) -> RealtimeEvent? {
        let type = json["type"] as? String ?? ""
        switch type {
        case "input_audio_buffer.speech_started":
            return .speechStarted
        case "conversation.item.input_audio_transcription.completed":
            let text = (json["transcript"] as? String) ?? ""
            return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .inputTranscriptionCompleted(text)
        case "response.audio_transcript.done":
            guard let text = json["transcript"] as? String else { return nil }
            return .responseAudioTranscriptDone(text)
        // WebRTC delivers a tool call as its own event, with name/call_id/
        // arguments on the event itself (OpenAI-compatible, and what Qwen
        // omni-realtime actually sends over the data channel). This — not the
        // function_call item inside response.done — is the reliable signal.
        case "response.function_call_arguments.done":
            guard let rawName = json["name"] as? String, let tool = PlaybackTool(rawValue: rawName) else { return nil }
            return .toolCall(name: tool, args: safeArgs(json["arguments"] as? String), callId: json["call_id"] as? String)
        case "response.done":
            // Some servers ALSO echo the function_call in the final output. Keep
            // handling it as a fallback for servers that don't emit the event
            // above; the controller dedupes by call_id so a tool never double-runs.
            let output = (json["response"] as? [String: Any])?["output"] as? [[String: Any]] ?? []
            for item in output where (item["type"] as? String) == "function_call" {
                guard let rawName = item["name"] as? String, let tool = PlaybackTool(rawValue: rawName) else { continue }
                let args = safeArgs(item["arguments"] as? String)
                return .toolCall(name: tool, args: args, callId: item["call_id"] as? String)
            }
            return .responseDone
        default:
            return nil
        }
    }

    private static func safeArgs(_ raw: String?) -> [String: Double] {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Double] = [:]
        for (key, value) in obj {
            if let d = value as? Double { result[key] = d }
            else if let i = value as? Int { result[key] = Double(i) }
        }
        return result
    }
}
