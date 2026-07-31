import XCTest
@testable import NexaInsightCore

final class DiscoverFeedParserTests: XCTestCase {
    // Trimmed from a real feed. Two entries: one normal watch video, one Short.
    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <title>Lex Fridman</title>
     <entry>
      <yt:videoId>XyXBwO5jYpw</yt:videoId>
      <yt:channelId>UCSHZKyawb77ixDdsGog4iWA</yt:channelId>
      <title>Gary Gallagher: American Civil War &amp; Lincoln</title>
      <link rel="alternate" href="https://www.youtube.com/watch?v=XyXBwO5jYpw"/>
      <author><name>Lex Fridman</name></author>
      <published>2026-07-28T20:02:11+00:00</published>
      <media:group>
       <media:thumbnail url="https://i1.ytimg.com/vi/XyXBwO5jYpw/hqdefault.jpg" width="480" height="360"/>
       <media:description>Gary Gallagher is a historian of the American Civil War.</media:description>
       <media:statistics views="189212"/>
      </media:group>
     </entry>
     <entry>
      <yt:videoId>3HQkVfZ4DNY</yt:videoId>
      <yt:channelId>UCSHZKyawb77ixDdsGog4iWA</yt:channelId>
      <title>Zippers are stronger than you think</title>
      <link rel="alternate" href="https://www.youtube.com/shorts/3HQkVfZ4DNY"/>
      <author><name>Lex Fridman</name></author>
      <published>2026-07-27T10:00:00+00:00</published>
      <media:group>
       <media:thumbnail url="https://i1.ytimg.com/vi/3HQkVfZ4DNY/hqdefault.jpg" width="480" height="360"/>
       <media:description>short clip</media:description>
       <media:statistics views="500"/>
      </media:group>
     </entry>
    </feed>
    """

    func testParsesEntryFields() {
        let items = DiscoverFeedParser.parse(Data(feed.utf8))
        XCTAssertEqual(items.count, 1, "the Short must be excluded")
        let item = items[0]
        XCTAssertEqual(item.videoId, "XyXBwO5jYpw")
        XCTAssertEqual(item.channelId, "UCSHZKyawb77ixDdsGog4iWA")
        XCTAssertEqual(item.title, "Gary Gallagher: American Civil War & Lincoln")
        XCTAssertEqual(item.channelTitle, "Lex Fridman")
        XCTAssertEqual(item.summary, "Gary Gallagher is a historian of the American Civil War.")
        XCTAssertEqual(item.thumbnailURL?.absoluteString, "https://i1.ytimg.com/vi/XyXBwO5jYpw/hqdefault.jpg")
        XCTAssertEqual(item.viewCount, 189212)
        XCTAssertEqual(item.watchURL.absoluteString, "https://www.youtube.com/watch?v=XyXBwO5jYpw")
        XCTAssertEqual(item.id, "XyXBwO5jYpw")
    }

    func testParsesPublishedDate() {
        let items = DiscoverFeedParser.parse(Data(feed.utf8))
        // 2026-07-28T20:02:11Z
        XCTAssertEqual(items[0].published.timeIntervalSince1970, 1785268931, accuracy: 1)
    }

    // Verified live: description and thumbnail were non-empty in all 15 entries
    // of both channels sampled, but that is a sample, not a guarantee. Missing
    // values must degrade, not crash or drop the entry.
    func testMissingOptionalFieldsDegradeGracefully() {
        let sparse = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
         <entry>
          <yt:videoId>abcdefghijk</yt:videoId>
          <yt:channelId>UCSHZKyawb77ixDdsGog4iWA</yt:channelId>
          <title>No extras</title>
          <link rel="alternate" href="https://www.youtube.com/watch?v=abcdefghijk"/>
          <author><name>Someone</name></author>
          <published>2026-07-01T00:00:00+00:00</published>
         </entry>
        </feed>
        """
        let items = DiscoverFeedParser.parse(Data(sparse.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].summary)
        XCTAssertNil(items[0].thumbnailURL)
        XCTAssertNil(items[0].viewCount)
        XCTAssertEqual(items[0].title, "No extras")
    }

    func testSkipsEntriesMissingRequiredFields() {
        let broken = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
         <entry>
          <title>No video id at all</title>
          <published>2026-07-01T00:00:00+00:00</published>
         </entry>
        </feed>
        """
        XCTAssertTrue(DiscoverFeedParser.parse(Data(broken.utf8)).isEmpty)
    }

    func testMalformedXMLReturnsEmptyWithoutCrashing() {
        XCTAssertTrue(DiscoverFeedParser.parse(Data("<feed><entry".utf8)).isEmpty)
        XCTAssertTrue(DiscoverFeedParser.parse(Data()).isEmpty)
    }

    func testMergeSortsNewestFirstAndDeduplicates() {
        let older = DiscoverEntry(
            videoId: "old11111111", channelId: "UCSHZKyawb77ixDdsGog4iWA", title: "Older",
            channelTitle: "A", published: Date(timeIntervalSince1970: 1000),
            summary: nil, thumbnailURL: nil, viewCount: nil,
            watchURL: URL(string: "https://www.youtube.com/watch?v=old11111111")!)
        let newer = DiscoverEntry(
            videoId: "new11111111", channelId: "UCHnyfMqiRRG1u-2MsSQLbXA", title: "Newer",
            channelTitle: "B", published: Date(timeIntervalSince1970: 2000),
            summary: nil, thumbnailURL: nil, viewCount: nil,
            watchURL: URL(string: "https://www.youtube.com/watch?v=new11111111")!)

        let merged = DiscoverFeedParser.merge([[older], [newer], [newer]])
        XCTAssertEqual(merged.map(\.videoId), ["new11111111", "old11111111"])
    }
}
