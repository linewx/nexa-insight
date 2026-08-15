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

    // Which mode an episode opens in.
    //
    // OFF by default: listening is the default way to study. It used to be on, under the
    // name `showReadingAnnotations`, from when reading was an exclusive mode that decided
    // whether the transcript was marked up at all. It no longer decides that — highlights
    // now appear whenever the episode HAS expressions, in either mode (see
    // StudyView.annotated) — so all this ever did was pick the mode you land in, and the
    // old name described a job it no longer had.
    //
    // Deliberately a NEW key: the old one is true on every device that has run the app,
    // and reusing it would silently keep opening in reading for exactly the people who
    // never chose it.
    @Published var opensInReading: Bool {
        didSet { defaults.set(opensInReading, forKey: "opensInReading") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: "backendBaseURL")
        let resolved = Self.resolveBackendBaseURL(stored)
        self.backendBaseURL = resolved
        self.localizedBylines = defaults.bool(forKey: "localizedBylines")
        // `bool(forKey:)` already returns false for a key never written, which is the
        // wanted default here — so unlike the flags above this needs no explicit
        // establishing. Spelled out anyway, because "the default is the absence of a
        // value" is the kind of thing that reads as an oversight.
        self.opensInReading = defaults.bool(forKey: "opensInReading")
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
