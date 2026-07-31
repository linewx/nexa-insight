import XCTest
@testable import NexaInsightCore

final class SubscriptionStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Isolated suite so tests never touch the app's real preferences.
        defaults = UserDefaults(suiteName: "SubscriptionStoreTests")!
        defaults.removePersistentDomain(forName: "SubscriptionStoreTests")
    }

    private func sub(_ id: String, _ title: String = "Channel") -> Subscription {
        Subscription(channelId: id, title: title, addedAt: Date(timeIntervalSince1970: 0))
    }

    func testStartsEmpty() {
        XCTAssertTrue(SubscriptionStore(defaults: defaults).subscriptions.isEmpty)
    }

    func testAddThenRead() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA", "Lex Fridman"))
        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCSHZKyawb77ixDdsGog4iWA"])
        XCTAssertEqual(store.subscriptions[0].title, "Lex Fridman")
    }

    func testAddingSameChannelTwiceKeepsOneAndUpdatesTitle() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA", "Old Name"))
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA", "New Name"))
        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(store.subscriptions[0].title, "New Name")
    }

    func testRemove() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA"))
        store.add(sub("UCHnyfMqiRRG1u-2MsSQLbXA"))
        store.remove(channelId: "UCSHZKyawb77ixDdsGog4iWA")
        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCHnyfMqiRRG1u-2MsSQLbXA"])
    }

    func testContains() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA"))
        XCTAssertTrue(store.contains(channelId: "UCSHZKyawb77ixDdsGog4iWA"))
        XCTAssertFalse(store.contains(channelId: "UCHnyfMqiRRG1u-2MsSQLbXA"))
    }

    func testPersistsAcrossInstances() {
        let first = SubscriptionStore(defaults: defaults)
        first.add(sub("UCSHZKyawb77ixDdsGog4iWA", "Lex Fridman"))

        let second = SubscriptionStore(defaults: defaults)
        XCTAssertEqual(second.subscriptions.map(\.channelId), ["UCSHZKyawb77ixDdsGog4iWA"])
        XCTAssertEqual(second.subscriptions[0].title, "Lex Fridman")
    }

    func testCorruptStoredValueIsIgnored() {
        defaults.set("not json", forKey: "discoverSubscriptions")
        XCTAssertTrue(SubscriptionStore(defaults: defaults).subscriptions.isEmpty)
    }
}
