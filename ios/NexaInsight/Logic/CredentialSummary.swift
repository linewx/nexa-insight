import Foundation

/// What the Settings root says about stored credentials without showing any of
/// them, and what each row on the Credentials page says about itself.
///
/// Split out as plain logic because the interesting parts are decisions, not
/// layout: whether a service counts as configured when it needs two fields, and
/// how to describe a secret you must never render.
enum CredentialSummary {
    /// A service is only configured when every field it needs is filled — the
    /// realtime classroom needs a workspace id alongside its key, and reporting
    /// it as ready with one of the two sent you to a Talk button that could not
    /// connect.
    struct Service: Equatable, Identifiable {
        let id: String
        let name: String
        let detail: String
        let values: [String]

        var isConfigured: Bool {
            !values.isEmpty && values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    static func services(
        dashscopeKey: String,
        workspaceId: String,
        youtubeAPIKey: String,
        openAIKey: String
    ) -> [Service] {
        [
            Service(
                id: "dashscope",
                name: "\u{5b9e}\u{65f6}\u{8bfe}\u{5802}",
                detail: "DashScope \u{5bc6}\u{94a5} + Workspace ID",
                values: [dashscopeKey, workspaceId]),
            Service(
                id: "youtube",
                name: "\u{9891}\u{9053}\u{6d4f}\u{89c8}",
                detail: "YouTube Data API \u{5bc6}\u{94a5}",
                values: [youtubeAPIKey]),
            Service(
                id: "openai",
                name: "\u{8ddf}\u{8bfb}\u{53cd}\u{9988}",
                detail: "OpenAI \u{5bc6}\u{94a5}",
                values: [openAIKey]),
        ]
    }

    /// The root row's right-hand summary: a count, not a list of names, so the
    /// page stays one line per group.
    static func rootSummary(_ services: [Service]) -> String {
        let configured = services.filter(\.isConfigured).count
        if configured == 0 { return "\u{672a}\u{914d}\u{7f6e}" }
        if configured == services.count { return "\u{5168}\u{90e8}\u{5df2}\u{914d}\u{7f6e}" }
        return "\(configured)/\(services.count) \u{5df2}\u{914d}\u{7f6e}"
    }

    /// Per-field state. A secure field whose placeholder always read "Stored in
    /// Keychain" could not tell a saved key from an empty one, so the state has
    /// to be explicit rather than implied by the placeholder.
    enum FieldState: Equatable {
        case saved
        case empty

        var label: String {
            switch self {
            case .saved: return "\u{5df2}\u{5b58}"
            case .empty: return "\u{672a}\u{914d}\u{7f6e}"
            }
        }
    }

    static func fieldState(_ value: String) -> FieldState {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .saved
    }
}
