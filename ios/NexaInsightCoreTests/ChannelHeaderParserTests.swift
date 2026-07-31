import XCTest
@testable import NexaInsightCore

final class ChannelHeaderParserTests: XCTestCase {
    private func page(_ dataJSON: String) -> Data {
        Data("<html><body><script>var ytInitialData = \(dataJSON);</script></body></html>".utf8)
    }

    // The older shape, which the channel page still served when measured.
    private let c4Header = """
    {"header":{"c4TabbedHeaderRenderer":{
      "title":{"simpleText":"Lex Fridman"},
      "subscriberCountText":{"simpleText":"4.7M subscribers"},
      "avatar":{"thumbnails":[
        {"url":"https://yt3.googleusercontent.com/abc=s48","width":48,"height":48},
        {"url":"https://yt3.googleusercontent.com/abc=s176","width":176,"height":176}]}
    }}}
    """

    func testParsesTitleAvatarAndSubscribers() {
        let header = ChannelHeaderParser.parse(page(c4Header))
        XCTAssertEqual(header.title, "Lex Fridman")
        XCTAssertEqual(header.subscriberText, "4.7M subscribers")
        XCTAssertEqual(header.avatarURL?.absoluteString, "https://yt3.googleusercontent.com/abc=s176")
    }

    // A 32pt avatar on a Retina screen needs more than the 48px variant, so the
    // widest thumbnail is chosen rather than the first one listed.
    func testPicksTheWidestAvatarVariant() {
        let header = ChannelHeaderParser.parse(page(c4Header))
        XCTAssertEqual(header.avatarURL?.absoluteString.hasSuffix("s176"), true)
    }

    // YouTube is migrating this layer, so the newer shape must parse too — the
    // videoRenderer/lockupViewModel split on sibling pages is the precedent.
    func testParsesNewerPageHeaderShape() {
        let json = """
        {"header":{"pageHeaderRenderer":{"content":{"pageHeaderViewModel":\
        {"title":{"dynamicTextViewModel":{"text":{"content":"Veritasium"}}},\
        "image":{"decoratedAvatarViewModel":{"avatar":{"avatarViewModel":{"image":\
        {"sources":[],"thumbnails":[{"url":"https://yt3.googleusercontent.com/v=s160","width":160}]}}}}},\
        "metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":\
        [{"text":{"content":"@veritasium"}},{"text":{"content":"1.67M subscribers"}}]}]}}}}}}}
        """
        let header = ChannelHeaderParser.parse(page(json))
        XCTAssertEqual(header.title, "Veritasium")
        XCTAssertEqual(header.avatarURL?.absoluteString, "https://yt3.googleusercontent.com/v=s160")
        XCTAssertEqual(header.subscriberText, "1.67M subscribers")
    }

    func testFallsBackToChannelMetadataRenderer() {
        let json = """
        {"metadata":{"channelMetadataRenderer":{
          "title":"Sean Carroll",
          "avatar":{"thumbnails":[{"url":"https://yt3.googleusercontent.com/s=s900","width":900}]}}}}
        """
        let header = ChannelHeaderParser.parse(page(json))
        XCTAssertEqual(header.title, "Sean Carroll")
        XCTAssertEqual(header.avatarURL?.absoluteString, "https://yt3.googleusercontent.com/s=s900")
    }

    // The contract that keeps a header failure from becoming a page failure: the
    // screen shows the title it already had and the content below is unaffected.
    func testMissingDataReturnsEmptyRatherThanFailing() {
        let header = ChannelHeaderParser.parse(Data("<html>consent interstitial</html>".utf8))
        XCTAssertEqual(header, .empty)
        XCTAssertTrue(header.isEmpty)
    }

    func testMalformedJSONReturnsEmpty() {
        XCTAssertEqual(ChannelHeaderParser.parse(page("{not json")), .empty)
    }

    func testUnknownShapeReturnsEmptyNotGarbage() {
        let header = ChannelHeaderParser.parse(page("""
        {"header":{"someFutureRenderer":{"whatever":{"simpleText":"x"}}}}
        """))
        XCTAssertNil(header.title)
        XCTAssertNil(header.avatarURL)
        XCTAssertNil(header.subscriberText)
    }

    // Partial data is normal and usable — a missing avatar must not discard the
    // subscriber count that did parse.
    func testPartialDataKeepsWhatParsed() {
        let header = ChannelHeaderParser.parse(page("""
        {"header":{"c4TabbedHeaderRenderer":{
          "title":{"simpleText":"No Avatar Channel"},
          "subscriberCountText":{"simpleText":"12K subscribers"}}}}
        """))
        XCTAssertEqual(header.title, "No Avatar Channel")
        XCTAssertEqual(header.subscriberText, "12K subscribers")
        XCTAssertNil(header.avatarURL)
        XCTAssertFalse(header.isEmpty)
    }

    func testProtocolRelativeAvatarIsMadeAbsolute() {
        let header = ChannelHeaderParser.parse(page("""
        {"header":{"c4TabbedHeaderRenderer":{"title":{"simpleText":"T"},
          "avatar":{"thumbnails":[{"url":"//yt3.googleusercontent.com/x=s88","width":88}]}}}}
        """))
        XCTAssertEqual(header.avatarURL?.absoluteString, "https://yt3.googleusercontent.com/x=s88")
    }
}
