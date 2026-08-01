#if os(iOS)
import SwiftUI

enum NXSpacing {
    static let x1: CGFloat = 4
    static let x2: CGFloat = 8
    static let x3: CGFloat = 12
    static let x4: CGFloat = 16
    static let x6: CGFloat = 24
    static let x8: CGFloat = 32
    static let x12: CGFloat = 48
}

enum NXRadius {
    static let small: CGFloat = 6
    static let control: CGFloat = 8
    static let popover: CGFloat = 10
    static let surface: CGFloat = 12
}

enum NXColor {
    static let primary = Color(red: 0.424, green: 0.486, blue: 1.0)
    static let insight = Color(red: 0.878, green: 0.659, blue: 0.294)
    static let error = Color(red: 0.894, green: 0.416, blue: 0.416)
    static let success = Color(red: 0.31, green: 0.686, blue: 0.514)

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x0E0F12) : Color(hex: 0xF7F7F8)
    }

    static func surface1(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x13151A) : Color.white
    }

    static func surface2(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x181B21) : Color(hex: 0xF1F2F4)
    }

    static func hover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x1D2129) : Color(hex: 0xECEEF1)
    }

    static func text(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xF2F3F5) : Color(hex: 0x17181B)
    }

    static func textSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xA5AAB4) : Color(hex: 0x5E636D)
    }

    static func textTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x747A86) : Color(hex: 0x8A909A)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    static func borderStrong(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)
    }
}

// Every size is relativeTo: a text style, so the whole app follows the reader's
// Dynamic Type setting. These were fixed points before, which meant a language
// learner who had turned text size up got the same 14pt transcript as everyone
// else — on the one screen where reading IS the task.
//
// The scale is unchanged: each pairs with the text style whose default size is
// closest, so nothing shifts at the default setting.
enum NXFont {
    // Text STYLES, not point sizes. `.system(size:)` never scales, which is what
    // pinned the transcript at 14pt however large the reader had set their text —
    // on the one screen where reading is the entire task. Each style below is the
    // one whose default size matches the size it replaces, so nothing moves at the
    // default setting.
    static let pageTitle = Font.system(.largeTitle, design: .default, weight: .semibold)
    static let sectionTitle = Font.system(.title3, weight: .semibold)
    static let subsectionTitle = Font.system(.subheadline, weight: .semibold)
    static let body = Font.system(.subheadline)
    static let bodyMedium = Font.system(.subheadline, weight: .medium)
    static let control = Font.system(.footnote, weight: .medium)
    static let controlEmphasis = Font.system(.body, weight: .semibold)
    static let auxiliary = Font.system(.caption)
    static let label = Font.system(.caption2, weight: .medium)
}

extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// Shared elevation for anything floating above scrolling content, so a button
// and the panel it becomes read as living on the same layer.
extension View {
    func nxFloatingShadow(_ scheme: ColorScheme) -> some View {
        shadow(color: Color.black.opacity(scheme == .dark ? 0.32 : 0.12), radius: 18, y: 8)
    }
}

struct NXFocusModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let focused: Bool

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: NXRadius.control)
                    .stroke(focused ? NXColor.primary : NXColor.border(scheme), lineWidth: focused ? 2 : 1)
            )
            .shadow(color: focused ? NXColor.primary.opacity(0.18) : .clear, radius: focused ? 8 : 0)
    }
}

struct NXTag: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text.uppercased())
            .font(NXFont.label)
            .lineLimit(1)
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, NXSpacing.x2)
            .padding(.vertical, NXSpacing.x1)
            .background((tint ?? Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: NXRadius.small))
    }
}

struct NXIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 32)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: NXRadius.control))
    }
}

struct NXPrimaryButton: View {
    let title: String
    var systemName: String? = nil
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NXSpacing.x2) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(NXFont.control)
            }
            .frame(minHeight: 36)
            .padding(.horizontal, NXSpacing.x3)
            .foregroundStyle(Color.white)
            .background(disabled ? NXColor.primary.opacity(0.36) : NXColor.primary, in: RoundedRectangle(cornerRadius: NXRadius.control))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct NXSecondaryButton: View {
    let title: String
    var systemName: String? = nil
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: NXSpacing.x2) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 13, weight: .semibold))
                }
                Text(title).font(NXFont.control)
            }
            .frame(minHeight: 36)
            .padding(.horizontal, NXSpacing.x3)
            .foregroundStyle(NXColor.text(scheme))
            .background(NXColor.surface2(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
            .overlay(RoundedRectangle(cornerRadius: NXRadius.control).stroke(NXColor.border(scheme), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct NXTextButton: View {
    let title: String
    var systemName: String? = nil
    var disabled = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: NXSpacing.x2) {
                if let systemName {
                    Image(systemName: systemName).font(.system(size: 13, weight: .medium))
                }
                Text(title).font(NXFont.control)
            }
            .foregroundStyle(disabled ? NXColor.textTertiary(scheme) : NXColor.textSecondary(scheme))
            .padding(.horizontal, NXSpacing.x2)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.62 : 1)
    }
}

struct NXSectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(NXFont.sectionTitle)
                .foregroundStyle(NXColor.text(scheme))
            Spacer()
            if let actionTitle, let action {
                NXTextButton(title: actionTitle, systemName: "arrow.right", action: action)
            }
        }
    }
}

struct NXProgressIndicator: View {
    let value: Int
    let label: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            HStack {
                Text(label.capitalized).font(NXFont.control)
                Spacer()
                Text("\(value)%").font(NXFont.auxiliary).monospacedDigit()
            }
            .foregroundStyle(NXColor.textSecondary(scheme))

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(NXColor.surface2(scheme))
                    Capsule()
                        .fill(NXColor.primary)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(100, value))) / 100)
                }
            }
            .frame(height: 4)
        }
    }
}

struct NXEmptyState: View {
    let title: String
    let message: String
    // Optional: some empty states have nothing to offer but an explanation, and a
    // button that merely restates the message is worse than no button.
    var actionTitle: String?
    var action: () -> Void = {}
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            Text(title)
                .font(NXFont.subsectionTitle)
                .foregroundStyle(NXColor.text(scheme))
            Text(message)
                .font(NXFont.body)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                NXPrimaryButton(title: actionTitle, systemName: "plus", action: action)
            }
        }
        .padding(.vertical, NXSpacing.x4)
    }
}

struct NXErrorState: View {
    let message: String
    var retry: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x3) {
            HStack(spacing: NXSpacing.x2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(NXColor.error)
                Text("Add failed")
                    .font(NXFont.subsectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
            }
            Text(message)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
                .lineLimit(4)
            if let retry {
                NXSecondaryButton(title: "Try again", systemName: "arrow.clockwise", action: retry)
            }
        }
        .padding(NXSpacing.x4)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
    }
}
#endif
