import Foundation

enum RealtimeEventParser {
    static func parse(_ json: [String: Any]) -> RealtimeEvent? {
        let type = json["type"] as? String ?? ""
        switch type {
        case "input_audio_buffer.speech_started":
            return .speechStarted
        // The server has taken the captured audio as a turn. This is the earliest
        // point the mic can safely close in quick-ask: the server decides a turn
        // ended by hearing trailing silence, which needs the mic open PAST the
        // finger lifting (on device, speech_stopped/committed both arrive after
        // release). Closing on release instead would drop the turn.
        case "input_audio_buffer.committed":
            return .inputAudioCommitted
        case "response.created":
            return .responseCreated
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

    /// A tool call's arguments, numeric and textual.
    ///
    /// Numbers used to be the whole story — every playback argument is one (seconds, a
    /// rate) — so strings were dropped without anyone noticing. Saving a note needs text,
    /// and `numbers` keeps the exact shape `playbackTargetPosition` reads, so the
    /// playback path is untouched by adding the other half.
    static func safeArgs(_ raw: String?) -> ToolArguments {
        guard let raw, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ToolArguments() }
        var numbers: [String: Double] = [:]
        var texts: [String: String] = [:]
        for (key, value) in obj {
            if let d = value as? Double { numbers[key] = d }
            else if let i = value as? Int { numbers[key] = Double(i) }
            else if let s = value as? String {
                // A model asked for a number sometimes sends "30". Kept in BOTH, so a
                // quoted number still reaches the playback path rather than being read
                // as text and silently ignored.
                if let d = Double(s) { numbers[key] = d }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { texts[key] = trimmed }
            }
        }
        return ToolArguments(numbers: numbers, texts: texts)
    }
}

/// The arguments of one tool call.
struct ToolArguments: Equatable {
    var numbers: [String: Double] = [:]
    var texts: [String: String] = [:]

    subscript(_ key: String) -> Double? { numbers[key] }
    func text(_ key: String) -> String? { texts[key] }
}
