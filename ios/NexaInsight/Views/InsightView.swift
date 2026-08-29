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
    @Environment(\.colorScheme) private var scheme

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
                }
                .padding(.horizontal, NXSpacing.x4)
                .padding(.top, NXSpacing.x4)
                .padding(.bottom, NXSpacing.x12)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NXColor.background(scheme))
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
