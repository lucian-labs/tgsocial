// Unit tests — PROTOCOL.md §11, the private extension.
//
// Two halves, the shape `WorkTests` set. The vector loops run the shared `private` block of
// `docs/card-vectors.json`, so iOS, Android and web are held to the same bytes: the parse, the
// public id, the invite grammar, the serialised lines and — the one that matters — §11.3's
// verification, which is a boolean the wrong way round would hand a hostile channel somebody's
// face. The behavioural tests below assert what a vector cannot: that the app's own card write
// carries `private.id` (§11.6), that the safety lists take the `c/<id>` grammar on the paths every
// surface renders through (§7.2), that a private post has no comments, no public link and no
// block target unless its card is verified (§11.5, PRODUCT §2.32), that the Connector's merged
// window never carries one (§11.5), and that the merge attributes a private source the way §11.5
// says. Each fails if the feature is removed rather than passing over its absence.

import Foundation
import XCTest
@testable import tgsocial

// MARK: - The shared vectors

final class PrivateVectorTests: XCTestCase {
    struct Vectors: Decodable {
        struct PrivateJSON: Decodable { let node: String; let feeds: [String] }
        struct ParseCase: Decodable { let name: String; let text: String; let expect: PrivateJSON? }
        struct PublicIdCase: Decodable { let text: String; let out: String? }
        struct InviteCase: Decodable { let `in`: String; let out: String? }
        struct OpenJSON: Decodable { let intent: String; let until: String }
        struct WorkJSON: Decodable { let role: String?; let does: [String]; let open: OpenJSON?; let feeds: [String] }
        struct CardJSON: Decodable {
            let name: String?
            let bio: String?
            let link: String?
            let `public`: Bool
            let feeds: [String]
            let follows: [String]
            let replies: String?
            let work: WorkJSON?
            let privateId: String?
            let `private`: PrivateJSON?
        }
        struct SerialiseCase: Decodable { let name: String; let card: CardJSON; let expect: String }
        struct VerifyCase: Decodable {
            let name: String
            let privateText: String
            let supergroupId: Int64
            let publicText: String
            let publicNode: String
            let out: Bool
        }
        struct Cases<T: Decodable>: Decodable { let cases: [T] }
        struct Private: Decodable {
            let parse: [ParseCase]
            let publicId: Cases<PublicIdCase>
            let invite: Cases<InviteCase>
            let serialise: [SerialiseCase]
            let verify: Cases<VerifyCase>
        }
        let `private`: Private
    }

    private func loadVectors() throws -> Vectors.Private {
        let bundle = Bundle(for: PrivateVectorTests.self)
        guard let url = bundle.url(forResource: "card-vectors", withExtension: "json") else {
            XCTFail("card-vectors.json missing from the test bundle"); throw NSError(domain: "tgsocialTests", code: 1)
        }
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).private
    }

    private func card(_ json: Vectors.CardJSON) -> Card {
        Card(name: json.name, bio: json.bio, link: json.link, isPublic: json.public,
             feeds: json.feeds, follows: json.follows, replies: json.replies)
    }

    private func work(_ json: Vectors.WorkJSON?) throws -> Work? {
        guard let json else { return nil }
        var out = Work(role: json.role, does: json.does, feeds: json.feeds)
        if let open = json.open {
            out.open = WorkOpen(intent: try XCTUnwrap(WorkIntent(rawValue: open.intent)), until: open.until)
        }
        return out
    }

    func testPrivateParseVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.parse.count, 8)
        for c in v.parse {
            let got = PrivateCodec.parse(c.text)
            guard let expected = c.expect else { XCTAssertNil(got, c.name); continue }
            guard let got else { XCTFail("\(c.name): expected a private card"); continue }
            XCTAssertEqual(got.node, expected.node, c.name)
            XCTAssertEqual(got.feeds, expected.feeds, c.name)
        }
    }

    func testPublicIdVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.publicId.cases.count, 6)
        for c in v.publicId.cases {
            XCTAssertEqual(PrivateCodec.publicId(c.text), c.out, c.text)
        }
    }

    func testInviteVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.invite.cases.count, 12)
        for c in v.invite.cases {
            XCTAssertEqual(InviteLink.normalise(c.in), c.out, c.in)
        }
    }

    func testSerialiseVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.serialise.count, 5)
        for c in v.serialise {
            let priv = c.card.private.map { PrivateCard(node: $0.node, feeds: $0.feeds) }
            let text = CardCodec.serialise(card(c.card), work: try work(c.card.work), privateId: c.card.privateId, private: priv)
            XCTAssertEqual(text, c.expect, c.name)
        }
    }

    /// §11.3, the one direction that proves anything. The cases include the two that matter: a
    /// hostile channel naming a real node whose card names a different id, and a real channel
    /// whose owner's card lost the line.
    func testVerifyVectors() throws {
        let v = try loadVectors()
        XCTAssertGreaterThanOrEqual(v.verify.cases.count, 7)
        XCTAssertTrue(v.verify.cases.contains { !$0.out }, "the block must contain a failing claim")
        for c in v.verify.cases {
            let got = PrivateCodec.verified(privateText: c.privateText, supergroupId: c.supergroupId,
                                            publicText: c.publicText, publicNode: c.publicNode)
            XCTAssertEqual(got, c.out, c.name)
        }
    }

    /// The §2 parser is unchanged by §11 (additivity): a private card is a §2 card with empty
    /// `feeds:` and `follows:`, and a public card with `private.id` parses to the card it parsed
    /// before. The two §2 vectors naming §11 run in `CardVectorTests`; this is the same claim on
    /// the parsed shape, since the Swift `Card` has no field to leak the keys into.
    func testSectionTwoIsUntouched() {
        let publicText = "tgsocial v1\nname: Elijah Lucian\npublic: yes\nfeeds: @waveloop_devlog\nprivate.id: 2481234567"
        let parsed = CardCodec.parse(publicText).card
        XCTAssertEqual(parsed, Card(name: "Elijah Lucian", isPublic: true, feeds: ["waveloop_devlog"]))
        XCTAssertEqual(CardCodec.serialise(parsed!), "tgsocial v1\nname: Elijah Lucian\npublic: yes\nfeeds: @waveloop_devlog",
                       "§2's own serialiser writes no §11 line — that is what a §2-only client does (§11.6)")
        let privateText = "tgsocial v1\nname: Elijah\npublic: no\nprivate.node: @tgs_elijah\nprivate.feeds: https://t.me/+AbCdEfGh12345678"
        XCTAssertEqual(CardCodec.parse(privateText).card, Card(name: "Elijah", isPublic: false))
    }

    /// Misplaced keys are dropped and never written (§11.2, §11.5): `private.node` on a public
    /// card yields no private card from a public read, and the serialiser cannot put `private.id`
    /// on a private card because the private write path never hands it one.
    func testMisplacedKeysNeverReachTheWire() {
        let priv = PrivateCard(node: "tgs_elijah", feeds: ["https://t.me/+AbCdEfGh12345678"])
        let text = CardCodec.serialise(Card(name: "E", isPublic: false), work: nil, privateId: "2481234567", private: priv)
        // A caller that hands both gets both lines — the private-card writer in the app hands
        // `privateId: nil`, and this asserts the line is absent exactly when it is not handed.
        XCTAssertTrue(text.contains("private.id: 2481234567"))
        let honest = CardCodec.serialise(Card(name: "E", isPublic: false), work: nil, privateId: nil, private: priv)
        XCTAssertFalse(honest.contains("private.id"))
        XCTAssertEqual(honest, "tgsocial v1\nname: E\npublic: no\nprivate.node: @tgs_elijah\nprivate.feeds: https://t.me/+AbCdEfGh12345678")
    }

    func testCapCountsThePrivateLines() {
        let long = Card(name: "E", bio: String(repeating: "x", count: 4040), isPublic: true)
        XCTAssertFalse(CardCodec.isFull(long, work: nil, privateId: nil))
        XCTAssertTrue(CardCodec.isFull(long, work: nil, privateId: "2481234567"),
                      "the 4096 cap is §2's, and the §11 line counts against it")
    }
}

// MARK: - Links and keys (§11.4.8, §7.2)

private enum PrivateFixture {
    static let supergroupId: Int64 = 2_481_234_567
    static let chatId: Int64 = -1_002_481_234_567
    static let sourceKey = "c/2481234567"

    /// A post from a private channel, verified → attributed to @tgs_ana.
    static func post(attributed: Bool = true, server: Int64 = 144) -> Post {
        var p = MediaFixture.post(messageId: MediaFixture.messageId(server: server))
        p.chatId = chatId
        p.sourceUsername = ""
        p.sourceKey = sourceKey
        p.sourceTitle = "Ana \u{00B7} private"
        p.privateSupergroupId = supergroupId
        if !attributed { p.authorUsername = nil; p.authorName = nil; p.authorPhoto = nil }
        return p
    }

    static func info() -> FeedInfo {
        FeedInfo(username: "", chatId: chatId, title: "Ana \u{00B7} private", description: "", photo: nil,
                 fetchedAt: Date(), privateSupergroupId: supergroupId)
    }
}

final class PrivateLinkTests: XCTestCase {
    func testPrivatePostLinkIsTheCPathWithTheShiftedId() {
        let post = PrivateFixture.post()
        XCTAssertEqual(post.deepLink, "https://t.me/c/2481234567/144")
        XCTAssertTrue(post.isPrivate)
        XCTAssertNil(CommentCodec.targetKey(post.deepLink), "§6.2 does not accept a t.me/c/ link as a comment target")
    }

    func testAlbumItemsOfAPrivatePostLinkTheSameWay() {
        let ids = [MediaFixture.messageId(server: 144), MediaFixture.messageId(server: 145)]
        var post = PrivateFixture.post()
        post.albumMessageIds = ids
        post.media = MediaFixture.photos(2)
        XCTAssertEqual(ViewerRequest.links(of: post), ["https://t.me/c/2481234567/144", "https://t.me/c/2481234567/145"])
    }

    func testSourceKeyGrammar() {
        XCTAssertEqual(PrivateFixture.info().key, "c/2481234567")
        XCTAssertEqual(PrivateLink.hiddenKey(supergroupId: 2_481_234_567, serverMessageId: 144), "c/2481234567/144")
        XCTAssertEqual(PrivateLink.supergroupId(fromSourceKey: "c/2481234567"), 2_481_234_567)
        XCTAssertNil(PrivateLink.supergroupId(fromSourceKey: "waveloop_devlog"))
        XCTAssertNil(PrivateLink.supergroupId(fromSourceKey: "c/2481234567/144"), "a hidden key is not a source key")
        XCTAssertNil(PrivateLink.supergroupId(fromSourceKey: "c/0"))
        XCTAssertNil(Username.normalise("c/2481234567"), "no username can collide with the grammar")
    }
}

// MARK: - Safety on private content (§7.2, PRODUCT §2.32)

final class PrivateSafetyTests: XCTestCase {
    func testHiddenAndMuteKeysUseTheCGrammar() {
        let post = PrivateFixture.post()
        XCTAssertEqual(Moderation.key(post: post), "c/2481234567/144")
        XCTAssertEqual(Moderation.muteKey(post: post), "c/2481234567")
        // And a public post is untouched by the grammar's existence.
        XCTAssertEqual(Moderation.key(post: MediaFixture.post()), "waveloop_devlog/144")
        XCTAssertEqual(Moderation.muteKey(post: MediaFixture.post()), "waveloop_devlog")
    }

    func testAHiddenPrivatePostNeverPaints() {
        let lists = SafetyLists(hidden: [HiddenItem(key: "c/2481234567/144", reason: "Spam", at: "2026-09-07T00:00:00Z")])
        XCTAssertFalse(lists.allows(post: PrivateFixture.post(), inMainFeed: true))
        XCTAssertFalse(lists.allows(post: PrivateFixture.post(), inMainFeed: false))
        XCTAssertTrue(lists.allows(post: PrivateFixture.post(server: 145), inMainFeed: true))
    }

    func testAMutedPrivateChannelLeavesTheMainFeedAndStaysOnItsOwnScreen() {
        let lists = SafetyLists(mutedFeeds: ["c/2481234567"])
        XCTAssertFalse(lists.allows(post: PrivateFixture.post(), inMainFeed: true))
        XCTAssertTrue(lists.allows(post: PrivateFixture.post(), inMainFeed: false), "§2.17: complete on its own screen")
        XCTAssertTrue(lists.allows(post: MediaFixture.post(), inMainFeed: true), "a public feed is not the private one")
    }

    /// §11.5: `blocked` names the verified public node, so blocking a person removes their private
    /// posts with their public ones — and an unverified channel's posts, attributed to nobody, are
    /// not swept up by a block of the node they merely claim.
    func testBlockingTheVerifiedNodeDropsTheirPrivatePosts() {
        let lists = SafetyLists(blocked: ["tgs_ana"])
        XCTAssertFalse(lists.allows(post: PrivateFixture.post(attributed: true), inMainFeed: true))
        XCTAssertTrue(lists.allows(post: PrivateFixture.post(attributed: false), inMainFeed: true))
    }

    func testAnOlderRecordWithTheNewKeysStillLoads() throws {
        let json = #"{"v":1,"userId":7,"blocked":[],"mutedFeeds":["c/2481234567"],"hidden":[{"key":"c/2481234567/144","reason":"Spam","at":"2026-09-07T00:00:00Z"}]}"#
        let lists = try JSONDecoder().decode(SafetyLists.self, from: Data(json.utf8))
        XCTAssertTrue(lists.isMuted(sourceKey: "c/2481234567"))
        XCTAssertTrue(lists.isHidden(key: "c/2481234567/144"))
        // An older client keys a post by its username, and a private post has none: the empty
        // username never matches, which is the correct result for a client that cannot read it.
        XCTAssertFalse(lists.isMuted(feed: ""))
        XCTAssertFalse(lists.isMuted(feed: "waveloop_devlog"))
    }

    func testTheReportEmailNamesThePrivateChannelByIdAndTheCLink() {
        let subject = ReportSubject(post: PrivateFixture.post())
        XCTAssertTrue(subject.isPrivate)
        XCTAssertEqual(subject.link, "https://t.me/c/2481234567/144")
        XCTAssertEqual(subject.hiddenKey, "c/2481234567/144")
        let body = ReportMail.body(subject: subject, reason: "Spam", app: "tgsocial 1.0.0 (1) \u{00B7} iOS")
        XCTAssertTrue(body.contains("Link: https://t.me/c/2481234567/144"))
        XCTAssertTrue(body.contains("Channel: private \u{00B7} 2481234567"))
        XCTAssertTrue(body.contains("Node: @tgs_ana"))
        // The public shape is unchanged.
        let publicBody = ReportMail.body(subject: ReportSubject(post: MediaFixture.post()), reason: "Spam", app: "x")
        XCTAssertTrue(publicBody.contains("Channel: @waveloop_devlog"))
    }

    func testTheReportConfirmSaysTheMaintainerCannotOpenIt() {
        let priv = ReportConfirm.paragraph(for: ReportSubject(post: PrivateFixture.post()))
        XCTAssertTrue(priv.hasSuffix("This is a private post. The maintainer can't open it \u{2014} report it to Telegram from the post as well."))
        XCTAssertEqual(ReportConfirm.paragraph(for: ReportSubject(post: MediaFixture.post())), ReportConfirm.paragraph)
    }
}

// MARK: - What a private post is on screen (PRODUCT §2.32, PROTOCOL §11.5)

final class PrivatePostRuleTests: XCTestCase {
    func testNoCommentsOnAPrivatePost() {
        XCTAssertFalse(PrivatePostRules.commentsAllowed(PrivateFixture.post()))
        XCTAssertTrue(PrivatePostRules.commentsAllowed(MediaFixture.post()))
    }

    func testTheSheetNamesTheFeedWithThePill() {
        XCTAssertEqual(PrivatePostRules.feedLine(PrivateFixture.post()), "Ana \u{00B7} private \u{00B7} Private")
        XCTAssertEqual(PrivatePostRules.feedLine(MediaFixture.post()), "WaveLoop devlog \u{00B7} @waveloop_devlog")
        XCTAssertEqual(PrivatePostRules.pill, "Private")
    }

    /// PRODUCT §2.32: `Block` is present only when the card is verified — there is no node to name
    /// otherwise, and naming the claimed one hands that name to whoever made the channel.
    func testBlockTargetOnlyWhenVerified() {
        XCTAssertEqual(PrivatePostRules.blockTarget(PrivateFixture.post(attributed: true)), "tgs_ana")
        XCTAssertNil(PrivatePostRules.blockTarget(PrivateFixture.post(attributed: false)))
    }

    func testShareIsTheCLinkAndNothingManufactured() {
        XCTAssertEqual(PrivatePostRules.shareLink(PrivateFixture.post()), "https://t.me/c/2481234567/144")
        XCTAssertFalse(PrivatePostRules.shareLink(PrivateFixture.post()).contains("t.me/s/"))
    }
}

// MARK: - The §7.2 record

final class PrivateRecordTests: XCTestCase {
    func testPendingIsKeyedByTheCanonicalLinkOneEntryEach() {
        var r = PrivateRecord()
        r.recordPending(invite: "https://t.me/+AbCdEfGh12345678", title: "Ana \u{00B7} private", photo: nil,
                        at: Date(timeIntervalSince1970: 1_787_500_920))
        r.recordPending(invite: "https://t.me/+AbCdEfGh12345678", title: "Ana \u{00B7} private", photo: nil,
                        at: Date(timeIntervalSince1970: 1_787_500_990))
        XCTAssertEqual(r.pending.count, 1)
        XCTAssertEqual(r.pending.first?.askedAt, Moderation.iso8601(Date(timeIntervalSince1970: 1_787_500_990)))
        r.clearPending(invite: "https://t.me/+AbCdEfGh12345678")
        XCTAssertTrue(r.isEmpty)
    }

    func testTheWireShapeRoundTripsAndToleratesMissingFields() throws {
        let json = #"{"v":1,"privateNode":{"chatId":-1002481234567,"supergroupId":2481234567,"pinnedMessageId":1048576,"invite":"https://t.me/+AbCdEfGh12345678"},"pending":[{"invite":"https://t.me/+QqQqQqQqQqQqQqQq","title":"Ana · private","askedAt":"2026-09-07T18:40:00Z"}]}"#
        let r = try JSONDecoder().decode(PrivateRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.privateNode?.supergroupId, 2_481_234_567)
        XCTAssertEqual(r.privateFeeds, [], "a missing list is an empty one, never a throw")
        XCTAssertEqual(r.pending.first?.title, "Ana \u{00B7} private")
        let again = try JSONDecoder().decode(PrivateRecord.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(again, r)
    }
}

// MARK: - The app's own paths

/// A card writer standing where `NodeRepository` stands, recording what it was handed. §11.6 is a
/// claim about the ARGUMENT on an ordinary follow, and this is the only place it can be seen.
@MainActor
private final class RecordingWriter: CardWriting {
    private(set) var pinned: [String] = []
    private(set) var handedPrivateId: [String?] = []

    func writeCard(_ card: Card, work: Work?, privateId: String?, node: MyNode) async throws -> MyNode {
        handedPrivateId.append(privateId)
        pinned.append(CardCodec.serialise(card, work: work, privateId: privateId))
        return node
    }
}

@MainActor
final class PrivateLivePathTests: XCTestCase {
    private let store = LocalStore()
    private var savedNode: MyNode?
    private var savedCard: Card?
    private var savedWork: Work?
    private var savedRecord: PrivateRecord?
    private var savedConfirmOff: Bool?

    /// `writeCard` persists my node and card, and the private record lives in the same store, so
    /// the suite borrows the real store and puts back exactly what it found.
    override func setUp() {
        savedNode = store.load(MyNode.self, LocalStore.myNode)
        savedCard = store.load(Card.self, LocalStore.myCard)
        savedWork = store.load(Work.self, LocalStore.myWork)
        savedRecord = store.load(PrivateRecord.self, LocalStore.privateRecord)
        savedConfirmOff = store.load(Bool.self, LocalStore.privateConfirmOff)
    }

    override func tearDown() {
        store.save(savedNode, LocalStore.myNode)
        store.save(savedCard, LocalStore.myCard)
        store.save(savedWork, LocalStore.myWork)
        store.save(savedRecord, LocalStore.privateRecord)
        store.save(savedConfirmOff, LocalStore.privateConfirmOff)
    }

    private static let node = PrivateNodeRef(chatId: PrivateFixture.chatId, supergroupId: PrivateFixture.supergroupId,
                                             pinnedMessageId: 1_048_576, invite: "https://t.me/+AbCdEfGh12345678")

    private func signedIn(writer: RecordingWriter, withPrivateNode: Bool = true, confirm: Bool = true, replies: String? = nil) -> AppModel {
        let model = AppModel()
        model.cardWriter = writer
        model.myNode = MyNode(chatId: -100_1, supergroupId: 1, username: "tgs_wren", pinnedMessageId: 8)
        model.myCard = Card(name: "Wren Alderiss", isPublic: true, feeds: ["demo_wren_bench"], follows: ["tgs_demo_mox"], replies: replies)
        model.myWork = Work(role: "Tide clocks")
        model.myCardState = .ok
        model.confirmPrivateOnCard = confirm
        if withPrivateNode { model.privateRecord = PrivateRecord(privateNode: Self.node) }
        return model
    }

    /// PROTOCOL §11.6 on the path a follow takes: the writer is handed `private.id`, and the bytes
    /// it would pin carry the line last, after the §2 and §10 keys.
    func testAFollowCarriesPrivateIdToTheWriter() async throws {
        let writer = RecordingWriter()
        let model = signedIn(writer: writer)
        let card = try XCTUnwrap(model.myCard)
        let wrote = await model.writeCard(card.following("tgs_demo_juno"))
        XCTAssertTrue(wrote)
        XCTAssertEqual(writer.handedPrivateId.last, "2481234567")
        let text = try XCTUnwrap(writer.pinned.last)
        XCTAssertEqual(PrivateCodec.publicId(text), "2481234567")
        XCTAssertTrue(text.hasSuffix("\nprivate.id: 2481234567"), "§11.2: the line comes after every §2 and §10 key")
        XCTAssertNotNil(WorkCodec.parse(text), "and the work card survived the same write")
        XCTAssertTrue(CardCodec.parse(text).card?.follows("tgs_demo_juno") ?? false)
    }

    /// PRODUCT §2.33: `Confirm on public card` off strips the line — the owner's choice, at the
    /// cost the copy names. And with no private node there is nothing to write.
    func testWithholdingOrHavingNoPrivateNodeWritesNoLine() async throws {
        let off = RecordingWriter()
        let withheld = signedIn(writer: off, confirm: false)
        let wroteWithheld = await withheld.writeCard(try XCTUnwrap(withheld.myCard))
        XCTAssertTrue(wroteWithheld)
        XCTAssertEqual(off.handedPrivateId.last, .some(nil))
        XCTAssertNil(PrivateCodec.publicId(try XCTUnwrap(off.pinned.last)))

        let none = RecordingWriter()
        let nodeless = signedIn(writer: none, withPrivateNode: false)
        let wroteNodeless = await nodeless.writeCard(try XCTUnwrap(nodeless.myCard))
        XCTAssertTrue(wroteNodeless)
        XCTAssertNil(PrivateCodec.publicId(try XCTUnwrap(none.pinned.last)))
    }

    /// §11.6's repair: a card read back without the line, while the owner has not withheld it,
    /// is rewritten with it. A card that already carries it is left alone.
    func testAMissingLineIsRepairedOnRead() async throws {
        let writer = RecordingWriter()
        let model = signedIn(writer: writer)
        await model.repairPrivateId(found: nil)
        XCTAssertEqual(writer.pinned.count, 1)
        XCTAssertEqual(PrivateCodec.publicId(try XCTUnwrap(writer.pinned.last)), "2481234567")
        await model.repairPrivateId(found: "2481234567")
        XCTAssertEqual(writer.pinned.count, 1, "nothing to repair, nothing written")
        await model.repairPrivateId(found: "9999999999")
        XCTAssertEqual(writer.pinned.count, 2, "a wrong id — a stale or a hostile line — is repaired too")
    }

    /// §11.5: the private sources carry their attribution — mine to me, a verified card's channel
    /// to the node it names, an unverified one to nobody — and the +1 walk sees none of it.
    func testPrivateSourcesAttributeByVerification() {
        let model = signedIn(writer: RecordingWriter())
        let verified = PrivateFollow(chatId: -100_5, supergroupId: 5, title: "Ana \u{00B7} private", photo: nil,
                                     pinnedMessageId: 1, card: PrivateCard(node: "tgs_ana"), verified: true,
                                     feeds: [PrivateFollowFeed(chatId: -100_6, supergroupId: 6, title: "Band notes", photo: nil,
                                                               invite: "https://t.me/+ZyXwVuTs87654321")])
        let hostile = PrivateFollow(chatId: -100_7, supergroupId: 7, title: "Ana \u{00B7} private", photo: nil,
                                    pinnedMessageId: 1, card: PrivateCard(node: "tgs_ana"), verified: false)
        model.privateFollows = [verified, hostile]
        let sources = model.privateSources
        XCTAssertEqual(sources.count, 4)
        XCTAssertEqual(sources.first { $0.info.chatId == PrivateFixture.chatId }?.owner, "tgs_wren")
        XCTAssertEqual(sources.first { $0.info.chatId == PrivateFixture.chatId }?.isMine, true)
        XCTAssertEqual(sources.first { $0.info.chatId == -100_5 }?.owner, "tgs_ana")
        XCTAssertEqual(sources.first { $0.info.chatId == -100_6 }?.owner, "tgs_ana", "a listed feed follows its card")
        XCTAssertNil(sources.first { $0.info.chatId == -100_7 }?.owner, "unverified: the channel, never the person")
        XCTAssertTrue(sources.allSatisfy { $0.info.isPrivate && $0.info.username.isEmpty })
        // No private +1 (§11.5): nothing here is a node, and the graph's inputs are cards.
        XCTAssertTrue(model.nearby.isEmpty && model.edges.isEmpty)
    }

    /// The merge stamps a private post from those sources the way §11.5 says, through the same
    /// `stamped` every public post goes through.
    func testTheMergeStampsPrivatePostsFromTheirSource() async throws {
        let model = signedIn(writer: RecordingWriter())
        let hostile = PrivateFollow(chatId: -100_7, supergroupId: 7, title: "Ana \u{00B7} private", photo: nil,
                                    pinnedMessageId: 1, card: PrivateCard(node: "tgs_ana"), verified: false)
        model.privateFollows = [hostile]
        try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [], privateSources: model.privateSources)

        var mine = PrivateFixture.post(attributed: false)
        mine.authorUsername = nil
        let stampedMine = model.feed.stamped(mine)
        XCTAssertEqual(stampedMine.authorUsername, "tgs_wren")
        // The name is the cached node card's, with §2.3's `@username` fallback when the cache has
        // no card for it — which is this test's state, since nothing here read a node.
        XCTAssertEqual(stampedMine.authorName, "@tgs_wren")

        var theirs = PrivateFixture.post(attributed: false)
        theirs.chatId = -100_7; theirs.sourceKey = "c/7"; theirs.privateSupergroupId = 7
        let stampedTheirs = model.feed.stamped(theirs)
        XCTAssertNil(stampedTheirs.authorUsername, "unverified: rendered as the channel")

        // Leaving drops the source, its posts, and nothing else (§11.8).
        model.feed.drop(sourceKey: "c/7")
        XCTAssertNil(model.feed.sources["c/7"])
        XCTAssertNotNil(model.feed.sources[PrivateFixture.sourceKey])
    }

    /// PRODUCT §2.28: Compose lists my private channels after my feeds, labelled as private.
    func testComposeTargetsListPrivateChannelsAsSuch() {
        let model = signedIn(writer: RecordingWriter())
        XCTAssertEqual(model.composeTargets, ["demo_wren_bench", "c/2481234567"])
        XCTAssertTrue(model.isPrivateTarget("c/2481234567"))
        XCTAssertFalse(model.isPrivateTarget("demo_wren_bench"))
        XCTAssertEqual(model.composeLabel("c/2481234567"), "Wren Alderiss \u{00B7} private \u{00B7} Private")
    }

    /// PROTOCOL §11.4.5: the count comes from `updateChatPendingJoinRequests`, and only for
    /// channels I own — a count on somebody else's channel is not mine to show.
    func testPendingCountsFollowTheUpdateAndOnlyForOwnedChannels() {
        let model = signedIn(writer: RecordingWriter())
        model.notePendingRequests(chatId: PrivateFixture.chatId, info: ChatJoinRequestsInfoFacts(totalCount: 2, userIds: [1, 2]))
        XCTAssertEqual(model.totalPendingRequests, 2)
        model.notePendingRequests(chatId: -100_99, info: ChatJoinRequestsInfoFacts(totalCount: 5, userIds: []))
        XCTAssertEqual(model.totalPendingRequests, 2)
        model.notePendingRequests(chatId: PrivateFixture.chatId, info: nil)
        XCTAssertEqual(model.totalPendingRequests, 0)
    }

    /// PROTOCOL §11.8: `updateSupergroup` with a lost membership drops the follow and its source.
    func testLosingMembershipDropsTheFollow() async throws {
        let model = signedIn(writer: RecordingWriter())
        let follow = PrivateFollow(chatId: -100_5, supergroupId: 5, title: "Ana \u{00B7} private", photo: nil,
                                   pinnedMessageId: 1, card: PrivateCard(node: "tgs_ana"), verified: true)
        model.privateFollows = [follow]
        try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [], privateSources: model.privateSources)
        XCTAssertNotNil(model.feed.sources["c/5"])
        model.notePrivateMembership(supergroupId: 5, isMember: true)
        XCTAssertEqual(model.privateFollows.count, 1, "still a member: nothing changes")
        model.notePrivateMembership(supergroupId: 5, isMember: false)
        XCTAssertTrue(model.privateFollows.isEmpty)
        XCTAssertNil(model.feed.sources["c/5"])
    }

    func testDeleteParagraphClauseIsDerived() {
        let model = signedIn(writer: RecordingWriter())
        XCTAssertEqual(model.deleteNodePrivateClause, "your private node")
        model.privateRecord.privateFeeds = [PrivateFeedRef(chatId: -100_2, supergroupId: 2, invite: nil, title: "Band notes")]
        XCTAssertEqual(model.deleteNodePrivateClause, "your private node and 1 private feed")
        model.privateRecord.privateFeeds.append(PrivateFeedRef(chatId: -100_3, supergroupId: 3, invite: nil, title: "Demos"))
        XCTAssertEqual(model.deleteNodePrivateClause, "your private node and 2 private feeds")
        let none = signedIn(writer: RecordingWriter(), withPrivateNode: false)
        XCTAssertNil(none.deleteNodePrivateClause)
    }

    /// PRODUCT §2.34: nothing private in the demo — no section, no sources, no targets.
    func testTheDemoHasNoPrivateLayer() {
        let model = signedIn(writer: RecordingWriter())
        model.enterDemo()
        XCTAssertTrue(model.privateSources.isEmpty)
        XCTAssertFalse(model.composeTargets.contains { model.isPrivateTarget($0) })
        model.leaveDemo()
    }

    // MARK: - §11.3 against a listed invite

    /// §11.3: a channel is attributed by ITS card. A verified card that lists another person's
    /// private node — its owner handed the invite over — does not get to re-attribute it, in
    /// either order the sources arrive, and cannot take one of mine. A listed channel with no
    /// card of its own still follows the card that lists it (§11.5).
    func testAListedInviteCannotReattributeAnotherPersonsNode() async throws {
        let model = signedIn(writer: RecordingWriter(), withPrivateNode: false)
        let bobInvite = "https://t.me/+BobBobBobBob1234"
        let bob = PrivateFollow(chatId: -100_8, supergroupId: 8, title: "Bob \u{00B7} private", photo: nil,
                                pinnedMessageId: 1, card: PrivateCard(node: "tgs_bob"), verified: true)
        // Sorts first by title, so the listing is the earlier source — the order that lost before.
        let zed = PrivateFollow(chatId: -100_9, supergroupId: 9, title: "Aardvark Zed \u{00B7} private", photo: nil,
                                pinnedMessageId: 1, card: PrivateCard(node: "tgs_zed", feeds: [bobInvite]), verified: true,
                                feeds: [PrivateFollowFeed(chatId: -100_8, supergroupId: 8, title: "Bob \u{00B7} private", photo: nil, invite: bobInvite)])
        model.privateFollows = [zed, bob]
        let sources = model.privateSources
        XCTAssertEqual(sources.filter { $0.info.key == "c/8" }.count, 1, "one entry per channel")
        XCTAssertEqual(sources.first { $0.info.key == "c/8" }?.owner, "tgs_bob")
        XCTAssertEqual(sources.first { $0.info.key == "c/8" }?.isListed, false)
        XCTAssertEqual(sources.first { $0.info.key == "c/9" }?.owner, "tgs_zed")
        XCTAssertEqual(model.privateOwner(chatId: -100_8)?.card.node, "tgs_bob", "the screen header names Bob too")

        var post = PrivateFixture.post(attributed: false)
        post.chatId = -100_8; post.sourceKey = "c/8"; post.privateSupergroupId = 8
        try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [], privateSources: sources)
        XCTAssertEqual(model.feed.stamped(post).authorUsername, "tgs_bob")
        XCTAssertEqual(PrivatePostRules.blockTarget(model.feed.stamped(post)), "tgs_bob", "and Block names Bob, not Zed")

        // The merge holds the line on its own, whichever order it is handed.
        let info = FeedInfo(username: "", chatId: -100_8, title: "Bob \u{00B7} private", description: "", photo: nil,
                            fetchedAt: Date(), privateSupergroupId: 8)
        let listed = PrivateSource(info: info, owner: "tgs_zed", isMine: false, isListed: true)
        let node = PrivateSource(info: info, owner: "tgs_bob", isMine: false)
        let mine = PrivateSource(info: info, owner: "tgs_wren", isMine: true)
        for order in [[listed, node], [node, listed]] {
            try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [], privateSources: order)
            XCTAssertEqual(model.feed.stamped(post).authorUsername, "tgs_bob")
        }
        try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [], privateSources: [listed, mine])
        XCTAssertEqual(model.feed.stamped(post).authorUsername, "tgs_wren", "nor can a listing take one of mine")

        let feedInfo = FeedInfo(username: "", chatId: -100_6, title: "Band notes", description: "", photo: nil,
                                fetchedAt: Date(), privateSupergroupId: 6)
        try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [],
                                            privateSources: [PrivateSource(info: feedInfo, owner: "tgs_zed", isMine: false, isListed: true)])
        var feedPost = PrivateFixture.post(attributed: false)
        feedPost.chatId = -100_6; feedPost.sourceKey = "c/6"; feedPost.privateSupergroupId = 6
        XCTAssertEqual(model.feed.stamped(feedPost).authorUsername, "tgs_zed", "a feed with no card of its own follows its card")
    }

    // MARK: - §11.4.7's arrival signal, once per burst

    /// TDLib replays `updateNewChat` for every chat on every start. With a request out, that
    /// burst is one pending pass, not one per channel — and no pass at all without a request.
    func testAStormOfChannelArrivalsIsOnePendingPass() async throws {
        let model = signedIn(writer: RecordingWriter(), withPrivateNode: false)
        var record = PrivateRecord()
        record.recordPending(invite: "https://t.me/+AbCdEfGh12345678", title: "Ana \u{00B7} private", photo: nil)
        model.privateRecord = record
        for _ in 0..<40 { model.notePrivateArrival(isChannel: true, hasUsername: false) }
        XCTAssertEqual(model.privateArrivalPasses, 0, "nothing runs inside the burst")
        try await Task.sleep(for: AppModel.privateArrivalDebounce + .milliseconds(700))
        XCTAssertEqual(model.privateArrivalPasses, 1)
        // A later, separate arrival is its own pass.
        model.notePrivateArrival(isChannel: true, hasUsername: false)
        try await Task.sleep(for: AppModel.privateArrivalDebounce + .milliseconds(700))
        XCTAssertEqual(model.privateArrivalPasses, 2)
        // Nothing pending, nothing scheduled.
        model.privateRecord = PrivateRecord()
        model.notePrivateArrival(isChannel: true, hasUsername: false)
        try await Task.sleep(for: AppModel.privateArrivalDebounce + .milliseconds(700))
        XCTAssertEqual(model.privateArrivalPasses, 2)
        XCTAssertFalse(model.td.isStarted, "no pass reached Telegram: the model was never signed in")
    }

    /// A refresh asked for while one is in flight joins it rather than starting a second burst
    /// of `resolveSources` and `getChatHistory`; the in-flight run owes one more pass.
    func testASecondRefreshWhileOneIsInFlightWaitsForIt() async {
        let model = signedIn(writer: RecordingWriter(), withPrivateNode: false)
        model.auth = .ready
        model.feedLoading = true
        await model.refreshFeed()
        XCTAssertTrue(model.feedRefreshWanted, "asked the in-flight run for one more pass")
        XCTAssertTrue(model.feedLoading, "and did not run one itself")
        XCTAssertFalse(model.td.isStarted, "nothing reached Telegram")
        model.feedLoading = false
        model.feedRefreshWanted = false
    }

    // MARK: - Delete My Node (PRODUCT §2.21, §2.33; PROTOCOL §11.4.12)

    private static let feed = PrivateFeedRef(chatId: -100_2, supergroupId: 2, invite: "https://t.me/+ZyXwVuTs87654321", title: "Band notes")

    /// Puts the private node and one feed into the record THROUGH the repository, which is what
    /// `deletePrivateChannels` reads back after each step.
    private func recordPrivate(on model: AppModel) {
        model.privateLayer.update { $0.privateNode = Self.node; $0.privateFeeds = [Self.feed] }
        model.privateRecord = model.privateLayer.record
    }

    private func deleter(replies: Bool, refusing: [Int64: String] = [:]) -> ScriptedDeleter {
        let d = ScriptedDeleter()
        d.owned = [-100_1, -100_3, PrivateFixture.chatId, -100_2]
        if replies { d.publicChats["tgs_wren_r"] = (chatId: -100_3, canDeleteForAll: true) }
        d.refuse = refusing
        return d
    }

    func testTheRunDeletesInProtocolOrder() async {
        let model = signedIn(writer: RecordingWriter(), replies: "tgs_wren_r")
        recordPrivate(on: model)
        let d = deleter(replies: true)
        model.chatDeleter = d
        let result = await model.deleteMyNode()
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(d.deleted, [-100_2, PrivateFixture.chatId, -100_3, -100_1],
                       "§11.4.12: private feeds, private node, comments channel, node")
        XCTAssertNil(model.myNode)
        XCTAssertTrue(model.privateRecord.isEmpty)
    }

    /// The private channels are gone for every member by the time the comments channel is tried,
    /// so its refusal is its own ending: the card stops naming a private node, and the copy
    /// never says nothing was deleted.
    func testACommentsRefusalAfterThePrivateChannelsWentSaysSo() async throws {
        let writer = RecordingWriter()
        let model = signedIn(writer: writer, replies: "tgs_wren_r")
        recordPrivate(on: model)
        let d = deleter(replies: true, refusing: [-100_3: "CHANNEL_INVALID"])
        model.chatDeleter = d
        let result = await model.deleteMyNode()
        XCTAssertEqual(result, .commentsFailedAfterPrivate(username: "tgs_wren", replies: "tgs_wren_r", error: "CHANNEL_INVALID"))
        XCTAssertEqual(d.deleted, [-100_2, PrivateFixture.chatId])
        XCTAssertNil(model.privateRecord.privateNode)
        XCTAssertTrue(model.privateRecord.privateFeeds.isEmpty)
        XCTAssertNotNil(model.myNode, "the node is still there")
        XCTAssertEqual(writer.handedPrivateId.last, .some(nil), "§11.4.12: `private.id` comes off the card")
        let text = try XCTUnwrap(writer.pinned.last)
        XCTAssertNil(PrivateCodec.publicId(text))
        XCTAssertEqual(CardCodec.parse(text).card?.replies, "tgs_wren_r", "the comments channel is still there, so the card still points at it")
        let copy = try XCTUnwrap(DeleteNodeModal.message(for: result))
        XCTAssertEqual(copy, "Your private channels are gone. @tgs_wren_r and @tgs_wren are still there \u{2014} Telegram said: CHANNEL_INVALID.")
        XCTAssertFalse(copy.contains("Nothing was deleted"))
    }

    /// A node refusal names everything that went before it — the private channels, and the
    /// comments channel when there was one — and strips both lines from the card.
    func testANodeRefusalNamesEverythingThatWentBeforeIt() async throws {
        let writer = RecordingWriter()
        let model = signedIn(writer: writer, replies: "tgs_wren_r")
        recordPrivate(on: model)
        let d = deleter(replies: true, refusing: [-100_1: "CHAT_ADMIN_REQUIRED"])
        model.chatDeleter = d
        let result = await model.deleteMyNode()
        XCTAssertEqual(result, .nodeFailedAfterPrivate(username: "tgs_wren", commentsWent: true, error: "CHAT_ADMIN_REQUIRED"))
        XCTAssertEqual(d.deleted, [-100_2, PrivateFixture.chatId, -100_3])
        let text = try XCTUnwrap(writer.pinned.last)
        XCTAssertNil(PrivateCodec.publicId(text))
        XCTAssertNil(CardCodec.parse(text).card?.replies, "PROTOCOL §4.4: `replies:` is stripped with `private.id`")
        XCTAssertEqual(DeleteNodeModal.message(for: result),
                       "Your private channels and your comments channel are gone. @tgs_wren is still there \u{2014} Telegram said: CHAT_ADMIN_REQUIRED.")

        let writer2 = RecordingWriter()
        let model2 = signedIn(writer: writer2)
        recordPrivate(on: model2)
        let d2 = deleter(replies: false, refusing: [-100_1: "CHAT_ADMIN_REQUIRED"])
        model2.chatDeleter = d2
        let result2 = await model2.deleteMyNode()
        XCTAssertEqual(result2, .nodeFailedAfterPrivate(username: "tgs_wren", commentsWent: false, error: "CHAT_ADMIN_REQUIRED"))
        XCTAssertEqual(d2.deleted, [-100_2, PrivateFixture.chatId])
        XCTAssertNil(PrivateCodec.publicId(try XCTUnwrap(writer2.pinned.last)))
        XCTAssertEqual(DeleteNodeModal.message(for: result2),
                       "Your private channels are gone. @tgs_wren is still there \u{2014} Telegram said: CHAT_ADMIN_REQUIRED.")
    }

    /// A private refusal stops before anything public — the one ending after the ownership
    /// checks that may still say `Nothing was deleted.`
    func testAPrivateRefusalStopsBeforeAnythingPublic() async throws {
        let writer = RecordingWriter()
        let model = signedIn(writer: writer, replies: "tgs_wren_r")
        recordPrivate(on: model)
        let d = deleter(replies: true, refusing: [-100_2: "CHANNEL_PRIVATE"])
        model.chatDeleter = d
        let result = await model.deleteMyNode()
        XCTAssertEqual(result, .privateFailed(title: "Band notes", error: "CHANNEL_PRIVATE"))
        XCTAssertTrue(d.deleted.isEmpty)
        XCTAssertTrue(writer.pinned.isEmpty, "no card write: nothing changed")
        XCTAssertEqual(model.privateRecord.privateNode, Self.node)
        XCTAssertTrue(try XCTUnwrap(DeleteNodeModal.message(for: result)).hasSuffix("Nothing was deleted."))
    }

    /// `Nothing was deleted.` is a claim about the whole run, and only the endings that stop
    /// before anything went may make it.
    func testOnlyTheEndingsBeforeAnyLossSayNothingWasDeleted() {
        let all: [DeleteNodeResult] = [
            .notOwner(username: "x"), .commentsFailed(username: "x", error: "e"), .nodeFailed(username: "x", error: "e"),
            .privateFailed(title: "t", error: "e"), .commentsFailedAfterPrivate(username: "x", replies: "r", error: "e"),
            .nodeFailedAfterPrivate(username: "x", commentsWent: true, error: "e"),
            .nodeFailedAfterPrivate(username: "x", commentsWent: false, error: "e"),
        ]
        for result in all {
            let says = DeleteNodeModal.message(for: result)?.contains("Nothing was deleted.") ?? false
            switch result {
            case .commentsFailed, .privateFailed: XCTAssertTrue(says, "\(result)")
            default: XCTAssertFalse(says, "\(result)")
            }
        }
    }

    // MARK: - A private channel deleted outside the app (§11.8, the owner's side)

    /// `updateSupergroup` with a lost status on my own private node: the record drops it and the
    /// feeds whose links lived on its card, the sources leave the merge, `private.id` is marked
    /// for stripping, §11.6's repair no longer puts the dead id back, and Delete My Node no
    /// longer stops on a channel that is not there.
    func testAPrivateNodeDeletedFromTelegramLeavesTheRecord() async throws {
        let writer = RecordingWriter()
        let model = signedIn(writer: writer)
        recordPrivate(on: model)
        try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [], privateSources: model.privateSources)
        XCTAssertNotNil(model.feed.sources[PrivateFixture.sourceKey])
        XCTAssertEqual(model.myPrivateId, "2481234567")
        model.notePrivateMembership(supergroupId: PrivateFixture.supergroupId, isMember: true)
        XCTAssertNotNil(model.privateRecord.privateNode, "still the creator: nothing changes")

        model.notePrivateMembership(supergroupId: PrivateFixture.supergroupId, isMember: false)
        XCTAssertNil(model.privateRecord.privateNode)
        XCTAssertTrue(model.privateRecord.privateFeeds.isEmpty, "the feeds' links lived on the card that just went")
        XCTAssertFalse(model.hasPrivateNode)
        XCTAssertNil(model.myPrivateId, "the next card write strips `private.id`")
        XCTAssertTrue(model.privateIdStale, "and one is owed")
        XCTAssertNil(model.feed.sources[PrivateFixture.sourceKey])
        XCTAssertNil(model.feed.sources["c/2"])
        XCTAssertFalse(model.composeTargets.contains { model.isPrivateTarget($0) })
        XCTAssertNil(model.deleteNodePrivateClause)
        await model.repairPrivateId(found: "2481234567")
        XCTAssertTrue(writer.pinned.isEmpty, "§11.6's repair does not resurrect a dead id")

        let d = deleter(replies: false)
        model.chatDeleter = d
        let result = await model.deleteMyNode()
        XCTAssertEqual(result, .deleted)
        XCTAssertEqual(d.deleted, [-100_1], "nothing private left to stop on")
    }

    /// A private feed deleted outside the app leaves the record and the merge; the node and the
    /// rest stay, and the private card owes a rewrite without the dead link.
    func testAPrivateFeedDeletedFromTelegramLeavesTheRecordAndKeepsTheNode() async throws {
        let model = signedIn(writer: RecordingWriter())
        recordPrivate(on: model)
        try await model.feed.resolveSources(me: "tgs_wren", myFeeds: [], follows: [], privateSources: model.privateSources)
        XCTAssertNotNil(model.feed.sources["c/2"])
        model.notePrivateMembership(supergroupId: 2, isMember: false)
        XCTAssertEqual(model.privateRecord.privateNode, Self.node)
        XCTAssertTrue(model.privateRecord.privateFeeds.isEmpty)
        XCTAssertNil(model.feed.sources["c/2"])
        XCTAssertNotNil(model.feed.sources[PrivateFixture.sourceKey])
        XCTAssertTrue(model.privateCardStale)
        XCTAssertFalse(model.privateIdStale)
        XCTAssertEqual(model.deleteNodePrivateClause, "your private node")
        XCTAssertEqual(model.composeTargets, ["demo_wren_bench", "c/2481234567"])
    }
}

/// Delete My Node's Telegram side, scripted: which chats exist, which are mine to delete, and
/// which refuse. Records the deletes in order — the thing PROTOCOL §11.4.12 is about.
@MainActor
private final class ScriptedDeleter: ChatDeleting {
    var publicChats: [String: (chatId: Int64, canDeleteForAll: Bool)] = [:]
    var owned = Set<Int64>()
    var refuse: [Int64: String] = [:]
    private(set) var deleted: [Int64] = []

    func publicChannel(username: String) async throws -> (chatId: Int64, canDeleteForAll: Bool)? { publicChats[username] }
    func canDeleteForAll(chatId: Int64) async throws -> Bool { owned.contains(chatId) }
    func deleteChat(chatId: Int64) async throws {
        if let message = refuse[chatId] { throw TDFailure(code: 400, message: message) }
        deleted.append(chatId)
    }
}

#if targetEnvironment(macCatalyst)
/// PROTOCOL §11.5: the Connector's merged window never carries a private post, under any preset.
final class PrivateConnectorTests: XCTestCase {
    func testExposableDropsEveryPrivatePost() {
        let window = [MediaFixture.post(), PrivateFixture.post(), MediaFixture.post(messageId: MediaFixture.messageId(server: 145))]
        let out = ScopeResolution.exposable(window)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.allSatisfy { !$0.isPrivate })
    }

    func testNoScopeCanNameAPrivateSource() {
        let scope = ScopeResolver.resolve(preset: .custom, inputs: ScopeInputs(custom: ["c/2481234567", "tgs_ana"]))
        XCTAssertEqual(scope.sources.map(\.username), ["tgs_ana"])
        XCTAssertFalse(scope.contains(""))
        XCTAssertThrowsError(try scope.admit("c/2481234567"))
    }
}
#endif
