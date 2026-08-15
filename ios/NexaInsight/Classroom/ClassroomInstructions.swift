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
The student controls the podcast. Accept playback commands in the source language or Chinese. Use the registered tools instead of merely describing actions. For absolute requests such as 'go to 10 minutes', '10:30', '第10分钟', or '跳到十分钟', call seek_to_timestamp with total seconds from the episode start; use seek_relative only for relative requests such as 'forward 30 seconds'. CRITICAL: a pure playback command (seek, pause, resume, next/previous sentence, speed) is an ACTION, not a discussion opener. When the learner only asks to move or control playback, call the tool and stop — say nothing, or at most one very short acknowledgement (e.g. '好的' / 'Sure'). Do NOT ask a follow-up question, do NOT give corrections, and do NOT start discussing the new position; the podcast will resume playing on its own. Only engage, correct, or ask follow-ups when the learner actually raises an idea or question to discuss. When finish_discussion is requested, briefly review the learner's argument, language accuracy, and reusable advanced expressions before resuming. The supplied classroom material has an episode map, current chapter, and transcript window. Use all three when relevant. You may add general background knowledge, but explicitly distinguish it from what the speakers said. If the learner's transcription is ambiguous or incomplete, ask one brief clarification instead of guessing.
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

func composeInstructions(_ full: String, freshContext: String, scene: ClassroomScene = .selfStudy) -> String {
    let base = "\(stableInstructions(full))\n\nCURRENT podcast position (this is the ONLY current context; ignore any earlier transcript window):\n\(freshContext)"
    guard scene == .reading else { return base }
    return "\(base)\n\n\(readingDirectness)"
}

/// What reading needs that listening does not: the answer itself, in the turn it was
/// asked in.
///
/// `teacherStyle` is Socratic — engage with the idea first, ask a follow-up — which is
/// right when the learner is listening and thinking aloud. Asked to explain a paragraph
/// it produced "好，我们来梳理一下这一小段里值得注意的几个点" and then ended the turn:
/// a promise to explain, with the explanation deferred to a turn that never came. The
/// learner holds a paragraph because they are stuck on it now, and a turn spent on
/// preamble also leaves the exchange with nothing to sediment.
private let readingDirectness = """
READING MODE. The learner is looking at one paragraph and has held it to ask about it. \
Answer THAT question in THIS turn, with the substance first. Do not open with a \
preamble, do not announce what you are about to explain ("好，我们来梳理一下…", "让我们 \
看看这里有几个点"), and do not defer content to a later turn — if there are three things \
worth saying, say them now. Asked what is worth studying in the paragraph, name the \
items and explain each one, rather than offering to. Keep the Socratic follow-up for \
AFTER the answer, and only when it adds something; one short question at most. \
Corrections still apply, but they come after the answer, not instead of it.
"""

let realtimePlaybackTools: [[String: Any]] = [
    ["type": "function", "name": "resume_playback", "description": "Resume/continue playing the podcast.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "pause_playback", "description": "Pause the podcast.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "previous_sentence", "description": "Go to the previous transcript sentence.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "next_sentence", "description": "Go to the next transcript sentence.", "parameters": ["type": "object", "properties": [:]]],
    ["type": "function", "name": "seek_to_timestamp", "description": "Jump to an absolute position in the episode.",
     "parameters": ["type": "object", "properties": ["seconds": ["type": "number", "description": "Seconds from the episode start."]], "required": ["seconds"]]],
]
