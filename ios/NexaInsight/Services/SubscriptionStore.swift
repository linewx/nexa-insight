import Foundation

// The channels the user follows.
//
// Lives in UserDefaults rather than SwiftData/EpisodeStore: a subscription list
// is a device-local preference, while EpisodeStore holds imported study content.
// Different lifecycles, so different homes.
final class SubscriptionStore: ObservableObject {
    private static let key = "discoverSubscriptions"

    private let defaults: UserDefaults

    @Published private(set) var subscriptions: [Subscription] = [] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([Subscription].self, from: data) {
            subscriptions = stored
        }
    }

    func add(_ subscription: Subscription) {
        if let index = subscriptions.firstIndex(where: { $0.channelId == subscription.channelId }) {
            subscriptions[index].title = subscription.title
        } else {
            subscriptions.append(subscription)
        }
    }

    func remove(channelId: String) {
        subscriptions.removeAll { $0.channelId == channelId }
    }

    func contains(channelId: String) -> Bool {
        subscriptions.contains { $0.channelId == channelId }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(subscriptions) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
