#if os(iOS)
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    private let keychain = KeychainStore()
    @State private var openAIKey = ""
    @State private var youtubeAPIKey = ""
    @State private var dashscopeKey = ""
    @State private var workspaceId = ""
    @State private var savedMessage: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader()
            form
        }
        // One header per screen: the brand row above. Left visible, the navigation
        // bar drew a second band behind it in a different tone.
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: SettingsDestination.self) { destination in
            switch destination {
            case .backend:
                BackendSettingsPage(settings: settings)
            case .credentials:
                CredentialsPage(
                    openAIKey: $openAIKey,
                    youtubeAPIKey: $youtubeAPIKey,
                    dashscopeKey: $dashscopeKey,
                    workspaceId: $workspaceId,
                    onSave: save,
                    savedMessage: savedMessage)
            }
        }
    }

    // No NavigationStack of its own: this is a tab, so the caller supplies the
    // stack. The old close button belonged to a sheet that no longer exists.
    private var services: [CredentialSummary.Service] {
        CredentialSummary.services(
            dashscopeKey: dashscopeKey, workspaceId: workspaceId,
            youtubeAPIKey: youtubeAPIKey, openAIKey: openAIKey)
    }

    // The root holds what you actually come here to change. Credentials are
    // fill-once-and-forget, and inline they cost five bordered cards and three
    // screens of scrolling to reach a toggle — so they move behind one row that
    // reports its own state.
    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x8) {
                    // No subtitles, and no caption under either toggle. A switch
                    // labelled "显示精读标注" does not need a sentence explaining
                    // that annotations get shown; the explanation was taller than
                    // the control it described.
                    SettingsSection(title: "\u{9605}\u{8bfb}\u{4e0e}\u{663e}\u{793a}") {
                        // Says what it does now. It used to read 显示精读标注, from when
                        // the flag decided whether the transcript was marked up at all;
                        // highlights no longer depend on it, so the old label promised
                        // something the switch could not deliver.
                        Toggle(isOn: $settings.opensInReading) {
                            Text("\u{9ed8}\u{8ba4}\u{4ee5}\u{7cbe}\u{8bfb}\u{6253}\u{5f00}")
                                .font(NXFont.bodyMedium)
                                .foregroundStyle(NXColor.text(scheme))
                        }
                        .tint(NXColor.primary)
                        .padding(.vertical, NXSpacing.x2)

                        Toggle(isOn: $settings.localizedBylines) {
                            Text("\u{65e5}\u{671f}\u{8ddf}\u{968f}\u{7cfb}\u{7edf}\u{8bed}\u{8a00}")
                                .font(NXFont.bodyMedium)
                                .foregroundStyle(NXColor.text(scheme))
                        }
                        .tint(NXColor.primary)
                        .padding(.vertical, NXSpacing.x2)
                    }

                    SettingsSection(title: "\u{8fde}\u{63a5}\u{4e0e}\u{51ed}\u{636e}") {
                        NavigationLink(value: SettingsDestination.backend) {
                            SettingsDisclosureRow(
                                title: "\u{540e}\u{7aef}",
                                systemName: "network",
                                trailing: { ConnectionStatus(urlString: settings.backendBaseURL) })
                        }
                        .buttonStyle(.plain)

                        Rectangle()
                            .fill(NXColor.border(scheme))
                            .frame(height: 1)

                        NavigationLink(value: SettingsDestination.credentials) {
                            SettingsDisclosureRow(
                                title: "\u{51ed}\u{636e}",
                                systemName: "key",
                                trailing: {
                                    Text(CredentialSummary.rootSummary(services))
                                        .font(NXFont.auxiliary)
                                        .foregroundStyle(NXColor.textSecondary(scheme))
                                })
                        }
                        .buttonStyle(.plain)
                    }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, NXSpacing.x4)
            .padding(.vertical, NXSpacing.x4)
            .frame(maxWidth: .infinity)
        }
        .background(NXColor.background(scheme))
        .onAppear(perform: load)
    }

    private func load() {
        openAIKey = keychain.get(.openAIKey) ?? ""
        youtubeAPIKey = keychain.get(.youtubeAPIKey) ?? ""
        dashscopeKey = keychain.get(.dashscopeKey) ?? ""
        workspaceId = keychain.get(.dashscopeWorkspaceId) ?? ""
    }

    private func save() {
        saveOrDelete(openAIKey, for: .openAIKey)
        saveOrDelete(youtubeAPIKey, for: .youtubeAPIKey)
        saveOrDelete(dashscopeKey, for: .dashscopeKey)
        saveOrDelete(workspaceId, for: .dashscopeWorkspaceId)
        savedMessage = "\u{51ed}\u{636e}\u{5df2}\u{4fdd}\u{5b58}"
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

enum SettingsDestination: Hashable {
    case backend
    case credentials
}

/// A root row that names a group and reports its state, so you can tell whether
/// anything needs attention without opening the page.
private struct SettingsDisclosureRow<Trailing: View>: View {
    let title: String
    let systemName: String
    @ViewBuilder let trailing: Trailing
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
                .frame(width: 16)
            Text(title)
                .font(NXFont.bodyMedium)
                .foregroundStyle(NXColor.text(scheme))
            Spacer(minLength: NXSpacing.x3)
            trailing
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NXColor.textTertiary(scheme))
        }
        .padding(.vertical, NXSpacing.x3)
        .contentShape(Rectangle())
    }
}

private struct BackendSettingsPage: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    @State private var reachability: BackendReachability = .untested

    private func testConnection() {
        guard let url = URL(string: settings.backendBaseURL) else {
            reachability = .unreachable("\u{4e0d}\u{662f}\u{6709}\u{6548}\u{7684} URL")
            return
        }
        reachability = .checking
        Task {
            reachability = await BackendClient(baseURL: url).probe()
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x8) {
                SettingsSection(title: "\u{540e}\u{7aef}") {
                    SettingsTextField(
                        title: "Base URL",
                        text: $settings.backendBaseURL,
                        placeholder: AppSettings.defaultBackendBaseURL,
                        systemName: "network")
                    // Reachability where the string check used to be. "Backend URL looks
                    // valid" only parsed the text and never sent a request, so a green dot
                    // could sit beside an address nothing was listening on — answering
                    // "is this a URL?" when the question was "is this right?".
                    ConnectionStatus(urlString: settings.backendBaseURL, result: reachability)
                    HStack(spacing: NXSpacing.x3) {
                        NXTextButton(
                            title: reachability.isChecking ? "\u{6d4b}\u{8bd5}\u{4e2d}..." : "\u{6d4b}\u{8bd5}\u{8fde}\u{63a5}",
                            systemName: reachability.isChecking ? "hourglass" : "bolt.horizontal",
                            disabled: reachability.isChecking,
                            action: testConnection)
                        Spacer()
                        NXTextButton(title: "\u{6062}\u{590d}\u{9ed8}\u{8ba4}", systemName: "arrow.counterclockwise") {
                            settings.backendBaseURL = AppSettings.defaultBackendBaseURL
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, NXSpacing.x4)
            .padding(.vertical, NXSpacing.x4)
            .frame(maxWidth: .infinity)
        }
        .background(NXColor.background(scheme))
        .navigationTitle("\u{540e}\u{7aef}")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One page for every secret. Each field says whether it already holds a value —
/// a secure field whose placeholder always read "Stored in Keychain" could not
/// distinguish a saved key from an empty one.
private struct CredentialsPage: View {
    @Binding var openAIKey: String
    @Binding var youtubeAPIKey: String
    @Binding var dashscopeKey: String
    @Binding var workspaceId: String
    let onSave: () -> Void
    let savedMessage: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x8) {
                // The one subtitle worth keeping on this page: that both fields are
                // required is not visible from the fields themselves, and getting
                // it wrong leaves Talk unable to connect.
                SettingsSection(
                    title: "\u{5b9e}\u{65f6}\u{8bfe}\u{5802}",
                    subtitle: "\u{4e24}\u{9879}\u{90fd}\u{8981}\u{586b}\u{3002}"
                ) {
                    SettingsSecureField(
                        title: "DashScope API key",
                        text: $dashscopeKey,
                        placeholder: CredentialSummary.fieldState(dashscopeKey).label,
                        systemName: "key")
                    SettingsTextField(
                        title: "Workspace ID",
                        text: $workspaceId,
                        placeholder: "llm-...",
                        systemName: "rectangle.connected.to.line.below")
                }

                SettingsSection(title: "\u{9891}\u{9053}\u{6d4f}\u{89c8}") {
                    SettingsSecureField(
                        title: "YouTube API key",
                        text: $youtubeAPIKey,
                        placeholder: CredentialSummary.fieldState(youtubeAPIKey).label,
                        systemName: "key")
                }

                SettingsSection(title: "\u{8ddf}\u{8bfb}\u{53cd}\u{9988}") {
                    SettingsSecureField(
                        title: "OpenAI API key",
                        text: $openAIKey,
                        placeholder: CredentialSummary.fieldState(openAIKey).label,
                        systemName: "key")
                }

                if let savedMessage {
                    SaveNotice(message: savedMessage)
                }

                NXPrimaryButton(title: "\u{4fdd}\u{5b58}\u{51ed}\u{636e}", systemName: "checkmark", action: onSave)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, NXSpacing.x4)
            .padding(.vertical, NXSpacing.x4)
            .frame(maxWidth: .infinity)
        }
        .background(NXColor.background(scheme))
        .navigationTitle("\u{51ed}\u{636e}")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    // Optional, and usually absent. Most groups are self-evident from their title
    // and the control inside; a sentence per group turned this screen into prose.
    var subtitle: String?
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            VStack(alignment: .leading, spacing: NXSpacing.x1) {
                Text(title)
                    .font(NXFont.sectionTitle)
                    .foregroundStyle(NXColor.text(scheme))
                if let subtitle {
                    Text(subtitle)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    /// What the last test found, or `.untested`. The syntax check still runs — telling someone
    /// the URL is malformed before they press a button is faster than a failed request — but it
    /// no longer PRETENDS to be a connection check.
    var result: BackendReachability = .untested
    @Environment(\.colorScheme) private var scheme

    private var wellFormed: Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme else { return false }
        return ["http", "https"].contains(scheme) && url.host() != nil
    }

    private var display: (color: Color, text: String) {
        guard wellFormed else {
            return (NXColor.error, "\u{8bf7}\u{8f93}\u{5165}\u{6709}\u{6548}\u{7684} http \u{6216} https \u{5730}\u{5740}")
        }
        switch result {
        case .untested:
            // Deliberately not green. Nothing has been contacted, and a green dot here is what
            // made the old indicator misleading.
            return (NXColor.textTertiary(scheme), "\u{5730}\u{5740}\u{683c}\u{5f0f}\u{6b63}\u{5e38}，\u{5c1a}\u{672a}\u{6d4b}\u{8bd5}")
        case .checking:
            return (NXColor.primary, "\u{6b63}\u{5728}\u{8fde}\u{63a5}...")
        case let .reachable(count):
            return (NXColor.success, "\u{5df2}\u{8fde}\u{63a5}，\u{540e}\u{7aef}\u{6709} \(count) \u{4e2a}\u{8282}\u{76ee}")
        case let .wrongService(message):
            // Amber, not red: the network is fine and the address is not, which is a different
            // thing to go and check.
            return (NXColor.insight, message)
        case let .unreachable(message):
            return (NXColor.error, message)
        }
    }

    var body: some View {
        HStack(spacing: NXSpacing.x2) {
            Circle()
                .fill(display.color)
                .frame(width: 7, height: 7)
            Text(display.text)
                .font(NXFont.auxiliary)
                .foregroundStyle(display.color == NXColor.textTertiary(scheme)
                                 ? NXColor.textTertiary(scheme) : display.color)
                .fixedSize(horizontal: false, vertical: true)
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
