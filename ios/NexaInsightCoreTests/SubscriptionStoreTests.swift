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

    // Regression lock on the highest-cost failure available here: the store
    // decodes the whole array under one `try?`, so a single undecodable element
    // silently empties the follow list. avatarURL and subscriberText were added
    // after users already had subscriptions saved without them, so if either
    // were non-optional this JSON would wipe every existing channel.
    func testDecodesSubscriptionsSavedBeforeAvatarFieldsExisted() {
        let legacy = """
        [{"channelId":"UCSHZKyawb77ixDdsGog4iWA","title":"Lex Fridman","addedAt":0}]
        """
        defaults.set(Data(legacy.utf8), forKey: "discoverSubscriptions")

        let store = SubscriptionStore(defaults: defaults)
        XCTAssertEqual(store.subscriptions.map(\.channelId), ["UCSHZKyawb77ixDdsGog4iWA"],
                       "adding a required field here would empty every existing user's list")
        XCTAssertEqual(store.subscriptions[0].title, "Lex Fridman")
        XCTAssertNil(store.subscriptions[0].avatarURL)
        XCTAssertNil(store.subscriptions[0].subscriberText)
    }

    func testAvatarAndSubscriberTextRoundTrip() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(Subscription(
            channelId: "UCSHZKyawb77ixDdsGog4iWA",
            title: "Lex Fridman",
            addedAt: Date(timeIntervalSince1970: 0),
            avatarURL: URL(string: "https://yt3.googleusercontent.com/abc=s176"),
            subscriberText: "4.7M subscribers"))

        let reloaded = SubscriptionStore(defaults: defaults)
        XCTAssertEqual(reloaded.subscriptions[0].avatarURL?.absoluteString,
                       "https://yt3.googleusercontent.com/abc=s176")
        XCTAssertEqual(reloaded.subscriptions[0].subscriberText, "4.7M subscribers")
    }

    // Re-following an existing channel must not blank fields the row displays.
    func testAddingAgainWithoutAvatarKeepsTheStoredOne() {
        let store = SubscriptionStore(defaults: defaults)
        store.add(Subscription(
            channelId: "UCSHZKyawb77ixDdsGog4iWA", title: "Lex Fridman",
            addedAt: Date(timeIntervalSince1970: 0),
            avatarURL: URL(string: "https://yt3.googleusercontent.com/abc=s176"),
            subscriberText: "4.7M subscribers"))
        store.add(sub("UCSHZKyawb77ixDdsGog4iWA", "Lex Fridman Renamed"))

        XCTAssertEqual(store.subscriptions.count, 1)
        XCTAssertEqual(store.subscriptions[0].title, "Lex Fridman Renamed")
        XCTAssertEqual(store.subscriptions[0].avatarURL?.absoluteString,
                       "https://yt3.googleusercontent.com/abc=s176",
                       "a re-follow without avatar data must not erase it")
        XCTAssertEqual(store.subscriptions[0].subscriberText, "4.7M subscribers")
    }
}
