#if os(iOS)
import SwiftUI

struct ExamplePracticeView: View {
    let episodeId: Int
    let expression: LearningExpressionDTO
    let store: EpisodeStore
    let onStartRecording: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var recorder = ExamplePracticeRecorder()
    @State private var isRecording = false
    @State private var activeURL: URL?
    @State private var activeRelativePath: String?
    @State private var isEvaluating = false
    @State private var error: String?
    @State private var latest: StoredExamplePractice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                HStack {
                    VStack(alignment: .leading, spacing: NXSpacing.x1) {
                        NXTag(text: "Example practice", tint: NXColor.primary)
                        Text(expression.text).font(NXFont.pageTitle).foregroundStyle(NXColor.text(scheme))
                    }
                    Spacer()
                    NXIconButton(systemName: "xmark", accessibilityLabel: "Close example practice", action: { dismiss() })
                }

                VStack(alignment: .leading, spacing: NXSpacing.x3) {
                    Text("Example sentence").font(NXFont.label).foregroundStyle(NXColor.textTertiary(scheme))
                    Text(expression.example).font(.system(size: 20, weight: .medium)).foregroundStyle(NXColor.text(scheme))
                    Text(expression.exampleChinese).font(NXFont.body).foregroundStyle(NXColor.textSecondary(scheme))
                }
                .padding(NXSpacing.x4)
                .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))

                Button(action: toggleRecording) {
                    Label(isRecording ? "停止录音" : "录下这句例句", systemImage: isRecording ? "stop.fill" : "mic.fill")
                        .font(NXFont.bodyMedium).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 50)
                        .background(isRecording ? NXColor.error : NXColor.primary, in: RoundedRectangle(cornerRadius: NXRadius.surface))
                }
                .buttonStyle(.plain)

                if let error { NXErrorState(message: error) }

                if isEvaluating {
                    ProgressView("正在评测你的录音...").frame(maxWidth: .infinity, alignment: .leading)
                } else if activeURL != nil && !isRecording {
                    Button("开始评测", action: evaluate)
                        .font(NXFont.bodyMedium).foregroundStyle(NXColor.primary)
                        .buttonStyle(.plain)
                }

                if let latest {
                    VStack(alignment: .leading, spacing: NXSpacing.x3) {
                        Text("练习反馈").font(NXFont.subsectionTitle).foregroundStyle(NXColor.text(scheme))
                        Text("综合 \(latest.overall) / 100").font(.system(size: 28, weight: .bold)).foregroundStyle(NXColor.primary)
                        HStack { metric("清晰度", latest.clarity); metric("重音与节奏", latest.stressRhythm); metric("完整度", latest.completeness) }
                        Text(latest.advice).font(NXFont.body).foregroundStyle(NXColor.textSecondary(scheme))
                        Text("这是练习反馈，不是正式或考试级发音测评。").font(NXFont.auxiliary).foregroundStyle(NXColor.textTertiary(scheme))
                    }
                    .padding(NXSpacing.x4)
                    .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
                }
            }
            .padding(NXSpacing.x6)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(NXColor.background(scheme))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { latest = store.examplePractices(episodeId: episodeId, expressionId: expression.id).first }
    }

    private func metric(_ title: String, _ score: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text("\(score)").font(NXFont.bodyMedium); Text(title).font(NXFont.auxiliary) }
            .foregroundStyle(NXColor.textSecondary(scheme)).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleRecording() {
        error = nil
        if isRecording { recorder.stop(); isRecording = false; return }
        let target = ExamplePracticeFiles.recordingURL(episodeId: episodeId, expressionId: expression.id)
        do {
            onStartRecording()
            try recorder.start(to: target.url)
            activeURL = target.url; activeRelativePath = target.relative; isRecording = true
        } catch { self.error = error.localizedDescription }
    }

    private func evaluate() {
        guard let activeURL, let activeRelativePath else { return }
        let keychain = KeychainStore()
        guard let key = keychain.get(.dashscopeKey), let workspace = keychain.get(.dashscopeWorkspaceId), !key.isEmpty, !workspace.isEmpty else {
            error = DashScopePracticeError.missingConfiguration.localizedDescription
            return
        }
        isEvaluating = true; error = nil
        Task {
            defer { isEvaluating = false }
            do {
                let score = try await DashScopePracticeClient(apiKey: key, workspaceId: workspace).evaluate(example: expression.example, audioURL: activeURL)
                latest = try store.addExamplePractice(episodeId: episodeId, expressionId: expression.id, localFilePath: activeRelativePath, overall: score.overall, clarity: score.clarity, stressRhythm: score.stressRhythm, completeness: score.completeness, advice: score.advice)
            } catch { self.error = error.localizedDescription }
        }
    }
}

private enum ExamplePracticeFiles {
    static func recordingURL(episodeId: Int, expressionId: Int) -> (url: URL, relative: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("example-practice/\(episodeId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(expressionId)-\(UUID().uuidString).wav"
        return (directory.appendingPathComponent(name), "example-practice/\(episodeId)/\(name)")
    }
}
#endif
