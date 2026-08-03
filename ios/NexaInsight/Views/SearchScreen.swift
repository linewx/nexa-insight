#if os(iOS)
import SwiftUI

// The full-screen search page, as on YouTube: a back arrow, the field, and a list
// beneath it.
//
// It replaces a field that expanded inside the header. That field had to share a
// 44pt bar with the brand and two icons, so it was cramped even after being given a
// minimum width — and typing left the feed sitting behind it, visible but stale.
// Searching is a mode, not a control, so it gets the screen.
//
// The list below is your own history rather than autocomplete: YouTube fills that
// space from a suggestion endpoint we do not have, and for someone returning to the
// same subjects their previous searches are the more useful list anyway.
struct SearchScreen: View {
    @Binding var query: String
    @ObservedObject var history: SearchHistoryStore
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void
    // Discover's field doubles as the import path, and losing that would cost the
    // one action with no alternative.
    var onPasteLink: ((String) -> Void)?

    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(NXColor.border(scheme))
            suggestions
            Spacer(minLength: 0)
        }
        .background(NXColor.background(scheme))
        // Focus on appear: arriving here IS the intent to type, so making the user
        // tap the field again would be a wasted step.
        .onAppear { focused = true }
    }

    private var field: some View {
        HStack(spacing: NXSpacing.x3) {
            Button(action: dismiss) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(NXColor.text(scheme))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            TextField(placeholder, text: $query)
                .font(NXFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit(submit)

            if !query.isEmpty {
                // Clears the text without leaving the page — distinct from Back,
                // which leaves. Two separate intents, two separate controls.
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, NXSpacing.x3)
        .padding(.vertical, NXSpacing.x2)
    }

    private var placeholder: String {
        onPasteLink == nil ? "Search" : "Search videos, or paste a link"
    }

    @ViewBuilder
    private var suggestions: some View {
        let matches = history.matching(query)
        if matches.isEmpty {
            // No empty-state illustration: on first use the keyboard is already up
            // and the field is focused, so there is nothing to explain.
            EmptyView()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matches, id: \.self) { term in
                        row(term)
                        Divider().overlay(NXColor.border(scheme)).padding(.leading, 52)
                    }
                }
            }
        }
    }

    private func row(_ term: String) -> some View {
        HStack(spacing: NXSpacing.x3) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15))
                .foregroundStyle(NXColor.textTertiary(scheme))
                .frame(width: 20)
                .accessibilityHidden(true)

            Button {
                query = term
                submit()
            } label: {
                Text(term)
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.text(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Removing one stale term should not mean clearing the whole history.
            Button { history.remove(term) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(term) from history")
        }
        .padding(.horizontal, NXSpacing.x4)
        .padding(.vertical, NXSpacing.x1)
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A URL cannot be a search term, so this branch stays unambiguous.
        if let onPasteLink, looksLikeSourceURL(trimmed) {
            onPasteLink(trimmed)
            dismiss()
            return
        }
        history.record(trimmed)
        focused = false
        onSubmit(trimmed)
        onDismiss()
    }

    private func dismiss() {
        focused = false
        onDismiss()
    }
}
#endif
