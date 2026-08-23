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
        struct TimeCase: Decodable { let date: String; let out: String }
        struct CountCase: Decodable { let `in`: Int; let out: String }

        let parse: [ParseCase]
        let serialise: [SerialiseCase]
        let username: Cases<UsernameCase>
        let deepLink: Cases<DeepLinkCase>
        let backlink: Cases<BacklinkCase>
        let timeFormat: Cases<TimeCase>
        let compactCount: Cases<CountCase>
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
                            feeds: c.card.feeds, follows: c.card.follows)
            XCTAssertEqual(CardCodec.serialise(card), c.expect, c.name)
            // Round trip.
            XCTAssertEqual(CardCodec.parse(c.expect).card?.feeds, c.card.feeds, c.name)
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

    func testBacklinkVectors() throws {
        let v = try loadVectors()
        for c in v.backlink.cases {
            XCTAssertEqual(Backlink.verifies(description: c.description, node: c.node), c.out, c.description)
        }
    }

    func testTimeFormatVectors() throws {
        let v = try loadVectors()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let now = try XCTUnwrap(f.date(from: "2026-08-23T14:30:00"))
        for c in v.timeFormat.cases {
            let date = try XCTUnwrap(f.date(from: c.date))
            XCTAssertEqual(PostTime.format(date, now: now), c.out, c.date)
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
}
