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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: "backendBaseURL")
        let resolved = Self.resolveBackendBaseURL(stored)
        self.backendBaseURL = resolved
        if stored != resolved {
            defaults.set(resolved, forKey: "backendBaseURL")
        }
    }

    static func resolveBackendBaseURL(_ stored: String?) -> String {
        guard let stored, !stored.isEmpty else {
            return Self.defaultBackendBaseURL
        }
        return stored
    }
}
