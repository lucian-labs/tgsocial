// App — Bluesky, as the rest of the app reaches it (PROTOCOL.md §12, PRODUCT.md §2.35–§2.40).
//
// Everything here is additive. Each entry point returns early in the demo (§2.40: the demo makes
// no network request and has no Bluesky), and none of them runs for a reader who never signed in
// and follows nobody with an `atproto.did` line — for them the feed pass below adds zero sources
// and makes zero requests.

import Foundation
import SwiftUI
import TDLibKit

/// PRODUCT §2.37's sheet: each row's pill.
enum LinkStep: Equatable { case idle, writing, done, failed, checking, verified }

/// Every Bluesky string in one place, verbatim from PRODUCT §2.35–§2.40, so the three builds
/// cannot drift apart one word at a time (§3).
enum BlueskyCopy {
    static let signIn = "Sign In with Bluesky"
    static let signInAgain = "Sign In Again"
    static let tagRow = "#waveloop drops in your feed"
    static let followsRow = "Your Bluesky follows in your feed"
    static let linkButton = "Link to My Node"
    static let signOut = "Sign Out of Bluesky"
    static let endedByBluesky = "Signed out by Bluesky"
    static let sheetTitle = "Sign in with Bluesky."
    static let signOutTitle = "Sign out of Bluesky?"
    static let signOutBody = "Your Bluesky follows leave your feed."
    static let telegramSignOutLine = "You'll be signed out of Bluesky too."
    static let pill = "Bluesky"
    static let openOn = "Open on Bluesky"
    static let playsOn = "Plays on Bluesky"
    static func quoting(_ handle: String) -> String { "Quoting @\(handle)" }
    static func signedIn(_ handle: String) -> String { "Signed in to Bluesky as \(handle)." }
    static let signedOut = "Signed out of Bluesky."
    static let linked = "Linked."
    static let unlinked = "Unlinked."
    static let postedBoth = "Posted here and on Bluesky."
    static func postedHereOnly(_ error: String) -> String { "Posted here. Bluesky didn't take it \u{2014} \(error)." }
    static let sessionEnded = "Bluesky signed you out."
    static func wait(_ s: Int) -> String { "Bluesky asked us to wait \(s) s." }
    static let notFound = "Couldn't find that Bluesky account."
    static let denied = "Bluesky didn't finish signing you in."
    /// `error=access_denied`: the person declined on Bluesky's page (PRODUCT §2.35).
    static let refused = "Not signed in to Bluesky."
    static let timedOut = "Bluesky sign-in timed out."
    static let waiting = "Waiting for Bluesky\u{2026}"
    /// §2.35's waiting state carries the screen's one helper line: without it a person looking at a
    /// spinner would not know the browser is where the next step is.
    static let finishInBrowser = "Finish in your browser."
    static let failed = "Couldn't sign in to Bluesky."
    static let alsoPost = "Also post to Bluesky"
    static let tooLong = "Too long for Bluesky. Shorten it or turn this off."
    static let blockBody = "Their posts disappear here, and they aren't told."
    static func linkTitle(_ handle: String, _ node: String) -> String { "Link \(handle) to @\(node)." }
    static let linkBody = "Your followers here see your Bluesky posts."
    static let twoLines = "Two lines, both public"
    static let anyoneCanCheck = "Anyone can check both"
    static func pendingRecord(_ node: String) -> String { "Your Bluesky account doesn't name @\(node) yet." }
    static let finishLinking = "Finish Linking"
    static let differentAccount = "Your card names a different Bluesky account."
    static let replace = "Replace"
    static func unlinkTitle(_ handle: String) -> String { "Unlink \(handle)?" }
    static let unlinkBody = "Your Bluesky posts leave your followers' feeds here."
    static let cardRepaired = "Card repaired."
    static let notSignedIn = "Not signed in"

    /// How a sign-in that did not finish is told (PRODUCT §2.35, §2.39). Nil: nothing is said — the
    /// person cancelled, or a second attempt was refused while one was already open.
    static func toast(for ending: BlueskyService.SignInError) -> String? {
        switch ending {
        case .cancelled, .busy: return nil
        case .notFound: return notFound
        case .denied: return denied
        case .refused: return refused
        case .timedOut: return timedOut
        case .rateLimited(let s): return wait(s)
        case .failed: return failed
        }
    }
}

extension AppModel {
    // MARK: The feed pass (§12.5)

    /// Me first, then my follows in `follows:` order — §2.3's attribution order, which §12.5 reuses.
    var blueskyScope: [NodeInfo] {
        var out: [NodeInfo] = []
        if let node = myNode, var me = nodes.cachedNode(node.username) ?? myNodeInfo {
            if me.atprotoDid == nil { me.atprotoDid = myAtprotoDid }
            out.append(me)
        }
        for f in myCard?.follows ?? [] { if let n = nodes.cachedNode(f) { out.append(n) } }
        return out
    }

    /// Between `resolveSources` and the merge: hand the merge its atproto sources from the link
    /// cache as it stands, and start the checks beside it. Not `async` on purpose — the Telegram
    /// merge must not wait on a Bluesky host (§12.5 rule 6), and a check that changes the sources
    /// asks for its own pass (`onSourcesChanged`). Nothing to check and nothing on → no request
    /// and no source.
    func prepareBlueskySources() {
        guard !isDemo else { feed.setAtprotoSources([]); return }
        let scope = blueskyScope
        feed.setAtprotoSources(bluesky.sources(scope: scope, isBlocked: { [moderation] in moderation.isBlocked($0) }))
        bluesky.startChecks(scope)
    }

    /// PRODUCT §2.35's Status row: `@handle · N sources`, `Not signed in`, `Sign in again`, or
    /// `Can't reach <host>` (§2.39). Nil — no row — when nothing Bluesky is in play, so the sheet
    /// is unchanged for anyone who never touched it.
    var blueskyStatusLabel: String? {
        guard !isDemo, let bsky = bluesky else { return nil }
        let count = bsky.activeSources.count
        guard bsky.isSignedIn || bsky.endedHandle != nil || count > 0 else { return nil }
        if let host = bsky.unreachableHost { return "Can't reach \(host)" }
        if bsky.endedHandle != nil { return "Sign in again" }
        guard let acct = bsky.account else { return BlueskyCopy.notSignedIn }
        return "\(acct.handleLabel) \u{00B7} \(count) source\(count == 1 ? "" : "s")"
    }

    // MARK: Sign in / out (§2.35, §2.39)

    /// How a sign-in ended, for the sheet: success and a cancel on Bluesky's page close it; a
    /// failure keeps it open so a mistyped handle is fixed where it was typed (§2.39).
    enum BlueskySignInOutcome: Equatable { case signedIn, cancelled, failed }

    func signInBluesky(_ typed: String) async -> BlueskySignInOutcome {
        guard !refuseDemoWrite() else { return .cancelled }
        if isOffline { showToast("You're offline.", tone: .bad); return .failed }
        do {
            let acct = try await bluesky.signIn(typed)
            showToast(BlueskyCopy.signedIn(acct.handleLabel), tone: .good)
            await refreshFeed()
            return .signedIn
        } catch let e as BlueskyService.SignInError {
            // §2.39: the server's words go to `Last error` verbatim.
            if case .failed(let message) = e { noteBlueskyError(message) }
            guard let words = BlueskyCopy.toast(for: e) else { return .cancelled }
            showToast(words, tone: .bad)
            return .failed
        } catch {
            showToast(BlueskyCopy.failed, tone: .bad)
            return .failed
        }
    }

    /// `onOpenURL`: the Bluesky callback on the registered scheme (PROTOCOL §12.7 steps 6–7). Any
    /// other URL is not ours to handle here and is left alone.
    func handleOpenURL(_ url: URL) {
        _ = bluesky?.receiveCallback(url)
    }

    func signOutBluesky() async {
        modal = nil
        await bluesky.signOut()
        showToast(BlueskyCopy.signedOut)
        await refreshFeed()
    }

    func noteBlueskyError(_ message: String) { noteError(message) }

    // MARK: Linking (§12.8, §2.37)

    /// The DID my card names, and whether the signed-in account is it.
    var myLinkedDid: String? { myAtprotoDid }

    /// Step 1 of Link: the record in the account's own repo.
    func linkWriteRecord() async -> String? {
        guard let node = myNode else { return "Make your node first." }
        do { try await bluesky.putLinkRecord(node: node.username); return nil } catch {
            return (error as? AtprotoError)?.localizedDescription ?? error.localizedDescription
        }
    }

    /// Step 2: the card line, through the one card-write path (§12.2 write-back included).
    func linkWriteCard() async -> Bool {
        guard let did = bluesky.account?.did else { return false }
        let previous = myAtprotoDid
        myAtprotoDid = did
        store.save(myAtprotoDid, LocalStore.myAtprotoDid)
        if await writeCard(myCard ?? Card()) { return true }
        myAtprotoDid = previous
        store.save(previous, LocalStore.myAtprotoDid)
        return false
    }

    /// Step 3: the check a stranger makes — signed out, uncached. Nil when it could not be reached.
    func linkCheckAsStranger() async -> Bool? {
        guard let node = myNode, let did = myAtprotoDid else { return false }
        let ok = try? await bluesky.checkNow(node: node.username, did: did)
        if ok == true { await refreshFeed() }
        return ok
    }

    /// Unlink (§12.8): the card line first — attribution stops for every reader on their next read
    /// of the card — then the record.
    func unlinkBluesky() async {
        modal = nil
        guard let node = myNode, let did = myAtprotoDid else { return }
        myAtprotoDid = nil
        store.save(Optional<String>.none, LocalStore.myAtprotoDid)
        guard await writeCard(myCard ?? Card()) else {
            myAtprotoDid = did
            store.save(did, LocalStore.myAtprotoDid)
            return
        }
        bluesky.forgetLink(node: node.username, did: did)
        if bluesky.account?.did == did { try? await bluesky.deleteLinkRecord(node: node.username) }
        showToast(BlueskyCopy.unlinked)
        await refreshFeed()
    }

    /// §12.2 / §2.37: a §2-only client rewrote my card and dropped the line. Signed in to the same
    /// account with the record still in place, the line is restored — `Card repaired.`, the way
    /// §2.33 repairs `private.id`.
    func repairAtprotoDid(found: String?) async {
        guard found == nil, myCardState == .ok, let node = myNode, let did = bluesky.account?.did,
              let check = bluesky.linkCheck(node: node.username, did: did), check.verified else { return }
        guard (try? await bluesky.checkNow(node: node.username, did: did)) == true else { return }
        myAtprotoDid = did
        store.save(did, LocalStore.myAtprotoDid)
        if await writeCard(myCard ?? Card()) { showToast(BlueskyCopy.cardRepaired) }
    }

    // MARK: Safety (§2.40)

    /// Blocking a node whose link is verified writes its DID beside its username (§12.9), so
    /// their Bluesky posts stay gone however they arrive.
    func blueskyDidForBlock(_ username: String) -> String? {
        bluesky.verifiedDid(nodes.cachedNode(username))
    }

    func blockAccount(did: String, handle: String) {
        modal = nil
        moderation.block(did)
        showToast("Blocked \(handle).")
    }

    /// Settings' `Unblock` on an account row (§2.40). Unties the DID from any node block too.
    func unblockAccount(did: String, handle: String) {
        moderation.unblock(did)
        showToast("Unblocked \(handle).")
    }

    /// §2.40's Settings rows name an account by handle: a linked account's profile, else a post
    /// already in the feed. Nil until one of those knows it — the row shows the DID meanwhile.
    func blueskyHandle(did: String) -> String? {
        if let p = bluesky.profiles[did], !p.handle.isEmpty, p.handle != "handle.invalid" { return "@" + p.handle }
        return posts.lazy.compactMap(\.bluesky).first { $0.authorDid == did && $0.handleLabel != did }?.handleLabel
    }

    func muteAccount(did: String, handle: String) {
        modal = nil
        moderation.mute(sourceKey: did)
        showToast("Muted \(handle).")
    }

    func unmuteAccount(did: String, handle: String) {
        modal = nil
        moderation.unmute(sourceKey: did)
        showToast("Unmuted \(handle).")
    }

    // MARK: Cross-post (§12.8, §2.38)

    /// After the Telegram post succeeded. Refused before sending anything when too long — the
    /// sheet has already said so — and never retried (§2.38: a retry that posts twice is worse).
    func crossPost(text: String, photoPath: String?, sent: Message, feed info: FeedInfo) async -> String? {
        let link = DeepLink.post(username: info.username, messageId: sent.id)
        do {
            try await activity.run("Posting to Bluesky") {
                try await self.bluesky.crossPost(text: text, telegramLink: link, feedTitle: info.title, photoPath: photoPath)
            }
            return nil
        } catch {
            return (error as? AtprotoError)?.localizedDescription ?? error.localizedDescription
        }
    }
}
