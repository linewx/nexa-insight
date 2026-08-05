import Foundation

final class AppSettings: ObservableObject {
    private let defaults: UserDefaults
    static var defaultBackendBaseURL: String {
        #if targetEnvironment(simulator)
        "http://localhost:8000"
        #else
        "http://100.64.0.1:8000"
        #endif
    }

    @Published var backendBaseURL: String {
        didSet { defaults.set(backendBaseURL, forKey: "backendBaseURL") }
    }

    // Whether Discover bylines follow the device language.
    //
    // Off by default. A ja-JP device otherwise rendered "3日前" and "41万 views"
    // beside English video titles, because RelativeDateTimeFormatter and compact
    // number notation both follow Locale.current. The content itself is English,
    // so English bylines are the consistent default — but a user who prefers
    // their own language can turn this on.
    @Published var localizedBylines: Bool {
        didSet { defaults.set(localizedBylines, forKey: "localizedBylines") }
    }

    // Whether the transcript marks up its learning expressions.
    //
    // On by default, and additive rather than a mode: annotations appear on top of
    // intensive listening instead of replacing it. Reading used to be an exclusive
    // mode, which removed tap-to-seek and the per-sentence controls — exactly the
    // things you want when a definition explains why you misheard a line.
    @Published var showReadingAnnotations: Bool {
        didSet { defaults.set(showReadingAnnotations, forKey: "showReadingAnnotations") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: "backendBaseURL")
        let resolved = Self.resolveBackendBaseURL(stored)
        self.backendBaseURL = resolved
        self.localizedBylines = defaults.bool(forKey: "localizedBylines")
        // `bool(forKey:)` returns false for a key that was never written, so the
        // default has to be established explicitly rather than inferred.
        self.showReadingAnnotations = defaults.object(forKey: "showReadingAnnotations") as? Bool ?? true
        if stored != resolved {
            defaults.set(resolved, forKey: "backendBaseURL")
        }
    }

    // The locale Discover bylines format with.
    var bylineLocale: Locale {
        localizedBylines ? .current : DiscoverFormat.defaultLocale
    }

    static func resolveBackendBaseURL(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else {
            return Self.defaultBackendBaseURL
        }
        return stored
    }
}
