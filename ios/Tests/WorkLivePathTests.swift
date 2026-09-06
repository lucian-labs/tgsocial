// Unit tests — the two §10 rules that live outside the codec, measured on the paths a signed-in
// user actually takes.
//
// `WorkTests.swift` proves `CardCodec.serialise(_:work:)` CAN carry the work lines and that
// `VouchCodec.keeps` CAN reject a self-vouch. Neither says whether the app calls them, and both
// rules are lost by a caller rather than by a codec: §10.6's data loss is a writer handed no work,
// and §10.4's forgery is a reader that indexes a message it should have skipped. So these go
// through `AppModel.writeCard` and `CommentRepository.vouch(from:ref:)` — the app's single card
// write and the app's single message-to-vouch conversion — and fail if either forgets.
//
// Its own file because it imports TDLibKit, which has a `Date` of its own; `WorkTests` uses
// Foundation's, and one file cannot say both (see `ConnectorServiceTests`).

import TDLibKit
import XCTest
@testable import tgsocial

// MARK: - §10.6, on the app's own write path

/// A card writer that records what it was handed and reports success, standing exactly where
/// `NodeRepository` stands. Nothing else can see the argument that §10.6 is about.
@MainActor
private final class RecordingCardWriter: CardWriting {
    private(set) var pinned: [String] = []
    private(set) var handedWork: [Work?] = []

    func writeCard(_ card: Card, work: Work?, node: MyNode) async throws -> MyNode {
        handedWork.append(work)
        // The bytes TDLib would receive, produced by the same serialiser the repository uses.
        pinned.append(CardCodec.serialise(card, work: work))
        return node
    }
}

@MainActor
final class CardWriteBackTests: XCTestCase {
    private let store = LocalStore()
    private var savedNode: MyNode?
    private var savedCard: Card?
    private var savedWork: Work?

    /// `writeCard` persists my node and my card, so the suite borrows the real store and puts back
    /// exactly what it found — a test that leaves a node behind changes what the next `AppModel()`
    /// in this process wakes up holding.
    override func setUp() {
        savedNode = store.load(MyNode.self, LocalStore.myNode)
        savedCard = store.load(Card.self, LocalStore.myCard)
        savedWork = store.load(Work.self, LocalStore.myWork)
    }

    override func tearDown() {
        store.save(savedNode, LocalStore.myNode)
        store.save(savedCard, LocalStore.myCard)
        store.save(savedWork, LocalStore.myWork)
    }

    private static let myWork = Work(role: "Tide clocks, built one at a time",
                                     does: ["electronics", "tide clocks", "bad solder"],
                                     open: WorkOpen(intent: .contract, until: "2099-12-01"),
                                     feeds: ["demo_wren_bench"])

    private func signedIn(writer: RecordingCardWriter) -> AppModel {
        let model = AppModel()
        model.cardWriter = writer
        model.myNode = MyNode(chatId: -100_1, supergroupId: 1, username: "tgs_wren", pinnedMessageId: 8)
        model.myCard = Card(name: "Wren Alderiss", bio: "Tide clocks and bad solder.", isPublic: true,
                            feeds: ["demo_tidewright", "demo_wren_bench"], follows: ["tgs_demo_mox"],
                            replies: "demo_wren_r")
        model.myWork = Self.myWork
        model.myCardState = .ok
        return model
    }

    /// PROTOCOL §10.6 / PRODUCT §2.23's "single most important line in this section", asserted at
    /// the level it can be broken: every card write in the app funnels through `AppModel.writeCard`,
    /// and following somebody rewrites the WHOLE pinned message. Hand the writer no work there and
    /// the user's own work card is deleted by their own follow — so this reads the bytes the writer
    /// received rather than trusting that the serialiser was asked for them.
    func testFollowingSomebodyRewritesTheWholeCardAndKeepsTheWorkLines() async throws {
        let writer = RecordingCardWriter()
        let model = signedIn(writer: writer)
        let card = try XCTUnwrap(model.myCard)

        let wrote = await model.writeCard(card.following("tgs_demo_juno"))
        XCTAssertTrue(wrote)

        let text = try XCTUnwrap(writer.pinned.last)
        XCTAssertEqual(WorkCodec.parse(text), Self.myWork, "the follow deleted the writer's own work card")
        XCTAssertEqual(writer.handedWork.last, Self.myWork)
        // And the follow itself landed: the two halves are one message, written once.
        XCTAssertTrue(CardCodec.parse(text).card?.follows("tgs_demo_juno") ?? false)
    }

    /// The same funnel, reached the four other ways PRODUCT §2.23 names — unfollow, a feed change,
    /// the Public toggle, and Edit Card. Every one of them is an `editMessageText` of the whole
    /// card, so every one of them is a chance to drop the lines.
    func testEveryOtherWriteThatRewritesTheCardCarriesThemToo() async throws {
        let writer = RecordingCardWriter()
        let model = signedIn(writer: writer)
        let card = try XCTUnwrap(model.myCard)

        let unfollowed = await model.writeCard(card.unfollowing("tgs_demo_mox"))
        var next = card; next.feeds = ["demo_tidewright"]
        let feedsChanged = await model.writeCard(next)
        var unlisted = card; unlisted.isPublic = false
        let listingChanged = await model.writeCard(unlisted)
        XCTAssertTrue(unfollowed && feedsChanged && listingChanged)

        XCTAssertEqual(writer.pinned.count, 3)
        for text in writer.pinned {
            XCTAssertNotNil(WorkCodec.parse(text), text)
        }
        // `work.feeds` is intersected with `feeds:` on the way out as well as on the way in, so
        // dropping the marked channel from `feeds:` drops the marking with it (§10.2) — which is a
        // narrowing of the work card, never a loss of the rest of it.
        let afterFeedChange = try XCTUnwrap(WorkCodec.parse(writer.pinned[1]))
        XCTAssertTrue(afterFeedChange.feeds.isEmpty)
        XCTAssertEqual(afterFeedChange.does, Self.myWork.does)
    }

    /// Edit Card saves both halves in ONE write (§10.6): the §2 fields and the §10 lines are the
    /// same pinned message, and two writes would be two chances to fail and a state where the bio
    /// landed and the work card did not.
    func testEditCardWritesBothHalvesOnce() async throws {
        let writer = RecordingCardWriter()
        let model = signedIn(writer: writer)

        let result = await model.saveCard(name: "Wren Alderiss", bio: "Now with fewer bad joints.", link: "",
                                          role: "Tide clocks, built one at a time",
                                          doesText: "electronics, tide clocks",
                                          intent: .contract, horizonDays: 60,
                                          feeds: ["demo_wren_bench"])
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(writer.pinned.count, 1, "one message, one write")
        let text = try XCTUnwrap(writer.pinned.last)
        XCTAssertEqual(CardCodec.parse(text).card?.bio, "Now with fewer bad joints.")
        XCTAssertEqual(WorkCodec.parse(text)?.does, ["electronics", "tide clocks"])
    }
}

// MARK: - §10.4, on the app's own read path

@MainActor
final class VouchReadPathTests: XCTestCase {

    /// A channel post as TDLib hands it over. Only the text matters to the conversion under test;
    /// the rest is the shape TDLib 1.8.66 requires of a `message`.
    private func message(_ text: String, chatId: Int64 = -100_7, messageId: Int64 = 3 << 20) -> Message {
        Message(
            authorSignature: "", autoDeleteIn: 0, canBeSaved: true, chatId: chatId,
            containsUnreadMention: false, containsUnreadPollVotes: false,
            content: .messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil,
                                              text: FormattedText(entities: [], text: text))),
            date: 1_772_000_000, editDate: 0, effectId: 0, ephemeralMessageId: 0, factCheck: nil,
            forwardInfo: nil, guestBotCallerId: nil, hasTimestampedMedia: false, id: messageId,
            importInfo: nil, interactionInfo: nil, isChannelPost: true, isFromOffline: false,
            isOutgoing: false, isPaidGramSuggestedPost: false, isPaidStarSuggestedPost: false,
            isPinned: false, mediaAlbumId: 0, paidMessageStarCount: 0, receiverId: nil,
            replyMarkup: nil, replyTo: nil, restrictionInfo: nil, schedulingState: nil,
            selfDestructIn: 0, selfDestructType: nil, senderBoostCount: 0, senderBusinessBotUserId: 0,
            senderId: .messageSenderChat(MessageSenderChat(chatId: chatId)), senderTag: "",
            sendingState: nil, suggestedPostInfo: nil, summaryLanguageCode: "", topicId: nil,
            unreadReactions: [], viaBotUserId: 0)
    }

    /// Wren's own comments channel: whatever it says about Wren, it is Wren saying it.
    private let wrensChannel = CommentRepository.ChannelRef(
        channelUsername: "demo_wren_r", ownerUsername: "tgs_demo_wren", ownerTitle: "Wren Alderiss",
        ownerPhoto: nil, isPlusOne: false, isMine: false)

    /// PROTOCOL §10.4: "A vouch for the channel's own owner MUST be ignored by readers." The whole
    /// format is unforgeable only because the one channel a person can write is the one that cannot
    /// speak about them — so the ban has to hold where messages become vouches, on the path every
    /// signed-in reader takes, not only in the demo builder and not only in the codec.
    func testAChannelCannotVouchForItsOwnOwner() {
        let selfVouch = message("vouch: https://t.me/tgs_demo_wren\ndoes: tide clocks\nNobody does this better.")
        XCTAssertNil(CommentRepository.vouch(from: selfVouch, ref: wrensChannel),
                     "a self-vouch reached the index every screen reads")

        // Case and an @ do not get round it: the comparison is on the username key.
        let dressedUp = message("vouch: https://t.me/TGS_Demo_Wren\ndoes: tide clocks\n")
        XCTAssertNil(CommentRepository.vouch(from: dressedUp, ref: wrensChannel))
    }

    /// And the same channel's vouch for somebody else is kept, whole — otherwise the test above
    /// would pass on a conversion that rejects everything.
    func testTheSameChannelsVouchForSomebodyElseIsKept() throws {
        let m = message("vouch: https://t.me/tgs_demo_juno\ndoes: glaze chemistry\nFired my clock faces for a year.")
        let vouch = try XCTUnwrap(CommentRepository.vouch(from: m, ref: wrensChannel))
        XCTAssertEqual(vouch.node, "tgs_demo_juno")
        XCTAssertEqual(vouch.does, "glaze chemistry")
        XCTAssertEqual(vouch.body, "Fired my clock faces for a year.")
        XCTAssertEqual(vouch.ownerUsername, "tgs_demo_wren")
        XCTAssertEqual(vouch.channelUsername, "demo_wren_r")
    }

    /// §10.4's other half on the same path: one channel carries both formats and neither conversion
    /// claims the other's message. A `re:` line always carries a message id and a `vouch:` line
    /// never does, which is what let §10 reuse §6.1's channel instead of inventing one.
    func testOnePassOverOneChannelHandsNoMessageToBothParsers() {
        let comment = message("re: https://t.me/demo_tidewright/144\nSix inches is the whole reason I stopped trusting that gauge.")
        let vouch = message("vouch: https://t.me/tgs_demo_juno\ndoes: glaze chemistry\n")
        let feed = FeedInfo(username: "demo_tidewright", chatId: -100_2, title: "Tidewright",
                            description: "", photo: nil, fetchedAt: .init())

        XCTAssertNil(CommentRepository.vouch(from: comment, ref: wrensChannel))
        XCTAssertNotNil(CommentRepository.comment(from: comment, ref: wrensChannel, feed: feed))

        XCTAssertNotNil(CommentRepository.vouch(from: vouch, ref: wrensChannel))
        XCTAssertNil(CommentRepository.comment(from: vouch, ref: wrensChannel, feed: feed))
    }
}
