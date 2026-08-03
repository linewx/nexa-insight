import XCTest
@testable import NexaInsightCore

// Fixtures below are trimmed from live YouTube Data API v3 responses, with field
// names and nesting preserved exactly. Unlike the scraped-page parsers, this API
// has a documented stability contract, so these shapes are a real contract to
// hold rather than a snapshot of something that churns.
final class YouTubeAPIParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_000_000)

    private let uploadsJSON = """
    {
      "kind": "youtube#playlistItemListResponse",
      "nextPageToken": "EAAaHlBUOkNESWlFRFEzT1RKQ1EwRTFORUV5TjBZeE5EWQ",
      "pageInfo": { "totalResults": 865, "resultsPerPage": 50 },
      "items": [
        {
          "kind": "youtube#playlistItem",
          "snippet": {
            "publishedAt": "2026-07-28T20:02:11Z",
            "channelId": "UCSHZKyawb77ixDdsGog4iWA",
            "title": "Gary Gallagher: American Civil War, Slavery, Lincoln",
            "description": "Gary Gallagher is a historian.",
            "thumbnails": {
              "default": { "url": "https://i.ytimg.com/vi/XyXBwO5jYpw/default.jpg" },
              "medium": { "url": "https://i.ytimg.com/vi/XyXBwO5jYpw/mqdefault.jpg" },
              "high": { "url": "https://i.ytimg.com/vi/XyXBwO5jYpw/hqdefault.jpg" },
              "standard": { "url": "https://i.ytimg.com/vi/XyXBwO5jYpw/sddefault.jpg" },
              "maxres": { "url": "https://i.ytimg.com/vi/XyXBwO5jYpw/maxresdefault.jpg" }
            },
            "videoOwnerChannelId": "UCSHZKyawb77ixDdsGog4iWA",
            "videoOwnerChannelTitle": "Lex Fridman"
          },
          "contentDetails": {
            "videoId": "XyXBwO5jYpw",
            "videoPublishedAt": "2026-07-28T20:02:11Z"
          }
        },
        {
          "kind": "youtube#playlistItem",
          "snippet": {
            "publishedAt": "2026-06-30T21:16:13Z",
            "title": "The Rise and Fall of the Roman Empire",
            "description": "",
            "thumbnails": {
              "high": { "url": "https://i.ytimg.com/vi/pv1TUJSEM2k/hqdefault.jpg" }
            },
            "videoOwnerChannelId": "UCSHZKyawb77ixDdsGog4iWA",
            "videoOwnerChannelTitle": "Lex Fridman"
          },
          "contentDetails": {
            "videoId": "pv1TUJSEM2k",
            "videoPublishedAt": "2026-06-30T21:16:13Z"
          }
        }
      ]
    }
    """

    private func parseUploads(_ json: String) throws -> UploadsPage {
        try YouTubeAPIParser.parseUploads(Data(json.utf8), now: now)
    }

    // MARK: - Uploads

    func testParsesUploadsPage() throws {
        let page = try parseUploads(uploadsJSON)
        XCTAssertEqual(page.videos.map(\.videoId), ["XyXBwO5jYpw", "pv1TUJSEM2k"])
        XCTAssertEqual(page.videos[0].title, "Gary Gallagher: American Civil War, Slavery, Lincoln")
        XCTAssertEqual(page.videos[0].channelTitle, "Lex Fridman")
        XCTAssertEqual(page.videos[0].channelId, "UCSHZKyawb77ixDdsGog4iWA")
    }

    // The entire point of this data source: RSS caps at 15, this channel has 865.
    func testTotalCountReportsTheWholeCatalog() throws {
        XCTAssertEqual(try parseUploads(uploadsJSON).totalCount, 865)
    }

    func testNextPageTokenIsCarried() throws {
        XCTAssertEqual(try parseUploads(uploadsJSON).nextPageToken,
                       "EAAaHlBUOkNESWlFRFEzT1RKQ1EwRTFORUV5TjBZeE5EWQ")
    }

    func testLastPageHasNoToken() throws {
        let json = """
        {"items": [], "pageInfo": {"totalResults": 865, "resultsPerPage": 50}}
        """
        let page = try parseUploads(json)
        XCTAssertNil(page.nextPageToken, "absence of the token is how paging ends")
        XCTAssertTrue(page.videos.isEmpty)
    }

    // The API returns the uploads playlist newest-first, which is the order we
    // want. Re-sorting would be redundant and would risk disagreeing with it.
    func testOrderIsPreserved() throws {
        let page = try parseUploads(uploadsJSON)
        XCTAssertEqual(page.videos.map(\.videoId), ["XyXBwO5jYpw", "pv1TUJSEM2k"],
                       "newest first, as the API sends it")
    }

    // maxres is absent on older uploads, so the walk down the list matters.
    func testPicksWidestAvailableThumbnail() throws {
        let page = try parseUploads(uploadsJSON)
        XCTAssertEqual(page.videos[0].thumbnailURL?.absoluteString,
                       "https://i.ytimg.com/vi/XyXBwO5jYpw/maxresdefault.jpg")
        XCTAssertEqual(page.videos[1].thumbnailURL?.absoluteString,
                       "https://i.ytimg.com/vi/pv1TUJSEM2k/hqdefault.jpg",
                       "falls back when maxres is absent")
    }

    func testEmptyDescriptionBecomesNil() throws {
        let page = try parseUploads(uploadsJSON)
        XCTAssertEqual(page.videos[0].summary, "Gary Gallagher is a historian.")
        XCTAssertNil(page.videos[1].summary, "an empty string is not a summary")
    }

    // Duration needs a second request (videos.list), so the first page renders
    // without it rather than blocking on it.
    func testDurationAndViewsAreAbsentUntilMerged() throws {
        let page = try parseUploads(uploadsJSON)
        XCTAssertNil(page.videos[0].durationText)
        XCTAssertNil(page.videos[0].viewsText)
    }

    func testPublishedDateBecomesRelativeText() throws {
        let page = try parseUploads(uploadsJSON)
        XCTAssertNotNil(page.videos[0].publishedText)
        XCTAssertFalse(page.videos[0].publishedText?.isEmpty ?? true)
    }

    // Deleted and private videos come back with an empty videoId; rendering them
    // would put blank untappable rows in the list.
    func testDroppedItemsWithEmptyVideoId() throws {
        let json = """
        {"items": [
          {"snippet": {"title": "Deleted video", "thumbnails": {}},
           "contentDetails": {"videoId": ""}},
          {"snippet": {"title": "Real one", "thumbnails": {}},
           "contentDetails": {"videoId": "XyXBwO5jYpw"}}
        ]}
        """
        XCTAssertEqual(try parseUploads(json).videos.map(\.videoId), ["XyXBwO5jYpw"])
    }

    func testMalformedJSONThrowsUnreadable() {
        XCTAssertThrowsError(try parseUploads("{not json")) { error in
            XCTAssertEqual(error as? YouTubeAPIError, .unreadable)
        }
    }

    // MARK: - Video details

    private let videosJSON = """
    {
      "items": [
        {
          "id": "XyXBwO5jYpw",
          "contentDetails": { "duration": "PT3H46M18S", "definition": "hd" },
          "statistics": { "viewCount": "220947", "likeCount": "3805" }
        },
        {
          "id": "3HQkVfZ4DNY",
          "contentDetails": { "duration": "PT1M" },
          "statistics": { "viewCount": "1500000" }
        }
      ]
    }
    """

    func testParsesDurationsAndViews() throws {
        let details = try YouTubeAPIParser.parseVideoDetails(Data(videosJSON.utf8))
        XCTAssertEqual(details["XyXBwO5jYpw"]?.durationText, "3:46:18")
        XCTAssertEqual(details["XyXBwO5jYpw"]?.viewsText, "220,947 views")
        XCTAssertFalse(details["XyXBwO5jYpw"]?.isShort ?? true)
    }

    // Regression lock: the device locale must not leak into this string. On a
    // Chinese-locale machine, compact formatting produced "22万 views" — a
    // localized number welded to a hardcoded English word. The scraped pages are
    // pinned to en-US by hl/gl, so this must match them or the two sources render
    // visibly differently in the same list.
    func testViewCountFormatDoesNotFollowTheDeviceLocale() throws {
        let details = try YouTubeAPIParser.parseVideoDetails(Data(videosJSON.utf8))
        let views = details["3HQkVfZ4DNY"]?.viewsText ?? ""
        XCTAssertEqual(views, "1,500,000 views")
        XCTAssertTrue(views.allSatisfy { $0.isASCII },
                      "matches the scraped pages' en-US form: \(views)")
    }

    func testFlagsVideosBelowTenMinutesByDuration() throws {
        let details = try YouTubeAPIParser.parseVideoDetails(Data(videosJSON.utf8))
        XCTAssertTrue(details["3HQkVfZ4DNY"]?.isShort ?? false)
        let json = """
        {"items": [{"id": "ten", "contentDetails": {"duration": "PT10M"}}]}
        """
        let tenMinute = try YouTubeAPIParser.parseVideoDetails(Data(json.utf8))
        XCTAssertFalse(tenMinute["ten"]?.isShort ?? true, "exactly ten minutes is kept")
    }

    // Keyed by id because the API does not promise to return ids in the order
    // they were requested — merging by position would mismatch durations.
    func testDetailsAreKeyedByVideoId() throws {
        let details = try YouTubeAPIParser.parseVideoDetails(Data(videosJSON.utf8))
        XCTAssertEqual(Set(details.keys), ["XyXBwO5jYpw", "3HQkVfZ4DNY"])
    }

    func testMissingStatisticsLeavesViewsNil() throws {
        let json = """
        {"items": [{"id": "aaa", "contentDetails": {"duration": "PT10M"}}]}
        """
        let details = try YouTubeAPIParser.parseVideoDetails(Data(json.utf8))
        XCTAssertEqual(details["aaa"]?.durationText, "10:00")
        XCTAssertNil(details["aaa"]?.viewsText)
    }

    // MARK: - Errors

    // Quota exhaustion is fixed by waiting; a bad key is fixed in Settings. The
    // reason string is what lets the UI tell them apart.
    func testExtractsErrorReason() {
        let json = """
        {"error": {"code": 403, "message": "quota exceeded",
          "errors": [{"reason": "quotaExceeded", "domain": "youtube.quota"}]}}
        """
        XCTAssertEqual(YouTubeAPIParser.errorReason(Data(json.utf8)), "quotaExceeded")
    }

    func testErrorReasonNilForNonErrorBody() {
        XCTAssertNil(YouTubeAPIParser.errorReason(Data(#"{"items":[]}"#.utf8)))
    }

    func testQuotaErrorMessageDiffersFromBadKey() {
        let quota = YouTubeAPIError.rejected(reason: "quotaExceeded").errorDescription ?? ""
        let badKey = YouTubeAPIError.rejected(reason: "badRequest").errorDescription ?? ""
        XCTAssertNotEqual(quota, badKey)
        XCTAssertTrue(quota.lowercased().contains("quota"))
        XCTAssertTrue(badKey.lowercased().contains("key"))
    }

    // MARK: - Playlist id

    // Verified live: UC... -> UU... returned that channel's 865 uploads.
    func testUploadsPlaylistIdSwapsThePrefix() {
        XCTAssertEqual(
            YouTubeAPIParser.uploadsPlaylistId(channelId: "UCSHZKyawb77ixDdsGog4iWA"),
            "UUSHZKyawb77ixDdsGog4iWA")
    }

    func testUploadsPlaylistIdRejectsMalformedChannelId() {
        XCTAssertNil(YouTubeAPIParser.uploadsPlaylistId(channelId: "not-a-channel"))
        XCTAssertNil(YouTubeAPIParser.uploadsPlaylistId(channelId: ""))
    }
}
