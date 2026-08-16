#if os(iOS)
import SwiftUI

/// Listen, speak, see a score — one tap, one screen.
///
/// Replaces ShadowingView (247 lines) and ExamplePracticeView (120), which differed only in
/// what text they showed. Both cost four taps for one score (open, record, stop, evaluate) and
/// neither could PLAY the sentence, so "跟读" meant "read this and hope".
///
/// The state machine is `PracticeFlow` and the stop decision is `SilenceGate`, both pure and
/// tested. This file is the parts that need a device: speaking, recording, scoring.
struct PracticeView: View {
    /// What the learner is practising. A card example, a pattern, or a transcript sentence —
    /// the flow is identical, so the only difference is the text and where a score is filed.
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
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            header
            sentence
            Spacer(minLength: NXSpacing.x4)
            stageView
            Spacer()
            actions
        }
        .padding(NXSpacing.x6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NXColor.background(scheme))
        // Starts itself. Opening the sheet WAS the tap — asking for another one to begin is
        // the tap this redesign removes.
        .task { start() }
        .onDisappear {
            speaker.stop()
            recorder.stop()
        }
    }

    private var header: some View {
        HStack {
            NXTag(text: "\u{8ddf}\u{8bfb}", tint: NXColor.primary)
            Spacer()
            NXIconButton(systemName: "xmark", accessibilityLabel: "关闭跟读", action: { dismiss() })
        }
    }

    private var sentence: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Text(subject.text)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(subject.chinese)
                .font(NXFont.body)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line of state, in the learner's language, in the place they are already looking.
    @ViewBuilder
    private var stageView: some View {
        switch flow.stage {
        case .idle, .listening:
            statusLine(icon: "speaker.wave.2.fill", text: "\u{542c}...")
        case .speaking(let level):
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                statusLine(icon: "mic.fill", text: "\u{8bf7}\u{8bf4}...")
                Waveform(level: level)
            }
        case .scoring:
            statusLine(icon: "hourglass", text: "\u{8bc4}\u{6d4b}\u{4e2d}...")
        case .scored:
            if let score { ScoreCard(score: score) }
        case .failed(let message):
            NXErrorState(message: message)
        }
    }

    private func statusLine(icon: String, text: String) -> some View {
        HStack(spacing: NXSpacing.x2) {
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(NXColor.primary)
            Text(text).font(NXFont.bodyMedium).foregroundStyle(NXColor.textSecondary(scheme))
        }
    }

    /// Only ever two, and only once there is something to react to. During listen-speak-score
    /// there is nothing to press, which is the point.
    @ViewBuilder
    private var actions: some View {
        if !flow.isBusy && flow.stage != .idle {
            HStack(spacing: NXSpacing.x3) {
                NXPrimaryButton(title: "\u{518d}\u{8bd5}\u{4e00}\u{6b21}", systemName: "arrow.counterclockwise", action: start)
                NXSecondaryButton(title: "\u{518d}\u{542c}\u{4e00}\u{904d}", systemName: "speaker.wave.2", action: replay)
            }
        }
    }

    private func start() {
        score = nil
        flow.begin()
        speak()
    }

    private func replay() {
        guard flow.replay() else { return }
        speak()
    }

    private func speak() {
        speaker.stop()
        recorder.stop()
        speaker.say(subject.text) {
            flow.sentenceFinished()
            beginTake()
        }
    }

    private func beginTake() {
        guard case .speaking = flow.stage else { return }
        let target = RecordingFiles.recordingURL(
            episodeId: subject.episodeId,
            sentenceId: subject.sentenceId ?? subject.expressionId ?? 0
        )
        recorder.onLevel = { level in flow.heard(level: level) }
        recorder.onFinished = { url in
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
            flow.failed("\u{8bf7}先在设置里填入评测密钥")
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

/// Live level, so the learner can see the mic is hearing them. The old screens showed only a
/// red "Recording..." label, which says the app is busy rather than that YOU are being heard.
private struct Waveform: View {
    let level: Float
    private static let bars = 9

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(0..<Self.bars, id: \.self) { index in
                Capsule()
                    .fill(NXColor.primary.opacity(0.85))
                    .frame(width: 4, height: height(index))
            }
        }
        .frame(height: 34, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    /// Tallest in the middle, so it reads as a voice rather than a bar chart.
    private func height(_ index: Int) -> CGFloat {
        let distance = abs(Double(index) - Double(Self.bars - 1) / 2)
        let falloff = 1 - distance / Double(Self.bars)
        return max(4, CGFloat(Double(level) * falloff) * 34)
    }
}

/// The score, with the advice given the most room — a number tells you where you are, the
/// sentence tells you what to change.
private struct ScoreCard: View {
    let score: DashScopePracticeResult
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            Text("\(score.overall)")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(NXColor.primary)
            Text(score.advice)
                .font(NXFont.bodyMedium)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
            // The three sub-scores were three labelled numbers competing with the advice.
            // Kept, but as one quiet line: they matter when you want detail, not by default.
            Text("\u{6e05}\u{6670} \(score.clarity) · \u{8282}\u{5949} \(score.stressRhythm) · \u{5b8c}\u{6574} \(score.completeness)")
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
        .padding(NXSpacing.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
    }
}
#endif
