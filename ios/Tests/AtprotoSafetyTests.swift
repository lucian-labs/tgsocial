// Unit tests — Bluesky posts through the safety filter and the merge's plumbing (PROTOCOL.md §12.5,
// §12.9; PRODUCT.md §2.35, §2.40).
//
// Every promise here is about what a reader stops seeing, so each test goes through the code that
// decides it — `SafetyLists.allows`, `FeedRepository.stamped`, `BlueskyService.page`,
// `ModerationStore` — with posts built by the app's own mapping from the JSON the AppView serves.
// Removing any one filter line fails at least one test below; a test that only checked a list had
// a DID appended to it would pass with the filter deleted.

import Foundation
import Security
import XCTest
@testable import tgsocial

// MARK: - Fixtures

enum BskyFixture {
    static let ana = "did:plc:ana2ana2ana2ana2ana2ana2"
    static let bob = "did:plc:bob2bob2bob2bob2bob2bob2"
    static let me = "did:plc:z72i7hdynmk6r22z27h6tvur"
    static let pds = URL(string: "https://pds.example")!

    static func json(_ object: Any) -> JSONValue {
        JSONValue.parse(try! JSONSerialization.data(withJSONObject: object))!
    }

    /// A FeedViewPost as getAuthorFeed / getTimeline serve it. `dropRkey` makes it a #waveloop drop
    /// by its own poster (§12.6); `telegram` makes it the §12.8 cross-post of that t.me post.
    static func entry(did: String, handle: String, rkey: String, at: String = "2026-09-25T18:00:00.000Z",
                      dropRkey: String? = nil, telegram: String? = nil) -> [String: Any] {
        var record: [String: Any] = ["$type": "app.bsky.feed.post", "text": "words", "createdAt": at]
        if let dropRkey {
            record["embed"] = ["$type": "app.bsky.embed.external",
                               "external": ["uri": "https://waveloop.app/drop?d=\(did)&r=\(dropRkey)", "title": "A drop", "description": ""]]
        }
        if let telegram {
            record["embed"] = ["$type": "app.bsky.embed.external",
                               "external": ["uri": telegram, "title": "Ana's notes", "description": ""]]
        }
        return ["post": ["uri": "at://\(did)/app.bsky.feed.post/\(rkey)", "cid": "bafy\(rkey)",
                         "author": ["did": did, "handle": handle], "record": record, "indexedAt": at,
                         "likeCount": 0, "replyCount": 0]]
    }

    /// The app's own `Post` for a Bluesky entry, as it arrives from `sourceKey` — unstamped.
    static func post(did: String, handle: String, rkey: String, sourceKey: String) -> Post {
        BlueskyMapping.post(Atproto.item(json(entry(did: did, handle: handle, rkey: rkey)))!, sourceKey: sourceKey)
    }

    static func session(expiresIn: TimeInterval = 3600, now: Date = Date()) -> BlueskySession {
        BlueskySession(did: me, handle: "bsky.app", pds: pds, issuer: "https://bsky.social",
                       tokenEndpoint: URL(string: "https://bsky.social/oauth/token")!,
                       revocationEndpoint: URL(string: "https://bsky.social/oauth/revoke")!,
                       accessToken: "at-old", refreshToken: "rt-old", expiresAt: now.addingTimeInterval(expiresIn),
                       scope: AtprotoClientConfig.scope, startedAt: now)
    }

    static func node(_ username: String, did: String, feeds: String = "@ana_notes") -> NodeInfo {
        let text = "tgsocial v1\nname: Ana Iliovic\npublic: yes\nfeeds: \(feeds)\natproto.did: \(did)"
        return NodeInfo(username: username, chatId: 7, title: "Ana", card: CardCodec.parse(text).card,
                        atprotoDid: Atproto.did(fromCard: text), state: .ok, photo: nil, fetchedAt: Date())
    }

    /// plc.directory and a PDS that name every node back (the §12.3 check passes for any pair),
    /// plus whatever `more` answers first.
    static func network(_ more: @escaping @Sendable (URLRequest) -> StubTransport.Reply? = { _ in nil }) -> StubTransport {
        StubTransport { req, _ in
            if let reply = more(req) { return reply }
            let url = req.url!
            if url.host == "plc.directory" {
                let did = String(url.path.dropFirst())
                return .json(200, ["id": did, "alsoKnownAs": ["at://someone.bsky.social"],
                                   "service": [["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": pds.absoluteString]]])
            }
            if url.path == "/xrpc/com.atproto.repo.getRecord" {
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let repo = q.first { $0.name == "repo" }?.value ?? ""
                let rkey = q.first { $0.name == "rkey" }?.value ?? ""
                return .json(200, ["uri": "at://\(repo)/\(Atproto.linkCollection)/\(rkey)", "cid": "bafyrecord",
                                   "value": ["$type": Atproto.linkCollection, "node": rkey, "createdAt": "2026-09-25T18:00:00.000Z"]])
            }
            return .json(200, [:])
        }
    }

    static func blockRecords(_ dids: [String]) -> StubTransport.Reply {
        .json(200, ["records": dids.enumerated().map { i, d in
            ["uri": "at://\(me)/app.bsky.graph.block/3mwblock0000\(i)", "cid": "bafyblock",
             "value": ["$type": "app.bsky.graph.block", "subject": d, "createdAt": "2026-09-25T18:00:00.000Z"]]
        }])
    }
}

/// Wraps a transport and holds every reply back on a timer that ignores cancellation — a host that
/// accepted the connection and is sitting on it, whatever the app has since decided.
final class HeldTransport: HTTPTransport, @unchecked Sendable {
    let inner: StubTransport
    let hold: TimeInterval
    init(_ inner: StubTransport, hold: TimeInterval) { self.inner = inner; self.hold = hold }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + hold) { c.resume() }
        }
        return try await inner.send(request)
    }
}

/// A Keychain that refuses every write the way a Mac build with no access group did
/// (errSecMissingEntitlement), but still hands back whatever it was built holding.
final class RefusingVault: SessionVault, @unchecked Sendable {
    private let stored: (BlueskySession, DPoPKey)?
    private(set) var clears = 0
    init(_ stored: (BlueskySession, DPoPKey)? = nil) { self.stored = stored }
    func load() -> (BlueskySession, DPoPKey)? { stored }
    func save(_ session: BlueskySession, key: DPoPKey) throws { throw VaultError(status: errSecMissingEntitlement) }
    func clear() { clears += 1 }
}

// MARK: - The filter (PRODUCT §2.18, PROTOCOL §12.9)

final class BlueskySafetyFilterTests: XCTestCase {
    private let ana = BskyFixture.ana
    private let bob = BskyFixture.bob

    /// A DID on the block list drops that account's posts from every surface, whichever source
    /// delivered them and whether or not they are attributed to a node — the tag, the follows,
    /// or a linked node whose card line has since been dropped.
    func testABlockedDidDropsTheirPostsHoweverTheyArrive() {
        let lists = SafetyLists(blocked: [bob])
        let viaTag = BskyFixture.post(did: bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc2a", sourceKey: "tag:waveloop")
        let viaFollows = BskyFixture.post(did: bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc2b", sourceKey: "bsky:following")
        let someoneElse = BskyFixture.post(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2c", sourceKey: "tag:waveloop")
        for post in [viaTag, viaFollows] {
            XCTAssertNil(post.authorUsername, "an account with no node is blocked by DID alone")
            XCTAssertFalse(lists.allows(post: post, inMainFeed: true))
            XCTAssertFalse(lists.allows(post: post, inMainFeed: false), "a block is every surface, not only the feed")
        }
        XCTAssertTrue(lists.allows(post: someoneElse, inMainFeed: true))
        XCTAssertEqual(lists.filtered(posts: [viaTag, someoneElse, viaFollows], inMainFeed: true).map(\.id), [someoneElse.id])
    }

    /// The node's block wrote its DID beside it. After the node drops `atproto.did`, its posts
    /// arrive attributed to nobody — the username no longer matches, and the DID must.
    func testANodeBlockHoldsAfterTheCardLineIsDropped() {
        let lists = SafetyLists(blocked: ["tgs_ana", ana])
        var attributed = BskyFixture.post(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2a", sourceKey: "at:\(ana)")
        attributed.authorUsername = "tgs_ana"
        let orphaned = BskyFixture.post(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2b", sourceKey: "tag:waveloop")
        XCTAssertFalse(lists.allows(post: attributed, inMainFeed: true))
        XCTAssertFalse(lists.allows(post: orphaned, inMainFeed: true))
        XCTAssertTrue(SafetyLists(blocked: ["tgs_ana"]).allows(post: orphaned, inMainFeed: true),
                      "the control: without the DID, the orphaned post is back — which is why the block writes it")
    }

    /// A muted DID takes the account out of the merged feed and nothing else (§12.9 Mute).
    func testAMutedDidLeavesTheMergedFeedOnly() {
        let lists = SafetyLists(mutedFeeds: [bob])
        let bobs = BskyFixture.post(did: bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc2a", sourceKey: "tag:waveloop")
        let anas = BskyFixture.post(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2b", sourceKey: "tag:waveloop")
        XCTAssertEqual(Moderation.muteKey(post: bobs), bob, "a Bluesky post's mute key is its author, never its source")
        XCTAssertFalse(lists.allows(post: bobs, inMainFeed: true))
        XCTAssertTrue(lists.allows(post: bobs, inMainFeed: false))
        XCTAssertTrue(lists.allows(post: anas, inMainFeed: true))
    }

    /// A hidden Bluesky post is keyed by its at-uri and gone everywhere; Settings names it
    /// `Bluesky · …` with its record key, never `@at:` (§2.40).
    func testAHiddenBlueskyPostIsKeyedByItsAtUri() throws {
        let post = BskyFixture.post(did: bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc2a", sourceKey: "tag:waveloop")
        let key = Moderation.key(post: post)
        XCTAssertEqual(key, "at://\(bob)/app.bsky.feed.post/3mw2cdr44fc2a")
        let lists = SafetyLists(hidden: [HiddenItem(key: key, reason: "Spam", at: "2026-09-25T18:00:00Z")])
        XCTAssertFalse(lists.allows(post: post, inMainFeed: false))
        let row = try XCTUnwrap(SettingsScreen.blueskyPost(lists.hidden[0]))
        XCTAssertEqual(row.rkey, "3mw2cdr44fc2a")
        XCTAssertNil(SettingsScreen.blueskyPost(HiddenItem(key: "waveloop_devlog/144", reason: "Spam", at: "")))
    }
}

// MARK: - Unblock lifts both (PROTOCOL §12.9)

@MainActor
final class BlueskyBlockPairTests: XCTestCase {
    private let ana = BskyFixture.ana
    private let store = LocalStore()
    private var savedLists: SafetyLists?
    private var savedPairs: [String: String]?

    override func setUp() {
        savedLists = store.load(SafetyLists.self, LocalStore.moderation)
        savedPairs = store.load([String: String].self, LocalStore.blockedWith)
        store.save(Optional<SafetyLists>.none, LocalStore.moderation)
        store.save(Optional<[String: String]>.none, LocalStore.blockedWith)
    }

    override func tearDown() {
        store.save(savedLists, LocalStore.moderation)
        store.save(savedPairs, LocalStore.blockedWith)
    }

    /// The failure this replaces: unblock asked the link as it stood, and after the card line was
    /// dropped, the cache lapsed or a sign-out wiped it, the DID stayed blocked. Here all of that
    /// has happened — the sign-out wipe included — and the node's unblock still lifts both.
    func testUnblockLiftsTheDidTheBlockWroteAfterTheLinkIsGone() {
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 176_543_210)
        moderation.block("tgs_ana", did: ana)
        XCTAssertEqual(moderation.lists.blocked, ["tgs_ana", ana])

        store.clear()
        let relaunched = ModerationStore(store: store)
        XCTAssertEqual(relaunched.lists.blocked, ["tgs_ana", ana], "the list survives sign-out (§7.1)")
        XCTAssertEqual(relaunched.blockedWith, ["tgs_ana": ana], "and so does which DID the node's block wrote")

        relaunched.unblock("@TGS_Ana")
        XCTAssertEqual(relaunched.lists.blocked, [], "`Unblock` lifts both")
        XCTAssertEqual(relaunched.blockedWith, [:])
    }

    /// The reader blocked the account on its own first; blocking and unblocking the node leaves
    /// that block where they put it.
    func testADidBlockedOnItsOwnStaysWhenTheNodeIsUnblocked() {
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 176_543_210)
        moderation.block(ana)
        moderation.block("tgs_ana", did: ana)
        XCTAssertEqual(moderation.blockedWith, [:], "not the node's to lift")
        moderation.unblock("tgs_ana")
        XCTAssertEqual(moderation.lists.blocked, [ana])
    }

    /// One DID may be linked from several nodes (§12.3): it stays until the last of them goes.
    func testADidTwoBlockedNodesShareStaysUntilBothAreUnblocked() {
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 176_543_210)
        moderation.block("tgs_ana", did: ana)
        moderation.block("tgs_ana_work", did: ana)
        moderation.unblock("tgs_ana")
        XCTAssertEqual(moderation.lists.blocked, [ana, "tgs_ana_work"], "the DID stays: tgs_ana_work wrote it too")
        moderation.unblock("tgs_ana_work")
        XCTAssertEqual(moderation.lists.blocked, [])
    }

    /// Settings' DID row lifts the DID alone and unties it, so a later node unblock has nothing
    /// left to lift and lifts nothing it should not.
    func testUnblockingTheAccountRowUntiesItFromTheNode() {
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 176_543_210)
        moderation.block("tgs_ana", did: ana)
        moderation.unblock(ana)
        XCTAssertEqual(moderation.lists.blocked, ["tgs_ana"])
        XCTAssertEqual(moderation.blockedWith, [:])
        moderation.block(ana)
        moderation.unblock("tgs_ana")
        XCTAssertEqual(moderation.lists.blocked, [ana], "re-blocked on its own, it is no longer the node's")
    }

    /// Another account signing in on this device gets empty lists (§7.1) — and no pairs either.
    func testAnotherAccountInheritsNoPairs() {
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 176_543_210)
        moderation.block("tgs_ana", did: ana)
        moderation.adopt(userId: 42)
        XCTAssertEqual(moderation.lists.blocked, [])
        XCTAssertEqual(moderation.blockedWith, [:])
        XCTAssertNil(store.load([String: String].self, LocalStore.blockedWith))
    }
}

// MARK: - The merge's plumbing (PROTOCOL §12.5)

@MainActor
final class BlueskyMergeTests: XCTestCase {
    private let ana = BskyFixture.ana
    private let bob = BskyFixture.bob
    private let store = LocalStore()

    override func setUp() { reset() }
    override func tearDown() { reset() }

    private func reset() {
        store.save(Optional<[String: LinkCheck]>.none, LocalStore.atprotoLinks)
        store.save(Optional<BlueskyPrefs>.none, LocalStore.blueskyPrefs)
        store.save(Optional<BlueskyBlocks>.none, LocalStore.blueskyBlocks)
        store.save(Optional<BlueskyAccount>.none, "blueskyAccount")
    }

    private func service(_ transport: HTTPTransport, vault: SessionVault = MemoryVault()) -> BlueskyService {
        BlueskyService(store: store, activity: ActivityRegistry(), config: .reference, transport: transport, vault: vault)
    }

    private func signedIn() -> MemoryVault {
        MemoryVault((BskyFixture.session(), DPoPKey.generate(preferSecureEnclave: false)))
    }

    /// §12.5 rule 4 at the place the feed actually stamps posts: attribution follows the AUTHOR's
    /// DID. Ana's post that came in through the tag is Ana's node's; Bob's post that came in
    /// through Ana's author source is Bob's account's, with no node.
    func testStampedAttributesByTheAuthorNotTheSource() async throws {
        let bsky = service(BskyFixture.network())
        let anaNode = BskyFixture.node("tgs_ana", did: ana)
        await bsky.refreshLinks([anaNode])
        _ = bsky.sources(scope: [anaNode], isBlocked: { _ in false })
        let td = TDClient(onUpdate: { _ in })
        let sends = SendTracker()
        let activity = ActivityRegistry()
        let feed = FeedRepository(td: td, store: store, nodes: NodeRepository(td: td, store: store, sends: sends, activity: activity),
                                  sends: sends, activity: activity)
        feed.atproto = bsky

        let anasViaTag = feed.stamped(BskyFixture.post(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2a", sourceKey: "tag:waveloop"))
        XCTAssertEqual(anasViaTag.authorUsername, "tgs_ana")
        XCTAssertEqual(anasViaTag.authorName, "Ana Iliovic")

        let bobsViaAna = feed.stamped(BskyFixture.post(did: bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc2b", sourceKey: "at:\(ana)"))
        XCTAssertNil(bobsViaAna.authorUsername, "never the node whose source delivered it")
        XCTAssertEqual(bobsViaAna.authorName, "@bob.bsky.social")
    }

    /// §12.9: an author the signed-in account blocks on Bluesky is dropped from the tag source
    /// (the AppView applies blocks to the follows source already, not to search).
    func testBlueskyBlocksAreDroppedFromTheTag() async throws {
        let tag = ["posts": [BskyFixture.entry(did: bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc2a", dropRkey: "3mwdrop00000a")["post"]!,
                             BskyFixture.entry(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2b", dropRkey: "3mwdrop00000b")["post"]!]]
        let net = BskyFixture.network { req in
            if req.url!.path == "/xrpc/com.atproto.repo.listRecords" { return BskyFixture.blockRecords([BskyFixture.bob]) }
            if req.url!.path.hasSuffix("app.bsky.feed.searchPosts") { return .json(200, tag) }
            return nil
        }
        let bsky = service(net, vault: signedIn())
        await bsky.refreshBlocks()
        let page = try await bsky.page(AtprotoSourceSpec(key: "tag:waveloop", kind: .tag("waveloop"), label: "#waveloop"), cursor: nil)
        XCTAssertEqual(page.entryCount, 2, "both drops were read")
        XCTAssertEqual(page.posts.compactMap(\.bluesky?.authorDid), [ana], "the blocked author's drop was not admitted")
    }

    /// The failure this replaces: blocks were read at sign-in only and held in memory, so a
    /// relaunch restored the session with an empty list. Here the second launch never reaches the
    /// block list at all, and the blocked author is still dropped on its first page.
    func testBlueskyBlocksSurviveARelaunch() async throws {
        let vault = signedIn()
        let first = service(BskyFixture.network { req in
            req.url!.path == "/xrpc/com.atproto.repo.listRecords" ? BskyFixture.blockRecords([BskyFixture.bob]) : nil
        }, vault: vault)
        await first.refreshBlocks()
        XCTAssertEqual(first.blueskyBlocks, [bob])

        let tag = ["posts": [BskyFixture.entry(did: bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc2a", dropRkey: "3mwdrop00000a")["post"]!]]
        let second = service(BskyFixture.network { req in
            XCTAssertNotEqual(req.url!.path, "/xrpc/com.atproto.repo.listRecords", "the relaunch reads nothing before its first page")
            return req.url!.path.hasSuffix("app.bsky.feed.searchPosts") ? .json(200, tag) : nil
        }, vault: vault)
        XCTAssertEqual(second.blueskyBlocks, [bob], "restored with the session")
        let page = try await second.page(AtprotoSourceSpec(key: "tag:waveloop", kind: .tag("waveloop"), label: "#waveloop"), cursor: nil)
        XCTAssertEqual(page.posts.count, 0)

        let otherAccount = service(BskyFixture.network(), vault: MemoryVault())
        XCTAssertEqual(otherAccount.blueskyBlocks, [], "a list is only ever the account's that read it")
    }

    /// Blocks made on Bluesky after sign-in are picked up by the background check once the list
    /// is `blocksRecheck` old — not before, so a 60 s refresh does not re-read ten pages.
    func testTheBlockListIsReReadOnceItIsStale() async throws {
        final class Counter: @unchecked Sendable { var n = 0 }
        let reads = Counter()
        let bsky = service(BskyFixture.network { req in
            guard req.url!.path == "/xrpc/com.atproto.repo.listRecords" else { return nil }
            reads.n += 1
            return BskyFixture.blockRecords(reads.n == 1 ? [BskyFixture.bob] : [BskyFixture.bob, BskyFixture.ana])
        }, vault: signedIn())
        let t0 = Date()
        await bsky.refreshBlocks(now: t0)
        await bsky.refreshBlocksIfDue(now: t0.addingTimeInterval(60))
        XCTAssertEqual(reads.n, 1)
        await bsky.refreshBlocksIfDue(now: t0.addingTimeInterval(BlueskyService.blocksRecheck + 1))
        XCTAssertEqual(reads.n, 2)
        XCTAssertEqual(bsky.blueskyBlocks, [bob, ana], "the block made since sign-in is in")
    }

    /// §12.5 rule 7: the copy of a Telegram post the reader already has renders once — the
    /// Bluesky copy is left out when its original's channel is on the author's node.
    func testACrossPostOfATelegramPostIsLeftOut() async throws {
        let feed = ["feed": [BskyFixture.entry(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2a", telegram: "https://t.me/ana_notes/12"),
                             BskyFixture.entry(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2b"),
                             BskyFixture.entry(did: ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc2c", telegram: "https://t.me/elsewhere/9")]]
        let bsky = service(BskyFixture.network { req in
            req.url!.path.hasSuffix("app.bsky.feed.getAuthorFeed") ? .json(200, feed) : nil
        })
        let anaNode = BskyFixture.node("tgs_ana", did: ana)
        await bsky.refreshLinks([anaNode])
        let spec = try XCTUnwrap(bsky.sources(scope: [anaNode], isBlocked: { _ in false }).first)
        let page = try await bsky.page(spec, cursor: nil)
        XCTAssertEqual(page.posts.compactMap(\.bluesky?.rkey), ["3mw2cdr44fc2b", "3mw2cdr44fc2c"],
                       "only the copy whose original is in Ana's own feeds goes")
    }

    // MARK: Checks beside the refresh, never in front of it (§12.5 rule 6)

    /// A PDS that sits on the connection held every reader's Telegram feed while the link checks
    /// waited it out. Now the sources come from the cache at once — unverified shows nothing — and
    /// the check that verifies the link asks for exactly one more pass.
    func testLinkChecksNeverHoldTheFeedPass() async throws {
        let bsky = service(HeldTransport(BskyFixture.network(), hold: 0.5))
        var passes = 0
        bsky.onSourcesChanged = { passes += 1 }
        let anaNode = BskyFixture.node("tgs_ana", did: ana)

        let clock = ContinuousClock()
        let started = clock.now
        let first = bsky.sources(scope: [anaNode], isBlocked: { _ in false })
        bsky.startChecks([anaNode])
        XCTAssertLessThan(clock.now - started, .milliseconds(100), "the feed pass did not wait on a Bluesky host")
        XCTAssertEqual(first, [], "not verified yet, so no source and nothing rendered")

        await bsky.settleChecks()
        XCTAssertEqual(passes, 1, "the link verified and asked for one more pass")
        XCTAssertEqual(bsky.sources(scope: [anaNode], isBlocked: { _ in false }).map(\.key), ["at:\(ana)"])

        bsky.startChecks([anaNode])
        await bsky.settleChecks()
        XCTAssertEqual(passes, 1, "nothing changed, so nothing more is asked for")
    }

    /// A follow made while a check is out is checked right after it, not skipped.
    func testAScopeAskedForMeanwhileRunsNext() async throws {
        let bsky = service(HeldTransport(BskyFixture.network(), hold: 0.2))
        let anaNode = BskyFixture.node("tgs_ana", did: ana)
        let bobNode = BskyFixture.node("tgs_bob", did: bob, feeds: "@bob_notes")
        bsky.startChecks([anaNode])
        bsky.startChecks([anaNode, bobNode])
        await bsky.settleChecks()
        XCTAssertEqual(bsky.verifiedDid(bobNode), bob)
        XCTAssertEqual(bsky.verifiedDid(anaNode), ana)
    }

    /// A Telegram sign-out while a check is out: the wipe stands. The check's answer arrives after
    /// it and is not written back into the cache it emptied.
    func testATelegramSignOutDuringACheckWritesNothingBack() async throws {
        let bsky = service(HeldTransport(BskyFixture.network(), hold: 0.2))
        let anaNode = BskyFixture.node("tgs_ana", did: ana)
        bsky.startChecks([anaNode])
        await bsky.endForTelegramSignOut()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(bsky.linkCheck(node: "tgs_ana", did: ana))
        XCTAssertNil(store.load([String: LinkCheck].self, LocalStore.atprotoLinks))
    }

    /// PRODUCT §2.35: the session and its settings are §7 local state. A Telegram sign-out drops
    /// them from memory too, so the next person signed in during this run starts with the tag off.
    func testTelegramSignOutLeavesNoBlueskyToggleBehind() async throws {
        let bsky = service(BskyFixture.network(), vault: signedIn())
        bsky.prefs.tagOn = true
        bsky.prefs.followsOn = false
        XCTAssertEqual(bsky.sources(scope: [], isBlocked: { _ in false }).map(\.key), ["tag:waveloop"])

        await bsky.endForTelegramSignOut()
        XCTAssertFalse(bsky.isSignedIn)
        XCTAssertEqual(bsky.prefs, BlueskyPrefs())
        XCTAssertEqual(bsky.sources(scope: [], isBlocked: { _ in false }), [], "no tag source for whoever signs in next")
        XCTAssertEqual(bsky.blueskyBlocks, [])
    }

    // MARK: A Keychain that refuses (§12.7 "Where the session lives")

    /// A refresh whose new pair the Keychain refused keeps working for this launch and says so in
    /// `Last error`, once — instead of a silent sign-out at the next launch.
    func testARefusedRefreshWriteReachesLastError() async throws {
        let now = Date()
        let vault = RefusingVault((BskyFixture.session(expiresIn: 10, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let bsky = service(BskyFixture.network { req in
            if req.url!.path == "/oauth/token" {
                return .json(200, ["access_token": "at-1", "refresh_token": "rt-1", "expires_in": 300, "token_type": "DPoP",
                                   "scope": AtprotoClientConfig.scope, "sub": BskyFixture.me])
            }
            return req.url!.path.hasSuffix("app.bsky.feed.getTimeline") ? .json(200, ["feed": []]) : nil
        }, vault: vault)
        var errors: [String] = []
        bsky.onError = { errors.append($0) }
        _ = try await bsky.page(AtprotoSourceSpec(key: "bsky:following", kind: .following, label: ""), cursor: nil)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("-34018") ?? false, errors.first ?? "")
        _ = try await bsky.page(AtprotoSourceSpec(key: "bsky:following", kind: .following, label: ""), cursor: "c2")
        XCTAssertEqual(errors.count, 1, "said once")
        XCTAssertTrue(bsky.isSignedIn, "this launch keeps the session it has")
    }
}

// MARK: - The vault refusing at sign-in (§12.7 step 9 → storage)

final class BlueskyVaultRefusalTests: XCTestCase {
    /// The Catalyst failure, reproduced with the status it had: sign-in must fail with the OSStatus
    /// in hand rather than install a session that exists only until the next launch — and the
    /// tokens nothing will hold are revoked.
    func testAKeychainThatRefusesTheSessionFailsTheSignIn() async throws {
        let stub = StubTransport { _, _ in .json(200, [:]) }
        let vault = RefusingVault()
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: stub), vault: vault, transport: stub)
        let sender = DPoPSender(key: DPoPKey.generate(preferSecureEnclave: false), transport: stub)
        do {
            try await auth.install(BskyFixture.session(), sender: sender)
            XCTFail("expected the install to fail")
        } catch AtprotoError.authFailed(let message) {
            XCTAssertTrue(message.contains("OSStatus -34018"), message)
        }
        let session = await auth.session
        XCTAssertNil(session, "nothing installed")
        XCTAssertEqual(vault.clears, 1, "no half-written pair left behind")
        XCTAssertEqual(stub.requests.map { $0.url?.absoluteString }, ["https://bsky.social/oauth/revoke"])
    }
}
