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

    // Merges rather than replaces. Opening a channel parses its header and calls
    // this again, which is how a subscription saved before avatars existed
    // upgrades from a monogram to the real image. New values win, but a nil does
    // not erase what is already stored — the channel screen may not have managed
    // to parse a header this time.
    func add(_ subscription: Subscription) {
        guard let index = subscriptions.firstIndex(where: { $0.channelId == subscription.channelId })
        else {
            subscriptions.append(subscription)
            return
        }
        subscriptions[index].title = subscription.title
        if let avatarURL = subscription.avatarURL { subscriptions[index].avatarURL = avatarURL }
        if let subscriberText = subscription.subscriberText {
            subscriptions[index].subscriberText = subscriberText
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
