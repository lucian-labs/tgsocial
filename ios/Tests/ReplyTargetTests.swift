// Unit tests — reply-target selection (PRODUCT §2.12, PROTOCOL §6.2).
//
// "Tapping any comment selects it as the reply target … That is the `re:` chain of PROTOCOL §6.2
// made direct — the target is whatever you tapped." The whole of that sentence reduces to one
// checkable thing: **which link ends up on the written comment's first line**. So these tests go
// through `CommentTargeting.message(body:)`, which runs the same `CommentCodec.serialise` on the
// same `active.link` that `CommentRepository.post` does.
//
// Plus the two places the selection has to reach: the carousel, where paging re-targets the thread
// to the album item you are looking at, and the composer, whose placeholder and quote line are
// derived from the target rather than typed twice.

import SwiftUI
import UIKit
import XCTest
@testable import tgsocial

private enum ReplyFixture {
    static let postLink = "https://t.me/waveloop_devlog/144"

    static func post() -> Post { MediaFixture.post() }

    /// An album: four photos, four message ids, one post.
    static func album() -> Post { MediaFixture.album() }

    static func comment(_ id: Int64 = 9, body: String = "Nice one. The bass is huge.") -> Comment {
        MediaFixture.comment(target: postLink, body: body, serverMessageId: id)
    }
}

// MARK: - Which link reaches the `re:` line

final class ReplyTargetTests: XCTestCase {
    private func firstLine(_ message: String) -> String {
        String(message.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    /// With nothing selected, the reply goes to the post: the `re:` line is the post's own t.me link.
    func testWithNothingSelectedTheReLineIsThePosts() {
        let targeting = CommentTargeting.make(post: ReplyFixture.post())
        XCTAssertFalse(targeting.isReply)
        XCTAssertEqual(targeting.active.link, ReplyFixture.postLink)
        XCTAssertEqual(firstLine(targeting.message(body: "Agreed.")),
                       CommentCodec.prefix + ReplyFixture.postLink)
    }

    /// Tapping a comment makes the `re:` line **that comment's own** t.me link — §6.2's chain, one
    /// link deeper, from one tap.
    func testTappingACommentMakesTheReLineThatCommentsOwnLink() {
        let comment = ReplyFixture.comment()
        let targeting = CommentTargeting.make(post: ReplyFixture.post(), reply: comment)
        XCTAssertTrue(targeting.isReply)
        XCTAssertEqual(targeting.active.link, comment.link)
        XCTAssertNotEqual(comment.link, ReplyFixture.postLink)
        XCTAssertEqual(firstLine(targeting.message(body: "Agreed.")),
                       CommentCodec.prefix + comment.link)
    }

    /// And clearing it — tapping the same comment again, or the quote's × — puts the line back on
    /// the post. Same value, one field different.
    func testClearingTheTargetPutsTheReLineBackOnThePost() {
        var targeting = CommentTargeting.make(post: ReplyFixture.post(), reply: ReplyFixture.comment())
        targeting.reply = nil
        XCTAssertFalse(targeting.isReply)
        XCTAssertEqual(firstLine(targeting.message(body: "Agreed.")),
                       CommentCodec.prefix + ReplyFixture.postLink)
    }

    /// The message is byte-compatible with §6.5: `re: `, one space, the full link, newline, body —
    /// and it round-trips through the parser every other client reads it with.
    func testTheMessageRoundTripsThroughTheProtocolParser() throws {
        let comment = ReplyFixture.comment()
        let targeting = CommentTargeting.make(post: ReplyFixture.post(), reply: comment)
        let message = targeting.message(body: "Agreed.\nAll of it.")
        let parsed = try XCTUnwrap(CommentCodec.parse(message))
        XCTAssertEqual(parsed.target, comment.link)
        XCTAssertEqual(parsed.body, "Agreed.\nAll of it.")
    }

    /// A reply to a reply targets the reply — the chain is whatever was tapped, at any depth.
    func testAReplyToAReplyTargetsTheReply() {
        let first = ReplyFixture.comment(9)
        let second = MediaFixture.comment(target: first.link, body: "So is the room.", serverMessageId: 10)
        let targeting = CommentTargeting.make(post: ReplyFixture.post(), reply: second)
        XCTAssertEqual(targeting.active.link, second.link)
        XCTAssertNotEqual(targeting.active.link, first.link)
    }
}

// MARK: - Selection is a toggle, and it reaches the carousel

@MainActor
final class ReplySelectionTests: XCTestCase {
    /// "Tapping it again … clears the target so the reply goes to the post." One gesture, both ways
    /// — which is why selection is a toggle rather than a setter.
    func testTappingTheSameCommentTwiceClearsIt() {
        let a = ReplyFixture.comment(9)
        let b = ReplyFixture.comment(10, body: "Agreed.")
        var selection: Comment?

        // The rule `AppModel.selectReply` implements, stated where it can be run without a model.
        func select(_ c: Comment) { selection = selection?.id == c.id ? nil : c }

        select(a); XCTAssertEqual(selection?.id, a.id)
        select(a); XCTAssertNil(selection)
        select(a); select(b); XCTAssertEqual(selection?.id, b.id, "a second comment replaces the first")
    }

    /// Paging the carousel re-targets the thread to that item's post: each album item is its own
    /// message, so each has its own `re:` link, and the composer follows the page you are on.
    func testPagingTheCarouselRetargetsToThatItemsPost() throws {
        let album = ReplyFixture.album()
        let request = try XCTUnwrap(ViewerRequest.from(album, tappedMediaIndex: 0))
        XCTAssertEqual(request.itemLinks.count, 4)
        XCTAssertEqual(Set(request.itemLinks).count, 4, "four items, four links")

        for page in 0..<4 {
            let link = try XCTUnwrap(request.link(at: page))
            let targeting = CommentTargeting.make(post: album, itemLink: link)
            XCTAssertEqual(targeting.active.link, link)
            XCTAssertEqual(targeting.message(body: "This one.").hasPrefix(CommentCodec.prefix + link), true)
        }
        XCTAssertNotEqual(request.link(at: 0), request.link(at: 3))
    }

    /// A selected comment still wins over the album item — the target is whatever you tapped, and
    /// the page you are on is only the fallback.
    func testASelectedCommentWinsOverTheAlbumItem() throws {
        let album = ReplyFixture.album()
        let request = try XCTUnwrap(ViewerRequest.from(album, tappedMediaIndex: 2))
        let comment = ReplyFixture.comment()
        let targeting = CommentTargeting.make(post: album, itemLink: request.link(at: 2), reply: comment)
        XCTAssertEqual(targeting.active.link, comment.link)
        XCTAssertEqual(targeting.post.link, request.link(at: 2))
    }

    /// A post that is not an album is one message: every item points at it, so paging changes the
    /// picture and not the target.
    func testANonAlbumPostsItemsAllPointAtTheOneMessage() throws {
        let post = MediaFixture.post(media: MediaFixture.photos(1))
        let request = try XCTUnwrap(ViewerRequest.from(post, tappedMediaIndex: 0))
        XCTAssertEqual(request.itemLinks, [post.deepLink])
    }

    /// Media inside a comment has no post, so the carousel carries no `Comments` control at all —
    /// there is no thread for it to open.
    func testMediaInsideACommentCarriesNoPost() throws {
        let request = try XCTUnwrap(ViewerRequest.from(media: MediaFixture.photos(1),
                                                       caption: "", tappedMediaIndex: 0))
        XCTAssertNil(request.post)
        XCTAssertTrue(request.itemLinks.isEmpty)
        XCTAssertNil(request.link(at: 0))
    }
}

// MARK: - What the composer says

final class ReplyComposerCopyTests: XCTestCase {
    /// "The composer's placeholder becomes `Reply to <name>.`" — derived from the target, so the
    /// name in the placeholder cannot disagree with the link in the `re:` line.
    func testThePlaceholderNamesWhoeverWasTapped() {
        let post = CommentTargeting.make(post: ReplyFixture.post())
        XCTAssertEqual(post.placeholder, "Say it.")
        let reply = CommentTargeting.make(post: ReplyFixture.post(), reply: ReplyFixture.comment())
        XCTAssertEqual(reply.placeholder, "Reply to Ana Iliovic.")
    }

    /// The quote line above the composer: `re: <who> — '<what>'`, elided rather than wrapped, and
    /// with newlines flattened so a multi-line comment stays one line.
    func testTheQuoteLineQuotesAndElides() {
        let long = String(repeating: "the bass is huge ", count: 20)
        let target = CommentTarget(link: ReplyFixture.comment().link, quoteTitle: "Ana Iliovic",
                                   quoteText: "line one\nline two")
        XCTAssertEqual(target.quoteLine, "re: Ana Iliovic \u{2014} 'line one line two'")

        let elided = CommentTarget(link: "", quoteTitle: "Ana Iliovic", quoteText: long)
        XCTAssertTrue(elided.quoteLine.hasSuffix("\u{2026}'"), elided.quoteLine)
        XCTAssertLessThan(elided.quoteLine.count, long.count)

        let empty = CommentTarget(link: "", quoteTitle: "WaveLoop devlog", quoteText: "")
        XCTAssertEqual(empty.quoteLine, "re: WaveLoop devlog")
    }
}

// MARK: - The thread tree, shared by both hosts

final class CommentThreadTests: XCTestCase {
    /// The carousel and the Thread screen render the same tree from the same function; the only
    /// difference is which roots they hand it.
    func testTheTreeIndentsRepliesUnderWhatTheyPointAt() {
        let root = MediaFixture.comment(target: ReplyFixture.postLink, body: "Nice one.", serverMessageId: 9)
        let reply = MediaFixture.comment(target: root.link, body: "Agreed.", serverMessageId: 10)
        let rows = CommentTree.rows(comments: [root, reply], roots: [ReplyFixture.postLink])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
        XCTAssertEqual(rows.map(\.comment.id), [root.id, reply.id])
        XCTAssertEqual(CommentTree.replyCount(of: root, in: [root, reply]), 1)
    }

    /// Depth is capped at 5 and deeper replies render flat (§6.2) — the cap is the codec's, so the
    /// two cannot drift.
    func testDepthIsCappedAndDeeperRepliesRenderFlat() {
        var comments: [Comment] = []
        var target = ReplyFixture.postLink
        for i in 0..<8 {
            let c = MediaFixture.comment(target: target, body: "d\(i)", serverMessageId: Int64(20 + i))
            comments.append(c)
            target = c.link
        }
        let rows = CommentTree.rows(comments: comments, roots: [ReplyFixture.postLink])
        XCTAssertEqual(rows.count, comments.count)
        XCTAssertEqual(rows.map(\.depth).max(), CommentCodec.maxDepth - 1)
    }

    /// The carousel's roots are one link, not the whole album — that is what "re-targets the thread
    /// to that item's post" means for what it shows.
    func testTheCarouselsThreadIsTheItemItIsShowing() {
        let onFirst = MediaFixture.comment(target: "https://t.me/waveloop_devlog/144",
                                           body: "first", serverMessageId: 9)
        let onThird = MediaFixture.comment(target: "https://t.me/waveloop_devlog/146",
                                           body: "third", serverMessageId: 10)
        let all = [onFirst, onThird]
        XCTAssertEqual(CommentTree.rows(comments: all, roots: ["https://t.me/waveloop_devlog/146"])
            .map(\.comment.id), [onThird.id, onFirst.id],
            "the item's own comment leads; an orphan still shows flat rather than vanishing")
        XCTAssertEqual(CommentTree.rows(comments: all, roots: ["https://t.me/waveloop_devlog/146"])
            .first?.comment.body, "third")
    }
}

// MARK: - The quote line's controls (COMPONENTS.md rule 6)

@MainActor
final class ReplyTargetRegionTests: XCTestCase {
    private static let cardWidth = HPTokens.Space.columnMax - 2 * HPTokens.Space.columnSide

    /// The × keeps a full `touchMin` in both axes on the assembled thread footer, and it does not
    /// reach into the `Comment` button laid out after it — which, being later, would take every
    /// point they shared.
    func testTheQuotesClearButtonKeepsAFullRegionClearOfTheComposer() throws {
        let regions = measure()
        let clear = try XCTUnwrap(regions[ReplyQuoteBar.clearRegion], "regions: \(regions.keys.sorted())")
        let quote = try XCTUnwrap(regions[ReplyQuoteBar.quoteRegion])
        let comment = try XCTUnwrap(regions[Self.commentRegion])
        print("[regions] quote=\(quote) clear=\(clear) comment=\(comment)")
        XCTAssertGreaterThanOrEqual(clear.width, HPTokens.Space.touchMin, "the × is \(clear.width)pt wide")
        XCTAssertGreaterThanOrEqual(clear.height, HPTokens.Space.touchMin, "the × is \(clear.height)pt tall")
        XCTAssertFalse(clear.intersects(comment.insetBy(dx: 0.5, dy: 0.5)),
                       "the × \(clear) reaches into the Comment button \(comment)")
        XCTAssertTrue(quote.insetBy(dx: -0.5, dy: -0.5).contains(clear),
                      "the × \(clear) hangs outside its own bar \(quote)")
    }

    /// The gold action underneath it is a pill, so its painted shape simply IS its target.
    func testTheComposersActionIsItsOwnTarget() throws {
        let comment = try XCTUnwrap(measure()[Self.commentRegion])
        XCTAssertGreaterThanOrEqual(comment.height, HPTokens.Space.touchMin)
        XCTAssertGreaterThanOrEqual(comment.width, HPTokens.Space.touchMin)
    }

    private static let commentRegion = "comment button"
    private final class RegionBox { var regions: [HPTouchRegion] = [] }

    /// The shipped bar and the shipped action, arranged the way `CommentThreadList` arranges them.
    private func measure() -> [String: CGRect] {
        let box = RegionBox()
        let reported = expectation(description: "hit regions reported")
        reported.assertForOverFulfill = false
        let target = CommentTarget(link: ReplyFixture.comment().link,
                                   quoteTitle: "Ana Iliovic", quoteText: "Nice one. The bass is huge.")
        let probe = HPCard {
            ReplyQuoteBar(target: target, onClear: {})
            HPButton("Comment", style: .primary) {}
                .padding(.top, HPTokens.Space.rowGap)
                .hpTouchRegion(Self.commentRegion)
        }
        .frame(width: Self.cardWidth)
        .environment(\.hpMeasureTouchTargets, true)
        .hpTouchSpace()
        .onPreferenceChange(HPTouchTargetKey.self) { regions in
            guard !regions.isEmpty else { return }
            box.regions = regions
            reported.fulfill()
        }
        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: HPTokens.Space.columnMax, height: 400))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        wait(for: [reported], timeout: 5)
        window.isHidden = true
        window.rootViewController = nil

        var out: [String: CGRect] = [:]
        for region in box.regions { out[region.label] = region.rect }
        return out
    }
}
