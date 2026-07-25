#if os(iOS)
import SwiftData
import SwiftUI

struct ShadowingView: View {
    let episodeId: Int
    let sentenceId: Int
    let sentenceText: String
    @StateObject private var vm: ShadowingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    init(episodeId: Int, sentenceId: Int, sentenceText: String, store: EpisodeStore) {
        self.episodeId = episodeId; self.sentenceId = sentenceId; self.sentenceText = sentenceText
        _vm = StateObject(wrappedValue: ShadowingViewModel(store: store, keychain: KeychainStore(), recorder: ShadowingRecorder()))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x8) {
                ShadowingHeader(onClose: { dismiss() })

                PracticePrompt(
                    sentenceText: sentenceText,
                    isRecording: vm.isRecording,
                    onRecordToggle: toggleRecording
                )

                if let error = vm.feedbackError {
                    NXErrorState(message: error)
                }

                TakesSection(
                    recordings: vm.orderedRecordings(),
                    requestingFeedback: vm.requestingFeedback,
                    onMarkBest: { recording in vm.markBest(recording: recording, sentenceId: sentenceId) },
                    onFeedback: { recording in
                        Task {
                            await vm.requestFeedback(recording: recording, sentenceText: sentenceText, sentenceId: sentenceId)
                        }
                    }
                )
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, NXSpacing.x6)
            .padding(.vertical, NXSpacing.x6)
            .frame(maxWidth: .infinity)
        }
        .background(NXColor.background(scheme))
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { vm.reload(sentenceId: sentenceId) }
    }

    private func toggleRecording() {
        if vm.isRecording {
            vm.stopRecording(episodeId: episodeId, sentenceId: sentenceId)
        } else {
            vm.startRecording(episodeId: episodeId, sentenceId: sentenceId)
        }
    }
}

private struct ShadowingHeader: View {
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x4) {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                NXTag(text: "Shadowing", tint: NXColor.primary)
                Text("Practice this line")
                    .font(NXFont.pageTitle)
                    .foregroundStyle(NXColor.text(scheme))
                Text("Record a take, compare it with the source, and keep the strongest version.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            NXIconButton(systemName: "xmark", accessibilityLabel: "Close shadowing", action: onClose)
        }
    }
}

private struct PracticePrompt: View {
    let sentenceText: String
    let isRecording: Bool
    let onRecordToggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x6) {
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                Text("Source line")
                    .font(NXFont.label)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                Text(sentenceText)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(NXColor.text(scheme))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, NXSpacing.x3)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(NXColor.primary.opacity(0.72))
                    .frame(width: 2)
            }

            HStack(alignment: .center, spacing: NXSpacing.x4) {
                RecordButton(isRecording: isRecording, action: onRecordToggle)

                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    Text(isRecording ? "Recording..." : "Ready to record")
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                    Text(isRecording ? "Tap stop when this take is complete." : "Speak naturally, then request feedback on the take.")
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(NXSpacing.x4)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 48, height: 48)
                .background(isRecording ? NXColor.error : NXColor.primary, in: RoundedRectangle(cornerRadius: NXRadius.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct TakesSection: View {
    let recordings: [StoredRecording]
    let requestingFeedback: Bool
    let onMarkBest: (StoredRecording) -> Void
    let onFeedback: (StoredRecording) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Takes")

            if recordings.isEmpty {
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    Text("No takes yet")
                        .font(NXFont.subsectionTitle)
                        .foregroundStyle(NXColor.text(scheme))
                    Text("Record one take to start comparing pronunciation and rhythm.")
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                }
                .padding(.vertical, NXSpacing.x4)
            } else {
                VStack(spacing: 0) {
                    ForEach(recordings, id: \.persistentModelID) { recording in
                        TakeRow(
                            recording: recording,
                            requestingFeedback: requestingFeedback,
                            onMarkBest: { onMarkBest(recording) },
                            onFeedback: { onFeedback(recording) }
                        )
                        if recording.persistentModelID != recordings.last?.persistentModelID {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
                .padding(.horizontal, NXSpacing.x4)
                .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
                .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
            }
        }
    }
}

private struct TakeRow: View {
    let recording: StoredRecording
    let requestingFeedback: Bool
    let onMarkBest: () -> Void
    let onFeedback: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            HStack(alignment: .center, spacing: NXSpacing.x3) {
                Image(systemName: recording.isBest ? "star.fill" : "waveform")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(recording.isBest ? NXColor.insight : NXColor.textTertiary(scheme))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    Text(recording.isBest ? "Best take" : "Practice take")
                        .font(NXFont.bodyMedium)
                        .foregroundStyle(NXColor.text(scheme))
                    Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                }

                Spacer(minLength: NXSpacing.x3)

                if !recording.isBest {
                    NXTextButton(title: "Best", systemName: "star", action: onMarkBest)
                }
                NXTextButton(
                    title: requestingFeedback ? "Waiting" : "Feedback",
                    systemName: requestingFeedback ? "clock" : "sparkles",
                    disabled: requestingFeedback,
                    action: onFeedback
                )
            }

            if let feedback = recording.feedback, !feedback.isEmpty {
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    NXTag(text: "Feedback", tint: NXColor.insight)
                    Text(feedback)
                        .font(NXFont.body)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, NXSpacing.x3)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(NXColor.insight.opacity(0.72))
                        .frame(width: 2)
                }
            }
        }
        .padding(.vertical, NXSpacing.x4)
    }
}
#endif
