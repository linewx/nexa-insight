import Foundation

/// A tool the teacher can call. Named for what it originally was; it now also saves
/// notes, and renaming it would churn the whole call chain and its tests for nothing.
enum PlaybackTool: String {
    case pause_playback, resume_playback, previous_sentence, next_sentence
    case repeat_current_sentence, seek_relative, seek_to_timestamp
    /// Search the transcript. Answers "where is X discussed", which the ±6-sentence context window
    /// cannot — and unlike the other tools this one MOVES NOTHING: it returns text for the teacher
    /// to read, then it decides where to seek.
    case find_in_episode
    case set_playback_speed, finish_discussion, exit_class
    /// Save a word or phrase as a highlighted card, when the learner ASKS for it.
    case save_note
    /// Save a question and its answer, with no highlight.
    case save_answer

    /// Whether this tool writes a note rather than moving the podcast. The playback
    /// machinery (freeze, seek, resume, the notice text) does not apply to these.
    var savesANote: Bool { self == .save_note || self == .save_answer }
}

/// One note the teacher was asked to keep.
///
/// The sentence is NOT carried: it is decided locally from the playback position, the
/// same way every other tool takes its position. Asking the model for a sentence id
/// invites it to invent one, and the highlight is anchored by searching for `text`
/// anyway (see ExpressionLocator).
struct NoteRequest: Equatable {
    /// A vocabulary card, or a question card with no highlight.
    enum Kind: Equatable {
        case expression(text: String, type: LearningExpressionType)
        case answer(question: String)
    }

    var kind: Kind
    /// The gloss for an expression, or the answer for a question.
    var body: String
    var example: String?
    /// The sense group the expression sits inside — the unit a native speaker processes at
    /// once. `throw shade` alone does not tell you what to do with it; "I'm not throwing
    /// shade at them, but…" does.
    var senseGroup: String?
    /// How to use it: the frame it sits in, not "used in daily conversation".
    var usage: String?
    /// The everyday reading the learner would land on, for the two kinds where a wrong
    /// reading is available. Shown BESIDE the real meaning, because a misunderstanding has
    /// to be named to be avoided.
    var literal: String?

    /// What the learner said, when it is known. An expression card keeps it so a card
    /// found a week later says why it was wanted.
    var request: String?

    /// Drops anything the model invented rather than quoted.
    ///
    /// Testing this prompt on a real transcript produced an example the passage did not
    /// contain — "The thing is, I'm not throwing shade at them…" where the line actually
    /// reads "So this is I'm not throwing shade at them…". It was completely plausible,
    /// which is exactly the danger: a card whose example never appeared teaches a sentence
    /// nobody said.
    ///
    /// The same distrust `ExpressionLocator` already applies to offsets ("plausibly wrong,
    /// so a range check passes and the highlight lands on unrelated words"). Prompts cannot
    /// promise this; only checking can.
    func verified(against transcript: String) -> NoteRequest {
        var copy = self
        if let example, !Self.appears(example, in: transcript) { copy.example = nil }
        if let senseGroup, !Self.appears(senseGroup, in: transcript) { copy.senseGroup = nil }
        return copy
    }

    /// Whitespace- and case-insensitive containment: transcripts carry double spaces and
    /// the model silently normalises them, so an exact match would reject real quotes.
    private static func appears(_ needle: String, in haystack: String) -> Bool {
        func flat(_ s: String) -> String {
            s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let n = flat(needle)
        return !n.isEmpty && flat(haystack).contains(n)
    }

    /// Reads a tool call, or nil when the model left out something a card cannot do
    /// without. Returning nil is better than storing a card with an empty gloss.
    static func from(tool: PlaybackTool, args: ToolArguments) -> NoteRequest? {
        switch tool {
        case .save_note:
            guard let text = args.text("text"), let meaning = args.text("meaning") else { return nil }
            // An unknown or missing type falls back to `word` rather than dropping the
            // note: the type only picks which fields the card shows, and losing a note
            // the learner explicitly asked for is much worse than showing it plainly.
            let type = args.text("note_type").flatMap { LearningExpressionType(rawValue: $0.lowercased()) } ?? .word
            return NoteRequest(kind: .expression(text: text, type: type), body: meaning,
                               example: args.text("example"),
                               senseGroup: args.text("sense_group"),
                               usage: args.text("usage"),
                               literal: args.text("literal"),
                               request: args.text("request"))
        case .save_answer:
            guard let question = args.text("question"), let answer = args.text("answer") else { return nil }
            return NoteRequest(kind: .answer(question: question), body: answer)
        default:
            return nil
        }
    }
}

enum ClassroomPhase { case idle, connecting, podcastPlaying, userSpeaking, discussionPaused, discussing, teacherSpeaking, resuming, ended }

struct ClassroomState: Equatable { var phase: ClassroomPhase; var pausedAtMs: Int? }

// How turn boundaries are detected.
// - continuous: the model's VAD decides when the learner stopped and auto-responds.
//   This is the reference (english_learning) behaviour, used by locked live mode.
// - pushToTalk: the finger decides. VAD still segments speech but must NOT
//   auto-respond; the response is requested explicitly on release.
enum TurnMode: Equatable { case continuous, pushToTalk }

// The turn_detection object sent in session.update, per mode. Pure so the
// mode→config mapping is unit-testable without a live transport. The VAD
// tuning (semantic_vad, threshold 0.5, 800ms) matches the ported reference;
// only create_response flips.
// WebRTC transport only honors server-side VAD (Alibaba Model Studio realtime
// docs: "WebRTC only supports server_vad / semantic_vad; manual mode is
// WebSocket-only"). So the config is identical in both modes and always lets the
// VAD create the response. Push-to-talk is implemented as a mic gate over this
// same VAD, NOT by flipping create_response — doing that stopped the model from
// ever responding on release.
func turnDetectionConfig(_ mode: TurnMode) -> [String: Any] {
    [
        "type": "semantic_vad",
        "threshold": 0.5,
        "silence_duration_ms": 800,
        "create_response": true,
    ]
}

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
    // No notice: a search moves nothing, so there is nothing for the dock to report. The teacher
    // announces what it found by speaking, and a "searched" banner over that would be noise.
    case .find_in_episode: return ""
    case .previous_sentence: return "Previous sentence · paused"
    case .next_sentence: return "Next sentence · paused"
    case .repeat_current_sentence: return "Repeating this sentence · paused"
    case .set_playback_speed: return "Playback speed updated"
    case .exit_class: return "Ending class"
    // Saving is confirmed with the note's own text (see noteNotice), which is more
    // useful than a generic word — "已记下 kind of" proves WHAT was heard, not just
    // that something was.
    case .save_note, .save_answer: return "\u{5df2}\u{8bb0}\u{4e0b}"
    }
}

/// The confirmation for a saved note, naming what was saved.
///
/// The naming is the point: in an explicit mode the learner needs to see that the right
/// thing was heard. "已记下" alone cannot distinguish a correct save from one that kept
/// a mis-transcribed word.
func noteNotice(_ request: NoteRequest) -> String {
    switch request.kind {
    case let .expression(text, _): "\u{5df2}\u{8bb0}\u{4e0b}\u{ff1a}\(text)"
    case .answer: "\u{5df2}\u{8bb0}\u{4e0b}\u{8fd9}\u{4e2a}\u{95ee}\u{9898}"
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

// MARK: - Floor token (single-voice arbitration)

// Who currently holds the floor. The single hard rule of the classroom: only
// the holder makes sound; the other two are silent. idle = nobody speaks (Live
// waiting on the learner, or the gap between quick-ask turns).
enum FloorHolder: Equatable { case player, user, teacher, idle }

/// How the learner is working, which decides two things a single bool could not.
///
/// It replaced `inLive: Bool`, where "resume the podcast when the teacher finishes"
/// was written as `!inLive`. Reading needs the podcast to stay exactly where it was
/// — you asked about a line you are looking at, not about where playback happens to
/// be — but under a bool the only way to say "don't resume" was to be Live, which
/// also means holding the mic open for barge-in. The two properties are independent,
/// so they are now two properties.
enum ClassroomScene: Equatable {
    /// Listening, asking by long-press. The podcast is the point, so it comes back
    /// as soon as the answer ends.
    case selfStudy
    /// A continuous class. The mic stays open so the learner can cut in, and the
    /// podcast waits until they ask for it.
    case live
    /// Reading, asking about a paragraph. Nothing auto-resumes: the answer ending is
    /// an invitation to follow up, not a cue to start playing over the reply.
    case reading

    /// Whether the mic stays open regardless of who holds the floor. Only a
    /// continuous class does; the other two open it for the duration of a turn.
    var holdsMicOpen: Bool { self == .live }

    /// Whether the podcast resumes by itself once the teacher stops talking.
    /// Never. The podcast waits for you to press play.
    ///
    /// It used to resume on `response.done`, which is the SERVER finishing GENERATION — not the
    /// teacher finishing SPEAKING. The answer's audio arrives over a WebRTC track and plays out
    /// afterwards, so the podcast started over the last seconds of the reply every time.
    ///
    /// There is no exact signal to wait for instead: WebRTC offers no playout-complete callback, so
    /// any automatic resume is a guess at how long the tail is. A guess that fires early talks over
    /// the answer, which is the complaint; a guess that fires late is a pause you did not ask for.
    /// Pressing play is one tap and is never wrong.
    var resumesPlaybackAfterAnswer: Bool { false }
}

enum FloorEvent {
    case userTookFloor                          // long-press down, or Live VAD hears the learner
    case userReleased                           // long-press up; see note below
    case turnCommitted                          // server accepted the turn -> a reply is coming
    case nothingSaid                            // released without speech; nobody gets the floor
    case teacherFinished(resumePlayback: Bool)  // teacher done; quick-ask resumes, Live stays idle
    case playbackRequested                      // learner pressed play / asked to play
    case playbackHeld                           // learner paused / asked to pause
    case sessionEnded
}

// The floor transitions, as one table instead of decisions scattered across the
// controller. Pure, so the rules are testable without a transport.
//
// The subtle one is `.userReleased` keeping the floor on `.user`. It's tempting to
// hand it to the teacher on release, but the server ends a turn by hearing
// TRAILING SILENCE — on device, speech_stopped and committed both arrive after the
// finger lifts. Since the mic gate derives from the floor (open on `.user`),
// yielding at release would close the mic and the turn would never be committed:
// no answer, ever. So release waits, and `.turnCommitted` is what hands over.
func floorReducer(_ holder: FloorHolder, _ event: FloorEvent) -> FloorHolder {
    switch event {
    case .userTookFloor: return .user
    case .userReleased: return holder            // keep listening until committed
    case .turnCommitted: return .teacher
    case .nothingSaid: return .idle
    case let .teacherFinished(resume): return resume ? .player : .idle
    case .playbackRequested: return .player
    case .playbackHeld: return .idle
    case .sessionEnded: return .idle
    }
}

// Granting the floor to `holder` means silencing the other two. Returns what to
// mute so the caller performs exactly one handoff, never leaving two sources on.
func silenced(by holder: FloorHolder) -> (pausePlayer: Bool, stopTeacher: Bool) {
    switch holder {
    case .player: return (false, true)   // podcast speaks; teacher quiet
    case .user: return (true, true)      // learner speaks; both quiet
    case .teacher: return (true, false)  // teacher speaks; podcast paused
    case .idle: return (true, true)      // nobody speaks
    }
}
