#if os(iOS)
import SwiftUI

/// Hold the button, say the sentence, see a score.
///
/// Replaces ShadowingView (247 lines) and ExamplePracticeView (120), which differed only in
/// what text they showed and cost four taps for one score.
///
/// SPEAKING is the task, so there is one control for it: press and hold. Holding *is* the
/// take — your thumb already knows when you have finished, so there is no stop button to find
/// and no state to read, and an accidental take is impossible because letting go ends it.
/// Hearing the sentence is support, so it is a 36pt circle beside the text; giving it half the
/// primary controls, as an earlier round did, said the wrong thing about what to do here.
///
/// Layout: no `Spacer()`. Two of them pushed the content to the edges of a 6.9" screen with a
/// void between. Every font is an `NXFont` style — hardcoding `.system(size: 26)` is what
/// DesignSystem's own comment warns against, since it never scales with the reader's text size.
struct PracticeView: View {
    /// What is being practised. A card example, a pattern, or a transcript sentence — the flow
    /// is identical, so the only difference is the text and where a score is filed.
    struct Subject {
        let episodeId: Int
        let text: String
        let chinese: String
        /// Set for a card; nil for a transcript sentence.
        let expressionId: Int?
        /// Set for a transcript sentence; nil for a card.
        let sentenceId: Int?
        /// Real speech where there is any, synthesis otherwise.
        ///
        /// Synthesis sounded bad for a findable reason: `AVSpeechSynthesisVoice(language:)`
        /// resolves to `super-compact.Samantha`, Apple's most compressed offline voice, and
        /// this machine has zero premium or enhanced English voices installed. A transcript
        /// sentence has the speaker's own audio behind it, so it uses that.
        var audio: ModelAudio = .synthesised
    }

    let subject: Subject
    let store: EpisodeStore
    /// Plays the episode's own audio between two offsets and calls back when it passes the end.
    /// Supplied by StudyView, which owns the player — this view must not hold a second one, or
    /// two players would fight over the audio session.
    var onPlayOriginal: ((Int, Int, @escaping () -> Void) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var flow = PracticeFlow()
    @State private var speaker = ModelSentence()
    @State private var recorder = PracticeRecorder()
    @State private var score: DashScopePracticeResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x4) {
                sentence
                recordButton
                status
                if let score { ScoreCard(score: score) }
            }
            .padding(NXSpacing.x4)
            .padding(.top, NXSpacing.x2)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(NXColor.background(scheme))
        .onDisappear {
            speaker.stop()
            recorder.stop()
        }
    }

    // No header. A "跟读" tag next to an × was a whole line spent telling the learner what they
    // just tapped, on a sheet that is dismissed by swiping down. The sentence is the title.

    /// The sentence, with listening as a small button beside it.
    ///
    /// Hearing it is support, not the task — it earned half the screen's primary controls in
    /// the previous round and did not deserve it. Speaking is the task.
    private var sentence: some View {
        HStack(alignment: .top, spacing: NXSpacing.x3) {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                Text(subject.text)
                    .font(NXFont.sectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subject.chinese)
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: listen) {
                Image(systemName: isListening ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(.body, weight: .medium))
                    .foregroundStyle(NXColor.primary)
                    .frame(width: 36, height: 36)
                    .background(NXColor.primary.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isSpeaking)
            .accessibilityLabel("听这句")
        }
        .padding(NXSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
    }

    /// Hold to talk. The one control this screen is for.
    ///
    /// Press-and-hold rather than tap-to-start/tap-to-stop, because holding IS the take: your
    /// thumb already knows when you have finished speaking, so there is no second target to
    /// find and no state to read. It also makes an accidental take impossible — let go and it
    /// is over.
    private var recordButton: some View {
        VStack(spacing: NXSpacing.x2) {
            ZStack {
                Circle()
                    .fill(isSpeaking ? NXColor.error : NXColor.primary)
                    .frame(width: 84, height: 84)
                    // Grows while held, so the press is visible without reading a label.
                    .scaleEffect(isSpeaking ? 1.08 : 1)
                    .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isSpeaking)
                if case .speaking(let level) = flow.stage {
                    Waveform(level: level, tint: .white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Circle())
            // A DragGesture with no minimum distance fires the moment the finger lands and
            // ends when it lifts, anywhere. `LongPressGesture` would impose a delay before
            // recording starts, and the first word would be lost inside it.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !isSpeaking { beginTake() } }
                    .onEnded { _ in if isSpeaking { endTake() } }
            )
            .accessibilityLabel("按住说话")
            Text(isSpeaking ? "\u{677e}\u{5f00}\u{7ed3}\u{675f}" : "\u{6309}\u{4f4f}\u{8bf4}\u{8bdd}")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    /// Only what the button cannot say for itself. "录音中" is redundant beside a red circle
    /// with a live waveform in it, and 按住说话 already sits under the button.
    @ViewBuilder
    private var status: some View {
        switch flow.stage {
        case .scoring:
            line("\u{8bc4}\u{6d4b}\u{4e2d}...")
        case .failed(let message):
            Text(message)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.error)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .listening, .speaking, .scored:
            EmptyView()
        }
    }

    private func line(_ text: String) -> some View {
        Text(text).font(NXFont.auxiliary).foregroundStyle(NXColor.textTertiary(scheme))
    }

    private var isListening: Bool { flow.stage == .listening }
    private var isSpeaking: Bool {
        if case .speaking = flow.stage { return true }
        return false
    }

    private func listen() {
        guard !isSpeaking else { return }  // never cut off a take in progress
        recorder.stop()
        flow.begin()
        if let window = subject.audio.playbackWindow, let play = onPlayOriginal {
            // The speaker's own voice, bounded to this sentence. Unbounded it would play the
            // whole 33-second paragraph the segment belongs to.
            play(window.start, window.end) { flow.listenFinished() }
        } else {
            speaker.say(subject.text) { flow.listenFinished() }
        }
    }

    /// Finger down.
    private func beginTake() {
        speaker.stop()
        score = nil
        flow.startTake()
        let target = RecordingFiles.recordingURL(
            episodeId: subject.episodeId,
            sentenceId: subject.sentenceId ?? subject.expressionId ?? 0)
        recorder.onLevel = { level in flow.heard(level: level) }
        recorder.onFinished = { url in
            // The silence gate. With hold-to-talk it only fires on the 30s ceiling — a finger
            // held down and forgotten — since lifting ends the take first.
            flow.takeFinished(recording: url)
            if let url { Task { await evaluate(url) } }
        }
        do {
            try recorder.start(to: target.url)
        } catch {
            flow.failed("\u{9ea6}\u{514b}\u{98ce}\u{6253}\u{4e0d}\u{5f00}：\(error.localizedDescription)")
        }
    }

    /// Finger up.
    private func endTake() {
        guard let url = recorder.stop() else {
            flow.failed("\u{6ca1}\u{5f55}\u{5230}\u{58f0}\u{97f3}")
            return
        }
        flow.takeFinished(recording: url)
        Task { await evaluate(url) }
    }

    private func evaluate(_ url: URL) async {
        let keychain = KeychainStore()
        guard let key = keychain.get(.dashscopeKey), !key.isEmpty,
              let workspace = keychain.get(.dashscopeWorkspaceId), !workspace.isEmpty else {
            flow.failed("\u{8bf7}\u{5148}\u{5728}\u{8bbe}\u{7f6e}\u{91cc}\u{586b}\u{5165}\u{8bc4}\u{6d4b}\u{5bc6}\u{94a5}")
            return
        }
        do {
            let result = try await DashScopePracticeClient(apiKey: key, workspaceId: workspace)
                .evaluate(example: subject.text, audioURL: url)
            score = result
            if let expressionId = subject.expressionId {
                _ = try? store.addExamplePractice(
                    episodeId: subject.episodeId, expressionId: expressionId,
                    localFilePath: url.lastPathComponent,
                    overall: result.overall, clarity: result.clarity,
                    stressRhythm: result.stressRhythm, completeness: result.completeness,
                    advice: result.advice)
            }
            flow.scored()
        } catch {
            flow.failed(error.localizedDescription)
        }
    }
}

/// Live level, so the learner can see the mic is hearing them. The old screens showed a red
/// "Recording..." label, which says the app is busy rather than that YOU are being heard.
private struct Waveform: View {
    let level: Float
    var tint: Color = NXColor.primary
    private static let bars = 7

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: 4, height: height(index))
            }
        }
        .frame(height: 30, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Tallest in the middle, so it reads as a voice rather than a bar chart.
    private func height(_ index: Int) -> CGFloat {
        let distance = abs(Double(index) - Double(Self.bars - 1) / 2)
        let falloff = 1 - distance / Double(Self.bars)
        return max(4, CGFloat(Double(level) * falloff) * 30)
    }
}

/// The score, with the advice given the most room — a number says where you are, the sentence
/// says what to change.
private struct ScoreCard: View {
    let score: DashScopePracticeResult
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            HStack(alignment: .firstTextBaseline, spacing: NXSpacing.x2) {
                Text("\(score.overall)")
                    .font(NXFont.pageTitle)
                    .foregroundStyle(NXColor.primary)
                Text("\u{6e05}\u{6670} \(score.clarity) · \u{8282}\u{5949} \(score.stressRhythm) · \u{5b8c}\u{6574} \(score.completeness)")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
            Text(score.advice)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NXSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
    }
}
#endif
