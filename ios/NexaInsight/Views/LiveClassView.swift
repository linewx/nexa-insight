#if os(iOS)
import SwiftUI

struct LiveClassView: View {
    @ObservedObject var session: LiveClassSession
    @State private var draft = ""
    let cursorMs: Int
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            if let controller = session.controller {
                DiscussionTopBar(
                    state: controller.state,
                    cursorMs: cursorMs,
                    connected: session.connected,
                    onEnd: endSession
                )
                Divider().overlay(NXColor.border(scheme))

                DiscussionBody(
                    turns: controller.transcript,
                    notice: session.notice,
                    state: controller.state,
                    cursorMs: cursorMs,
                    onPrompt: { prompt in send(prompt, through: controller) }
                )

                Divider().overlay(NXColor.border(scheme))

                MessageComposer(
                    draft: $draft,
                    placeholder: "Ask about this moment, challenge a claim, or make a note",
                    onSend: { sendDraft(through: controller) }
                )
                .padding(NXSpacing.x4)
                .background(NXColor.surface1(scheme))
            } else {
                DiscussionLoadingState(error: session.error, onEnd: endSession)
            }
        }
        .background(NXColor.background(scheme))
        .toolbar(.hidden, for: .navigationBar)
        .task { await session.start() }
    }

    private func sendDraft(through controller: ClassroomController) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        controller.sendText(text)
    }

    private func send(_ text: String, through controller: ClassroomController) {
        controller.sendText(text)
    }

    private func endSession() {
        session.end()
        onEnd()
    }
}

struct InlineDiscussionPanel: View {
    @ObservedObject var session: LiveClassSession
    let anchor: SentenceDTO
    @ObservedObject var player: LocalAudioPlayback
    let onSaveInsight: (String) -> Void
    let onEnd: () -> Void
    @State private var draft = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            discussionHeader
            Divider().overlay(NXColor.border(scheme))

            if let controller = session.controller {
                DiscussionBody(
                    turns: controller.transcript,
                    notice: session.notice,
                    state: controller.state,
                    cursorMs: player.currentMs,
                    onPrompt: { controller.sendText($0) },
                    onSaveInsight: onSaveInsight
                )
                Divider().overlay(NXColor.border(scheme))
                MessageComposer(
                    draft: $draft,
                    placeholder: "Ask anything",
                    onSend: { sendDraft(through: controller) }
                )
                .padding(NXSpacing.x3)
            } else {
                DiscussionLoadingState(error: session.error, onEnd: onEnd)
            }
        }
        .background(NXColor.surface1(scheme))
        .task(id: session.id) { await session.start(at: anchor.startMs) }
    }

    private var discussionHeader: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            HStack(alignment: .top, spacing: NXSpacing.x3) {
                VStack(alignment: .leading, spacing: NXSpacing.x1) {
                    HStack(spacing: NXSpacing.x2) {
                        StatusDot(active: session.connected)
                        NXTag(text: "Discussion", tint: NXColor.primary)
                        Text(formatTime(anchor.startMs))
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textTertiary(scheme))
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: NXSpacing.x2)
                NXIconButton(systemName: "xmark", accessibilityLabel: "End discussion", action: onEnd)
            }

            HStack(spacing: NXSpacing.x2) {
                playbackButton(systemName: "gobackward.15", label: "Back 15 seconds") {
                    player.seek(max(0, player.currentMs - 15_000))
                    player.pause()
                }
                playbackButton(systemName: "repeat", label: "Repeat from discussion start") {
                    player.seek(anchor.startMs)
                    player.play()
                }
                Button {
                    player.playbackState == .playing ? player.pause() : player.play()
                } label: {
                    Label(player.playbackState == .playing ? "Pause" : "Continue", systemImage: player.playbackState == .playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(NXColor.primary)
                .controlSize(.small)
                playbackButton(systemName: "goforward.15", label: "Forward 15 seconds") {
                    player.seek(player.currentMs + 15_000)
                    player.pause()
                }
            }
        }
        .padding(NXSpacing.x4)
    }

    private func playbackButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(NXColor.textSecondary(scheme))
        .accessibilityLabel(label)
    }

    private func sendDraft(through controller: ClassroomController) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        controller.sendText(text)
    }
}

private struct DiscussionTopBar: View {
    let state: ClassroomState
    let cursorMs: Int
    let connected: Bool
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        HStack(alignment: .center, spacing: NXSpacing.x3) {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                HStack(spacing: NXSpacing.x2) {
                    StatusDot(active: connected)
                    Text(classroomMode(state).capitalized)
                        .font(NXFont.label)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                    Text(formatTime(cursorMs))
                        .font(NXFont.label)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                        .monospacedDigit()
                }
                Text(classroomStatusMessage(state, cursorMs))
                    .font(compact ? NXFont.bodyMedium : NXFont.subsectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(compact ? 2 : 1)
            }

            Spacer(minLength: NXSpacing.x3)

            NXSecondaryButton(title: "End", systemName: "xmark", action: onEnd)
        }
        .padding(.horizontal, compact ? NXSpacing.x4 : NXSpacing.x6)
        .padding(.vertical, NXSpacing.x4)
        .background(NXColor.surface1(scheme))
    }
}

private struct StatusDot: View {
    let active: Bool

    var body: some View {
        Circle()
            .fill(active ? NXColor.success : NXColor.textTertiary(.dark))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

private struct DiscussionBody: View {
    let turns: [TutorTurn]
    let notice: String
    let state: ClassroomState
    let cursorMs: Int
    let onPrompt: (String) -> Void
    var onSaveInsight: ((String) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: NXSpacing.x6) {
                    SessionStatePanel(notice: notice, state: state, cursorMs: cursorMs)

                    if turns.isEmpty {
                        EmptyDiscussion(onPrompt: onPrompt)
                    } else {
                        LazyVStack(alignment: .leading, spacing: NXSpacing.x6) {
                            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                                ConversationTurnView(turn: turn, onSaveInsight: onSaveInsight)
                                    .id(index)
                            }
                        }
                    }
                }
                .frame(maxWidth: 820, alignment: .leading)
                .padding(.horizontal, NXSpacing.x4)
                .padding(.vertical, NXSpacing.x6)
                .frame(maxWidth: .infinity)
                .onChange(of: turns.count) { _, count in
                    guard count > 0 else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct SessionStatePanel: View {
    let notice: String
    let state: ClassroomState
    let cursorMs: Int
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            HStack(spacing: NXSpacing.x2) {
                Image(systemName: stateIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NXColor.primary)
                    .frame(width: 18)
                Text(primaryText)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                Spacer()
                Text(formatTime(cursorMs))
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .monospacedDigit()
            }

            if !notice.isEmpty {
                Text(notice)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
        }
        .padding(NXSpacing.x4)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }

    private var stateIcon: String {
        switch state.phase {
        case .podcastPlaying, .resuming: return "waveform"
        case .userSpeaking: return "mic"
        case .teacherSpeaking, .discussing: return "sparkles"
        default: return "pause"
        }
    }

    private var primaryText: String {
        switch state.phase {
        case .podcastPlaying: return "Listening to the source"
        case .userSpeaking: return "Capturing your question"
        case .teacherSpeaking: return "AI is responding"
        case .discussing: return "Preparing a response"
        case .resuming: return "Returning to playback"
        default: return "Discussion paused"
        }
    }

    private var secondaryText: String {
        switch state.phase {
        case .podcastPlaying:
            return "Speak or type when something is worth unpacking."
        case .userSpeaking:
            return "The source is paused so the discussion stays anchored to this moment."
        case .teacherSpeaking, .discussing:
            return "The response will use the nearby transcript and chapter context."
        default:
            return "Ask a follow-up, turn the moment into an insight, or resume the source."
        }
    }
}

private struct EmptyDiscussion: View {
    let onPrompt: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            SuggestedPromptRow(text: "Explain this idea", onPrompt: onPrompt)
            SuggestedPromptRow(text: "Challenge this claim", onPrompt: onPrompt)
            SuggestedPromptRow(text: "Connect the bigger picture", onPrompt: onPrompt)
        }
    }
}

private struct SuggestedPromptRow: View {
    let text: String
    let onPrompt: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            onPrompt(text)
        } label: {
            HStack(spacing: NXSpacing.x3) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                Text(text)
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
                Spacer(minLength: 0)
            }
            .padding(.vertical, NXSpacing.x2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationTurnView: View {
    let turn: TutorTurn
    var onSaveInsight: ((String) -> Void)? = nil

    var body: some View {
        switch turn.role {
        case .assistant:
            AssistantMessage(turn: turn, onSaveInsight: onSaveInsight)
        case .user:
            UserMessage(turn: turn)
        case .system:
            SystemMessage(turn: turn)
        }
    }
}

private struct AssistantMessage: View {
    let turn: TutorTurn
    var onSaveInsight: ((String) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            HStack(spacing: NXSpacing.x2) {
                NXTag(text: "AI", tint: NXColor.primary)
                Text("Response")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
            Text(turn.text)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let onSaveInsight {
                NXTextButton(title: "Save insight", systemName: "lightbulb", action: { onSaveInsight(turn.text) })
            }
            if !turn.corrections.isEmpty {
                VStack(alignment: .leading, spacing: NXSpacing.x2) {
                    ForEach(turn.corrections, id: \.self) { correction in
                        Text(correction)
                            .font(NXFont.auxiliary)
                            .foregroundStyle(NXColor.textSecondary(scheme))
                    }
                }
                .padding(.leading, NXSpacing.x3)
                .overlay(alignment: .leading) {
                    Rectangle().fill(NXColor.insight).frame(width: 2)
                }
            }
        }
    }
}

private struct UserMessage: View {
    let turn: TutorTurn
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack {
            Spacer(minLength: NXSpacing.x8)
            Text(turn.text)
                .font(NXFont.body)
                .foregroundStyle(NXColor.text(scheme))
                .lineSpacing(2)
                .padding(.horizontal, NXSpacing.x3)
                .padding(.vertical, NXSpacing.x2)
                .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
                .overlay(RoundedRectangle(cornerRadius: NXRadius.control).stroke(NXColor.border(scheme), lineWidth: 1))
        }
    }
}

private struct SystemMessage: View {
    let turn: TutorTurn
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(turn.text)
            .font(NXFont.auxiliary)
            .foregroundStyle(NXColor.textTertiary(scheme))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct MessageComposer: View {
    @Binding var draft: String
    let placeholder: String
    let onSend: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: NXSpacing.x3) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .font(NXFont.body)
                .lineLimit(1...5)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit {
                    if canSend { onSend() }
                }
                .padding(.horizontal, NXSpacing.x3)
                .padding(.vertical, NXSpacing.x3)
                .background(NXColor.surface2(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
                .modifier(NXFocusModifier(focused: focused))

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 36, height: 36)
                    .background(canSend ? NXColor.primary : NXColor.primary.opacity(0.35), in: RoundedRectangle(cornerRadius: NXRadius.control))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
    }
}

private struct DiscussionLoadingState: View {
    let error: String?
    let onEnd: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x8) {
            HStack {
                Text("Discussion")
                    .font(NXFont.sectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                Spacer()
                NXSecondaryButton(title: "Close", systemName: "xmark", action: onEnd)
            }

            if let error {
                NXErrorState(message: error)
            } else {
                VStack(alignment: .leading, spacing: NXSpacing.x4) {
                    SkeletonLine(width: 180)
                    SkeletonLine(width: 280)
                    SkeletonLine(width: 240)
                }
                .padding(NXSpacing.x4)
                .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
                .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
                Text("Connecting to the realtime classroom...")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            }

            Spacer()
        }
        .padding(NXSpacing.x6)
        .background(NXColor.background(scheme))
    }
}

private struct SkeletonLine: View {
    let width: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: NXRadius.small)
            .fill(NXColor.surface2(scheme))
            .frame(width: width, height: 12)
    }
}
#endif
