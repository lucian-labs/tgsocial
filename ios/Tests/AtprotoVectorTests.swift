// Unit tests — PROTOCOL.md §12, the atproto extension, against the shared vectors.
//
// Every `atproto` block in `docs/card-vectors.json` runs here the way `web/test/protocol.test.mjs`
// runs it, so the two clients answer the same bytes the same way. Then the things a vector cannot
// say on its own: the merge run through the app's real `Post` and `FeedMerger` types (interleaving
// a Bluesky source with a Telegram one across a page boundary), attribution refused when the DID's
// repo does not name the node — measured through `BlueskyService` with the network stubbed — and
// the additivity claim: someone who never signs in gets no source and no request.

import Foundation
import XCTest
@testable import tgsocial

final class AtprotoVectorTests: XCTestCase {

    /// The `atproto` block, read loosely: its cases are AppView JSON, which is what `Atproto` reads.
    static func loadAtprotoVectors() throws -> JSONValue {
        let bundle = Bundle(for: AtprotoVectorTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "card-vectors", withExtension: "json"), "card-vectors.json missing from the test bundle")
        let all = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: url)))
        let block = all["atproto"]
        XCTAssertFalse(block.isNull, "the atproto block exists")
        return block
    }

    private func cases(_ name: String) throws -> [JSONValue] {
        let block = try Self.loadAtprotoVectors()[name]
        let list = block["cases"].array ?? block.array ?? []
        XCTAssertGreaterThan(list.count, 0, "\(name) has cases")
        return list
    }

    private func label(_ c: JSONValue) -> String { c["name"].string ?? c["in"].string ?? "?" }

    // MARK: §12.2 the key

    func testDidVectors() throws {
        for c in try cases("did") { XCTAssertEqual(Atproto.normaliseDid(c["in"].string), c["out"].string, label(c)) }
    }

    func testParseVectors() throws {
        for c in try cases("parse") {
            XCTAssertEqual(Atproto.did(fromCard: c["text"].string ?? ""), c["out"].string, label(c))
        }
    }

    /// The §2 half of additivity: the §12 case in §2's own `parse` block parses as an ordinary card,
    /// the key ignored, and §2's own serialiser never writes it back.
    func testTheCardKeyIsAnUnknownKeyToSection2() throws {
        let bundle = Bundle(for: AtprotoVectorTests.self)
        let all = try XCTUnwrap(JSONValue.parse(try Data(contentsOf: try XCTUnwrap(bundle.url(forResource: "card-vectors", withExtension: "json")))))
        let c = try XCTUnwrap(all["parse"].array?.first { ($0["name"].string ?? "").contains("§12") })
        let card = try XCTUnwrap(CardCodec.parse(c["text"].string ?? "").card, "a §12 card is a §2 card")
        XCTAssertEqual(card.feeds, ["waveloop_devlog"])
        XCTAssertFalse(CardCodec.serialise(card).contains("atproto"))
        // And the overload with no DID is the §11 overload, character for character.
        XCTAssertEqual(CardCodec.serialise(card, work: nil, privateId: nil, atprotoDid: nil),
                       CardCodec.serialise(card, work: nil, privateId: nil))
    }

    func testSerialiseVectors() throws {
        for c in try cases("serialise") {
            let j = c["card"]
            let card = Card(name: j["name"].string, bio: j["bio"].string, link: j["link"].string, isPublic: j["public"].bool ?? false,
                            feeds: (j["feeds"].array ?? []).compactMap(\.string), follows: (j["follows"].array ?? []).compactMap(\.string),
                            replies: j["replies"].string)
            let work: Work? = j["work"].isNull ? nil : Work(role: j["work"]["role"].string,
                                                            does: (j["work"]["does"].array ?? []).compactMap(\.string),
                                                            feeds: (j["work"]["feeds"].array ?? []).compactMap(\.string))
            let priv: PrivateCard? = j["private"].isNull ? nil : PrivateCard(node: j["private"]["node"].string ?? "",
                                                                            feeds: (j["private"]["feeds"].array ?? []).compactMap(\.string))
            let text = CardCodec.serialise(card, work: work, privateId: j["privateId"].string, private: priv, atprotoDid: j["atprotoDid"].string)
            XCTAssertEqual(text, c["expect"].string, label(c))
        }
    }

    func testRecordKeyVectors() throws {
        for c in try cases("recordKey") { XCTAssertEqual(Atproto.linkRecordKey(c["in"].string), c["out"].string, label(c)) }
    }

    /// §12.3's two-way check. The refusing cases include the one this build is asked to prove:
    /// the card names the DID but the DID's repo does not name the node back.
    func testVerifyVectors() throws {
        let all = try cases("verify")
        XCTAssertTrue(all.contains { $0["out"].bool == false && !$0["record"].isNull }, "a refusing case with a record present")
        for c in all {
            let record: JSONValue? = c["record"].isNull ? nil : c["record"]
            XCTAssertEqual(Atproto.linkVerified(cardText: c["cardText"].string ?? "", node: c["node"].string ?? "",
                                                did: c["did"].string, record: record),
                           c["out"].bool, label(c))
        }
    }

    // MARK: §12.5 dates and admission

    func testSortAtVectors() throws {
        for c in try cases("sortAt") { XCTAssertEqual(Atproto.sortAt(c["post"]), c["out"].int, label(c)) }
    }

    func testFeedTimeVectors() throws {
        for c in try cases("feedTime") { XCTAssertEqual(Atproto.feedTime(c["entry"]), c["out"].int, label(c)) }
    }

    func testTidVectors() throws {
        for c in try cases("tid") {
            // Microseconds exceed a Double's exact range only past year 2255; these are exact.
            XCTAssertEqual(Atproto.tidMicros(c["in"].string), Int64(c["out"].number ?? -1), label(c))
        }
    }

    func testAdmitVectors() throws {
        for c in try cases("admit") { XCTAssertEqual(Atproto.item(c["entry"]) != nil, c["out"].bool, label(c)) }
    }

    func testCrossPostVectors() throws {
        for c in try cases("crossPost") {
            XCTAssertEqual(Atproto.crossPostTarget(c["post"], nodeFeeds: (c["nodeFeeds"].array ?? []).compactMap(\.string)),
                           c["out"].string, label(c))
        }
    }

    func testDropVectors() throws {
        for c in try cases("drop") { XCTAssertEqual(Atproto.dropRef(c["post"]), c["out"].string, label(c)) }
    }

    func testPostKeyVectors() throws {
        for c in try cases("postKey") { XCTAssertEqual(Atproto.safetyKey(c["in"].string), c["out"].string, label(c)) }
    }

    func testClientMetadataVectors() throws {
        for c in try cases("clientMetadata") {
            XCTAssertEqual(Atproto.clientMetadataProblems(c["doc"], fetchedFrom: c["fetchedFrom"].string),
                           (c["out"].array ?? []).compactMap(\.string), label(c))
        }
    }

    // MARK: §12.5 the merge, through the app's own types

    /// A Telegram message as the feed holds it — only what the merge reads is meaningful.
    static func telegramPost(key: String, id: Int64, date: Int) -> Post {
        Post(messageId: id, chatId: 1, sourceKey: key, sourceUsername: key, sourceTitle: key, sourcePhoto: nil, date: date,
             text: .empty, media: [], albumId: 0, albumMessageIds: [], views: 0, reactions: [],
             forwardedFrom: nil, forwardedChatId: nil, forwardedUserId: nil)
    }

    /// One atproto page as `FeedRepository.refill` hands it to the merger: admitted, mapped to the
    /// app's `Post`, with the page's entry count and oldest feed time counted BEFORE admission.
    static func push(_ page: JSONValue, to key: String, tag: Bool, into merger: inout FeedMerger<Post>) {
        let entries = page["feed"].array ?? page["posts"].array ?? []
        let oldest = entries.compactMap(Atproto.feedTime).min()
        let posts = entries.compactMap { tag ? Atproto.tagItem($0) : Atproto.item($0) }.map { BlueskyMapping.post($0, sourceKey: key) }
        merger.addAtprotoPage(posts, to: key, pageEntryCount: entries.count, oldestFeedTime: oldest, cursor: page["cursor"].string)
    }

    /// §4.8's loop, the way the app drives it: drain everything the merge will give, and when it
    /// stops, feed the source it names its next page. `fail` and "no pages left" exhaust it.
    static func run(_ scenario: JSONValue) -> [Post] {
        let sources = scenario["sources"].array ?? []
        var merger = FeedMerger<Post>(sourceKeys: sources.compactMap { $0["key"].string })
        var pages: [String: [JSONValue]] = [:]
        var byKey: [String: JSONValue] = [:]
        for s in sources { pages[s["key"].string!] = s["pages"].array ?? []; byKey[s["key"].string!] = s }
        var out: [Post] = []
        for _ in 0..<100 {
            out += merger.drain(100)
            guard let key = merger.sourceToRefill else { break }
            let src = byKey[key]!
            guard var queue = pages[key], !queue.isEmpty else { merger.markExhausted(key); continue }
            let page = queue.removeFirst()
            pages[key] = queue
            if page.string == "fail" { merger.markExhausted(key); continue }
            if src["kind"].string == "telegram" {
                let msgs = (page.array ?? []).map { telegramPost(key: key, id: Int64($0["id"].int ?? 0), date: $0["date"].int ?? 0) }
                merger.add(msgs, to: key, exhausted: msgs.isEmpty)
            } else {
                push(page, to: key, tag: src["admit"].string == "tag", into: &merger)
            }
        }
        XCTAssertTrue(merger.isExhausted, "the scenario drains every source")
        return out
    }

    func testMergeVectors() throws {
        for c in try cases("merge") {
            let out = Self.run(c)
            let ids = out.map { $0.bluesky?.uri ?? "\($0.sourceKey)/\($0.messageId)" }
            XCTAssertEqual(ids, (c["expect"].array ?? []).compactMap(\.string), label(c))
            XCTAssertTrue(FeedOrder.isNewestFirst(out), "\(label(c)): newest first, ties included")
        }
    }

    /// The build's own statement of the headline case, measured step by step rather than only at
    /// the end: a Telegram source and a Bluesky source interleave newest-first, and the merge
    /// STOPS at the page boundary — it will not emit an older Telegram post while the Bluesky
    /// source might still hold a newer one on a page it has not read.
    func testBlueskyAndTelegramInterleaveAcrossAPageBoundary() throws {
        let scenario = try XCTUnwrap(try cases("merge").first { label($0).hasPrefix("a Telegram feed and a linked Bluesky account") })
        let bskyKey = "at:did:plc:ana2ana2ana2ana2ana2ana2"
        let bskyPages = try XCTUnwrap(scenario["sources"].array?.first { $0["key"].string == bskyKey }?["pages"].array)
        let tg = "waveloop_devlog"
        var merger = FeedMerger<Post>(sourceKeys: [tg, bskyKey])

        merger.add([Self.telegramPost(key: tg, id: 3_145_728, date: 1_790_013_650),
                    Self.telegramPost(key: tg, id: 2_097_152, date: 1_790_013_630)], to: tg, exhausted: false)
        Self.push(bskyPages[0], to: bskyKey, tag: false, into: &merger)
        let first = merger.drain(100)
        XCTAssertEqual(first.map { $0.bluesky != nil ? "b" : "t" }, ["b", "t", "b"],
                       "Bluesky 18:01:00, Telegram 18:00:50, Bluesky 18:00:40 — then it waits")
        XCTAssertEqual(merger.sourceToRefill, bskyKey, "the Bluesky source ran dry first and is asked for its next page")
        XCTAssertEqual(merger.atprotoCursor(for: bskyKey), "c1", "with the cursor its last page returned, untouched")
        XCTAssertEqual(merger.sources[tg]?.buffer.map(\.messageId), [2_097_152], "the older Telegram post is held back")

        Self.push(bskyPages[1], to: bskyKey, tag: false, into: &merger)
        let second = merger.drain(100)
        XCTAssertEqual(second.map { $0.bluesky != nil ? "b" : "t" }, ["t"],
                       "Telegram 18:00:30 goes; Bluesky 18:00:20 waits, because Telegram has now run dry")
        XCTAssertEqual(merger.sourceToRefill, tg, "the boundary holds the other way round too")
        merger.add([Self.telegramPost(key: tg, id: 1_048_576, date: 1_790_013_610)], to: tg, exhausted: false)
        let third = merger.drain(100)
        XCTAssertEqual(third.map { $0.bluesky != nil ? "b" : "t" }, ["b"], "Bluesky 18:00:20 above Telegram 18:00:10")
        XCTAssertTrue(FeedOrder.isNewestFirst(first + second + third))
        // A Bluesky post in the merge is keyed by its at-uri and carries its TID as the tiebreak.
        let b = try XCTUnwrap(first.first)
        XCTAssertEqual(b.id, b.bluesky?.uri)
        XCTAssertEqual(b.messageId, Atproto.tidMicros(b.bluesky?.rkey))
        XCTAssertEqual(b.chatId, 0, "no TDLib update can match a Bluesky post")
    }

    // MARK: §12.3 attribution, end to end through BlueskyService

    private static let anaDid = "did:plc:ana2ana2ana2ana2ana2ana2"
    private static let anaPds = "https://pds.ana.example"

    /// plc.directory → the PDS → getRecord, stubbed. `recordNode` is what Ana's repo names; nil
    /// answers RecordNotFound (400), exactly as a PDS does (measured 2026-09-25).
    private static func linkStub(recordNode: String?) -> StubTransport {
        StubTransport { req, _ in
            let url = req.url!
            if url.host == "plc.directory" {
                return .json(200, ["id": anaDid, "alsoKnownAs": ["at://ana.bsky.social"],
                                   "service": [["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": anaPds]]])
            }
            if url.path == "/xrpc/com.atproto.repo.getRecord" {
                let rkey = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "rkey" }?.value ?? ""
                guard let recordNode else { return .json(400, ["error": "RecordNotFound", "message": "Could not locate record"]) }
                return .json(200, ["uri": "at://\(anaDid)/\(Atproto.linkCollection)/\(rkey)", "cid": "bafyrecord",
                                   "value": ["$type": Atproto.linkCollection, "node": recordNode, "createdAt": "2026-09-25T18:00:00.000Z"]])
            }
            XCTFail("unexpected request \(url)")
            return .json(500, [:])
        }
    }

    private static func anaNode(did: String? = anaDid) -> NodeInfo {
        let text = "tgsocial v1\nname: Ana Iliovic\npublic: yes\nfeeds: @ana_notes" + (did.map { "\natproto.did: \($0)" } ?? "")
        return NodeInfo(username: "tgs_ana", chatId: 7, title: "Ana", card: CardCodec.parse(text).card,
                        atprotoDid: Atproto.did(fromCard: text), state: .ok, photo: nil, fetchedAt: Date())
    }

    @MainActor
    private func service(_ transport: StubTransport) -> BlueskyService {
        let store = LocalStore()
        store.save(Optional<[String: LinkCheck]>.none, LocalStore.atprotoLinks)
        store.save(Optional<BlueskyPrefs>.none, LocalStore.blueskyPrefs)
        return BlueskyService(store: store, activity: ActivityRegistry(), config: .reference, transport: transport, vault: MemoryVault())
    }

    /// Both halves name each other: the account is attributed to the node and becomes a source.
    @MainActor
    func testAttributionWhenTheRepoNamesTheNodeBack() async throws {
        let stub = Self.linkStub(recordNode: "tgs_ana")
        let bsky = service(stub)
        let ana = Self.anaNode()
        await bsky.refreshLinks([ana])
        XCTAssertEqual(bsky.verifiedDid(ana), Self.anaDid)
        let sources = bsky.sources(scope: [ana], isBlocked: { _ in false })
        XCTAssertEqual(sources.map(\.key), ["at:\(Self.anaDid)"])
        XCTAssertEqual(bsky.attributedNode(did: Self.anaDid)?.username, "tgs_ana")
        let get = try XCTUnwrap(stub.requests.last?.url)
        XCTAssertEqual(get.host, "pds.ana.example", "read from the DID's own PDS, never an assumed host")
        XCTAssertNil(stub.requests.last?.value(forHTTPHeaderField: "Authorization"), "the check is signed out — any reader can make it")
    }

    /// The card claims the DID; the DID's repo names a DIFFERENT node. That is a claim about
    /// someone else's account, and it is refused: no attribution, no source, nothing rendered.
    @MainActor
    func testAttributionRefusedWhenTheRepoNamesAnotherNode() async throws {
        let bsky = service(Self.linkStub(recordNode: "tgs_someone_else"))
        let ana = Self.anaNode()
        await bsky.refreshLinks([ana])
        XCTAssertNil(bsky.verifiedDid(ana))
        XCTAssertEqual(bsky.linkCheck(node: "tgs_ana", did: Self.anaDid)?.verified, false, "a definite no, cached")
        XCTAssertEqual(bsky.sources(scope: [ana], isBlocked: { _ in false }), [], "no author source")
        XCTAssertNil(bsky.attributedNode(did: Self.anaDid), "a post by that DID is the account's own, not the node's")
    }

    /// The card claims the DID; the repo holds no record at all (RecordNotFound). Refused the same.
    @MainActor
    func testAttributionRefusedWhenTheRepoHasNoRecord() async throws {
        let bsky = service(Self.linkStub(recordNode: nil))
        let ana = Self.anaNode()
        await bsky.refreshLinks([ana])
        XCTAssertNil(bsky.verifiedDid(ana))
        XCTAssertNil(bsky.attributedNode(did: Self.anaDid))
    }

    /// A network failure is not a "no" — but it is not a "yes" either: with no previous pass the
    /// link stays unverified (§12.3 caching).
    @MainActor
    func testUnreachablePDSNeverVerifies() async throws {
        let bsky = service(StubTransport { _, _ in .json(503, ["error": "Unavailable"]) })
        let ana = Self.anaNode()
        await bsky.refreshLinks([ana])
        XCTAssertNil(bsky.verifiedDid(ana))
        XCTAssertNil(bsky.linkCheck(node: "tgs_ana", did: Self.anaDid), "no answer is not cached as one")
    }

    /// Attribution runs on the author's DID, not the source that delivered the post (§12.5 rule 4):
    /// Ana's post arriving through the tag is still Ana's node's; a stranger's through Ana's scope
    /// is still the stranger's.
    @MainActor
    func testAttributionFollowsTheAuthorNotTheSource() async throws {
        let bsky = service(Self.linkStub(recordNode: "tgs_ana"))
        let ana = Self.anaNode()
        await bsky.refreshLinks([ana])
        _ = bsky.sources(scope: [ana], isBlocked: { _ in false })
        XCTAssertEqual(bsky.attributedNode(did: Self.anaDid)?.username, "tgs_ana")
        XCTAssertNil(bsky.attributedNode(did: "did:plc:bob2bob2bob2bob2bob2bob2"))
    }

    // MARK: Additivity — the app for someone who never signs in

    /// No sign-in, nobody linked, tag at its default: zero atproto sources and zero requests.
    @MainActor
    func testNeverSignedInMeansNoSourceAndNoRequest() async throws {
        let stub = StubTransport { req, _ in XCTFail("no request expected, got \(req.url!)"); return .json(500, [:]) }
        let bsky = service(stub)
        let plain = NodeInfo(username: "tgs_elijah", chatId: 1, title: "Elijah",
                             card: CardCodec.parse("tgsocial v1\nname: Elijah\npublic: yes").card,
                             state: .ok, photo: nil, fetchedAt: Date())
        XCTAssertNil(plain.atprotoDid)
        await bsky.refreshLinks([plain, plain])
        XCTAssertFalse(bsky.isSignedIn)
        XCTAssertFalse(bsky.prefs.tagOn, "the tag starts off (§2.35): it is trollable by construction")
        XCTAssertEqual(bsky.sources(scope: [plain], isBlocked: { _ in false }), [])
        XCTAssertEqual(stub.requests.count, 0)
    }

    /// A merger with no atproto sources is the §4.8 merger exactly: the atproto state never set.
    func testTelegramOnlyMergeIsUnchanged() {
        var merger = FeedMerger<Post>(sourceKeys: ["a", "b"])
        merger.add([Self.telegramPost(key: "a", id: 2, date: 20), Self.telegramPost(key: "a", id: 1, date: 10)], to: "a", exhausted: true)
        merger.add([Self.telegramPost(key: "b", id: 5, date: 15)], to: "b", exhausted: true)
        XCTAssertEqual(merger.drain(10).map(\.date), [20, 15, 10])
        XCTAssertTrue(merger.seenMergeIds.isEmpty)
        XCTAssertNil(merger.atprotoCursor(for: "a"))
    }
}
