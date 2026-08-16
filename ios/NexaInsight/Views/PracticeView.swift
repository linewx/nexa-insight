#if os(iOS)
import SwiftUI

/// Listen, speak, see a score — on one compact screen, driven by the learner.
///
/// Replaces ShadowingView (247 lines) and ExamplePracticeView (120), which differed only in
/// what text they showed, cost four taps for one score, and — the real gap — could not PLAY
/// anything. "跟读" means shadow this, and there was nothing to shadow.
///
/// Two controls, always in the same place: hear it, say it. The take ends when the learner
/// taps again; `SilenceGate` only backstops a take they walked away from. Auto-advancing from
/// playback straight into recording was tried and felt like being rushed.
///
/// Layout note: no `Spacer()` here. Two of them pushed the sentence to the top and the buttons
/// to the bottom of a 6.9" screen with a void between, and every font is an `NXFont` style —
/// hardcoding `.system(size: 26)` is exactly what DesignSystem's own comment warns against,
/// since it never scales with the reader's text size.
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
    }

    let subject: Subject
    let store: EpisodeStore
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
                controls
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

    private var sentence: some View {
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
        .padding(NXSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
    }

    /// Two buttons, fixed in place. They never move or reorder between stages, so the learner
    /// aims once — the old screens revealed 开始评测 only after recording, moving the target.
    private var controls: some View {
        // Sized here rather than with NXPrimaryButton, whose 36pt/footnote is right for a
        // toolbar and too small for the two actions this screen exists for. Equal halves, so
        // neither is the one you have to aim at.
        HStack(spacing: NXSpacing.x3) {
            action(
                title: isListening ? "\u{6b63}\u{5728}\u{653e}" : "\u{542c}\u{4e00}\u{904d}",
                icon: "speaker.wave.2",
                filled: false,
                run: listen)
            action(
                title: isSpeaking ? "\u{8bf4}\u{5b8c}\u{4e86}" : "\u{8bf4}\u{4e00}\u{904d}",
                icon: isSpeaking ? "stop.fill" : "mic.fill",
                filled: true,
                run: toggleTake)
        }
    }

    private func action(title: String, icon: String, filled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: NXSpacing.x2) {
                Image(systemName: icon).font(.system(.footnote, weight: .semibold))
                Text(title).font(NXFont.controlEmphasis)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(filled ? Color.white : NXColor.primary)
            .background {
                RoundedRectangle(cornerRadius: NXRadius.control)
                    .fill(filled ? NXColor.primary : NXColor.primary.opacity(0.12))
            }
        }
        .buttonStyle(.plain)
    }

    /// One line, in the same slot every stage, so nothing below it jumps as state changes.
    @ViewBuilder
    private var status: some View {
        switch flow.stage {
        case .idle:
            line("\u{5148}\u{542c}\u{4e00}\u{904d}，\u{518d}\u{8bf4}\u{4e00}\u{904d}")
        case .listening:
            line("\u{542c}...")
        case .speaking(let level):
            HStack(spacing: NXSpacing.x3) {
                line("\u{5f55}\u{97f3}\u{4e2d}")
                Waveform(level: level)
            }
        case .scoring:
            line("\u{8bc4}\u{6d4b}\u{4e2d}...")
        case .scored:
            EmptyView()  // the score card below says it
        case .failed(let message):
            Text(message)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.error)
                .fixedSize(horizontal: false, vertical: true)
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
        speaker.say(subject.text) { flow.listenFinished() }
    }

    private func toggleTake() {
        if isSpeaking {
            // The learner decides when the take is done. Reading the file back through the
            // same path the silence gate uses keeps one place that scores a take.
            if let url = recorder.stop() {
                flow.takeFinished(recording: url)
                Task { await evaluate(url) }
            } else {
                flow.failed("\u{6ca1}\u{5f55}\u{5230}\u{58f0}\u{97f3}")
            }
            return
        }
        speaker.stop()
        score = nil
        flow.startTake()
        let target = RecordingFiles.recordingURL(
            episodeId: subject.episodeId,
            sentenceId: subject.sentenceId ?? subject.expressionId ?? 0)
        recorder.onLevel = { level in flow.heard(level: level) }
        recorder.onFinished = { url in
            // Only fires when the gate ends a take the learner left running.
            flow.takeFinished(recording: url)
            if let url { Task { await evaluate(url) } }
        }
        do {
            try recorder.start(to: target.url)
        } catch {
            flow.failed("\u{9ea6}\u{514b}\u{98ce}\u{6253}\u{4e0d}\u{5f00}：\(error.localizedDescription)")
        }
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
    private static let bars = 7

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(NXColor.primary.opacity(0.85))
                    .frame(width: 3, height: height(index))
            }
        }
        .frame(height: 16, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Tallest in the middle, so it reads as a voice rather than a bar chart.
    private func height(_ index: Int) -> CGFloat {
        let distance = abs(Double(index) - Double(Self.bars - 1) / 2)
        let falloff = 1 - distance / Double(Self.bars)
        return max(3, CGFloat(Double(level) * falloff) * 16)
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
