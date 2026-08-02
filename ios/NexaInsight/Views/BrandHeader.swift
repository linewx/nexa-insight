#if os(iOS)
import SwiftUI

// The one header, identical on every tab.
//
// Each tab used to name itself — "Discover", "Channels", "Library" — directly
// above a tab bar highlighting that same name. Two statements of one fact, and a
// large-title bar costs ~40pt to make it. The brand goes here instead, so the
// header reads as the app rather than as a label for the screen.
// A pinned row above the content, NOT a toolbar item.
//
// As a leading ToolbarItem it disappeared on scroll: the navigation bar collapses
// leading items to make room for a title. The brand is not a navigation control and
// should not be subject to that, so it sits in the layout instead — and the actions
// beside it stay put for the same reason.
struct BrandHeader<Actions: View>: View {
    @ViewBuilder var actions: Actions
    @Environment(\.colorScheme) private var scheme

    init(@ViewBuilder actions: () -> Actions) {
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            BrandMark()
            Text("NexaInsight")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(NXColor.text(scheme))
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: NXSpacing.x3)

            // Own HStack so the icons are not packed at the wordmark's 8pt spacing;
            // adjacent 16pt glyphs need more room than words do to read as separate
            // targets rather than one cluster.
            //
            // .buttonStyle(.plain) is the load-bearing part: a default Button paints
            // its label with the accent colour and ignores an inherited
            // foregroundStyle, which is why these kept coming out blue.
            HStack(spacing: NXSpacing.x6) {
                actions
            }
            .buttonStyle(.plain)
            .foregroundStyle(NXColor.text(scheme))
        }
        .padding(.horizontal, NXSpacing.x4)
        .padding(.top, NXSpacing.x2)
        .padding(.bottom, NXSpacing.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The page's own colour, with no divider. Two mistakes produced the pale
        // strip pinned to the top: giving this row surface1, AND leaving the
        // navigation bar drawing its own background behind it — two stacked bands
        // in a slightly different colour from everything around them. The row does
        // not need one: it sits outside the scroll view, so no content ever passes
        // under it, and type weight alone marks it as the top of the page.
        .background(NXColor.background(scheme))
    }
}

// The real app icon, not a lookalike drawn from an SF Symbol — the point is that
// the header matches what you tapped on the home screen.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image("BrandIcon")
            .resizable()
            .frame(width: size, height: size)
            // iOS clips the home-screen icon to a squircle; matching that here keeps
            // the two readings of the same mark consistent.
            .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct CollapsibleSearchField: View {
    @Binding var query: String
    let active: Bool
    var placeholder: String = "Search"
    let onSubmit: (String) -> Void
    let onClear: () -> Void
    // Optional: Discover also accepts a pasted link, and losing that to an extra
    // tap would be a real cost, so it keeps its own toolbar button.
    var onPasteLink: ((String) -> Void)?

    @Binding var expanded: Bool
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if expanded || active {
            HStack(spacing: NXSpacing.x2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .accessibilityHidden(true)

                TextField(placeholder, text: $query)
                    .font(NXFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit(submit)

                Button {
                    // Collapsing and clearing are one action: leaving a stale query
                    // behind an icon would hide the reason the list looks filtered.
                    onClear()
                    expanded = false
                    focused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
            }
            .padding(.horizontal, NXSpacing.x3)
            .frame(height: 36)
            // Claims the width a toolbar would otherwise share with the leading
            // items. Without this the field collapses to fit its placeholder.
            .frame(minWidth: 240, maxWidth: .infinity)
            .background(NXColor.surface2(scheme), in: Capsule())
            .onAppear { focused = true }
        } else {
            Button {
                expanded = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    // Set here, not via .tint: tint does not reach an Image's
                    // rendering colour, which is why these stayed blue.
                    .foregroundStyle(NXColor.text(scheme))
            }
            .accessibilityLabel("Search")
        }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A URL cannot be a search term, so this branch stays unambiguous even
        // though the field is now shared with the paste-a-link path.
        if let onPasteLink, looksLikeSourceURL(trimmed) {
            onPasteLink(trimmed)
        } else {
            focused = false
            onSubmit(trimmed)
        }
    }
}
extension BrandHeader where Actions == EmptyView {
    // Screens with nothing to act on — Settings is the whole page already.
    init() { self.init(actions: { EmptyView() }) }
}
#endif
