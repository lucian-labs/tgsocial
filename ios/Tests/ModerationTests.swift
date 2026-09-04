// Unit tests — the safety lists and the filter they feed (PRODUCT §2.15–§2.21, PROTOCOL §7.1).
//
// The features here are promises about what a reader stops seeing and about what leaves the
// device, so the tests go through the things that decide both: `SafetyLists.filtered`, which every
// surface renders through, `ReportMail`, which is the entire outbound payload, and `MailLauncher`,
// which decides when the reader is told any of it happened. A test that only checked a list had a
// name appended to it would pass with the filter deleted.

import Foundation
import MessageUI
import XCTest
@testable import tgsocial

private enum SafetyFixture {
    static let blockedNode = "tgs_ana"
    static let otherNode = "tgs_bob"

    /// The post from `MediaFixture` is attributed to @tgs_ana in @waveloop_devlog, message 144 —
    /// the very row PROTOCOL §7.1 uses as its example.
    static func post() -> Post { MediaFixture.post() }

    static func post(node: String?, feed: String, server: Int64) -> Post {
        var p = MediaFixture.post(messageId: MediaFixture.messageId(server: server))
        p.sourceUsername = feed
        p.sourceKey = Username.key(feed)
        p.authorUsername = node
        p.authorName = node.map { "@" + $0 }
        return p
    }

    static func comment(owner: String, target: String, server: Int64) -> Comment {
        Comment(channelUsername: owner + "_r", chatId: -100_4,
                messageId: MediaFixture.messageId(server: server),
                date: 1_787_500_930, target: target, body: "words", media: [],
                ownerUsername: owner, ownerTitle: owner, ownerPhoto: nil,
                isPlusOne: false, isMine: false, isPending: false)
    }

    static let postLink = "https://t.me/waveloop_devlog/144"
}

// MARK: - Keys (PROTOCOL §7.1)

final class SafetyKeyTests: XCTestCase {
    /// The hidden key is the §6.2 target key — `<channel>/<messageId>`, lowercased — so one lookup
    /// filters a hidden post and a hidden comment alike.
    func testHiddenKeyOfAPostIsChannelSlashServerMessageId() {
        XCTAssertEqual(Moderation.key(post: SafetyFixture.post()), "waveloop_devlog/144")
    }

    func testHiddenKeyOfACommentIsItsOwnChannelAndMessage() {
        let comment = SafetyFixture.comment(owner: "tgs_ana", target: SafetyFixture.postLink, server: 9)
        XCTAssertEqual(Moderation.key(comment: comment), "tgs_ana_r/9")
    }

    /// And a `re:` line resolves to the same string: the two arrive at one key from opposite ends.
    func testAPostKeyAndItsLinkKeyAgree() {
        let post = SafetyFixture.post()
        XCTAssertEqual(Moderation.key(link: post.deepLink), Moderation.key(post: post))
        XCTAssertEqual(Moderation.key(link: "https://t.me/WaveLoop_Devlog/144"), "waveloop_devlog/144")
        XCTAssertNil(Moderation.key(link: "https://example.com/144"))
    }

    /// Usernames are case-insensitive on Telegram, so a list that missed `@TGS_Ana` would be a
    /// filter with a hole in it.
    func testListEntriesAreNormalisedAndMatchAnyCasing() {
        var lists = SafetyLists()
        lists.blocked = [Moderation.listKey("@TGS_Ana")]
        XCTAssertEqual(lists.blocked, ["tgs_ana"])
        XCTAssertTrue(lists.isBlocked("TGS_ANA"))
        XCTAssertTrue(lists.isBlocked("@tgs_ana"))
        XCTAssertFalse(lists.isBlocked("tgs_anaa"))
    }
}

// MARK: - The filter (PRODUCT §2.18)

final class SafetyFilterTests: XCTestCase {
    private func lists(blocked: [String] = [], muted: [String] = [], hidden: [String] = []) -> SafetyLists {
        SafetyLists(userId: 1,
                    blocked: blocked.map(Moderation.listKey),
                    mutedFeeds: muted.map(Moderation.listKey),
                    hidden: hidden.map { HiddenItem(key: $0, reason: "Spam", at: "2026-09-04T21:02:11Z") })
    }

    /// "A reviewer can confirm the filter without opening Settings: block a node, and their posts
    /// are gone from the feed on the next render."
    func testBlockingANodeRemovesTheirPostsFromEverySurface() {
        let mine = SafetyFixture.post(node: SafetyFixture.otherNode, feed: "lucianlabs", server: 12)
        let theirs = SafetyFixture.post()
        let filter = lists(blocked: ["tgs_ana"])
        XCTAssertEqual(filter.filtered(posts: [theirs, mine], inMainFeed: true).map(\.id), [mine.id])
        XCTAssertEqual(filter.filtered(posts: [theirs, mine], inMainFeed: false).map(\.id), [mine.id])
    }

    /// An unattributed post is not a blocked node's post: the rule is the attributed node (§2.3),
    /// and a channel with no node behind it belongs to nobody on the list.
    func testAnUnattributedPostSurvivesABlockOnTheChannelsName() {
        let post = SafetyFixture.post(node: nil, feed: "waveloop_devlog", server: 144)
        XCTAssertEqual(lists(blocked: ["waveloop_devlog"]).filtered(posts: [post], inMainFeed: true).count, 1)
    }

    /// Mute is the main feed only: the channel stays reachable and complete on its own screen.
    func testMuteDropsAPostFromTheMainFeedAndNowhereElse() {
        let post = SafetyFixture.post()
        let filter = lists(muted: ["waveloop_devlog"])
        XCTAssertTrue(filter.filtered(posts: [post], inMainFeed: true).isEmpty)
        XCTAssertEqual(filter.filtered(posts: [post], inMainFeed: false).map(\.id), [post.id])
    }

    /// Reporting hides on both, immediately, by key.
    func testAReportedPostIsHiddenOnEverySurface() {
        let post = SafetyFixture.post()
        let filter = lists(hidden: ["waveloop_devlog/144"])
        XCTAssertTrue(filter.filtered(posts: [post], inMainFeed: true).isEmpty)
        XCTAssertTrue(filter.filtered(posts: [post], inMainFeed: false).isEmpty)
    }

    /// A blocked node's comment goes, and so does the reply hanging off it — otherwise
    /// `CommentTree.rows` promotes the orphan and the thread renders it one indent to the left.
    func testBlockingDropsACommentAndTheRepliesUnderIt() {
        let theirs = SafetyFixture.comment(owner: "tgs_ana", target: SafetyFixture.postLink, server: 9)
        let replyToThem = SafetyFixture.comment(owner: "tgs_bob", target: theirs.link, server: 10)
        let deeper = SafetyFixture.comment(owner: "tgs_bob", target: replyToThem.link, server: 11)
        let onThePost = SafetyFixture.comment(owner: "tgs_bob", target: SafetyFixture.postLink, server: 12)

        let kept = lists(blocked: ["tgs_ana"]).filtered(comments: [theirs, replyToThem, deeper, onThePost])
        XCTAssertEqual(kept.map(\.id), [onThePost.id])

        // And the tree the thread actually renders has nothing left of them either.
        let rows = CommentTree.rows(comments: kept, roots: [SafetyFixture.postLink])
        XCTAssertEqual(rows.map(\.comment.id), [onThePost.id])
    }

    /// A reported comment is hidden by the same key a reported post is.
    func testReportingACommentHidesIt() {
        let reported = SafetyFixture.comment(owner: "tgs_bob", target: SafetyFixture.postLink, server: 9)
        let other = SafetyFixture.comment(owner: "tgs_bob", target: SafetyFixture.postLink, server: 10)
        let kept = lists(hidden: [Moderation.key(comment: reported)]).filtered(comments: [reported, other])
        XCTAssertEqual(kept.map(\.id), [other.id])
    }

    /// Nothing filtered leaves residue in a count: the graph lists, the +1 walk and the edges all
    /// drop the blocked node rather than keeping a placeholder.
    func testBlockedNodesLeaveNoResidueInTheGraph() {
        let blocked = NodeInfo(username: "tgs_ana", chatId: 1, title: "Ana", card: Card(), state: .ok,
                               photo: nil, fetchedAt: .distantPast)
        let other = NodeInfo(username: "tgs_bob", chatId: 2, title: "Bob", card: Card(), state: .ok,
                             photo: nil, fetchedAt: .distantPast)
        let filter = lists(blocked: ["tgs_ana"])
        XCTAssertEqual(filter.filtered(nodes: [blocked, other]).map(\.username), ["tgs_bob"])
        XCTAssertEqual(filter.filtered(entries: [DirectoryEntry(node: blocked, followedByCount: 3),
                                                 DirectoryEntry(node: other, followedByCount: 1)]).map(\.node.username),
                       ["tgs_bob"])
        let edges = filter.filtered(edges: ["tgs_ana": ["tgs_bob"], "tgs_bob": ["tgs_ana", "tgs_cat"]])
        XCTAssertNil(edges["tgs_ana"])
        XCTAssertEqual(edges["tgs_bob"], ["tgs_cat"])
    }

    /// Empty lists are the fresh-install state and must not filter anything.
    func testAFreshInstallFiltersNothing() {
        let post = SafetyFixture.post()
        let comment = SafetyFixture.comment(owner: "tgs_ana", target: SafetyFixture.postLink, server: 9)
        XCTAssertEqual(SafetyLists().filtered(posts: [post], inMainFeed: true).count, 1)
        XCTAssertEqual(SafetyLists().filtered(comments: [comment]).count, 1)
    }
}

// MARK: - The report email (PRODUCT §2.15)

final class ReportMailTests: XCTestCase {
    /// The reasons are the subject line verbatim, which is what stops them being reworded per
    /// build — and the list is the whole list, in this order, on every platform.
    func testTheSevenReasonsAreTheListAndTheSubjectLine() {
        XCTAssertEqual(Moderation.reasons, ["Spam", "Nudity or sexual content", "Violence or threats",
                                            "Hate or harassment", "Child safety", "Illegal content",
                                            "Something else"])
        XCTAssertEqual(ReportMail.subject(reason: "Child safety"), "tgsocial report \u{2014} Child safety")
    }

    /// The body, byte for byte, including the trailing blank line the cursor lands on. The app adds
    /// nothing else — no phone number, no device id.
    func testThePostBodyIsExactlyTheSpecifiedLines() {
        let subject = ReportSubject(post: MediaFixture.post())
        let body = ReportMail.body(subject: subject, reason: "Spam", app: "tgsocial 1.0.0 (12) \u{00B7} iOS")
        XCTAssertEqual(body, """
        Reason: Spam
        Link: https://t.me/waveloop_devlog/144
        Channel: @waveloop_devlog
        Message: 144
        Node: @tgs_ana
        Kind: post
        App: tgsocial 1.0.0 (12) \u{00B7} iOS

        Anything you want to add:


        """)
        XCTAssertTrue(body.hasSuffix("Anything you want to add:\n\n"))
        XCTAssertEqual(ReportMail.to, "elijah@lucianlabs.ca")
    }

    /// A comment reports its own channel and message, and `Kind:` says so.
    func testACommentReportsItsOwnMessage() {
        let comment = MediaFixture.comment(target: "https://t.me/waveloop_devlog/144")
        let subject = ReportSubject(comment: comment)
        XCTAssertEqual(subject.hiddenKey, "tgs_ana_r/9")
        let body = ReportMail.body(subject: subject, reason: "Hate or harassment", app: "tgsocial 1.0.0 (12) \u{00B7} iOS")
        XCTAssertTrue(body.contains("Link: https://t.me/tgs_ana_r/9"))
        XCTAssertTrue(body.contains("Channel: @tgs_ana_r"))
        XCTAssertTrue(body.contains("Message: 9"))
        XCTAssertTrue(body.contains("Node: @tgs_ana"))
        XCTAssertTrue(body.contains("Kind: comment"))
    }

    /// `Node:` reads `unattributed` when there is none — never a blank line, never the channel.
    func testAnUnattributedPostReportsUnattributed() {
        var post = MediaFixture.post()
        post.authorUsername = nil
        let body = ReportMail.body(subject: ReportSubject(post: post), reason: "Spam", app: "x")
        XCTAssertTrue(body.contains("Node: unattributed"))
    }

    /// The `mailto:` fallback has to survive the em dash and the newlines, or the composer opens on
    /// a truncated report.
    func testTheMailtoFallbackCarriesTheWholeSubjectAndBody() throws {
        let subject = ReportMail.subject(reason: "Illegal content")
        let body = ReportMail.body(subject: ReportSubject(post: MediaFixture.post()), reason: "Illegal content", app: "x")
        let url = try XCTUnwrap(ReportMail.mailto(subject: subject, body: body))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "mailto")
        XCTAssertEqual(components.path, "elijah@lucianlabs.ca")
        let items = components.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "subject" }?.value, subject)
        XCTAssertEqual(items.first { $0.name == "body" }?.value, body)
        // Percent-encoded on the wire: a raw newline or `#` in a URL would truncate the body.
        XCTAssertFalse(url.absoluteString.contains("\n"))
    }
}

// MARK: - When the toast lands (PRODUCT §2.15)

/// `Reported. It's hidden here now.` is the only sign the app gives that a report was recorded and
/// the content hidden, and `MFMailComposeViewController` covers the whole app while it is up — the
/// toast host is a SwiftUI overlay in RootView, underneath it, running its own auto-dismiss. So the
/// claim under test is the ordering: the composer branch answers when the composer *closes*, and
/// the branch where nothing opened answers straight away with the `false` that changes the words.
///
/// The composer itself is never built here — `MFMailComposeViewController()` is nil on a simulator
/// with no mail account — so the tests drive `composerClosed()`, which is the step the delegate
/// callback exists to reach.
@MainActor
final class ReportToastTimingTests: XCTestCase {
    /// A launcher whose composer always opens and whose `mailto:` fallback is a failure: on this
    /// branch nothing may reach the system, and falling through would mean the wrong toast.
    private func withComposer() -> MailLauncher {
        let launcher = MailLauncher()
        launcher.platform.canSendMail = { true }
        launcher.platform.present = { _ in true }
        launcher.platform.open = { _, done in XCTFail("the composer branch must not fall through"); done(false) }
        return launcher
    }

    func testTheCompletionWaitsForTheComposerToClose() {
        let launcher = withComposer()
        var opened: Bool?
        launcher.send(to: ReportMail.to, subject: ReportMail.subject(reason: "Spam"), body: "Reason: Spam\n") { opened = $0 }
        XCTAssertNil(opened, "the toast cannot be emitted under the composer that covers it")

        launcher.composerClosed()
        XCTAssertEqual(opened, true, "the toast lands as the composer goes away")
    }

    /// It fires once. A second dismissal — or a stray delegate callback — must not repaint a toast
    /// over whatever the reader is doing by then.
    func testItConfirmsOnceAndOnlyOnce() {
        let launcher = withComposer()
        var count = 0
        launcher.send(to: ReportMail.to, subject: "s", body: "b") { _ in count += 1 }
        launcher.composerClosed()
        launcher.composerClosed()
        XCTAssertEqual(count, 1)
    }

    /// Nothing to present and nothing to open: `No mail app. Write to …`, and it is not deferred —
    /// there is no composer whose dismissal it could be waiting for.
    func testNoComposerAndNoMailtoAnswersImmediately() {
        let launcher = MailLauncher()
        launcher.platform.canSendMail = { false }
        launcher.platform.open = { _, done in done(false) }
        var opened: Bool?
        launcher.send(to: ReportMail.to, subject: "s", body: "b") { opened = $0 }
        XCTAssertEqual(opened, false)
    }

    /// A composer that cannot be presented is not a composer: the send falls through to `mailto:`
    /// rather than parking the completion on a dismissal that will never come.
    func testAComposerThatCannotBePresentedFallsThroughToMailto() throws {
        let launcher = MailLauncher()
        var url: URL?
        launcher.platform.canSendMail = { true }
        launcher.platform.present = { _ in false }
        launcher.platform.open = { opened, done in url = opened; done(true) }
        var result: Bool?
        launcher.send(to: ReportMail.to, subject: ReportMail.subject(reason: "Spam"), body: "Reason: Spam\n") { result = $0 }
        XCTAssertEqual(result, true, "the mailto: branch keeps its old timing — openURL's own handler")
        XCTAssertEqual(try XCTUnwrap(url).scheme, "mailto")
    }
}

// MARK: - The record (PROTOCOL §7.1)

final class SafetyRecordTests: XCTestCase {
    /// The wire shape, read back from the exact JSON PROTOCOL §7.1 prints.
    func testTheSpecRecordDecodes() throws {
        let json = """
        {
          "v": 1,
          "userId": 176543210,
          "blocked": ["tgs_ana", "tgs_bob"],
          "mutedFeeds": ["waveloop_devlog"],
          "hidden": [
            { "key": "waveloop_devlog/144", "reason": "Spam", "at": "2026-09-04T21:02:11Z" }
          ]
        }
        """
        let lists = try JSONDecoder().decode(SafetyLists.self, from: Data(json.utf8))
        XCTAssertEqual(lists.v, 1)
        XCTAssertEqual(lists.userId, 176_543_210)
        XCTAssertEqual(lists.blocked, ["tgs_ana", "tgs_bob"])
        XCTAssertEqual(lists.mutedFeeds, ["waveloop_devlog"])
        XCTAssertEqual(lists.hidden, [HiddenItem(key: "waveloop_devlog/144", reason: "Spam", at: "2026-09-04T21:02:11Z")])
        XCTAssertTrue(lists.isHidden(key: "waveloop_devlog/144"))
    }

    /// And writes back the same field names, because Android and web read this file's own shape.
    func testItEncodesUnderTheSpecFieldNames() throws {
        let lists = SafetyLists(userId: 7, blocked: ["tgs_ana"], mutedFeeds: ["waveloop_devlog"],
                                hidden: [HiddenItem(key: "waveloop_devlog/144", reason: "Spam", at: "2026-09-04T21:02:11Z")])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(lists)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "userId", "blocked", "mutedFeeds", "hidden"])
        let hidden = try XCTUnwrap((object["hidden"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(hidden.keys), ["key", "reason", "at"])
    }

    /// "Unknown `v` is read as best it can be and never dropped": a record from a later version
    /// that has moved a field on still yields the block list it does carry.
    func testAnUnknownVersionKeepsWhateverItCarries() throws {
        let json = """
        { "v": 4, "userId": 9, "blocked": ["tgs_ana"], "somethingNew": {"x": 1} }
        """
        let lists = try JSONDecoder().decode(SafetyLists.self, from: Data(json.utf8))
        XCTAssertEqual(lists.v, 4)
        XCTAssertEqual(lists.blocked, ["tgs_ana"])
        XCTAssertTrue(lists.mutedFeeds.isEmpty)
        XCTAssertTrue(lists.hidden.isEmpty)
    }

    /// Settings shows the report's own date, not a re-derived one.
    func testTheHiddenRowsDateIsTheRecordsOwn() {
        XCTAssertEqual(Moderation.reportedDate("2026-09-04T21:02:11Z"), "2026-09-04")
        XCTAssertEqual(Moderation.reportedDate("whenever"), "whenever")
    }

    /// PRODUCT §2.21: case-insensitive, tolerates a missing `@`, and matches nothing else.
    func testTheDeleteConfirmMatch() {
        XCTAssertTrue(Moderation.confirmsDelete("@tgs_elijah", username: "tgs_elijah"))
        XCTAssertTrue(Moderation.confirmsDelete("tgs_elijah", username: "tgs_elijah"))
        XCTAssertTrue(Moderation.confirmsDelete("  @TGS_Elijah  ", username: "tgs_elijah"))
        XCTAssertFalse(Moderation.confirmsDelete("", username: "tgs_elijah"))
        XCTAssertFalse(Moderation.confirmsDelete("@", username: "tgs_elijah"))
        XCTAssertFalse(Moderation.confirmsDelete("tgs_elija", username: "tgs_elijah"))
    }
}

// MARK: - The store, and what survives a sign-out

@MainActor
final class SafetyStoreTests: XCTestCase {
    private func freshStore() -> LocalStore {
        let store = LocalStore()
        store.save(Optional<SafetyLists>.none, LocalStore.moderation)
        return store
    }

    /// The one that matters most: signing out wipes local state and the lists stay. A block list
    /// that evaporated would re-expose the reader to the person they blocked on the next sign-in.
    func testTheSafetyListsSurviveTheWipeThatSignOutRuns() {
        let store = freshStore()
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 176_543_210)
        moderation.block("tgs_ana")
        moderation.mute(feed: "waveloop_devlog")
        moderation.hide(key: "waveloop_devlog/144", reason: "Spam")
        store.save("a cache", LocalStore.myTitle)

        store.clear()

        XCTAssertNil(store.load(String.self, LocalStore.myTitle))
        let reloaded = ModerationStore(store: store)
        XCTAssertEqual(reloaded.lists.blocked, ["tgs_ana"])
        XCTAssertEqual(reloaded.lists.mutedFeeds, ["waveloop_devlog"])
        XCTAssertEqual(reloaded.lists.hidden.map(\.key), ["waveloop_devlog/144"])
        XCTAssertEqual(reloaded.lists.userId, 176_543_210)
    }

    /// Same account, the lists carry over; a different account on the same device gets empty ones,
    /// because a list inherited by someone else would be someone else's judgement.
    func testAdoptKeepsTheListsForTheSameAccountAndClearsThemForAnother() {
        let store = freshStore()
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 1)
        moderation.block("tgs_ana")

        let sameAccount = ModerationStore(store: store)
        sameAccount.adopt(userId: 1)
        XCTAssertEqual(sameAccount.lists.blocked, ["tgs_ana"])

        let otherAccount = ModerationStore(store: store)
        otherAccount.adopt(userId: 2)
        XCTAssertTrue(otherAccount.lists.blocked.isEmpty)
        XCTAssertEqual(otherAccount.lists.userId, 2)
        // And that is the state on disk now, not just in memory.
        XCTAssertTrue(ModerationStore(store: store).lists.blocked.isEmpty)
    }

    /// Every mutation is written through, and every undo lifts only its own list.
    func testEachUndoLiftsOnlyItsOwnList() {
        let store = freshStore()
        let moderation = ModerationStore(store: store)
        moderation.adopt(userId: 1)
        moderation.block("@TGS_Ana")
        moderation.mute(feed: "waveloop_devlog")
        moderation.hide(key: "WaveLoop_Devlog/144", reason: "Spam")
        XCTAssertTrue(moderation.isBlocked("tgs_ana"))
        XCTAssertTrue(moderation.isHidden(key: "waveloop_devlog/144"))

        moderation.unblock("tgs_ana")
        XCTAssertFalse(moderation.isBlocked("tgs_ana"))
        XCTAssertTrue(moderation.isMuted(feed: "waveloop_devlog"))
        XCTAssertTrue(moderation.isHidden(key: "waveloop_devlog/144"))

        moderation.unhide(key: "waveloop_devlog/144")
        XCTAssertTrue(moderation.isMuted(feed: "waveloop_devlog"))
        XCTAssertEqual(ModerationStore(store: store).lists.mutedFeeds, ["waveloop_devlog"])

        moderation.unmute(feed: "waveloop_devlog")
        XCTAssertTrue(ModerationStore(store: store).lists.isEmpty)
    }

    /// Reporting the same thing twice keeps one row, carrying the latest reason.
    func testHidingTheSameThingTwiceKeepsOneRow() {
        let store = freshStore()
        let moderation = ModerationStore(store: store)
        moderation.hide(key: "waveloop_devlog/144", reason: "Spam")
        moderation.hide(key: "waveloop_devlog/144", reason: "Child safety")
        XCTAssertEqual(moderation.lists.hidden.count, 1)
        XCTAssertEqual(moderation.lists.hidden.first?.reason, "Child safety")
    }

    /// `at` is ISO 8601 UTC, which is what makes the stored date the date Settings shows.
    func testTheReportTimestampIsIso8601Utc() {
        let store = freshStore()
        let moderation = ModerationStore(store: store)
        moderation.hide(key: "waveloop_devlog/144", reason: "Spam",
                        at: Foundation.Date(timeIntervalSince1970: 1_788_555_731))
        XCTAssertEqual(moderation.lists.hidden.first?.at, "2026-09-04T21:02:11Z")
        XCTAssertEqual(Moderation.reportedDate(moderation.lists.hidden.first?.at ?? ""), "2026-09-04")
    }
}
