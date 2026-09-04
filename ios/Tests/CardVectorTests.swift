// Unit tests — every case in docs/card-vectors.json (PROTOCOL.md §2), plus the feed merge.

import Foundation
import XCTest
@testable import tgsocial

final class CardVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct ParseCase: Decodable {
            let name: String
            let text: String
            let expect: Expected?
            let newerVersion: Bool?
        }
        struct Expected: Decodable {
            let name: String?
            let bio: String?
            let link: String?
            let `public`: Bool
            let feeds: [String]
            let follows: [String]
            let replies: String?
        }
        struct SerialiseCase: Decodable {
            let name: String
            let card: Expected
            let expect: String
        }
        struct UsernameCase: Decodable { let `in`: String; let out: String? }
        struct Cases<T: Decodable>: Decodable { let cases: [T] }
        struct DeepLinkCase: Decodable { let username: String; let messageId: Int64; let out: String }
        struct BacklinkCase: Decodable { let description: String; let node: String; let out: Bool }
        struct TimeCase: Decodable { let date: String; let out: String; let exact: String }
        struct CountCase: Decodable { let `in`: Int; let out: String }
        struct CommentParseCase: Decodable {
            struct Out: Decodable { let target: String; let body: String }
            let `in`: String
            let out: Out?
        }
        struct CommentSerialiseCase: Decodable { let target: String; let body: String; let out: String }
        struct CommentVectors: Decodable {
            let parse: [CommentParseCase]
            let serialise: [CommentSerialiseCase]
        }

        let parse: [ParseCase]
        let serialise: [SerialiseCase]
        let username: Cases<UsernameCase>
        let deepLink: Cases<DeepLinkCase>
        let backlink: Cases<BacklinkCase>
        let timeFormat: Cases<TimeCase>
        let compactCount: Cases<CountCase>
        let comment: CommentVectors
    }

    private func loadVectors() throws -> Vectors {
        let bundle = Bundle(for: CardVectorTests.self)
        guard let url = bundle.url(forResource: "card-vectors", withExtension: "json") else {
            XCTFail("card-vectors.json missing from the test bundle"); throw NSError(domain: "tgsocialTests", code: 1)
        }
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    func testParseVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThan(v.parse.count, 0)
        for c in v.parse {
            let result = CardCodec.parse(c.text)
            if let expected = c.expect {
                guard let card = result.card else { XCTFail("\(c.name): expected a card, got \(result)"); continue }
                XCTAssertEqual(card.name, expected.name, c.name)
                XCTAssertEqual(card.bio, expected.bio, c.name)
                XCTAssertEqual(card.link, expected.link, c.name)
                XCTAssertEqual(card.isPublic, expected.public, c.name)
                XCTAssertEqual(card.feeds, expected.feeds, c.name)
                XCTAssertEqual(card.follows, expected.follows, c.name)
                XCTAssertEqual(card.replies, expected.replies, c.name)
            } else if c.newerVersion == true {
                XCTAssertEqual(result, .newerVersion, c.name)
            } else {
                XCTAssertEqual(result, .notACard, c.name)
            }
        }
    }

    func testSerialiseVectors() throws {
        let v = try loadVectors()
        for c in v.serialise {
            let card = Card(name: c.card.name, bio: c.card.bio, link: c.card.link, isPublic: c.card.public,
                            feeds: c.card.feeds, follows: c.card.follows, replies: c.card.replies)
            XCTAssertEqual(CardCodec.serialise(card), c.expect, c.name)
            // Round trip.
            XCTAssertEqual(CardCodec.parse(c.expect).card?.feeds, c.card.feeds, c.name)
            XCTAssertEqual(CardCodec.parse(c.expect).card?.replies, c.card.replies, c.name)
        }
    }

    func testUsernameVectors() throws {
        let v = try loadVectors()
        for c in v.username.cases {
            XCTAssertEqual(Username.normalise(c.in), c.out, "normalise(\(c.in))")
        }
    }

    func testDeepLinkVectors() throws {
        let v = try loadVectors()
        for c in v.deepLink.cases {
            XCTAssertEqual(DeepLink.post(username: c.username, messageId: c.messageId), c.out)
        }
    }

    /// The default, and the only state for anyone who just cloned this: no `TGS_PUBLIC_ORIGIN`,
    /// so `Copy Link` (PRODUCT §2.6) copies the t.me link. A feed and a node are both public
    /// channels, so that link resolves for a reader with no server of ours in the picture.
    func testPublicLinksFallBackToTelegram() {
        XCTAssertEqual(PublicLink.feed(username: "waveloop_devlog", origin: nil),
                       "https://t.me/waveloop_devlog")
        XCTAssertEqual(PublicLink.node(username: "tgs_ana", origin: nil),
                       "https://t.me/tgs_ana")
    }

    /// PRODUCT §2.13: a self-hoster who configures an origin gets the absolute public URLs back.
    func testPublicLinksWithConfiguredOrigin() {
        let origin = "https://tgsocial.example.com"
        XCTAssertEqual(PublicLink.feed(username: "waveloop_devlog", origin: origin),
                       "https://tgsocial.example.com/f/waveloop_devlog")
        XCTAssertEqual(PublicLink.node(username: "tgs_ana", origin: origin),
                       "https://tgsocial.example.com/n/tgs_ana")
    }

    /// The setting is optional, so the Info.plist value is routinely absent, empty (an xcconfig
    /// key nobody defined substitutes to nothing) or an unexpanded `$(…)`. All three mean unset.
    /// A trailing slash is trimmed so the path concatenation above cannot double the separator.
    func testPublicOriginNormalisation() {
        XCTAssertNil(PublicLink.normalise(nil))
        XCTAssertNil(PublicLink.normalise(""))
        XCTAssertNil(PublicLink.normalise("   "))
        XCTAssertNil(PublicLink.normalise("$(TGS_PUBLIC_ORIGIN)"))
        XCTAssertNil(PublicLink.fromBundle(Bundle(for: CardVectorTests.self)))
        XCTAssertEqual(PublicLink.normalise("  https://tgsocial.example.com  "),
                       "https://tgsocial.example.com")
        XCTAssertEqual(PublicLink.normalise("http://localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(PublicLink.feed(username: "x", origin: PublicLink.normalise("https://e.com//")),
                       "https://e.com/f/x")
    }

    /// Scheme and host or nothing (`setPublicOrigin` in `web/js/protocol.js` draws the same line):
    /// the public routes are root-anchored, so an origin carrying a path mints links the reader
    /// cannot route. The first case is the one this platform actually produces — xcconfig starts a
    /// comment at `//`, so `TGS_PUBLIC_ORIGIN = https://host` reaches Info.plist as `https:` — and
    /// accepting it would put `https:/f/waveloop_devlog` on the clipboard. Rejecting is not fatal:
    /// no origin means the t.me link, which works.
    func testPublicOriginRejectsMalformedValues() {
        for bad in ["https:",                          // xcconfig ate the host after `//`
                    "https://",                        // and the same with the slashes kept
                    "tgsocial.example.com",            // bare host, no scheme
                    "https://tgsocial.example.com/f",  // carries a path
                    "https://tgsocial.example.com/f/", // ditto, trailing slash trimmed first
                    "https://example.com?x=1",
                    "https://exa mple.com",
                    "javascript:alert(1)"] {
            XCTAssertNil(PublicLink.normalise(bad), "normalise(\(bad))")
        }
        XCTAssertEqual(PublicLink.feed(username: "waveloop_devlog", origin: PublicLink.normalise("https:")),
                       "https://t.me/waveloop_devlog")
        XCTAssertEqual(PublicLink.node(username: "tgs_ana", origin: PublicLink.normalise("https:")),
                       "https://t.me/tgs_ana")
    }

    func testBacklinkVectors() throws {
        let v = try loadVectors()
        for c in v.backlink.cases {
            XCTAssertEqual(Backlink.verifies(description: c.description, node: c.node), c.out, c.description)
        }
    }

    /// PRODUCT §2.3: relative on the card (largest unit, floor; 30-day months, 365-day years),
    /// exact (`yyyy-MM-dd HH:mm`) in the long-press sheet.
    func testTimeFormatVectors() throws {
        let v = try loadVectors()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = try XCTUnwrap(f.date(from: "2026-08-23T14:30:00"))
        for c in v.timeFormat.cases {
            let date = try XCTUnwrap(f.date(from: c.date))
            XCTAssertEqual(PostTime.relative(date, now: now), c.out, c.date)
            XCTAssertEqual(PostTime.exact(date), c.exact, c.date)
        }
    }

    func testCompactCountVectors() throws {
        let v = try loadVectors()
        for c in v.compactCount.cases {
            XCTAssertEqual(CompactCount.format(c.in), c.out, "\(c.in)")
        }
    }

    func testCardFullRefusesWrite() {
        var card = Card(name: "x")
        card.follows = (0..<400).map { "tgs_user_\(String(format: "%04d", $0))" }
        XCTAssertTrue(CardCodec.isFull(card))
        XCTAssertFalse(CardCodec.isFull(Card(name: "x", follows: ["tgs_ana"])))
    }

    func testFloodWaitParsing() {
        XCTAssertEqual(FloodWait.seconds(code: 429, message: "Too Many Requests: retry after 17"), 17)
        XCTAssertNil(FloodWait.seconds(code: 400, message: "PHONE_CODE_INVALID"))
    }

    func testIndexGroupLine() {
        XCTAssertEqual(IndexGroup.parse("node: @tgs_ana"), "tgs_ana")
        XCTAssertNil(IndexGroup.parse("hello"))
        XCTAssertEqual(IndexGroup.announcement(node: "tgs_ana"), "node: @tgs_ana")
    }

    func testCommentParseVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThan(v.comment.parse.count, 0)
        for c in v.comment.parse {
            let result = CommentCodec.parse(c.in)
            if let expected = c.out {
                XCTAssertEqual(result?.target, expected.target, c.in)
                XCTAssertEqual(result?.body, expected.body, c.in)
            } else {
                XCTAssertNil(result, c.in)
            }
        }
    }

    func testCommentSerialiseVectors() throws {
        let v = try loadVectors()
        for c in v.comment.serialise {
            XCTAssertEqual(CommentCodec.serialise(target: c.target, body: c.body), c.out)
            // Round trip.
            let parsed = CommentCodec.parse(c.out)
            XCTAssertEqual(parsed?.target, c.target)
            XCTAssertEqual(parsed?.body, c.body)
        }
    }

    func testCommentTargetKeyIsCaseInsensitive() {
        XCTAssertEqual(CommentCodec.targetKey("https://t.me/Waveloop_Devlog/144"),
                       CommentCodec.targetKey("https://t.me/waveloop_devlog/144"))
        XCTAssertNil(CommentCodec.targetKey("https://t.me/waveloop_devlog"))
    }
}

/// PRODUCT §2.3 — attribution: the node a post reaches me through.
final class AttributionTests: XCTestCase {
    func testMyFeedAttributesToMe() {
        XCTAssertEqual(Attribution.node(feed: "waveloop_devlog", me: "tgs_elijah",
                                        myFeeds: ["waveloop_devlog"],
                                        follows: [("tgs_ana", ["waveloop_devlog"])]),
                       "tgs_elijah")
    }

    func testFollowedNodesFeedAttributesToThatNode() {
        XCTAssertEqual(Attribution.node(feed: "ana_notes", me: "tgs_elijah",
                                        myFeeds: ["waveloop_devlog"],
                                        follows: [("tgs_bob", ["bobs_feed"]), ("tgs_ana", ["ana_notes"])]),
                       "tgs_ana")
    }

    func testTwoNodesListingOneFeedEarliestInFollowsWins() {
        XCTAssertEqual(Attribution.node(feed: "shared_feed", me: "tgs_elijah",
                                        myFeeds: [],
                                        follows: [("tgs_ana", ["shared_feed"]), ("tgs_bob", ["shared_feed"])]),
                       "tgs_ana")
        // Order in `follows:` decides, not the alphabet.
        XCTAssertEqual(Attribution.node(feed: "shared_feed", me: "tgs_elijah",
                                        myFeeds: [],
                                        follows: [("tgs_zed", ["shared_feed"]), ("tgs_ana", ["shared_feed"])]),
                       "tgs_zed")
    }

    func testUnlistedFeedHasNoAttribution() {
        XCTAssertNil(Attribution.node(feed: "random_channel", me: "tgs_elijah",
                                      myFeeds: ["waveloop_devlog"],
                                      follows: [("tgs_ana", ["ana_notes"])]))
        XCTAssertNil(Attribution.node(feed: "waveloop_devlog", me: nil, myFeeds: ["waveloop_devlog"], follows: []))
    }

    func testAttributionIsCaseInsensitiveOnUsernames() {
        XCTAssertEqual(Attribution.node(feed: "Ana_Notes", me: "tgs_elijah",
                                        myFeeds: [],
                                        follows: [("tgs_ana", ["ana_notes"])]),
                       "tgs_ana")
    }
}

final class FeedMergeTests: XCTestCase {
    struct Item: FeedEntry, Equatable {
        let sourceKey: String
        let messageId: Int64
        let date: Int
    }

    func testMergeIsChronologicalAcrossSources() {
        var m = FeedMerger<Item>(sourceKeys: ["a", "b"])
        m.add([Item(sourceKey: "a", messageId: 3, date: 300), Item(sourceKey: "a", messageId: 1, date: 100)], to: "a", exhausted: false)
        m.add([Item(sourceKey: "b", messageId: 4, date: 250), Item(sourceKey: "b", messageId: 2, date: 150)], to: "b", exhausted: false)
        let out = m.drain(10)
        XCTAssertEqual(out.map(\.date), [300, 250, 150])
        // "a" still holds 100 but "b" is empty and not exhausted: the merge must stop and ask for "b".
        XCTAssertEqual(m.sourceToRefill, "b")
        m.add([], to: "b", exhausted: true)
        XCTAssertEqual(m.drain(10).map(\.date), [100])
        // "a" has drained its buffer but has not reported the end of its history yet.
        XCTAssertEqual(m.sourceToRefill, "a")
        XCTAssertFalse(m.isExhausted)
        m.add([], to: "a", exhausted: true)
        XCTAssertTrue(m.isExhausted)
    }

    func testRefillPrefersNewestLastKnown() {
        var m = FeedMerger<Item>(sourceKeys: ["a", "b", "c"])
        m.add([Item(sourceKey: "a", messageId: 9, date: 900)], to: "a", exhausted: false)
        m.add([Item(sourceKey: "b", messageId: 8, date: 800)], to: "b", exhausted: false)
        m.add([Item(sourceKey: "c", messageId: 7, date: 700)], to: "c", exhausted: false)
        XCTAssertEqual(m.drain(10).map(\.date), [900])
        XCTAssertEqual(m.sourceToRefill, "a")
        XCTAssertEqual(m.cursor(for: "a"), 9)
    }

    func testUnfetchedSourceIsRefilledFirst() {
        var m = FeedMerger<Item>(sourceKeys: ["a", "b"])
        m.add([Item(sourceKey: "a", messageId: 5, date: 500)], to: "a", exhausted: false)
        XCTAssertFalse(m.canEmit)
        XCTAssertEqual(m.sourceToRefill, "b")
    }

    /// PRODUCT §2.3: every list of posts is strictly newest first, end to end. Three interleaved
    /// sources, pages arriving in arbitrary order, must merge to one descending timeline.
    func testThreeInterleavedSourcesEmitNewestFirst() {
        var m = FeedMerger<Item>(sourceKeys: ["a", "b", "c"])
        m.add([Item(sourceKey: "a", messageId: 1, date: 100),
               Item(sourceKey: "a", messageId: 9, date: 900),
               Item(sourceKey: "a", messageId: 4, date: 400)], to: "a", exhausted: true)
        m.add([Item(sourceKey: "b", messageId: 8, date: 800),
               Item(sourceKey: "b", messageId: 2, date: 200),
               Item(sourceKey: "b", messageId: 5, date: 500)], to: "b", exhausted: true)
        m.add([Item(sourceKey: "c", messageId: 6, date: 600),
               Item(sourceKey: "c", messageId: 3, date: 300),
               Item(sourceKey: "c", messageId: 7, date: 700)], to: "c", exhausted: true)
        let out = m.drain(20)
        XCTAssertEqual(out.map(\.date), [900, 800, 700, 600, 500, 400, 300, 200, 100])
        XCTAssertTrue(FeedOrder.isNewestFirst(out))
        XCTAssertTrue(m.isExhausted)
    }

    /// Date ties break by message id, still descending; live inserts re-sort through the same rule.
    func testNewestFirstBreaksTiesByMessageId() {
        var items = [Item(sourceKey: "a", messageId: 1, date: 500),
                     Item(sourceKey: "a", messageId: 3, date: 500),
                     Item(sourceKey: "a", messageId: 2, date: 500)]
        FeedOrder.sortNewestFirst(&items)
        XCTAssertEqual(items.map(\.messageId), [3, 2, 1])
        XCTAssertTrue(FeedOrder.isNewestFirst(items))
    }
}
