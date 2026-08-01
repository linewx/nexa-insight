#if os(iOS)
import SwiftUI

// The one header, identical on every tab.
//
// Each tab used to name itself — "Discover", "Channels", "Library" — directly
// above a tab bar highlighting that same name. Two statements of one fact, and a
// large-title bar costs ~40pt to make it. The brand goes here instead, so the
// header reads as the app rather than as a label for the screen.
struct BrandHeader: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: NXSpacing.x2) {
                BrandMark()
                Text("Nexa")
                    .font(.system(size: 17, weight: .semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Nexa Insight")
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: NXRadius.small)
                .fill(NXColor.primary)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// A search field that starts as an icon and expands in place.
//
// The field was permanently docked below the title, ~48pt of chrome for something
// used in bursts. As an icon it costs nothing until wanted, and the transcript or
// feed gets the space back.
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
                    .font(.system(size: 16, weight: .medium))
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
#endif
