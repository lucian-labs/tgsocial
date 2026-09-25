// Unit tests — signed in means Telegram, Bluesky, or both (PRODUCT.md §1, §2.1, §2.8, §2.41;
// PROTOCOL.md §7, §7.1, §12.11; Elijah 2026-09-25: "it should allow combined logins to telegram
// and blueky", "instead of "you" put an avatar on the bottom right of the menu and put "settings"
// on top right of that").
//
// Measured, not assumed: routing is read off the model's one value in all four states; Telegram's
// sign-in, Ready, the remote sign-out and the parking are driven with TDLib's own updates through
// the model's one update consumer (`handle`), with what the reader typed read back off the seam
// that stands in for TDLib; the sign-outs run the shipped functions and the wipe is read back off
// the disk; the Bluesky-only feed is built against a stubbed Bluesky with a TDLib client that must
// still not exist afterwards; a Bluesky sign-in runs end to end (discovery, PAR, the browser, the
// callback, the token) through the app model, with the root sampled while it is in flight; and the
// tab bar, You and the Telegram-only screens are laid out in a real window and their controls' —
// and the avatar's — frames read back.

import SwiftUI
import TDLibKit
import UIKit
import XCTest
@testable import tgsocial

@MainActor
enum SessionFixture {
    static let me = BskyFixture.me
    static let ana = BskyFixture.ana
    static let bob = BskyFixture.bob
    static let node = MyNode(chatId: -100_1, supergroupId: 1, username: "tgs_wren", pinnedMessageId: 8)
    static let avatar = "https://cdn.bsky.app/img/avatar/plain/\(BskyFixture.me)/bafkavatar@jpeg"

    /// A Bluesky that serves the timeline (two posts), the follows (three accounts, one page), the
    /// writes, and — for everything else — the whole sign-in server `BlueskySignInTests` measured.
    /// `profileDelay` holds the sign-in's profile read open: the window after the session is held
    /// and before the sign-in returns, which is where a late routing decision would show.
    nonisolated static func network(profileDelay: Duration? = nil) -> StubTransport {
        StubTransport { req, _ in
            let path = req.url?.path ?? ""
            if path.hasSuffix("app.bsky.actor.getProfile") {
                var reply = BlueskySignInTests.answer(req)
                reply.delay = profileDelay
                return reply
            }
            if path.hasSuffix("app.bsky.feed.getTimeline") {
                return .json(200, ["feed": [
                    BskyFixture.entry(did: BskyFixture.ana, handle: "ana.bsky.social", rkey: "3mw2cdr44fc3a", at: "2026-09-25T18:00:00.000Z"),
                    BskyFixture.entry(did: BskyFixture.bob, handle: "bob.bsky.social", rkey: "3mw2cdr44fc3b", at: "2026-09-25T17:00:00.000Z"),
                ]])
            }
            if path.hasSuffix("app.bsky.graph.getFollows") {
                return .json(200, ["follows": [
                    ["did": BskyFixture.ana, "handle": "ana.bsky.social", "displayName": "Ana Iliovic"],
                    ["did": BskyFixture.bob, "handle": "bob.bsky.social"],
                    ["did": "did:plc:cat2cat2cat2cat2cat2cat2", "handle": "cat.bsky.social"],
                ]])
            }
            if path.hasSuffix("com.atproto.repo.createRecord") {
                return .json(200, ["uri": "at://\(BskyFixture.me)/app.bsky.feed.post/3mw2cdr44fc4a", "cid": "bafypost"])
            }
            return BlueskySignInTests.answer(req)
        }
    }

    final class Browser { var opened: [URL] = [] }

    enum Bluesky { case none, live(avatar: String?), ended }

    /// An app model over the real `LocalStore` (snapshotted by the suite) and a Bluesky built on a
    /// memory vault and `transport`. TDLib is never started under XCTest (`mayStartTDLib`); the
    /// model's asks for it are counted in `tdlibStartRequests`.
    static func model(_ bluesky: Bluesky = .none, transport: StubTransport = network(),
                      browser: Browser = Browser()) -> AppModel {
        let store = LocalStore()
        let vault: MemoryVault
        switch bluesky {
        case .none:
            vault = MemoryVault()
        case .live(let avatar):
            vault = MemoryVault((BskyFixture.session(), DPoPKey.generate(preferSecureEnclave: false)))
            store.save(BlueskyAccount(did: me, handle: "elijah.bsky.social", displayName: "Elijah Lucian", avatar: avatar),
                       LocalStore.blueskyAccount)
        case .ended:
            vault = MemoryVault()
            store.save(BlueskyEnded(did: me, handle: "elijah.bsky.social"), LocalStore.blueskyEnded)
        }
        let model = AppModel(makeBluesky: { store, activity in
            BlueskyService(store: store, activity: activity, config: .reference, transport: transport, vault: vault,
                           openBrowser: { url in browser.opened.append(url); return true })
        })
        XCTAssertFalse(model.mayStartTDLib, "the test host never starts TDLib")
        model.bluesky.prefs = BlueskyPrefs(followsOn: true, tagOn: false)
        return model
    }

    /// Telegram signed in, as `authorizationStateReady` leaves it.
    static func telegram(_ model: AppModel, node: Bool = true) {
        model.auth = .ready
        model.telegramUserId = 7
        model.nodeLookupDone = true
        if node {
            model.myNode = Self.node
            model.myCard = Card(name: "Wren Alderiss", isPublic: true)
            model.myCardState = .ok
        }
    }
}

@MainActor
final class SessionTests: XCTestCase {
    private var backup: URL?
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tgsocial", isDirectory: true)
    }

    /// Every test here signs in and out, and a sign-out wipes the store: the suite runs on a fresh
    /// directory and puts back exactly what it found.
    override func setUp() {
        let fm = FileManager.default
        let copy = fm.temporaryDirectory.appendingPathComponent("tgsocial-store-\(UUID().uuidString)")
        if fm.fileExists(atPath: Self.directory.path) { try? fm.copyItem(at: Self.directory, to: copy); backup = copy }
        try? fm.removeItem(at: Self.directory)
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.directory)
        if let backup { try? fm.copyItem(at: backup, to: Self.directory); try? fm.removeItem(at: backup) }
        else { try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true) }
    }

    private let store = LocalStore()

    private func until(_ what: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Routing (PRODUCT §1)

    /// The four states, each read off the one value, and where each puts the reader. Setup is
    /// Telegram's alone; a Bluesky session that Bluesky ended still counts as held.
    func testRoutingInAllFourStates() {
        let out = SessionFixture.model()
        XCTAssertEqual(out.session.kind, .signedOut)
        XCTAssertEqual(out.root, .signIn)

        let telegram = SessionFixture.model()
        SessionFixture.telegram(telegram, node: false)
        XCTAssertEqual(telegram.session.kind, .telegramOnly)
        XCTAssertEqual(telegram.root, .setup, "Telegram with no node is Setup")
        telegram.myNode = SessionFixture.node
        XCTAssertEqual(telegram.root, .app)

        let bluesky = SessionFixture.model(.live(avatar: nil))
        bluesky.nodeLookupDone = true
        XCTAssertEqual(bluesky.session.kind, .blueskyOnly)
        XCTAssertEqual(bluesky.root, .app, "Bluesky alone is signed in, and never sees Setup")
        XCTAssertFalse(bluesky.needsSetup)

        let both = SessionFixture.model(.live(avatar: nil))
        SessionFixture.telegram(both)
        XCTAssertEqual(both.session.kind, .both)
        XCTAssertEqual(both.root, .app)

        let ended = SessionFixture.model(.ended)
        XCTAssertFalse(ended.bluesky.isSignedIn, "the session is over")
        XCTAssertEqual(ended.session.kind, .blueskyOnly, "and still held: the reader did not sign out")
        XCTAssertEqual(ended.root, .app)

        // The demo is signed in to nothing, and is the app.
        let demo = SessionFixture.model(.live(avatar: nil))
        demo.enterDemo()
        XCTAssertEqual(demo.session.kind, .signedOut)
        XCTAssertEqual(demo.root, .app)
        demo.leaveDemo()
    }

    /// §2.1, driven the way it happens: TDLib's own updates, the number and code the reader typed,
    /// then `authorizationStateReady`. The offer is the root in the same turn as Ready — before
    /// `getMe`'s round trip, so no frame of the tabbed Feed comes first — and ahead of Setup; the
    /// preference is written when it is shown; and a launch restoring a session offers nothing.
    func testATelegramSignInTheReaderTypedOffersBlueskyFirstAndOnce() async {
        let model = SessionFixture.model()
        var sent: [TelegramAuthStep] = []
        model.authStepOverride = { sent.append($0) }
        tdlib(.authorizationStateWaitPhoneNumber, model)
        XCTAssertEqual(model.root, .signIn)
        await model.submitPhone("+1 604 555 0199")
        tdlib(Self.codeStep, model)
        await model.submitCode(" 12345 ")
        XCTAssertEqual(sent, [.phone("+1 604 555 0199"), .code("12345")], "what the reader typed reached Telegram")

        tdlib(.authorizationStateReady, model)
        XCTAssertEqual(model.root, .offer(.bluesky), "in the same turn as Ready")
        XCTAssertEqual(store.load(Bool.self, LocalStore.offeredOther), true, "written when shown, not when answered")
        model.nodeLookupDone = true   // onReady's node lookup: a TDLib read the test host does not make
        XCTAssertEqual(model.root, .offer(.bluesky), "ahead of Setup")
        model.declineOffer()
        XCTAssertEqual(model.root, .setup, "`Not Now` goes on to Setup with no node")

        // Once per install: the next sign-in typed on this device is not offered it again.
        let again = SessionFixture.model()
        again.authStepOverride = { _ in }
        tdlib(.authorizationStateWaitPhoneNumber, again)
        await again.submitPhone("+1 604 555 0199")
        tdlib(.authorizationStateReady, again)
        XCTAssertNil(again.offer, "once per install")

        // A launch restoring a session is not a sign-in: nothing typed, nothing offered.
        store.save(Optional<Bool>.none, LocalStore.offeredOther)
        let restored = SessionFixture.model()
        tdlib(.authorizationStateReady, restored)
        XCTAssertNil(restored.offer)
        XCTAssertEqual(restored.root, .app)
        XCTAssertNil(store.load(Bool.self, LocalStore.offeredOther))
    }

    // MARK: Telegram from inside the app (§2.1, PROTOCOL §12.11)

    /// Signed in to Bluesky alone TDLib is off, and `Send Code` is what starts it: the preference
    /// goes, nothing is sent until TDLib answers, and that answer is not parked under the reader.
    /// Ready lands back where the steps were opened, with no offer.
    func testSendCodeStartsTelegramFromOffAndLandsBackWhereItWasOpened() async throws {
        store.save(true, LocalStore.telegramSignedOut)
        let model = SessionFixture.model(.live(avatar: nil))
        await model.startServices()
        XCTAssertEqual(model.auth, .off)
        XCTAssertEqual(model.tdlibStartRequests, 0)
        model.tab = .explore
        model.openTelegramSignIn()
        var sent: [TelegramAuthStep] = []
        model.authStepOverride = { sent.append($0) }

        let send = Task { await model.submitPhone("+1 604 555 0199") }
        try await until("TDLib asked for") { model.tdlibStartRequests == 1 }
        XCTAssertEqual(model.auth, .loading)
        XCTAssertNil(store.load(Bool.self, LocalStore.telegramSignedOut), "removed when the reader starts Telegram's sign-in")
        XCTAssertTrue(sent.isEmpty, "nothing is sent before TDLib answers")
        tdlib(.authorizationStateWaitPhoneNumber, model)
        await send.value
        XCTAssertEqual(sent, [.phone("+1 604 555 0199")])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.auth, .phone, "the answer to the reader's own Send Code is not parked")
        XCTAssertNil(store.load(Bool.self, LocalStore.telegramSignedOut))

        tdlib(Self.codeStep, model)
        await model.submitCode("12345")
        tdlib(.authorizationStateReady, model)
        XCTAssertEqual(model.session.kind, .both)
        XCTAssertEqual(model.path, [], "the pushed steps are gone")
        XCTAssertEqual(model.tab, .explore, "back where they were opened")
        XCTAssertNil(model.offer, "a second network added from inside the app offers nothing")
        XCTAssertEqual(model.root, .app)
    }

    /// A `Send Code` the reader walks away from does not leave TDLib starting on every launch.
    /// Leaving the steps parks the client; a launch that finds the code step TDLib kept, with
    /// nobody in the steps, parks it. Each writes the preference, so the launch after starts none.
    func testAnAbandonedTelegramSignInIsParkedAgain() async throws {
        store.save(true, LocalStore.telegramSignedOut)
        let model = SessionFixture.model(.live(avatar: nil))
        await model.startServices()
        model.openTelegramSignIn()
        model.authStepOverride = { _ in }
        let send = Task { await model.submitPhone("+1 604 555 0199") }
        try await until("TDLib asked for") { model.auth == .loading }
        tdlib(.authorizationStateWaitPhoneNumber, model)
        await send.value
        tdlib(Self.codeStep, model)
        XCTAssertEqual(model.auth, .code(phone: "+16045550199"))
        model.path.removeLast()   // what `‹ Back`'s dismiss writes through the stack's binding
        try await until("parked in the run") { model.auth == .off }
        XCTAssertEqual(store.load(Bool.self, LocalStore.telegramSignedOut), true)
        XCTAssertEqual(model.session.kind, .blueskyOnly)

        // The app quit on the code step instead, before anything parked it: the preference is
        // absent, so the launch starts TDLib (§12.11 "absent means start TDLib"), which answers
        // with the code step it kept.
        store.save(Optional<Bool>.none, LocalStore.telegramSignedOut)
        let relaunch = SessionFixture.model(.live(avatar: nil))
        await relaunch.startServices()
        XCTAssertEqual(relaunch.tdlibStartRequests, 1)
        tdlib(Self.codeStep, relaunch)
        try await until("parked at launch") { relaunch.auth == .off }
        XCTAssertEqual(store.load(Bool.self, LocalStore.telegramSignedOut), true)
        XCTAssertNil(relaunch.toast, "a launch parking a client says nothing")
        try await until("the feed, from Bluesky") { relaunch.feedReady && !relaunch.feedLoading && !relaunch.posts.isEmpty }

        // And the launch after that starts nothing.
        let next = SessionFixture.model(.live(avatar: nil))
        await next.startServices()
        XCTAssertEqual(next.tdlibStartRequests, 0)
        XCTAssertEqual(next.auth, .off)
    }

    /// `Send Code`, then `‹ Back` before TDLib has even answered: the number is never sent, and the
    /// answer, when it comes, is parked in the same turn — no phone step for nobody.
    func testLeavingBeforeTDLibAnswersSendsNothing() async throws {
        store.save(true, LocalStore.telegramSignedOut)
        let model = SessionFixture.model(.live(avatar: nil))
        await model.startServices()
        model.openTelegramSignIn()
        var sent: [TelegramAuthStep] = []
        model.authStepOverride = { sent.append($0) }
        let send = Task { await model.submitPhone("+1 604 555 0199") }
        try await until("TDLib asked for") { model.auth == .loading }
        model.path.removeLast()
        XCTAssertEqual(model.auth, .loading, "a client that has not answered is not closed")
        tdlib(.authorizationStateWaitPhoneNumber, model)
        XCTAssertEqual(model.auth, .off, "parked in the turn it answered")
        await send.value
        XCTAssertTrue(sent.isEmpty, "the number the reader walked away from was not sent")
        XCTAssertEqual(store.load(Bool.self, LocalStore.telegramSignedOut), true)
    }

    /// A Bluesky sign-in that lands while TDLib is still coming up does not park it — the client may
    /// be restoring a session — and parks it the moment TDLib answers that nobody is signed in.
    func testABlueskySignInThatLandsBeforeTDLibAnswersParksItWhenItDoes() async throws {
        let browser = SessionFixture.Browser()
        let stub = SessionFixture.network()
        let model = SessionFixture.model(transport: stub, browser: browser)
        XCTAssertEqual(model.auth, .loading)
        let outcome = try await signInToBluesky(model, stub: stub, browser: browser)
        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(model.auth, .loading, "not parked before TDLib has said anything")
        XCTAssertNil(store.load(Bool.self, LocalStore.telegramSignedOut))
        tdlib(.authorizationStateWaitPhoneNumber, model)
        try await until("parked") { model.auth == .off }
        XCTAssertEqual(store.load(Bool.self, LocalStore.telegramSignedOut), true)
        XCTAssertEqual(model.root, .offer(.telegram), "the offer's phone step stays: `Send Code` starts TDLib again")
    }

    /// PRODUCT §4 "Telegram signs you out", from TDLib's own updates: a LoggingOut that was not
    /// ours, Closing, Closed. With a Bluesky session held the app stays open on Bluesky, Telegram's
    /// part is wiped, the toast says so, and no client comes back — this run or the next launch.
    /// Without one it is the last one out, and a fresh client comes up for the phone step.
    func testTelegramSigningYouOutKeepsBlueskyOpen() async throws {
        let model = SessionFixture.model(.live(avatar: nil))
        SessionFixture.telegram(model)
        store.save(SessionFixture.node, LocalStore.myNode)
        remoteSignOut(model)
        XCTAssertEqual(model.session.kind, .blueskyOnly)
        XCTAssertEqual(model.root, .app)
        XCTAssertEqual(model.auth, .off)
        XCTAssertEqual(model.toast?.text, SessionCopy.telegramSignedYouOut)
        XCTAssertNil(model.myNode)
        XCTAssertNil(store.load(MyNode.self, LocalStore.myNode), "Telegram's part is gone from disk")
        XCTAssertEqual(store.load(Bool.self, LocalStore.telegramSignedOut), true)
        XCTAssertEqual(model.tdlibStartRequests, 0, "no client comes back")
        XCTAssertFalse(model.td.isStarted)
        XCTAssertTrue(model.bluesky.isSignedIn, "Bluesky's session stays")
        try await until("the feed, from Bluesky") { model.feedReady && !model.feedLoading && !model.posts.isEmpty }

        let relaunch = SessionFixture.model(.live(avatar: nil))
        await relaunch.startServices()
        XCTAssertEqual(relaunch.tdlibStartRequests, 0, "nor at the next launch")

        store.save(true, LocalStore.offeredOther)
        let alone = SessionFixture.model()
        SessionFixture.telegram(alone)
        remoteSignOut(alone)
        XCTAssertEqual(alone.root, .signIn)
        XCTAssertEqual(alone.toast?.text, SessionCopy.telegramSignedYouOut)
        XCTAssertEqual(alone.auth, .loading)
        XCTAssertEqual(alone.tdlibStartRequests, 1, "a fresh client, for the phone step")
        try await until("the last one out's wipe") { store.load(Bool.self, LocalStore.offeredOther) == nil }
    }

    // MARK: Sign in with Bluesky, first (§2.1, §12.11)

    /// The whole of §12.7 through the app model, signed in to nothing: the session lands, the
    /// TDLib client the phone step made is parked and the preference written, the other network is
    /// offered, and TDLib is never asked for.
    func testBlueskyFirstSignsInParksTelegramAndOffersIt() async throws {
        let browser = SessionFixture.Browser()
        let stub = SessionFixture.network(profileDelay: .milliseconds(300))
        let model = SessionFixture.model(transport: stub, browser: browser)
        model.auth = .phone   // TDLib has said: not signed in.
        XCTAssertEqual(model.root, .signIn)

        let done = Flag()
        let task = Task { () -> AppModel.BlueskySignInOutcome in
            let outcome = await model.signInBluesky(SessionFixture.me)
            done.value = true
            return outcome
        }
        try await until("the browser") { !browser.opened.isEmpty && model.bluesky.waitingHandle != nil }
        let state = try sentState(stub)
        model.handleOpenURL(URL(string: "\(AtprotoClientConfig.reference.redirectURI)?code=c-1&state=\(state)&iss=https%3A%2F%2Fbsky.social")!)
        // From the instant the session is held until the sign-in returns (its profile read, held
        // open by the stub), every frame SwiftUI could paint shows the offer — never the tabbed
        // Feed (§2.1: "before anything else").
        var painted: [RootScreen] = []
        while !done.value {
            if model.blueskyHeld { painted.append(model.root) }
            try await Task.sleep(for: .milliseconds(5))
        }
        let outcome = await task.value
        XCTAssertGreaterThan(painted.count, 10, "the window was watched")
        XCTAssertTrue(painted.allSatisfy { $0 == .offer(.telegram) }, "painted: \(painted)")

        XCTAssertEqual(outcome, .signedIn)
        XCTAssertEqual(model.session.kind, .blueskyOnly)
        XCTAssertEqual(model.auth, .off, "Bluesky alone runs no TDLib client")
        XCTAssertEqual(store.load(Bool.self, LocalStore.telegramSignedOut), true, "so the next launch does not start one")
        XCTAssertEqual(model.root, .offer(.telegram))
        model.declineOffer()
        XCTAssertEqual(model.root, .app)
        XCTAssertFalse(model.td.isStarted)
        XCTAssertEqual(model.tdlibStartRequests, 0)
        XCTAssertEqual(model.moderation.lists.did, SessionFixture.me, "§7.1: the record is keyed by the DID")
    }

    // MARK: The safety lists (PROTOCOL §7.1)

    /// Telegram first, a block made; then Bluesky signs in through the app. The lists are kept and
    /// the DID is written beside the Telegram id — on disk, not only in memory — and no offer shows,
    /// because the second network was added from inside the app.
    func testSafetyListsSurviveBlueskyJoiningTelegram() async throws {
        store.save(SafetyLists(userId: 7, blocked: ["tgs_ana"], mutedFeeds: ["waveloop_devlog"]), LocalStore.moderation)
        let browser = SessionFixture.Browser()
        let stub = SessionFixture.network()
        let model = SessionFixture.model(transport: stub, browser: browser)
        SessionFixture.telegram(model)

        let task = Task { await model.signInBluesky(SessionFixture.me) }
        try await until("the browser") { !browser.opened.isEmpty && model.bluesky.waitingHandle != nil }
        model.handleOpenURL(URL(string: "\(AtprotoClientConfig.reference.redirectURI)?code=c-1&state=\(try sentState(stub))&iss=https%3A%2F%2Fbsky.social")!)
        _ = await task.value

        XCTAssertEqual(model.session.kind, .both)
        XCTAssertNil(model.offer)
        XCTAssertEqual(model.auth, .ready, "Telegram is not parked when it is signed in")
        let onDisk = try XCTUnwrap(store.load(SafetyLists.self, LocalStore.moderation))
        XCTAssertEqual(onDisk.blocked, ["tgs_ana"])
        XCTAssertEqual(onDisk.mutedFeeds, ["waveloop_devlog"])
        XCTAssertEqual(onDisk.userId, 7)
        XCTAssertEqual(onDisk.did, SessionFixture.me)
    }

    /// Telegram signed in with its id unread (`getMe` failed at Ready), then Bluesky signs in. The
    /// held-but-unknown key is not treated as absent — that fired §7.1's replace row and emptied
    /// the lists of the person who wrote them. Nothing is compared until the id can be read.
    func testABlueskySignInKeepsTheListsWhileTelegramsIdIsUnknown() async throws {
        store.save(SafetyLists(userId: 7, blocked: ["tgs_ana"], mutedFeeds: ["waveloop_devlog"]), LocalStore.moderation)
        let browser = SessionFixture.Browser()
        let stub = SessionFixture.network()
        let model = SessionFixture.model(transport: stub, browser: browser)
        SessionFixture.telegram(model)
        model.telegramUserId = nil
        let outcome = try await signInToBluesky(model, stub: stub, browser: browser)
        XCTAssertEqual(outcome, .signedIn)

        XCTAssertEqual(model.session.kind, .both)
        XCTAssertEqual(model.moderation.lists.blocked, ["tgs_ana"])
        let onDisk = try XCTUnwrap(store.load(SafetyLists.self, LocalStore.moderation))
        XCTAssertEqual(onDisk.blocked, ["tgs_ana"])
        XCTAssertEqual(onDisk.mutedFeeds, ["waveloop_devlog"])
        XCTAssertEqual(onDisk.userId, 7)
    }

    /// §7.1's table, row by row, on the value the store applies.
    func testTheRecordIsKeptReplacedOrAdoptedByItsKeys() {
        let a = SessionFixture.ana, b = SessionFixture.bob
        // Keep, and overwrite: Telegram 7 held, Bluesky B signs in → kept, `did` becomes B.
        let kept = SafetyLists(userId: 7, did: a, blocked: ["tgs_ana"]).adopted(userId: 7, did: b)
        XCTAssertEqual(kept.blocked, ["tgs_ana"]); XCTAssertEqual(kept.did, b); XCTAssertEqual(kept.userId, 7)
        // A Bluesky-only record, Telegram joining: the DID matches, the id is written.
        let joined = SafetyLists(userId: 0, did: a, blocked: [b]).adopted(userId: 7, did: a)
        XCTAssertEqual(joined.blocked, [b]); XCTAssertEqual(joined.userId, 7)
        // Replace: back through the OTHER network after signing out of both starts empty.
        let other = SafetyLists(userId: 7, blocked: ["tgs_ana"]).adopted(userId: nil, did: a)
        XCTAssertTrue(other.isEmpty); XCTAssertEqual(other.did, a); XCTAssertEqual(other.userId, 0)
        // Adopt: a record with no key at all belongs to whoever signs in first.
        let adopted = SafetyLists(blocked: ["tgs_ana"]).adopted(userId: nil, did: a)
        XCTAssertEqual(adopted.blocked, ["tgs_ana"]); XCTAssertEqual(adopted.did, a)
        // A field whose network is not held neither matches nor conflicts.
        let untouched = SafetyLists(userId: 7, did: a, blocked: ["tgs_ana"]).adopted(userId: 7, did: nil)
        XCTAssertEqual(untouched.did, a); XCTAssertEqual(untouched.blocked, ["tgs_ana"])
    }

    /// A Bluesky-only reader's record has a null `userId` and MUST be written (§7.1: the test is
    /// "this is the demo", not "`userId` is null") — on the wire as `null`, beside the DID.
    func testABlueskyOnlyRecordIsWrittenWithANullUserId() throws {
        let model = SessionFixture.model(.live(avatar: nil))
        model.moderation.adopt(userId: nil, did: SessionFixture.me)
        model.blockAccount(did: SessionFixture.bob, handle: "@bob.bsky.social")
        let data = try Data(contentsOf: Self.directory.appendingPathComponent(LocalStore.moderation + ".json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["userId"] is NSNull)
        XCTAssertEqual(object["did"] as? String, SessionFixture.me)
        XCTAssertEqual(object["blocked"] as? [String], [SessionFixture.bob])
    }

    // MARK: Sign-outs (PRODUCT §4, §2.20; PROTOCOL §7)

    /// Both signed in: each sign-out leaves the other network signed in and the app open.
    func testSigningOutOfOneKeepsYouIn() async throws {
        let both = SessionFixture.model(.live(avatar: nil))
        SessionFixture.telegram(both)
        await both.signOutBluesky()
        XCTAssertEqual(both.session.kind, .telegramOnly)
        XCTAssertEqual(both.root, .app)
        XCTAssertEqual(both.myNode, SessionFixture.node, "Telegram's part is untouched")

        let other = SessionFixture.model(.live(avatar: nil))
        SessionFixture.telegram(other)
        other.bluesky.prefs.tagOn = true
        store.save(true, LocalStore.offeredOther)
        store.save(FeedMode.work, LocalStore.feedMode)
        store.save(SafetyLists(userId: 7, did: SessionFixture.me, blocked: ["tgs_ana"]), LocalStore.moderation)
        var loggedOut = 0
        other.logOutOverride = { loggedOut += 1 }
        await other.signOutTelegram()

        XCTAssertEqual(loggedOut, 1)
        XCTAssertEqual(other.session.kind, .blueskyOnly)
        XCTAssertEqual(other.root, .app, "the app stays open, Bluesky only")
        XCTAssertEqual(other.auth, .off)
        XCTAssertNil(other.myNode)
        XCTAssertNil(store.load(MyNode.self, LocalStore.myNode), "Telegram's part is gone from disk")
        XCTAssertEqual(store.load(Bool.self, LocalStore.telegramSignedOut), true)
        XCTAssertTrue(other.bluesky.isSignedIn, "Bluesky's session stays")
        XCTAssertNotNil(store.load(BlueskyAccount.self, LocalStore.blueskyAccount))
        XCTAssertTrue(other.bluesky.prefs.tagOn, "and its toggles")
        XCTAssertEqual(store.load(Bool.self, LocalStore.offeredOther), true, "UI preferences go only with the last one out")
        XCTAssertEqual(store.load(FeedMode.self, LocalStore.feedMode), .work)
        XCTAssertEqual(store.load(SafetyLists.self, LocalStore.moderation)?.blocked, ["tgs_ana"])
        XCTAssertEqual(other.tdlibStartRequests, 0, "and TDLib is not brought back up")
    }

    /// The last one out, whichever network: Sign in, everything wiped, the safety lists kept.
    func testTheLastOneOutReturnsToSignIn() async throws {
        store.save(SafetyLists(userId: 7, blocked: ["tgs_ana"]), LocalStore.moderation)
        store.save(true, LocalStore.offeredOther)
        let telegram = SessionFixture.model()
        SessionFixture.telegram(telegram)
        telegram.logOutOverride = {}
        await telegram.signOutTelegram()
        XCTAssertEqual(telegram.session.kind, .signedOut)
        XCTAssertEqual(telegram.root, .signIn)
        XCTAssertNil(store.load(Bool.self, LocalStore.offeredOther), "UI preferences go with the last one out")
        XCTAssertEqual(store.load(SafetyLists.self, LocalStore.moderation)?.blocked, ["tgs_ana"], "the lists survive by design")

        // Bluesky alone: a record this account keyed (the Telegram-keyed one above would be, rightly,
        // someone else's to a DID arriving alone — §7.1's "replace" row).
        store.save(SafetyLists(did: SessionFixture.me, blocked: [SessionFixture.bob]), LocalStore.moderation)
        store.save(true, LocalStore.telegramSignedOut)
        store.save(true, LocalStore.offeredOther)
        let bluesky = SessionFixture.model(.live(avatar: nil))
        await bluesky.startServices()
        XCTAssertEqual(bluesky.auth, .off)
        XCTAssertEqual(bluesky.tdlibStartRequests, 0)
        await bluesky.signOutBluesky()
        XCTAssertEqual(bluesky.session.kind, .signedOut)
        XCTAssertEqual(bluesky.root, .signIn)
        XCTAssertEqual(bluesky.tdlibStartRequests, 1, "TDLib comes back up for Telegram's phone step")
        XCTAssertNil(store.load(Bool.self, LocalStore.telegramSignedOut))
        XCTAssertNil(store.load(BlueskyAccount.self, LocalStore.blueskyAccount))
        XCTAssertNil(store.load(Bool.self, LocalStore.offeredOther))
        XCTAssertEqual(store.load(SafetyLists.self, LocalStore.moderation)?.blocked, [SessionFixture.bob])
    }

    /// An ended session is held — and signing out of it is the last one out too.
    func testAnEndedSessionCanBeSignedOutOf() async {
        let model = SessionFixture.model(.ended)
        XCTAssertTrue(model.session.isSignedIn)
        await model.signOutBluesky()
        XCTAssertEqual(model.root, .signIn)
        XCTAssertNil(store.load(BlueskyEnded.self, LocalStore.blueskyEnded))
    }

    // MARK: Bluesky alone (PROTOCOL §12.11)

    /// A launch with a Bluesky session held and Telegram known signed out builds the feed from
    /// Bluesky's sources — and no TDLib client exists afterwards, because none was ever asked for.
    /// The pill reads from Pending and the device's network, not from a TDLib connection.
    func testBlueskyAloneBuildsTheFeedWithTDLibNeverAuthorized() async throws {
        store.save(true, LocalStore.telegramSignedOut)
        let stub = SessionFixture.network()
        let model = SessionFixture.model(.live(avatar: nil), transport: stub)
        await model.startServices()
        XCTAssertEqual(model.auth, .off)
        try await until("the feed") { model.feedReady && !model.feedLoading }

        XCTAssertEqual(model.posts.compactMap(\.bluesky?.authorDid), [SessionFixture.ana, SessionFixture.bob], "newest first")
        XCTAssertTrue(model.feed.sources.isEmpty, "no Telegram source was resolved")
        XCTAssertTrue(stub.requests.contains { $0.url?.path.hasSuffix("app.bsky.feed.getTimeline") == true })
        XCTAssertFalse(model.td.isStarted, "no TDLib client was made")
        XCTAssertEqual(model.tdlibStartRequests, 0, "and none was asked for")

        try await until("nothing pending") { model.activity.isEmpty }
        model.deviceOnline = true
        XCTAssertEqual(model.status, .synced)
        model.deviceOnline = false
        XCTAssertEqual(model.status, .offline)
        XCTAssertEqual(model.telegramLabel, "Not signed in")

        // The control: signed in to nothing, a launch asks for TDLib, for the phone step.
        store.save(Optional<Bool>.none, LocalStore.telegramSignedOut)
        let out = SessionFixture.model()
        await out.startServices()
        XCTAssertEqual(out.tdlibStartRequests, 1)
    }

    /// §2.7, Bluesky only: `getFollows` for the session's own DID, from the AppView, without auth;
    /// listed, a blocked account neither a row nor a dot.
    func testTheGraphIsTheBlueskyFollowsList() async throws {
        let stub = SessionFixture.network()
        let model = SessionFixture.model(.live(avatar: nil), transport: stub)
        model.moderation.adopt(userId: nil, did: SessionFixture.me)
        model.blockAccount(did: SessionFixture.bob, handle: "@bob.bsky.social")
        await model.refreshBlueskyFollows()
        XCTAssertEqual(model.blueskyFollows.count, 3)
        XCTAssertEqual(model.visibleBlueskyFollows.map(\.did), [SessionFixture.ana, "did:plc:cat2cat2cat2cat2cat2cat2"])
        XCTAssertTrue(model.blueskyFollowsExhausted, "no cursor, no second page")
        let req = try XCTUnwrap(stub.requests.last { $0.url?.path.hasSuffix("app.bsky.graph.getFollows") == true })
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first { $0.name == "actor" }?.value, SessionFixture.me)
        XCTAssertEqual(q.first { $0.name == "limit" }?.value, "100")
        XCTAssertEqual(req.url?.host, "public.api.bsky.app")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    /// §2.9, Bluesky only: the direct post — the text, its facets, no link card (there is no
    /// Telegram original), created in the account's own repo.
    func testComposeBlueskyOnlyPostsDirectly() async throws {
        let stub = SessionFixture.network()
        let model = SessionFixture.model(.live(avatar: nil), transport: stub)
        let ok = await model.postToBluesky(text: "New take #waveloop https://waveloop.app", photoPath: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.toast?.text, "Posted.")
        let req = try XCTUnwrap(stub.requests.last { $0.url?.path.hasSuffix("com.atproto.repo.createRecord") == true })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["repo"] as? String, BskyFixture.me)
        let record = try XCTUnwrap(body["record"] as? [String: Any])
        XCTAssertEqual(record["text"] as? String, "New take #waveloop https://waveloop.app")
        XCTAssertNil(record["embed"], "no external embed: nothing to link back to")
        let features = ((record["facets"] as? [[String: Any]]) ?? []).compactMap { ($0["features"] as? [[String: Any]])?.first?["$type"] as? String }
        XCTAssertEqual(Set(features), ["app.bsky.richtext.facet#tag", "app.bsky.richtext.facet#link"])

        let tooLong = String(repeating: "a", count: BlueskyText.maxGraphemes + 1)
        let refused = await model.postToBluesky(text: tooLong, photoPath: nil)
        XCTAssertFalse(refused, "never truncated, never sent")
    }

    /// PRODUCT §4: the feed refreshes by itself when the network returns. Bluesky alone there is no
    /// TDLib `Connected` to say so; the device's network does. (No `startServices`: its path monitor
    /// would write the simulator's real network over the one this test sets.)
    func testABlueskyOnlyFeedRefreshesWhenTheNetworkReturns() async throws {
        let stub = SessionFixture.network()
        let model = SessionFixture.model(.live(avatar: nil), transport: stub)
        model.auth = .off
        model.deviceOnline = false
        await model.refreshFeed()
        XCTAssertTrue(model.feedStale, "offline, the read serves cache and is marked stale")
        XCTAssertEqual(timelineReads(stub), 0)
        XCTAssertEqual(model.status, .offline)

        model.deviceOnline = true
        try await until("the refresh the network's return asks for") { !model.feedStale && !model.feedLoading }
        XCTAssertEqual(timelineReads(stub), 1)
        XCTAssertEqual(model.posts.count, 2)
    }

    // MARK: §2.41's Telegram card, on every Telegram-only surface

    /// Signed in to Bluesky alone, each screen whose content is Telegram's shows `Sign In with
    /// Telegram` — laid out, measured — and the button opens Telegram's steps as a pushed screen.
    /// Settings shows the sign-in in its `TELEGRAM` card, and neither sign-out nor Delete My Node.
    func testEachTelegramOnlySurfaceShowsItsSignInAffordance() throws {
        let model = SessionFixture.model(.live(avatar: nil))
        model.nodeLookupDone = true
        let screens: [(String, AnyView)] = [
            ("Explore", AnyView(ExploreScreen())),
            ("Node profile", AnyView(NodeProfileScreen(username: "tgs_ana"))),
            ("Feed channel", AnyView(FeedChannelScreen(username: "waveloop_devlog"))),
            ("You", AnyView(YouScreen())),
            ("Settings", AnyView(SettingsScreen())),
        ]
        for (name, screen) in screens {
            let regions = measure(screen, model: model)
            XCTAssertNotNil(regions[SessionCopy.signInWithTelegram], "\(name) has no `Sign In with Telegram`")
            if name == "Settings" {
                XCTAssertNil(regions["Delete My Node"], "the app created nothing on Bluesky")
                XCTAssertNil(regions[SessionCopy.signOutOfTelegram])
            }
        }
        XCTAssertFalse(model.td.isStarted, "none of them read anything from Telegram")
        XCTAssertEqual(SessionCopy.needsTelegram(SessionCopy.findNodes), "Sign in to Telegram to find nodes.")
        XCTAssertEqual(SessionCopy.needsTelegram(SessionCopy.see("tgs_ana")), "Sign in to Telegram to see @tgs_ana.")
        XCTAssertEqual(SessionCopy.needsTelegram(SessionCopy.useConnector), "Sign in to Telegram to use the Connector.")

        model.openTelegramSignIn()
        XCTAssertEqual(model.path, [.telegramSignIn])
        model.openTelegramSignIn()
        XCTAssertEqual(model.path, [.telegramSignIn], "one push, however often it is tapped")
    }

    // MARK: The avatar tab (PRODUCT §1)

    /// The rightmost item is the avatar — the picture itself found on the shipped bar, 24pt, inside
    /// `You`'s segment — and every segment of the shipped bar is exactly as tall and as wide as the
    /// same bar of words, selected or not.
    func testTheRightmostTabIsTheAvatarAndTheBarKeepsItsHeight() throws {
        XCTAssertEqual(Tab.allCases.last, .you)
        XCTAssertEqual(Tab.you.label, "You", "the word stays, as the item's accessibility label")
        let tabs = Tab.allCases.map(\.label)
        // The bar as it was: the same items, words only, laid out in the same window.
        let words = measure(HPFloatingTabs(items: Tab.allCases, selected: .constant(Tab.feed), label: { $0.label }),
                            model: SessionFixture.model())
        XCTAssertNil(words[TabAvatarView.region], "the reference draws no picture")

        for selected in [Tab.feed, .you] {
            let model = SessionFixture.model(.live(avatar: nil))
            model.tab = selected
            XCTAssertEqual(model.root, .app)
            let all = measureAll(BottomChrome(), model: model)
            let shipped = regionsByLabel(all)
            XCTAssertEqual(tabs.compactMap { shipped[$0] }.count, tabs.count, "every item reported: \(shipped.keys.sorted())")
            let rightmost = try XCTUnwrap(tabs.max { (shipped[$0]?.maxX ?? 0) < (shipped[$1]?.maxX ?? 0) })
            XCTAssertEqual(rightmost, "You")

            let avatars = all.filter { $0.label == TabAvatarView.region }.map(\.rect)
            XCTAssertEqual(avatars.count, 1, "the shipped bar draws one avatar (selected: \(selected))")
            let avatar = try XCTUnwrap(avatars.first)
            let you = try XCTUnwrap(shipped["You"])
            XCTAssertEqual(avatar.width, HPTokens.Space.avatarTab, accuracy: 0.5)
            XCTAssertEqual(avatar.height, HPTokens.Space.avatarTab, accuracy: 0.5)
            XCTAssertTrue(you.insetBy(dx: -0.5, dy: -0.5).contains(avatar), "inside You's segment")
            XCTAssertEqual(avatar.midX, you.midX, accuracy: 0.5, "centred in it")

            for label in tabs {
                let a = try XCTUnwrap(shipped[label]), w = try XCTUnwrap(words[label])
                XCTAssertEqual(a.height, w.height, accuracy: 0.5, "\(label): the bar is no taller for the avatar")
                XCTAssertEqual(a.width, w.width, accuracy: 0.5, "\(label): and no wider — the word still sets the width")
                XCTAssertGreaterThanOrEqual(a.height, HPTokens.Space.touchMin, "\(label): a 40pt target")
            }
        }
    }

    /// Node photo → Bluesky avatar → initial, in every state that has them.
    func testTheAvatarFallsBackFromNodePhotoToBlueskyToInitial() {
        let photo = PhotoRef(fileId: 1, uniqueId: "p1", width: 640, height: 640, minithumbnail: nil)

        let telegram = SessionFixture.model()
        SessionFixture.telegram(telegram)
        telegram.myPhoto = photo
        XCTAssertEqual(telegram.tabAvatar, .nodePhoto(photo))
        telegram.myPhoto = nil
        XCTAssertEqual(telegram.tabAvatar, .initial("W"), "the card's name")

        let both = SessionFixture.model(.live(avatar: SessionFixture.avatar))
        SessionFixture.telegram(both)
        XCTAssertEqual(both.tabAvatar, .blueskyAvatar(SessionFixture.avatar), "a node with no photo falls back to Bluesky")
        both.myPhoto = photo
        XCTAssertEqual(both.tabAvatar, .nodePhoto(photo), "the node photo comes first")

        let bluesky = SessionFixture.model(.live(avatar: SessionFixture.avatar))
        XCTAssertEqual(bluesky.tabAvatar, .blueskyAvatar(SessionFixture.avatar))
        let plain = SessionFixture.model(.live(avatar: nil))
        XCTAssertEqual(plain.tabAvatar, .initial("E"), "the Bluesky display name's initial")
        let ended = SessionFixture.model(.ended)
        XCTAssertEqual(ended.tabAvatar, .initial("e"), "the ended account's handle")
    }

    // MARK: Settings, top right on You (PRODUCT §2.8)

    /// In every state You shows exactly one `Settings` — the body row is gone — and it sits above
    /// the header at its right edge. Settings is reached from nowhere else.
    func testSettingsIsOnYouTopRightAndNowhereElse() throws {
        let node = SessionFixture.model()
        SessionFixture.telegram(node)
        let noNode = SessionFixture.model()
        SessionFixture.telegram(noNode, node: false)
        noNode.setupSkipped = true
        let bluesky = SessionFixture.model(.live(avatar: nil))
        for (name, model) in [("node", node), ("no node", noNode), ("Bluesky only", bluesky)] {
            let regions = measureAll(YouScreen(), model: model)
            let settings = regions.filter { $0.label == SessionCopy.settings }
            XCTAssertEqual(settings.count, 1, "\(name): one `Settings`, not a second row at the bottom")
            let button = try XCTUnwrap(settings.first?.rect)
            let header = try XCTUnwrap(regions.first { $0.label == YouScreen.headerRegion }?.rect, name)
            XCTAssertLessThanOrEqual(button.maxY, header.minY + 0.5, "\(name): above the header")
            XCTAssertEqual(button.maxX, header.maxX, accuracy: 1, "\(name): at its right edge")
        }
        // Nowhere else: Feed and Settings itself carry no `Settings` control.
        let elsewhere = SessionFixture.model(.live(avatar: nil))
        for screen in [AnyView(FeedScreen()), AnyView(SettingsScreen())] {
            XCTAssertFalse(measureAll(screen, model: elsewhere).contains { $0.label == SessionCopy.settings })
        }
    }

    // MARK: Copy (PRODUCT §3)

    /// One verb for both networks, and the new confirm and helper lines are one short sentence.
    func testTheNewCopyIsLabelsAndSaysSignIn() {
        XCTAssertEqual(SessionCopy.headline, "Telegram and Bluesky, as one feed.")
        XCTAssertEqual(SessionCopy.offerTitle(.bluesky), "Also sign in to Bluesky?")
        XCTAssertEqual(SessionCopy.offerTitle(.telegram), "Also sign in to Telegram?")
        XCTAssertEqual(SessionCopy.signOutTelegramTitle, "Sign out of Telegram?")
        XCTAssertEqual(SessionCopy.signOutTelegramBody, "Your node stays on Telegram.")
        let all = [SessionCopy.headline, SessionCopy.offerTitle(.bluesky), SessionCopy.offerTitle(.telegram),
                   SessionCopy.signInWithTelegram, SessionCopy.signOutOfTelegram, SessionCopy.signOutTelegramBody,
                   SessionCopy.telegramSignedYouOut, SessionCopy.needsTelegram(SessionCopy.findNodes),
                   BlueskyCopy.signIn, BlueskyCopy.signOut]
        for line in all {
            XCTAssertFalse(line.lowercased().contains("connect"), "§3: `Sign in`, never \"connect\" — \(line)")
            XCTAssertLessThan(line.count, 70, line)
            XCTAssertLessThanOrEqual(line.filter { ".?!".contains($0) }.count, 1, "one sentence: \(line)")
        }
    }

    // MARK: Harness

    private final class RegionBox { var regions: [HPTouchRegion] = [] }
    private final class Flag { var value = false }

    /// TDLib's `updateAuthorizationState`, through the model's one update consumer.
    private func tdlib(_ state: AuthorizationState, _ model: AppModel) {
        model.handle(.updateAuthorizationState(UpdateAuthorizationState(authorizationState: state)))
    }

    private static let codeStep = AuthorizationState.authorizationStateWaitCode(AuthorizationStateWaitCode(
        codeInfo: AuthenticationCodeInfo(nextType: nil, phoneNumber: "+16045550199", timeout: 60,
                                         type: .authenticationCodeTypeSms(AuthenticationCodeTypeSms(length: 5)))))

    /// A session ended from another device: TDLib logs out without our `logOut`, then closes.
    private func remoteSignOut(_ model: AppModel) {
        for state in [AuthorizationState.authorizationStateLoggingOut, .authorizationStateClosing, .authorizationStateClosed] {
            tdlib(state, model)
        }
    }

    /// §12.7 through the app model: the browser opens, Bluesky calls back, the sign-in finishes.
    private func signInToBluesky(_ model: AppModel, stub: StubTransport,
                                 browser: SessionFixture.Browser) async throws -> AppModel.BlueskySignInOutcome {
        let task = Task { await model.signInBluesky(SessionFixture.me) }
        try await until("the browser") { !browser.opened.isEmpty && model.bluesky.waitingHandle != nil }
        model.handleOpenURL(URL(string: "\(AtprotoClientConfig.reference.redirectURI)?code=c-1&state=\(try sentState(stub))&iss=https%3A%2F%2Fbsky.social")!)
        return await task.value
    }

    private func timelineReads(_ stub: StubTransport) -> Int {
        stub.requests.filter { $0.url?.path.hasSuffix("app.bsky.feed.getTimeline") == true }.count
    }

    private func regionsByLabel(_ regions: [HPTouchRegion]) -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for r in regions where out[r.label] == nil { out[r.label] = r.rect }
        return out
    }

    private func sentState(_ stub: StubTransport) throws -> String {
        let par = try XCTUnwrap(stub.requests.last { $0.url?.path == "/oauth/par" }, "PAR was sent")
        let body = String(data: try XCTUnwrap(par.httpBody), encoding: .utf8) ?? ""
        return try XCTUnwrap(URLComponents(string: "?" + body)?.queryItems?.first { $0.name == "state" }?.value)
    }

    private func measure(_ view: some View, model: AppModel) -> [String: CGRect] {
        regionsByLabel(measureAll(view, model: model))
    }

    /// The view in a phone-sized key window with the model in its environment, laid out; every
    /// region its controls report under `hpMeasureTouchTargets`.
    private func measureAll(_ view: some View, model: AppModel) -> [HPTouchRegion] {
        let box = RegionBox()
        let reported = expectation(description: "regions reported")
        reported.assertForOverFulfill = false
        // The view's own frame is always reported, so a screen with no control of its own still
        // answers — with nothing but this — instead of timing the wait out.
        let probe = view
            .hpTouchRegion("__root")
            .environment(model)
            .environment(\.hpMeasureTouchTargets, true)
            .hpTouchSpace()
            .onPreferenceChange(HPTouchTargetKey.self) { regions in
                box.regions = regions
                if !regions.isEmpty { reported.fulfill() }
            }
        let host = UIHostingController(rootView: probe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 1600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        wait(for: [reported], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let regions = box.regions
        window.isHidden = true
        window.rootViewController = nil
        return regions
    }
}
