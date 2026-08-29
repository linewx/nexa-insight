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
/// Hearing the sentence is support, so it is a small capsule under it; giving it half the
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
    /// The episode's audio file, so this sheet can play one sentence of it on its OWN player.
    ///
    /// It used to call back into StudyView to seek the MAIN player, which meant asking to hear
    /// one line moved the transcript underneath the sheet and left it playing from there — the
    /// outer paragraph carried on, because it was the same player at the same position.
    ///
    /// The earlier comment here warned that a second player would fight over the audio session.
    /// SegmentPlayback does not touch the session at all: the main player has already configured
    /// it, and this only needs to make sound.
    var audioFileURL: URL? = nil
    /// Pauses the main player while this sheet is open, so one sentence is the only thing heard.
    var onSuspendMainPlayback: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var flow = PracticeFlow()
    @State private var speaker = ModelSentence()
    @State private var recorder = PracticeRecorder()
    @State private var score: DashScopePracticeResult?
    /// This sheet's own player. A dummy URL when there is no audio — the TTS path is used then,
    /// and an AVPlayer over a missing file simply never plays.
    @StateObject private var segment: SegmentPlayback

    init(subject: Subject, store: EpisodeStore, audioFileURL: URL? = nil,
         onSuspendMainPlayback: (() -> Void)? = nil) {
        self.subject = subject
        self.store = store
        self.audioFileURL = audioFileURL
        self.onSuspendMainPlayback = onSuspendMainPlayback
        _segment = StateObject(wrappedValue: SegmentPlayback(
            fileURL: audioFileURL ?? URL(fileURLWithPath: "/dev/null")))
    }

    var body: some View {
        // No ScrollView. Everything fits a `.medium` sheet by construction — scrolling a
        // half-sheet with four elements in it is the app admitting the layout does not fit,
        // and the score arrived below the fold, which is the one thing you want to see.
        //
        // The record button shrinks once a score exists: before it is the only thing to do, and
        // after it is "try again". Measured — 534pt of content in a 437pt sheet was the
        // overflow, and this is where the height comes from.
        //
        // Spacing is no longer uniform. One gap for everything was set while the content
        // OVERFLOWED, and once it fitted the same value left the sentence and the button
        // stranded at opposite ends with a void between them. The sentence and its 听 button
        // belong together, the record button is the thing you came to press, and the status line
        // describes that button — so it sits close to it rather than floating midway.
        VStack(spacing: 0) {
            sentence
            Spacer(minLength: NXSpacing.x4)
            recordButton
            // Close to the button it describes: "按住说话" and the level readout are a caption,
            // not a separate section.
            status.padding(.top, NXSpacing.x2)
            if let score {
                Spacer(minLength: NXSpacing.x3)
                ScoreCard(score: score)
            }
            // Absorbs whatever the sheet has left over, so nothing is stretched to fill it.
            Spacer(minLength: 0)
        }
        .task {
            // Ahead of the first press, not inside it: activating the audio session blocks the
            // main thread long enough to swallow the first syllable and to leave the button
            // looking unresponsive.
            recorder.prepareSession()
        }
        .padding(.horizontal, NXSpacing.x4)
        .padding(.top, score == nil ? NXSpacing.x6 : NXSpacing.x4)
        .padding(.bottom, NXSpacing.x4)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: score == nil)
        // Centred, not leading. The button is the focus of this screen and a left-aligned
        // stack hung it off to one side of its own sheet.
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
        VStack(spacing: NXSpacing.x2) {
            // Listening is an icon in the corner, not a labelled control. It kept creeping back
            // up the hierarchy — half the primary buttons, then a captioned capsule — and it is
            // support for the task, not a step in it.
            HStack(alignment: .top, spacing: NXSpacing.x2) {
                Text(subject.text)
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(NXColor.text(scheme))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    // Keeps the sentence optically centred despite the icon on one side.
                    .padding(.leading, 28)
                Button(action: listen) {
                    Image(systemName: isListening ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(isListening ? NXColor.primary : NXColor.textTertiary(scheme))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSpeaking)
                .accessibilityLabel("听这句")
            }
            Text(subject.chinese)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, NXSpacing.x4)
        .padding(.vertical, NXSpacing.x4)
        .frame(maxWidth: .infinity)
        .background {
            // A flat grey rectangle was most of what read as crude. A soft gradient plus a
            // hairline border gives the card an edge and a light source.
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [NXColor.surface1(scheme),
                                 NXColor.surface2(scheme).opacity(scheme == .dark ? 0.9 : 0.55)],
                        startPoint: .top, endPoint: .bottom))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(NXColor.primary.opacity(scheme == .dark ? 0.14 : 0.08),
                                      lineWidth: 1)
                }
        }
    }

    /// Hold to talk. The one control this screen is for.
    ///
    /// Press-and-hold rather than tap-to-start/tap-to-stop, because holding IS the take: your
    /// thumb already knows when you have finished speaking, so there is no second target to
    /// find and no state to read. It also makes an accidental take impossible — let go and it
    /// is over.
    /// Full size while it is the only thing to do; smaller once a score is showing, where it
    /// means "try again". This is what buys the score card its room without scrolling.
    private var buttonDiameter: CGFloat { score == nil ? 88 : 64 }
    private var haloDiameter: CGFloat { buttonDiameter + 30 }

    private var recordButton: some View {
        VStack(spacing: NXSpacing.x2) {
            ZStack {
                // A halo that only exists while recording, sized by how loudly you are
                // speaking. A bare disc on a flat background was the crudest thing here — this
                // gives the press somewhere to land and makes level visible at a glance.
                Circle()
                    .fill((isSpeaking ? NXColor.error : NXColor.primary).opacity(0.14))
                    .frame(width: haloDiameter, height: haloDiameter)
                    .scaleEffect(isSpeaking ? 1 + CGFloat(currentLevel) * 0.22 : 0.86)
                    .opacity(isSpeaking ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: currentLevel)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSpeaking)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: isSpeaking
                                ? [NXColor.error, NXColor.error.opacity(0.82)]
                                : [NXColor.primary, NXColor.primary.opacity(0.78)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: buttonDiameter, height: buttonDiameter)
                    // A coloured shadow rather than a grey one, so the button reads as lit
                    // rather than as a sticker sitting on the page.
                    .shadow(color: (isSpeaking ? NXColor.error : NXColor.primary)
                        .opacity(scheme == .dark ? 0.5 : 0.34), radius: 16, y: 7)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    }
                    // Presses IN, not out. Growing under the thumb pushed the button toward
                    // the finger covering it; shrinking reads as depressed.
                    .scaleEffect(isSpeaking ? 0.95 : 1)
                    .animation(.spring(response: 0.26, dampingFraction: 0.7), value: isSpeaking)
                if case .speaking(let level) = flow.stage {
                    Waveform(level: level, tint: .white)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: score == nil ? 30 : 22, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                }
            }
            .frame(width: haloDiameter, height: haloDiameter)
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
            Text(isSpeaking ? "\u{677e}\u{5f00}\u{7ed3}\u{675f}"
                 : (score == nil ? "\u{6309}\u{4f4f}\u{8bf4}\u{8bdd}" : "\u{6309}\u{4f4f}\u{518d}\u{8bf4}\u{4e00}\u{904d}"))
                .font(NXFont.label)
                .foregroundStyle(isSpeaking ? NXColor.error : NXColor.textTertiary(scheme))
                .animation(.easeInOut(duration: 0.15), value: isSpeaking)
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
    /// Drives the halo. 0 when not recording, so it collapses rather than freezing at its last
    /// size when the take ends.
    private var currentLevel: Float {
        if case .speaking(let level) = flow.stage { return level }
        return 0
    }
    private var isSpeaking: Bool {
        if case .speaking = flow.stage { return true }
        return false
    }

    private func listen() {
        guard !isSpeaking else { return }  // never cut off a take in progress
        recorder.stop()
        // The outer paragraph must not play under this sheet. Asked for once per listen rather
        // than only on open, since the learner can start the transcript from the dock behind.
        onSuspendMainPlayback?()
        flow.begin()
        if let window = subject.audio.playbackWindow, audioFileURL != nil {
            // The speaker's own voice, bounded to this sentence, on this sheet's own player.
            segment.play(fromMs: window.start, toMs: window.end) { flow.listenFinished() }
        } else {
            speaker.say(subject.text) { flow.listenFinished() }
        }
    }

    /// Finger down.
    private func beginTake() {
        speaker.stop()
        segment.stop()
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

    /// Green when it was good, amber when it was not. A single colour for every score made the
    /// number decorative — you had to read it to know how you did.
    private var tint: Color {
        score.overall >= 80 ? NXColor.success : (score.overall >= 60 ? NXColor.insight : NXColor.error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            HStack(alignment: .center, spacing: NXSpacing.x3) {
                // A ring rather than a bare numeral: it shows the score against its ceiling,
                // which a "82" alone does not.
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.16), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(min(100, max(0, score.overall))) / 100)
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(score.overall)")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    metric("\u{6e05}\u{6670}", score.clarity)
                    metric("\u{8282}\u{5949}", score.stressRhythm)
                    metric("\u{5b8c}\u{6574}", score.completeness)
                }
            }
            Text(score.advice)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NXSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(NXColor.surface1(scheme))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                }
        }
    }

    /// Three bars beat three numbers: the short one is the thing to work on, without reading.
    private func metric(_ label: String, _ value: Int) -> some View {
        HStack(spacing: NXSpacing.x2) {
            Text(label)
                .font(NXFont.label)
                .foregroundStyle(NXColor.textTertiary(scheme))
                .frame(width: 26, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.14))
                    Capsule()
                        .fill(tint.opacity(0.75))
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, value))) / 100)
                }
            }
            .frame(height: 5)
            Text("\(value)")
                .font(NXFont.label)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .frame(width: 22, alignment: .trailing)
        }
    }
}
#endif
