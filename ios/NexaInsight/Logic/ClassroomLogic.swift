import Foundation

enum PlaybackTool: String {
    case pause_playback, resume_playback, previous_sentence, next_sentence
    case repeat_current_sentence, seek_relative, seek_to_timestamp
    case set_playback_speed, finish_discussion, exit_class
}

enum ClassroomPhase { case idle, connecting, podcastPlaying, userSpeaking, discussionPaused, discussing, teacherSpeaking, resuming, ended }

struct ClassroomState: Equatable { var phase: ClassroomPhase; var pausedAtMs: Int? }

enum ClassroomEvent {
    case speechStarted(atMs: Int), paused(atMs: Int), falseActivation
    case teacherStarted, teacherFinished, discussionStarted, resumed
    case entered, connected, collapsed, ended
}

func classroomReducer(_ state: ClassroomState, _ event: ClassroomEvent) -> ClassroomState {
    switch event {
    case let .speechStarted(atMs):
        return ClassroomState(phase: .userSpeaking, pausedAtMs: state.pausedAtMs ?? atMs)
    case let .paused(atMs):
        return ClassroomState(phase: .discussionPaused, pausedAtMs: atMs)
    case .falseActivation:
        return ClassroomState(phase: .discussionPaused, pausedAtMs: state.pausedAtMs)
    case .teacherStarted:
        return state.phase == .discussing ? ClassroomState(phase: .teacherSpeaking, pausedAtMs: state.pausedAtMs) : state
    case .teacherFinished:
        return state.phase == .teacherSpeaking ? ClassroomState(phase: .discussionPaused, pausedAtMs: state.pausedAtMs) : state
    case .discussionStarted:
        return ClassroomState(phase: .discussing, pausedAtMs: state.pausedAtMs)
    case .resumed:
        return ClassroomState(phase: .resuming, pausedAtMs: nil)
    case .entered:
        return ClassroomState(phase: .idle, pausedAtMs: nil)
    case .connected:
        return ClassroomState(phase: .podcastPlaying, pausedAtMs: nil)
    case .collapsed:
        return ClassroomState(phase: .idle, pausedAtMs: nil)
    case .ended:
        return ClassroomState(phase: .ended, pausedAtMs: state.pausedAtMs)
    }
}

func reliablePlaybackPosition(_ livePositionMs: Int, _ capturedPositionMs: Int) -> Int {
    livePositionMs > 0 ? livePositionMs : capturedPositionMs
}

func classroomCursorPosition(_ livePositionMs: Int, _ frozenPositionMs: Int?, _ initialPositionMs: Int) -> Int {
    frozenPositionMs ?? reliablePlaybackPosition(livePositionMs, initialPositionMs)
}

func classroomMode(_ state: ClassroomState) -> String {
    (state.phase == .podcastPlaying || state.phase == .idle) ? "listening" : "discussion"
}

private func classroomTime(_ ms: Int) -> String {
    let seconds = ms / 1000
    return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
}

func classroomStatusMessage(_ state: ClassroomState, _ positionMs: Int) -> String {
    switch state.phase {
    case .idle: return "Self-study · press Talk to bring in your teacher"
    case .podcastPlaying: return "Podcast playing · say anything to interrupt"
    case .resuming: return "Starting podcast..."
    case .userSpeaking: return "You are speaking · podcast paused at \(classroomTime(positionMs))"
    case .teacherSpeaking: return "Teacher is speaking · podcast paused at \(classroomTime(positionMs))"
    case .discussing: return "Teacher is preparing a response · paused at \(classroomTime(positionMs))"
    case .connecting: return "Connecting your voice classroom..."
    default: return "Discussion held at \(classroomTime(positionMs))"
    }
}

private let latinWordRegex = try! NSRegularExpression(pattern: "[a-z]+(?:'[a-z]+)?")

func latinWords(_ text: String) -> [String] {
    let range = NSRange(text.startIndex..., in: text)
    return latinWordRegex.matches(in: text, range: range).compactMap {
        Range($0.range, in: text).map { String(text[$0]) }
    }
}

func isCurrentSentenceMeaningRequest(_ transcript: String) -> Bool {
    let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let zh = try! NSRegularExpression(pattern: "(当前|这|这句|这句话).*(什么意思|含义|怎么理解)")
    let en = try! NSRegularExpression(pattern: "what does (this|the current) sentence mean")
    let range = NSRange(value.startIndex..., in: value)
    return zh.firstMatch(in: value, range: range) != nil || en.firstMatch(in: value, range: range) != nil
}

func isActionableTranscript(_ transcript: String) -> Bool {
    let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.isEmpty { return false }
    let hasHan = normalized.range(of: "\\p{Han}", options: .regularExpression) != nil
    if hasHan {
        let fillers = try! NSRegularExpression(pattern: "^(我说的是|我说|等一下|喂|你好|不知道|继续吧|继续|暂停|停一下|好的|嗯|啊)$")
        if fillers.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil { return false }
        return normalized.count >= 4 || isCurrentSentenceMeaningRequest(normalized)
    }
    let words = latinWords(normalized)
    if ["pause", "continue", "resume", "repeat", "back"].contains(words.joined(separator: " ")) { return true }
    if words.count < 3 { return false }
    for (index, word) in words.enumerated() where index > 0 && word == words[index - 1] { return false }
    return true
}

func mergeTranscriptFragment(_ existing: String, _ fragment: String) -> String {
    "\(existing) \(fragment)".replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

func matchDirectCommand(_ transcript: String) -> (name: PlaybackTool, args: [String: Double])? {
    func stripTrailing(_ s: String) -> String {
        s.replacingOccurrences(of: "[。！？.!?,，、\\s]+$", with: "", options: .regularExpression)
    }
    var value = stripTrailing(transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    if value.isEmpty { return nil }
    let discuss = "(什么意思|含义|解释|讲讲|讲解|理解|为什么|观点|意思是|聊聊|讨论|explain|mean|why|discuss|what)"
    if value.range(of: discuss, options: .regularExpression) != nil { return nil }
    value = value.replacingOccurrences(of: "^.*[，,。.]\\s*", with: "", options: .regularExpression)
    let filler = "^(好的?|嗯+|那|然后|ok|okay|alright|well|so|um+|uh+|let'?s|请|麻烦你?|我们|咱们|你|帮我)\\s*"
    var prev: String
    repeat { prev = value; value = value.replacingOccurrences(of: filler, with: "", options: .regularExpression) } while value != prev
    value = value.replacingOccurrences(of: "[吧啦呀呢嘛]+$", with: "", options: .regularExpression)
    value = stripTrailing(value).trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    func match(_ pattern: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
    if match("^(继续|继续继续|继续播放|接着放|接着播|接着听|回到播客|恢复播放|播放|播放视频|resume|resume playback|continue|continue playing|keep going|play|play the podcast|play the video|go back to the podcast)$") {
        return (.resume_playback, [:])
    }
    if match("^(暂停|停一下|停下|pause|pause playback|stop|hold on)$") { return (.pause_playback, [:]) }
    if match("^(上一句|回到上一句|previous sentence|go back one sentence)$") { return (.previous_sentence, [:]) }
    if match("^(下一句|next sentence)$") { return (.next_sentence, [:]) }
    if match("^(重播这句|再放一遍|重播|replay|play it again|say that again)$") { return (.repeat_current_sentence, [:]) }
    return nil
}

func playbackNotice(_ name: PlaybackTool, _ positionMs: Int) -> String {
    switch name {
    case .resume_playback, .finish_discussion: return "Podcast playing"
    case .pause_playback: return "Paused at \(classroomTime(positionMs))"
    case .seek_to_timestamp, .seek_relative: return "Moved to \(classroomTime(positionMs)) · paused"
    case .previous_sentence: return "Previous sentence · paused"
    case .next_sentence: return "Next sentence · paused"
    case .repeat_current_sentence: return "Repeating this sentence · paused"
    case .set_playback_speed: return "Playback speed updated"
    case .exit_class: return "Ending class"
    }
}

func playbackTargetPosition(_ name: PlaybackTool, _ args: [String: Double], _ currentMs: Int, _ currentSentenceIndex: Int, _ sentenceStarts: [Int]) -> Int {
    switch name {
    case .seek_to_timestamp: return max(0, Int((args["seconds"] ?? 0) * 1000))
    case .seek_relative: return max(0, currentMs + Int((args["seconds"] ?? 0) * 1000))
    case .previous_sentence:
        let i = max(0, currentSentenceIndex - 1)
        return sentenceStarts.indices.contains(i) ? sentenceStarts[i] : currentMs
    case .next_sentence:
        let i = min(sentenceStarts.count - 1, currentSentenceIndex + 1)
        return sentenceStarts.indices.contains(i) ? sentenceStarts[i] : currentMs
    case .repeat_current_sentence:
        return sentenceStarts.indices.contains(currentSentenceIndex) ? sentenceStarts[currentSentenceIndex] : currentMs
    default: return currentMs
    }
}
