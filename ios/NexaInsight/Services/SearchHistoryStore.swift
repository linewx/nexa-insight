import Foundation

// Terms you have searched before, newest first.
//
// The full-screen search page needs something under the field, and YouTube fills
// that space with autocomplete suggestions from an endpoint we do not have. What we
// do have is your own history, which costs no request and — for a learner returning
// to the same subjects — is arguably the more useful list.
final class SearchHistoryStore: ObservableObject {
    // Enough to cover the subjects someone is actually working through, short
    // enough that the list never needs its own scrolling.
    static let limit = 8

    @Published private(set) var terms: [String] = []

    private let defaults: UserDefaults
    private let key = "searchHistory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = defaults.stringArray(forKey: key) ?? []
    }

    // Re-searching an existing term moves it to the front rather than duplicating
    // it, so the list stays a set ordered by recency.
    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = terms.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.insert(trimmed, at: 0)
        terms = Array(next.prefix(Self.limit))
        defaults.set(terms, forKey: key)
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        defaults.set(terms, forKey: key)
    }

    func clear() {
        terms = []
        defaults.removeObject(forKey: key)
    }

    // Filters as you type, so the list narrows toward what you are reaching for
    // instead of sitting there unchanged. An empty query shows everything.
    func matching(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return terms }
        return terms.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}
