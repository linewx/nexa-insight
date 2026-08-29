#if os(iOS)
import SwiftUI

/// What an episode argued, as a page read INSTEAD of the hour.
///
/// Not a summary and not a study surface: the reader cannot listen to every podcast end to end,
/// and wants the core positions, the hard numbers, and what follows from them in five to ten
/// minutes of Chinese. Native material only — a lesson's content is its language.
///
/// Five sections, each answering something that otherwise needs the hour:
///
/// - the thesis says what is at stake, so you can stop here if it is not for you
/// - claims come WITH their evidence and with who disputed them; a claim without its grounds is
///   just a model's word, and flattening several speakers into one agreeing voice is the commonest
///   way a summary misleads
/// - facts are flagged for whether a source was actually named, because an off-the-cuff figure
///   presented as established is one you would go on to quote
/// - takeaways are inferences, and may be absent: the backend drops anything that merely restates
/// - anchors are for after the five minutes, when one exchange is worth hearing in their voices
struct InsightPage: View {
    let insight: InsightDTO
    let durationMs: Int?
    /// Seeks the episode audio. Every timestamp on this page is tappable, because the point of
    /// reading first is knowing which three minutes to actually listen to.
    let onJump: (Int) -> Void
    let onClose: () -> Void
    /// The conversation about this page, when one is in progress. Nil when nothing has been asked.
    var ask: ReadingAsk? = nil
    /// Hold-to-talk. Asks about the PAGE, not about a moment in the audio — "this claim" means
    /// something on screen here.
    var onHoldStart: () -> Void = {}
    var onHoldEnd: () -> Void = {}
    /// Released after dragging up: abandon the question rather than send it.
    var onHoldCancel: () -> Void = {}
    @Environment(\.colorScheme) private var scheme
    /// Whether an upward drag has passed the cancel threshold. Held here rather than derived from
    /// the gesture so the label and colour can change the moment it arms, not on release.
    @State private var cancelArmed = false
    /// The page's own height, so the swipe can tell "near the bottom" from "on the capsule".
    @State private var pageHeight: CGFloat = 0

    /// Named so the drag reports coordinates against this page rather than whatever ancestor
    /// SwiftUI would otherwise pick.
    private static let pageSpace = "insightPage"
    /// The strip at the bottom the exit swipe keeps out of: capsule, status line and padding.
    private static let askBarZone: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: NXSpacing.x6) {
                    thesis
                    if !insight.claims.isEmpty { claims }
                    if !insight.facts.isEmpty { facts }
                    if !insight.takeaways.isEmpty { takeaways }
                    if !insight.anchors.isEmpty { anchors }
                    // The exchange sits at the end of the page, under what it is about, rather
                    // than in a sheet over it — the claim being discussed has to stay readable.
                    conversation
                }
                .padding(.horizontal, NXSpacing.x4)
                .padding(.top, NXSpacing.x4)
                // Clears the ask bar, so the last line is never stranded beneath it.
                .padding(.bottom, 120)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { askBar }
        // Right-swipe to leave, the mirror of the leftward swipe that opens the notes drawer,
        // with the same thresholds so the gesture means one thing across the app.
        //
        // `.simultaneousGesture` so the page still scrolls: a swipe that consumed the drag would
        // make a five-minute read unscrollable, which is worse than having no swipe at all.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .named(Self.pageSpace))
                .onEnded { value in
                    // Not from the ask capsule. Any drag there starts recording, so a sideways
                    // flick off the button would send a question AND leave the page — the notes
                    // drawer guards its own top edge for the same reason.
                    guard value.startLocation.y < pageHeight - Self.askBarZone else { return }
                    // And never while a question is in flight: leaving mid-turn would strand the
                    // answer on a page nobody is looking at.
                    guard ask == nil || ask?.phase == .idle else { return }
                    let rightwards = value.translation.width
                    let vertical = abs(value.translation.height)
                    // Twice as far sideways as up or down: a scroll that drifts is not a swipe.
                    guard rightwards > vertical * 2 else { return }
                    guard rightwards > 60 || value.predictedEndTranslation.width > 120 else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onClose()
                }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NXColor.background(scheme))
        .coordinateSpace(name: Self.pageSpace)
        .background {
            GeometryReader { geo in
                Color.clear.onAppear { pageHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in pageHeight = new }
            }
        }
    }

    private var header: some View {
        HStack(spacing: NXSpacing.x3) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(NXColor.textSecondary(scheme))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\u{8fd4}\u{56de}")

            Text("\u{6d1e}\u{5bdf}")
                .font(NXFont.subsectionTitle)
                .foregroundStyle(NXColor.text(scheme))
            Spacer(minLength: 0)
            // The length of what was replaced. Reading this page instead of an 87-minute episode
            // is the whole proposition, so the number belongs on it.
            if let minutes = durationMs.map({ max(1, $0 / 60_000) }) {
                Text("\u{539f}\u{7247} \(minutes) \u{5206}\u{949f}")
                    .font(NXFont.label)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
        }
        .padding(.horizontal, NXSpacing.x3)
        .padding(.vertical, NXSpacing.x2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NXColor.border(scheme)).frame(height: 0.5)
        }
    }

    /// One sentence, set larger than anything else: it is the page's answer to "is this for me".
    private var thesis: some View {
        Text(insight.thesis)
            .font(.system(.title3, design: .serif, weight: .semibold))
            .foregroundStyle(NXColor.text(scheme))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var claims: some View {
        section("\u{6838}\u{5fc3}\u{89c2}\u{70b9}") {
            VStack(alignment: .leading, spacing: NXSpacing.x4) {
                ForEach(Array(insight.claims.enumerated()), id: \.offset) { _, claim in
                    VStack(alignment: .leading, spacing: NXSpacing.x2) {
                        HStack(alignment: .firstTextBaseline, spacing: NXSpacing.x2) {
                            Circle()
                                .fill(NXColor.primary)
                                .frame(width: 5, height: 5)
                                .offset(y: -4)
                            Text(claim.claim)
                                .font(NXFont.body)
                                .foregroundStyle(NXColor.text(scheme))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // Indented under the claim they belong to, and labelled, because
                        // "what they argued" and "what they offered for it" are different
                        // things and running them together is how a summary launders a
                        // weak argument.
                        if let evidence = claim.evidence {
                            annotation("\u{4f9d}\u{636e}", evidence)
                        }
                        if let dispute = claim.dispute {
                            annotation("\u{5206}\u{6b67}", dispute, tinted: true)
                        }
                        if let atMs = claim.atMs {
                            timestamp(atMs)
                        }
                    }
                }
            }
        }
    }

    private var facts: some View {
        section("\u{4e8b}\u{5b9e}\u{4e0e}\u{6570}\u{5b57}") {
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                ForEach(Array(insight.facts.enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .firstTextBaseline, spacing: NXSpacing.x2) {
                        Text("\u{00b7}")
                            .font(NXFont.body)
                            .foregroundStyle(NXColor.textTertiary(scheme))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fact.fact)
                                .font(NXFont.body)
                                .foregroundStyle(NXColor.text(scheme))
                                .fixedSize(horizontal: false, vertical: true)
                            // Only the unsourced ones are marked. Labelling both would make the
                            // distinction furniture; the warning exists so a number you might
                            // quote later cannot pass as established.
                            if !fact.sourced {
                                Text("\u{65e0}\u{51fa}\u{5904}")
                                    .font(NXFont.label)
                                    .foregroundStyle(NXColor.error)
                            }
                            if let atMs = fact.atMs {
                                timestamp(atMs)
                            }
                        }
                    }
                }
            }
        }
    }

    private var takeaways: some View {
        section("\u{542f}\u{53d1}") {
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                ForEach(Array(insight.takeaways.enumerated()), id: \.offset) { _, text in
                    HStack(alignment: .firstTextBaseline, spacing: NXSpacing.x2) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(NXColor.primary)
                        Text(text)
                            .font(NXFont.body)
                            .foregroundStyle(NXColor.text(scheme))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var anchors: some View {
        section("\u{503c}\u{5f97}\u{4eb2}\u{8033}\u{542c}") {
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                ForEach(Array(insight.anchors.enumerated()), id: \.offset) { _, anchor in
                    Button { onJump(anchor.atMs) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: NXSpacing.x3) {
                            Text(Self.clock(anchor.atMs))
                                .font(.system(.footnote, design: .monospaced, weight: .medium))
                                .foregroundStyle(NXColor.primary)
                            Text(anchor.why)
                                .font(NXFont.auxiliary)
                                .foregroundStyle(NXColor.textSecondary(scheme))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// How far up the finger must travel to arm cancelling. Matches the dock's threshold: the
    /// gesture should mean the same thing everywhere it exists.
    private static let cancelThreshold: CGFloat = 60

    /// Hold-to-talk, as a capsule floating over the page.
    ///
    /// The same gesture as holding a paragraph in the transcript, and deliberately the same
    /// shape — but it asks about this PAGE. Reading a five-minute summary is exactly when a
    /// question arrives ("who disputed that?", "is that figure real?"), and the answer should be
    /// about the claim on screen rather than a moment in audio the reader may never have heard.
    private var askBar: some View {
        VStack(spacing: NXSpacing.x2) {
            // Says which of four things is happening. Without it the button looked identical
            // whether the mic was open, the question was in flight, or the teacher was mid-answer
            // — and a control that looks the same in every state cannot tell you what to do next.
            Text(statusText)
                .font(NXFont.label)
                .foregroundStyle(statusTint)
                .animation(.easeInOut(duration: 0.15), value: statusText)

            HStack(spacing: NXSpacing.x2) {
                Image(systemName: capsuleIcon)
                    .font(.system(size: 13, weight: .semibold))
                Text(capsuleLabel)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, NXSpacing.x6)
            .frame(height: 44)
            .background(capsuleTint, in: Capsule())
            .nxFloatingShadow(scheme)
            // Lifts with the finger while cancelling is armed, so the drag has somewhere to go.
            .offset(y: cancelArmed ? -8 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: cancelArmed)
            // A drag with no minimum distance: recording begins the instant the finger lands. A
            // LongPressGesture would put its own delay in front of the first word.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isRecording {
                            onHoldStart()
                            // Medium on the way in, so the press is felt before any pixel moves.
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        // Negative height is upward. A light tick on each crossing, both ways, so
                        // arming and disarming are distinguishable without looking.
                        let armed = value.translation.height < -Self.cancelThreshold
                        if armed != cancelArmed {
                            cancelArmed = armed
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        if cancelArmed {
                            onHoldCancel()
                            // Rigid, distinctly unlike the send: cancelling must not feel like a
                            // question went out.
                            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        } else {
                            onHoldEnd()
                        }
                        cancelArmed = false
                    }
            )
            .accessibilityLabel(cancelArmed ? "\u{4e0a}\u{6ed1}\u{53d6}\u{6d88}" : "\u{6309}\u{4f4f}\u{5c31}\u{6d1e}\u{5bdf}\u{63d0}\u{95ee}")
        }
        .padding(.bottom, NXSpacing.x8)
    }

    /// What is happening, in the learner's words.
    private var statusText: String {
        if cancelArmed { return "\u{677e}\u{5f00}\u{53d6}\u{6d88}" }
        switch ask?.phase {
        case .recording: return "\u{6b63}\u{5728}\u{542c}\u{2026}\u{4e0a}\u{6ed1}\u{53d6}\u{6d88}"
        case .waiting: return "\u{5728}\u{60f3}\u{2026}"
        // Named, and it names what to DO about it: pressing during an answer interrupts, which is
        // otherwise something the learner has no way to discover.
        case .answering: return "\u{8001}\u{5e08}\u{6b63}\u{5728}\u{56de}\u{7b54}\u{ff0c}\u{6309}\u{4f4f}\u{53ef}\u{6253}\u{65ad}"
        case .misheard: return "\u{6ca1}\u{542c}\u{6e05}\u{ff0c}\u{518d}\u{8bf4}\u{4e00}\u{904d}"
        case .idle: return "\u{7ee7}\u{7eed}\u{6309}\u{4f4f}\u{8ffd}\u{95ee}"
        case nil: return "\u{6309}\u{4f4f}\u{5c31}\u{8fd9}\u{4e00}\u{9875}\u{63d0}\u{95ee}"
        }
    }

    private var statusTint: Color {
        if cancelArmed { return NXColor.error }
        return ask?.phase == .recording ? NXColor.primary : NXColor.textTertiary(scheme)
    }

    private var capsuleIcon: String {
        if cancelArmed { return "xmark" }
        switch ask?.phase {
        case .recording: return "waveform"
        case .waiting: return "ellipsis"
        case .answering: return "hand.raised.fill"
        default: return "mic.fill"
        }
    }

    private var capsuleLabel: String {
        if cancelArmed { return "\u{53d6}\u{6d88}" }
        switch ask?.phase {
        case .recording: return "\u{677e}\u{5f00}\u{53d1}\u{9001}"
        case .waiting: return "\u{5728}\u{60f3}"
        case .answering: return "\u{6253}\u{65ad}"
        default: return "\u{6309}\u{4f4f}\u{63d0}\u{95ee}"
        }
    }

    private var capsuleTint: Color {
        if cancelArmed { return NXColor.error }
        return isRecording ? NXColor.error : NXColor.primary
    }

    private var isRecording: Bool { ask?.phase == .recording }

    /// What was asked and what came back, at the end of the page.
    @ViewBuilder private var conversation: some View {
        if let ask, !ask.turns.isEmpty {
            VStack(alignment: .leading, spacing: NXSpacing.x3) {
                Rectangle().fill(NXColor.border(scheme)).frame(height: 0.5)
                ForEach(Array(ask.turns.enumerated()), id: \.offset) { _, turn in
                    HStack(alignment: .top, spacing: NXSpacing.x2) {
                        // The learner's turn is shown VERBATIM as the server heard it: without
                        // it, an answer to a misheard question looks like a wrong answer.
                        Image(systemName: turn.role == .user ? "person.fill" : "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(turn.role == .user
                                             ? NXColor.textTertiary(scheme) : NXColor.primary)
                            .frame(width: 12)
                        Text(turn.text)
                            .font(NXFont.auxiliary)
                            .foregroundStyle(turn.role == .user
                                             ? NXColor.textSecondary(scheme) : NXColor.text(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            Text(title)
                .font(NXFont.label)
                .foregroundStyle(NXColor.textTertiary(scheme))
            content()
        }
    }

    private func annotation(_ label: String, _ text: String, tinted: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NXSpacing.x2) {
            Text(label)
                .font(NXFont.label)
                .foregroundStyle(tinted ? NXColor.error : NXColor.textTertiary(scheme))
            Text(text)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, NXSpacing.x4)
    }

    private func timestamp(_ atMs: Int) -> some View {
        Button { onJump(atMs) } label: {
            Text(Self.clock(atMs))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(NXColor.primary)
        }
        .buttonStyle(.plain)
        .padding(.leading, NXSpacing.x4)
    }

    static func clock(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
#endif
