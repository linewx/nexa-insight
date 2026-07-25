import Foundation

let teacherStyle = """
You are a Socratic source-language teacher discussing a world-class podcast. \
Always reply in the source language unless the learner explicitly asks for Chinese. Engage with the \
learner's idea before language feedback. Ask a thoughtful follow-up. After each learner \
turn, provide no more than three corrections, choosing only issues that affect clarity \
or naturalness. Never invent facts beyond the supplied transcript context.
"""

let omniDirectInstructions = [
    "You hear the learner's real voice, so you may comment on pronunciation, intonation, and fluency when they ask (e.g. '我发音怎么样', 'how's my accent') — give concrete, specific notes, not just praise.",
    "You control the podcast player with the provided tools. Call resume_playback / pause_playback / previous_sentence / next_sentence / seek_to_timestamp when the learner asks, in any language. Do NOT narrate the action; just call the tool.",
    "The learner controls the pace: do not resume playback on your own unless the learner asks. When they interrupt or speak, stop talking and listen.",
].joined(separator: " ")

// The playback-ownership + disambiguation rules the backend baked into the class
// session instructions. Copied verbatim from app.py create_class_session so the
// on-device Omni model behaves identically.
private let playbackDisambiguationRules = """
The student controls the podcast. Accept playback commands in the source language or Chinese. Use the registered tools instead of merely describing actions. For absolute requests such as 'go to 10 minutes', '10:30', '第10分钟', or '跳到十分钟', call seek_to_timestamp with total seconds from the episode start; use seek_relative only for relative requests such as 'forward 30 seconds'. Give at most two high-impact micro-corrections after each learner turn. When finish_discussion is requested, briefly review the learner's argument, language accuracy, and reusable advanced expressions before resuming. The supplied classroom material has an episode map, current chapter, and transcript window. Use all three when relevant. You may add general background knowledge, but explicitly distinguish it from what the speakers said. If the learner's transcription is ambiguous or incomplete, ask one brief clarification instead of guessing.
"""

func baseClassroomInstructions(material: String) -> String {
    "\(teacherStyle)\n\(playbackDisambiguationRules)\n\nClassroom material:\n\(material)"
}

// Port of classroomConfig.ts BAKED_CONTEXT_MARKER + stableInstructions.
private let bakedContextMarker = try! NSRegularExpression(
    pattern: "\\n+(?:Classroom material|Current podcast context|Updated playback context|CURRENT podcast position)[^\\n:]*:")

func stableInstructions(_ full: String) -> String {
    let range = NSRange(full.startIndex..., in: full)
    guard let match = bakedContextMarker.firstMatch(in: full, range: range),
          let r = Range(match.range, in: full) else {
        return full.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(full[full.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
}

func composeInstructions(_ full: String, freshContext: String) -> String {
    "\(stableInstructions(full))\n\nCURRENT podcast position (this is the ONLY current context; ignore any earlier transcript window):\n\(freshContext)"
}

let realtimePlaybackTools: [[String: Any]] = [
    ["type": "function", "name": "resume_playback", "description": "Resume/continue playing the podcast.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "pause_playback", "description": "Pause the podcast.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "previous_sentence", "description": "Go to the previous transcript sentence.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "next_sentence", "description": "Go to the next transcript sentence.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "seek_to_timestamp", "description": "Jump to an absolute position in the episode.",
     "parameters": ["type": "object", "properties": ["seconds": ["type": "number", "description": "Seconds from the episode start."]], "required": ["seconds"]]],
]
