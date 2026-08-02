import XCTest
@testable import NexaInsightCore

final class SearchHistoryStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SearchHistoryStoreTests")!
        defaults.removePersistentDomain(forName: "SearchHistoryStoreTests")
    }

    private func store() -> SearchHistoryStore {
        SearchHistoryStore(defaults: defaults)
    }

    func testStartsEmpty() {
        XCTAssertTrue(store().terms.isEmpty)
    }

    func testNewestFirst() {
        let s = store()
        s.record("quantum gravity")
        s.record("roman empire")
        XCTAssertEqual(s.terms, ["roman empire", "quantum gravity"])
    }

    // The list is a set ordered by recency, so searching something again moves it
    // rather than adding a second copy.
    func testRepeatSearchMovesToFrontWithoutDuplicating() {
        let s = store()
        s.record("physics")
        s.record("history")
        s.record("physics")
        XCTAssertEqual(s.terms, ["physics", "history"])
    }

    // Case differences are the same search as far as a person is concerned.
    func testCaseInsensitiveDeduplication() {
        let s = store()
        s.record("Physics")
        s.record("physics")
        XCTAssertEqual(s.terms.count, 1)
        XCTAssertEqual(s.terms.first, "physics", "the latest spelling wins")
    }

    func testWhitespaceIsTrimmedAndBlanksIgnored() {
        let s = store()
        s.record("  spaced  ")
        s.record("   ")
        s.record("")
        XCTAssertEqual(s.terms, ["spaced"])
    }

    // Capped so the list never needs to scroll on the search page.
    func testCapsAtTheLimit() {
        let s = store()
        for i in 1...(SearchHistoryStore.limit + 4) { s.record("term \(i)") }
        XCTAssertEqual(s.terms.count, SearchHistoryStore.limit)
        XCTAssertEqual(s.terms.first, "term \(SearchHistoryStore.limit + 4)")
        XCTAssertFalse(s.terms.contains("term 1"), "the oldest fell off")
    }

    func testPersistsAcrossInstances() {
        store().record("persisted")
        XCTAssertEqual(store().terms, ["persisted"])
    }

    func testRemoveAndClear() {
        let s = store()
        s.record("a")
        s.record("b")
        s.remove("a")
        XCTAssertEqual(s.terms, ["b"])
        s.clear()
        XCTAssertTrue(s.terms.isEmpty)
        XCTAssertTrue(store().terms.isEmpty, "clearing persists too")
    }

    // Typing narrows the list toward what you are reaching for.
    func testMatchingFiltersAsYouType() {
        let s = store()
        s.record("quantum gravity")
        s.record("roman history")
        s.record("quantum computing")
        XCTAssertEqual(s.matching("quantum"), ["quantum computing", "quantum gravity"])
        XCTAssertEqual(s.matching("ROM"), ["roman history"], "case-insensitive")
        XCTAssertEqual(s.matching("").count, 3, "an empty query shows everything")
        XCTAssertTrue(s.matching("zzz").isEmpty)
    }
}
