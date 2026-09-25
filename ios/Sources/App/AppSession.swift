// App — who is signed in, and where that puts the reader (PRODUCT.md §1, §2.1, §2.41; PROTOCOL.md
// §7, §12.11).
//
// Signed in means Telegram, Bluesky, or both (Elijah, 2026-09-25: "it should allow combined logins
// to telegram and blueky"). That is ONE value, `session`, computed here and read by every gate —
// root routing, Setup, the tab bar, the status pill, Compose, Settings, the Connector — so no
// screen decides for itself what "signed in" means. Sign-outs are per network; the last one out is
// the one that wipes everything but the safety lists.

import Foundation
import Network
import SwiftUI

/// PRODUCT §1's four states.
enum SessionKind: Equatable {
    case telegramOnly, blueskyOnly, both, signedOut
}

/// The one value. `telegram` is `authorizationStateReady`; `bluesky` is a session held — live, or
/// ended by Bluesky and not signed out of (§1: "A Bluesky session that Bluesky ended still counts
/// as held").
struct AppSession: Equatable {
    var telegram: Bool
    var bluesky: Bool

    var kind: SessionKind {
        switch (telegram, bluesky) {
        case (true, true): return .both
        case (true, false): return .telegramOnly
        case (false, true): return .blueskyOnly
        case (false, false): return .signedOut
        }
    }

    var isSignedIn: Bool { telegram || bluesky }
}

/// The network §2.1 offers once, after the first sign-in.
enum OtherNetwork: Equatable { case telegram, bluesky }

/// One of Telegram's sign-in calls, as the reader sent it (PROTOCOL §4.1).
enum TelegramAuthStep: Equatable {
    case phone(String), code(String), password(String)
}

extension AuthPhase {
    /// TDLib has answered, and the answer is "not signed in": a step of Telegram's sign-in (one the
    /// app has or not), or no client on purpose. `.loading` is not an answer — a client still
    /// coming up may be restoring a signed-in session.
    var saysNotSignedIn: Bool {
        switch self {
        case .phone, .code, .password, .otherDevice, .registration, .unsupported, .off: return true
        case .loading, .ready, .loggingOut: return false
        }
    }

    /// Where `setAuthenticationPhoneNumber` is accepted: the phone step, and — TDLib's own rule —
    /// the steps after it, so a code step TDLib kept across a relaunch takes a new number.
    var takesPhoneNumber: Bool {
        switch self {
        case .phone, .code, .password, .registration: return true
        default: return false
        }
    }
}

/// What the shell shows at its root (PRODUCT §1, §2.1, §2.2). The tabbed stack is `.app`.
enum RootScreen: Equatable {
    case secretsMissing
    case signIn
    case offer(OtherNetwork)
    case setup
    case app
}

/// PRODUCT §1: the last tab's picture, first of: your node's photo; your Bluesky avatar; the
/// initial of your name in the display serif.
enum TabAvatar: Equatable {
    case nodePhoto(PhotoRef)
    case blueskyAvatar(String)
    case initial(String)
}

/// Every string the two-network shell adds, verbatim from PRODUCT §2.1, §2.8, §2.9, §2.20, §2.41 and
/// §4 — one place, so the three builds cannot drift apart one word at a time (§3). One verb for
/// both networks: `Sign in` (§3), never "connect".
enum SessionCopy {
    static let headline = "Telegram and Bluesky, as one feed."
    static func offerTitle(_ network: OtherNetwork) -> String {
        network == .bluesky ? "Also sign in to Bluesky?" : "Also sign in to Telegram?"
    }
    static let notNow = "Not Now"
    static let telegramMark = "Telegram"
    static let blueskyMark = "Bluesky"
    static let phoneLabel = "Phone number"
    static let handleLabel = "Handle"
    static let sendCode = "Send Code"
    static let signInWithTelegram = "Sign In with Telegram"
    static let signOutOfTelegram = "Sign Out of Telegram"
    static let signOutTelegramTitle = "Sign out of Telegram?"
    static let signOutTelegramBody = "Your node stays on Telegram."
    static let telegramSignedYouOut = "Telegram signed you out."
    static let notSignedIn = "Not signed in"
    static let phoneRow = "Phone"
    static let settings = "Settings"
    static let youLabel = "You"
    /// §2.41's Telegram card: the screen's one helper line, with the screen's own verb.
    static func needsTelegram(_ verb: String) -> String { "Sign in to Telegram to \(verb)." }
    static let findNodes = "find nodes"
    static func see(_ username: String) -> String { "see @\(username)" }
    static let useConnector = "use the Connector"
    /// §2.9, Bluesky only.
    static func postTo(_ handle: String) -> String { "Bluesky \u{00B7} \(handle)" }
    static let posted = "Posted."
    static func blueskyRefused(_ error: String) -> String { "Bluesky didn't take it \u{2014} \(error)." }
    /// §2.7, Bluesky only.
    static let blueskyFollowsMark = "Bluesky"
    static let notFollowing = "Not following anyone yet."
}

extension AppModel {
    // MARK: The one value (PRODUCT §1)

    var telegramReady: Bool { auth == .ready }

    /// A Bluesky session held (§1). Nil-safe because `bluesky` is built in `init`, after the
    /// properties a SwiftUI preview could read.
    var blueskyHeld: Bool { bluesky?.isHeld ?? false }

    /// The demo is signed in to nothing (§2.22) — it is its own world, routed ahead of this.
    var session: AppSession {
        guard !isDemo else { return AppSession(telegram: false, bluesky: false) }
        return AppSession(telegram: telegramReady, bluesky: blueskyHeld)
    }

    /// The shell's root. The offer comes before Setup (§2.1: "before anything else"), and Setup is
    /// Telegram's alone — `needsSetup` asks for `authorizationStateReady` — so a Bluesky-only reader
    /// never sees it.
    var root: RootScreen {
        if secretsMissing { return .secretsMissing }
        if isDemo { return .app }
        if let offer { return .offer(offer) }
        if !session.isSignedIn { return .signIn }
        if needsSetup { return .setup }
        return .app
    }

    // MARK: UI preferences (PROTOCOL §7)

    /// §12.11 `telegramSignedOut`, and only while a Bluesky session is held: without one, a launch
    /// has nobody to be signed in as but Telegram, so TDLib starts as it always did.
    var telegramKnownSignedOut: Bool {
        store.load(Bool.self, LocalStore.telegramSignedOut) == true && blueskyHeld
    }

    var offeredOther: Bool { store.load(Bool.self, LocalStore.offeredOther) == true }

    // MARK: §2.1's offer

    /// Set when the offer is SHOWN, not answered, so a relaunch mid-offer does not show it twice.
    /// Absent in the demo, after the first time, and when the other network is already held — the
    /// callers only ask when it is not.
    func offerOther(_ network: OtherNetwork) {
        guard !isDemo, !offeredOther else { return }
        store.save(true, LocalStore.offeredOther)
        offer = network
    }

    /// `Not Now`: on to Setup (Telegram with no node) or Feed — `root` routes it. Declining
    /// Telegram's offer leaves its steps, so a client they started is parked (§12.11).
    func declineOffer() {
        let wasTelegram = offer == .telegram
        offer = nil
        tab = .feed
        if wasTelegram { leftTelegramSignIn() }
    }

    // MARK: TDLib, only when Telegram is wanted (PROTOCOL §12.11)

    /// Every place the app starts TDLib comes through here, so "Bluesky alone never starts it" has
    /// one door to measure.
    func startTelegram() {
        tdlibStartRequests += 1
        guard mayStartTDLib else { return }
        td.start()
    }

    /// The same door for the fresh client TDLib wants after it closed itself (`logOut`, local or
    /// remote) with Telegram still wanted.
    func restartTelegram() {
        tdlibStartRequests += 1
        guard mayStartTDLib else { return }
        td.recreate()
    }

    /// `Send Code` with TDLib off, or still coming up: start it and wait for its answer. True when
    /// TDLib takes a number there — the phone step, or the code step it kept from an attempt the
    /// reader abandoned (parked, then restarted here).
    func ensureTelegramClient() async -> Bool {
        // "removed when the reader starts Telegram's sign-in"
        store.save(Optional<Bool>.none, LocalStore.telegramSignedOut)
        if auth == .off {
            auth = .loading
            startTelegram()
        }
        let deadline = Foundation.Date().addingTimeInterval(20)
        while auth == .loading, Foundation.Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return auth.takesPhoneNumber
    }

    /// Write the preference and close the client, so the next launch — and this run — run no TDLib
    /// for nobody (§12.11). Only once TDLib has SAID it is not signed in, or is already off: a
    /// client still `.loading` may be restoring a signed-in session, and parking that would hide a
    /// real Telegram account behind a preference. Its answer, when it comes, goes past
    /// `telegramAnsweredSignedOut`, which parks it then.
    func parkTelegram() async {
        guard parkTelegramState() else { return }
        await td.close()
    }

    /// Parking's synchronous half — the preference and `auth` — so it lands in the same turn as
    /// whatever asked for it, and nothing (`Send Code`'s wait included) reads the answer being
    /// parked as a live phone step. The close follows on its own.
    private func parkTelegramState() -> Bool {
        guard auth.saysNotSignedIn else { return false }
        telegramSigningIn = false
        store.save(true, LocalStore.telegramSignedOut)
        auth = .off
        return true
    }

    /// Nobody wants a TDLib client: a Bluesky session is held, Telegram is not signed in, and the
    /// reader is not in Telegram's steps.
    var telegramUnwanted: Bool { !isDemo && blueskyHeld && !telegramReady && !telegramSigningIn }

    /// TDLib answered "not signed in". With nobody wanting the client — a launch that started it
    /// because the preference was absent (a `Send Code` abandoned, the app quit on the code step),
    /// or a Bluesky sign-in that landed while it was still coming up — it is parked, which writes
    /// the preference, so the launch after starts none. Without this the absent preference started
    /// TDLib on every launch, for good. Either way a Bluesky-held feed not yet read is read here:
    /// no `authorizationStateReady` is coming to read it.
    func telegramAnsweredSignedOut() {
        guard !isDemo, blueskyHeld else { return }
        if telegramUnwanted, parkTelegramState() { Task { await td.close() } }
        if !feedReady { Task { await refreshFeed() } }
    }

    /// The reader left Telegram's steps before Ready — `‹ Back` or a tab (`path`), or `Not Now` on
    /// the offer. The sign-in they started is over, and its client is parked if nobody wants it.
    func leftTelegramSignIn() {
        guard !telegramReady else { return }
        telegramSigningIn = false
        if telegramUnwanted, parkTelegramState() { Task { await td.close() } }
    }

    /// `authorizationStateReady`, the part that decides where the reader goes. Synchronous, and run
    /// in the same turn as `auth = .ready`: §2.1's offer comes "before anything else", and an offer
    /// set after `getMe`'s round trip let the tabbed Feed paint first.
    func telegramBecameReady() {
        let fresh = telegramSigningIn
        telegramSigningIn = false
        store.save(Optional<Bool>.none, LocalStore.telegramSignedOut)
        // PRODUCT §2.1: the in-app Telegram sign-in lands back where it was opened (or on Setup,
        // which routes itself when there is no node).
        path.removeAll { $0 == .telegramSignIn }
        // A launch restoring a session is not a sign-in, and offers nothing.
        guard fresh else { return }
        if blueskyHeld {
            // Finishing the offer's second sign-in goes on (§2.1).
            if offer == .telegram { offer = nil }
        } else {
            offerOther(.bluesky)
        }
    }

    /// PROTOCOL §7.1's Telegram key, when a Bluesky sign-in lands with Telegram signed in but its
    /// id never read (`getMe` failed at Ready): read it now. Nil while it still cannot be read —
    /// then nothing is compared (`blueskySessionLanded`).
    func readTelegramUserId() async -> Int64? {
        if let telegramUserId { return telegramUserId }
        guard telegramReady, mayStartTDLib else { return nil }
        if let read = try? await td.api.getMe() { me = read; telegramUserId = read.id }
        return telegramUserId
    }

    /// `Sign In with Telegram` from inside the app — You, Settings, and every §2.41 Telegram card.
    func openTelegramSignIn() {
        guard path.last != .telegramSignIn else { return }
        path.append(.telegramSignIn)
    }

    // MARK: Sign out (PRODUCT §4, §2.20, §2.35; PROTOCOL §7)

    /// `Sign Out of Telegram`. With a Bluesky session held it clears Telegram's part and the app
    /// stays open, Bluesky only; otherwise it is the last one out.
    func signOutTelegram() async {
        #if targetEnvironment(macCatalyst)
        // PRODUCT §2.14 / CONNECTOR.md §2: signing out of Telegram turns the bridge off and wipes
        // the token, whether or not Bluesky stays. Before `logOut`, so no request can be served
        // against a session that is on its way out.
        connector.signOut()
        #endif
        modal = nil
        viewer = nil
        audio.stop()
        let keepBluesky = blueskyHeld
        // Written before `logOut`, so the Closed it causes finds it and leaves TDLib off.
        if keepBluesky { store.save(true, LocalStore.telegramSignedOut) }
        telegramUserSignOut = true
        auth = .loggingOut
        if let logOut = logOutOverride { await logOut() } else { _ = try? await td.api.logOut() }
        telegramUserSignOut = false
        if keepBluesky {
            discardTelegramState()
            if auth == .loggingOut { auth = .off }
        } else {
            await discardEverything()
        }
        me = nil
        telegramUserId = nil
        nodeLookupDone = false
        lastError = nil
        if keepBluesky { await refreshFeed() }
    }

    /// `Sign Out of Bluesky`. With Telegram signed in it is §2.35's sign-out and nothing more;
    /// otherwise it is the last one out, and the app lands on Sign in with TDLib coming up for the
    /// phone step.
    func signOutBluesky() async {
        modal = nil
        guard !telegramReady else {
            await bluesky.signOut()
            showToast(BlueskyCopy.signedOut)
            await refreshFeed()
            return
        }
        viewer = nil
        audio.stop()
        await discardEverything()
        showToast(BlueskyCopy.signedOut)
        if !td.isStarted, auth == .off || auth == .loading {
            auth = .loading
            startTelegram()
        }
    }

    /// PRODUCT §4 "Telegram signs you out": the session ended from another device. Telegram's local
    /// state goes as a sign-out's would; the app stays open on Bluesky when a session is held.
    func finishRemoteTelegramSignOut() {
        #if targetEnvironment(macCatalyst)
        connector.signOut()
        #endif
        viewer = nil
        if blueskyHeld {
            discardTelegramState()
            Task { await refreshFeed() }
        } else {
            Task { await discardEverything() }
        }
        me = nil
        telegramUserId = nil
        nodeLookupDone = false
        showToast(SessionCopy.telegramSignedYouOut, tone: .bad)
    }

    /// Telegram's part of §7: TDLib's database is `logOut`'s; this is the rest — `myNode`, the card
    /// cache, Telegram's cursors, the comment index, the private record and the link-verification
    /// cache. Bluesky's part and the UI preferences stay. Delete My Node wipes exactly this too.
    func discardTelegramState() {
        bluesky.discardTelegramPart()
        store.clear(keeping: LocalStore.survivesTelegramSignOut)
        clearTelegramMemory()
    }

    /// The last one out: everything, UI preferences included, except the safety lists — which
    /// survive by design (PROTOCOL §7.1), keyed so the next person to sign in does not inherit them.
    func discardEverything() async {
        // Bluesky's share goes from memory too, not only from disk (§2.35): the session (revoked,
        // best effort), the toggles, the caches.
        await bluesky.endForLastOneOut()
        // PROTOCOL §7: the drop caches are discardable and go with the last one out — a drop is
        // read signed out, so neither network's own sign-out touches them.
        drops.clear()
        dropViewer = nil
        store.clear()
        clearTelegramMemory()
        feedMode = .all
        offer = nil
        telegramSigningIn = false
        blueskyFollows = []; blueskyFollowsCursor = nil; blueskyFollowsExhausted = false
    }

    private func clearTelegramMemory() {
        myNode = nil; myCard = nil; myWork = nil; myAtprotoDid = nil; myCardState = .ok; myTitle = ""; myPhoto = nil
        setupSkipped = false; inSetup = false
        posts = []; nearby = []; directory = []; direct = []; edges = [:]; candidates = []
        feed.clear(); nodes.clear(); discovery.clear(); comments.clear()
        clearPrivateState()
        path = []; tab = .feed; replySelection = nil
        feedReady = false; feedStale = false; feedExhausted = false
        lastFeedRefresh = nil; myCardFetchedAt = nil
    }

    // MARK: Bluesky alone (PROTOCOL §12.11)

    /// The §4.8 merge over the following source and the tag — no author sources (they come from
    /// nodes in `follows:`, and there is no `follows:`), no pending approvals, no comment index,
    /// and not one call to TDLib. A failed read is not toasted (§2.39: it happens again by itself).
    func refreshBlueskyOnlyFeed() async {
        feed.useNoTelegramSources()
        prepareBlueskySources()
        do {
            try await feed.refresh()
            feedStale = false
            lastFeedRefresh = Foundation.Date()
        } catch {
            feedStale = true
        }
        posts = feed.posts
        feedExhausted = feed.isExhausted
    }

    /// PRODUCT §2.7, Bluesky only: `getFollows`, from the top.
    func refreshBlueskyFollows() async {
        guard !isDemo, !blueskyFollowsLoading else { return }
        blueskyFollowsCursor = nil
        blueskyFollowsExhausted = false
        await loadBlueskyFollows(reset: true)
    }

    /// The list pages as it scrolls; the ring draws the accounts loaded so far.
    func loadMoreBlueskyFollows() async {
        guard !isDemo, !blueskyFollowsLoading, !blueskyFollowsExhausted else { return }
        await loadBlueskyFollows(reset: false)
    }

    private func loadBlueskyFollows(reset: Bool) async {
        blueskyFollowsLoading = true
        defer { blueskyFollowsLoading = false }
        guard let page = try? await bluesky.follows(cursor: reset ? nil : blueskyFollowsCursor) else { return }
        blueskyFollows = reset ? page.follows : blueskyFollows + page.follows.filter { f in !blueskyFollows.contains { $0.did == f.did } }
        blueskyFollowsCursor = page.cursor
        blueskyFollowsExhausted = page.cursor == nil
    }

    /// §2.18 applies: a blocked account is not a dot and not a row.
    var visibleBlueskyFollows: [BlueskyFollow] {
        let blocked = Set(moderation.lists.blocked)
        return blueskyFollows.filter { !blocked.contains($0.did.lowercased()) }
    }

    /// PRODUCT §2.9, Bluesky only: straight to Bluesky (PROTOCOL §12.8, direct post). No retry
    /// button, for §2.38's reason: a retry that posts twice is worse than one that does not.
    func postToBluesky(text: String, photoPath: String?) async -> Bool {
        if refuseDemoWrite() { return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        guard BlueskyText.fits(text) else { return false }
        do {
            try await activity.run("Posting to Bluesky") {
                try await self.bluesky.directPost(text: text, photoPath: photoPath)
            }
            showToast(SessionCopy.posted, tone: .good)
            await refreshFeed()
            return true
        } catch {
            let words = (error as? AtprotoError)?.localizedDescription ?? error.localizedDescription
            noteBlueskyError(words)
            showToast(SessionCopy.blueskyRefused(words), tone: .bad)
            return false
        }
    }

    // MARK: The avatar tab (PRODUCT §1)

    /// Node photo → Bluesky avatar → initial. The node photo counts only while there is a node.
    var tabAvatar: TabAvatar {
        if myNode != nil, let photo = myPhoto { return .nodePhoto(photo) }
        if !isDemo, let url = bluesky?.account?.avatar, !url.isEmpty { return .blueskyAvatar(url) }
        return .initial(myInitial)
    }

    /// The initial of your name: the card's name, the node title, then the Bluesky display name and
    /// handle — whichever of them this reader has.
    var myInitial: String {
        let candidates = [myCard?.name, myTitle, bluesky?.account?.displayName,
                          bluesky?.account?.handle ?? bluesky?.endedHandle]
        let name = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return String(name.drop(while: { $0 == "@" }).prefix(1))
    }

    // MARK: The device's network (§2.10, Bluesky only)

    /// PRODUCT §4: the feed refreshes by itself when the network returns. Signed in to Telegram,
    /// TDLib's `Connected` says so (`handle`); Bluesky alone there is no TDLib connection, and the
    /// device's network is the only word there is. `deviceOnline`'s `didSet` calls this, so the
    /// path monitor and a test flip the same switch.
    func deviceNetworkReturned() {
        guard session.kind == .blueskyOnly, feedStale, !feedLoading else { return }
        Task { await refreshFeed() }
    }

    func startNetworkMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.deviceOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "tgsocial.path"))
        pathMonitor = monitor
    }
}
