#if os(iOS)
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    private let keychain = KeychainStore()
    @State private var openAIKey = ""
    @State private var dashscopeKey = ""
    @State private var workspaceId = ""
    @State private var savedMessage: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NXSpacing.x8) {
                    SettingsHeader(onClose: { dismiss() })

                    SettingsSection(
                        title: "Backend",
                        subtitle: "Used for importing and downloading prepared sources."
                    ) {
                        SettingsTextField(
                            title: "Base URL",
                            text: $settings.backendBaseURL,
                            placeholder: AppSettings.defaultBackendBaseURL,
                            systemName: "network"
                        )
                        HStack(spacing: NXSpacing.x3) {
                            ConnectionStatus(urlString: settings.backendBaseURL)
                            Spacer()
                            NXTextButton(title: "Reset default", systemName: "arrow.counterclockwise") {
                                settings.backendBaseURL = AppSettings.defaultBackendBaseURL
                            }
                        }
                    }

                    SettingsSection(
                        title: "Realtime classroom",
                        subtitle: "DashScope powers voice discussion around the current source."
                    ) {
                        SettingsSecureField(
                            title: "DashScope API key",
                            text: $dashscopeKey,
                            placeholder: "Stored in Keychain",
                            systemName: "key"
                        )
                        SettingsTextField(
                            title: "Workspace ID",
                            text: $workspaceId,
                            placeholder: "llm-...",
                            systemName: "rectangle.connected.to.line.below"
                        )
                        ReadinessRow(
                            ready: !dashscopeKey.isEmpty && !workspaceId.isEmpty,
                            readyText: "Realtime discussion configured",
                            missingText: "Add DashScope key and workspace ID to use Talk"
                        )
                    }

                    SettingsSection(
                        title: "Optional services",
                        subtitle: "OpenAI is only needed for features that explicitly use it."
                    ) {
                        SettingsSecureField(
                            title: "OpenAI API key",
                            text: $openAIKey,
                            placeholder: "Stored in Keychain",
                            systemName: "key"
                        )
                        ReadinessRow(
                            ready: !openAIKey.isEmpty,
                            readyText: "OpenAI key saved",
                            missingText: "No OpenAI key saved"
                        )
                    }

                    SettingsSection(
                        title: "Display",
                        subtitle: "Discover content is English, so dates and view counts default to English too."
                    ) {
                        Toggle(isOn: $settings.localizedBylines) {
                            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                                Text("Use device language for dates")
                                    .font(NXFont.bodyMedium)
                                    .foregroundStyle(NXColor.text(scheme))
                                Text("On a Japanese device this shows \u{300c}3\u{65e5}\u{524d}\u{300d} instead of \u{201c}3d ago\u{201d}.")
                                    .font(NXFont.auxiliary)
                                    .foregroundStyle(NXColor.textSecondary(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(NXColor.primary)
                    }

                    if let savedMessage {
                        SaveNotice(message: savedMessage)
                    }

                    HStack {
                        NXSecondaryButton(title: "Close", action: { dismiss() })
                        Spacer()
                        NXPrimaryButton(title: "Save changes", systemName: "checkmark", action: save)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, NXSpacing.x6)
                .padding(.vertical, NXSpacing.x6)
                .frame(maxWidth: .infinity)
            }
            .background(NXColor.background(scheme))
            .toolbar(.hidden, for: .navigationBar)
            .onAppear(perform: load)
        }
    }

    private func load() {
        openAIKey = keychain.get(.openAIKey) ?? ""
        dashscopeKey = keychain.get(.dashscopeKey) ?? ""
        workspaceId = keychain.get(.dashscopeWorkspaceId) ?? ""
    }

    private func save() {
        saveOrDelete(openAIKey, for: .openAIKey)
        saveOrDelete(dashscopeKey, for: .dashscopeKey)
        saveOrDelete(workspaceId, for: .dashscopeWorkspaceId)
        savedMessage = "Settings saved"
    }

    private func saveOrDelete(_ value: String, for key: SecretKey) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(key)
        } else {
            keychain.set(trimmed, for: key)
        }
    }
}

private struct SettingsHeader: View {
    let onClose: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: NXSpacing.x4) {
            VStack(alignment: .leading, spacing: NXSpacing.x2) {
                Text("Settings")
                    .font(NXFont.pageTitle)
                    .foregroundStyle(NXColor.text(scheme))
                Text("Connections and local secrets for Nexa Insight.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            }
            Spacer()
            NXIconButton(systemName: "xmark", accessibilityLabel: "Close settings", action: onClose)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(title)
                    .font(NXFont.sectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                Text(subtitle)
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            }

            VStack(spacing: 0) {
                content
            }
            .padding(NXSpacing.x4)
            .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
            .overlay(RoundedRectangle(cornerRadius: NXRadius.surface).stroke(NXColor.border(scheme), lineWidth: 1))
        }
    }
}

private struct SettingsTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let systemName: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            SettingsFieldLabel(title: title, systemName: systemName)
            TextField(placeholder, text: $text)
                .font(NXFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($focused)
                .padding(.horizontal, NXSpacing.x3)
                .frame(height: 42)
                .background(NXColor.surface2(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
                .modifier(NXFocusModifier(focused: focused))
        }
        .padding(.vertical, NXSpacing.x3)
    }
}

private struct SettingsSecureField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let systemName: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            SettingsFieldLabel(title: title, systemName: systemName)
            SecureField(placeholder, text: $text)
                .font(NXFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, NXSpacing.x3)
                .frame(height: 42)
                .background(NXColor.surface2(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
                .modifier(NXFocusModifier(focused: focused))
        }
        .padding(.vertical, NXSpacing.x3)
    }
}

private struct SettingsFieldLabel: View {
    let title: String
    let systemName: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
                .frame(width: 16)
            Text(title)
                .font(NXFont.control)
                .foregroundStyle(NXColor.textSecondary(scheme))
        }
    }
}

private struct ConnectionStatus: View {
    let urlString: String
    @Environment(\.colorScheme) private var scheme

    private var valid: Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme else { return false }
        return ["http", "https"].contains(scheme) && url.host() != nil
    }

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            Circle()
                .fill(valid ? NXColor.success : NXColor.error)
                .frame(width: 7, height: 7)
            Text(valid ? "Backend URL looks valid" : "Enter a valid http or https URL")
                .font(NXFont.auxiliary)
                .foregroundStyle(valid ? NXColor.textTertiary(scheme) : NXColor.error)
        }
        .padding(.top, NXSpacing.x2)
    }
}

private struct ReadinessRow: View {
    let ready: Bool
    let readyText: String
    let missingText: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ready ? NXColor.success : NXColor.textTertiary(scheme))
            Text(ready ? readyText : missingText)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
            Spacer()
        }
        .padding(.top, NXSpacing.x2)
    }
}

private struct SaveNotice: View {
    let message: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(NXColor.success)
            Text(message)
                .font(NXFont.body)
                .foregroundStyle(NXColor.textSecondary(scheme))
        }
        .padding(.horizontal, NXSpacing.x3)
        .padding(.vertical, NXSpacing.x2)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.control))
        .overlay(RoundedRectangle(cornerRadius: NXRadius.control).stroke(NXColor.border(scheme), lineWidth: 1))
    }
}
#endif
