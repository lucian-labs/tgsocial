// Repo — Bluesky, read into the feed (PROTOCOL.md §12, PRODUCT.md §2.35–§2.40).
//
// The app's one owner of everything atproto: the session (through `BlueskyAuth`), the §12.3 link
// cache, the two toggles, and the pages the §4.8 merge asks for. It is additive by construction —
// a reader who never opens Settings has no session, the tag off, and no request made unless a node
// they follow carries an `atproto.did` line (§2.35: "except that a node they follow may now carry
// Bluesky posts, which needs nothing from them").

import AuthenticationServices
import Foundation
import Observation
import UIKit

/// The signed-in account, as Settings shows it (§2.35).
struct BlueskyAccount: Codable, Equatable {
    var did: String
    var handle: String
    var displayName: String?
    var avatar: String?
    var handleLabel: String { handle.isEmpty || handle == "handle.invalid" ? did : "@" + handle }
}

/// §2.35's two toggles. The follows toggle starts ON after sign-in ("reading who you follow is the
/// reason to sign in"); the tag starts OFF because the tag is trollable by construction (§12.6).
struct BlueskyPrefs: Codable, Equatable {
    var followsOn = true
    var tagOn = false
}

/// §12.9's Bluesky blocks, stored with the account they were read from. Persisted so a session
/// restored at launch filters from its first refresh: read only at sign-in and held only in memory,
/// the list was empty after every relaunch and a blocked author came back through the tag.
struct BlueskyBlocks: Codable, Equatable {
    var did: String
    var dids: [String]
    var fetchedAt: Date
}

/// One atproto source in the merge (§12.5's table).
struct AtprotoSourceSpec: Equatable {
    let key: String
    let kind: Atproto.SourceKind
    /// For an author source: the node the DID is verified to — the label on the pending row.
    var label: String
}

/// What one page contributes to the merge (`FeedMerger.addAtprotoPage`).
struct AtprotoPage {
    var posts: [Post]
    var entryCount: Int
    var oldestFeedTime: Int?
    var cursor: String?
}

@MainActor
protocol AtprotoFeedSource: AnyObject {
    func page(_ source: AtprotoSourceSpec, cursor: String?) async throws -> AtprotoPage
    /// §12.5 Attribution: the node the author DID is verified to, by §2.3's rule; nil → the account.
    func attributedNode(did: String) -> NodeInfo?
}

@MainActor @Observable
final class BlueskyService {
    @ObservationIgnored let config: AtprotoClientConfig
    @ObservationIgnored let reader: AtprotoReader
    @ObservationIgnored let auth: BlueskyAuth
    @ObservationIgnored let oauth: AtprotoOAuth
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let activity: ActivityRegistry
    @ObservationIgnored private let vault: SessionVault
    @ObservationIgnored private let transport: HTTPTransport

    /// Signed in, or nil.
    private(set) var account: BlueskyAccount?
    /// §2.39: Bluesky ended the session. Settings shows `Signed out by Bluesky` with the handle, so
    /// `Sign In Again` can open with it filled in; the toast has been shown once.
    private(set) var endedHandle: String?
    var prefs: BlueskyPrefs { didSet { if prefs != oldValue { store.save(prefs, LocalStore.blueskyPrefs) } } }
    /// §12.3's cache, keyed `node|did`. Persisted beside the card cache; discardable (§7).
    private(set) var linkChecks: [String: LinkCheck] = [:]
    /// Handles, names and avatars for linked accounts (node profile row, §2.36).
    private(set) var profiles: [String: BlueskyAccount] = [:]
    /// The atproto sources in the current merge — the Status sheet's `N sources` (§2.35).
    private(set) var activeSources: [AtprotoSourceSpec] = []
    /// The last host that did not answer this pass (§2.39 `Can't reach <host>`); nil when all did.
    private(set) var unreachableHost: String?
    /// §12.9: authors the signed-in account blocks on Bluesky, from its public block records.
    @ObservationIgnored private(set) var blueskyBlocks = Set<String>()
    /// When `blueskyBlocks` was last read; nil means "read it on the next check".
    @ObservationIgnored private(set) var blocksFetchedAt: Date?
    /// The link checks and the block read in flight (`startChecks`), and a scope asked for meanwhile.
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var queuedScope: [NodeInfo]?
    /// First pages, reused inside §12.4's 60-second floor so a burst of refreshes is one read.
    @ObservationIgnored private var firstPages: [String: (at: Date, page: JSONValue)] = [:]
    /// The follows the merge attributes through, set with the sources.
    @ObservationIgnored private var scope: [NodeInfo] = []
    @ObservationIgnored private var webAuth: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = AuthAnchor()
    /// Called once when a read finds the session ended (§2.39's single toast).
    @ObservationIgnored var onSessionEnded: (() -> Void)?
    /// A background check changed what the merge would admit: one more feed pass, please.
    @ObservationIgnored var onSourcesChanged: (() -> Void)?
    /// Words for `Last error` (§2.39) that no toast carries — a refreshed session the Keychain refused.
    @ObservationIgnored var onError: ((String) -> Void)?

    static let minRefresh: TimeInterval = 60
    static let linkRecheck: TimeInterval = 24 * 3600
    /// How stale the block list may get before a check re-reads it. A block made on Bluesky reaches
    /// this feed within ten minutes; re-reading it on every 60 s refresh would add up to ten
    /// `listRecords` pages to each pass for a list that rarely moves (§12.4 cost).
    static let blocksRecheck: TimeInterval = 10 * 60

    init(store: LocalStore, activity: ActivityRegistry, config: AtprotoClientConfig = .fromBundle(),
         transport: HTTPTransport = URLSessionTransport.shared, vault: SessionVault = KeychainVault()) {
        self.store = store; self.activity = activity; self.config = config; self.vault = vault; self.transport = transport
        oauth = AtprotoOAuth(config: config, transport: transport)
        reader = AtprotoReader(transport: transport)
        auth = BlueskyAuth(oauth: oauth, vault: vault, transport: transport)
        prefs = store.load(BlueskyPrefs.self, LocalStore.blueskyPrefs) ?? BlueskyPrefs()
        linkChecks = store.load([String: LinkCheck].self, LocalStore.atprotoLinks) ?? [:]
        if let (session, _) = vault.load() {
            account = store.load(BlueskyAccount.self, Self.accountKey).flatMap { $0.did == session.did ? $0 : nil }
                ?? BlueskyAccount(did: session.did, handle: session.handle)
            // The restored session's blocks, if they are this account's; the first check refreshes them.
            if let saved = store.load(BlueskyBlocks.self, LocalStore.blueskyBlocks), saved.did == session.did {
                blueskyBlocks = Set(saved.dids)
                blocksFetchedAt = saved.fetchedAt
            }
        }
    }

    private static let accountKey = "blueskyAccount"
    var isSignedIn: Bool { account != nil }

    // MARK: Sign in (§12.7, §2.35)

    enum SignInError: Error, Equatable {
        case notFound, denied, failed(String), cancelled, rateLimited(Int)
    }

    /// The whole of §12.7 steps 1–9. Throws the §2.39 outcome; returns the account on success.
    func signIn(_ typed: String) async throws -> BlueskyAccount {
        do {
            let token = activity.begin("Finding your Bluesky server")
            let target: AuthTarget
            let key = DPoPKey.generate()
            let sender = DPoPSender(key: key, transport: transport)
            let pkce = PKCE.make()
            let state = Base64URL.encode(PKCE.randomBytes(16))
            let url: URL
            do {
                target = try await oauth.discover(typed)
                url = try await oauth.pushAuthorization(target, pkce: pkce, state: state, dpop: sender)
                activity.end(token)
            } catch { activity.end(token); throw error }
            let callback = try await openAuthorization(url)
            let code = try AtprotoOAuth.callbackCode(callback, state: state, issuer: target.metadata.issuer, redirectURI: config.redirectURI)
            let tokens = try await oauth.exchange(code: code, pkce: pkce, target: target, dpop: sender)
            let checked = try await oauth.verify(tokens, target: target)
            guard let refresh = tokens.refreshToken else { throw AtprotoError.authFailed("no refresh token") }
            let session = BlueskySession(did: checked.did, handle: checked.handle, pds: checked.pds, issuer: target.metadata.issuer,
                                         tokenEndpoint: target.metadata.tokenEndpoint, revocationEndpoint: target.metadata.revocationEndpoint,
                                         accessToken: tokens.accessToken, refreshToken: refresh,
                                         expiresAt: Date().addingTimeInterval(TimeInterval(tokens.expiresIn)), scope: tokens.scope,
                                         startedAt: Date())
            // Throws when the Keychain refuses the pair; the §2.39 `Couldn't sign in` path, with the
            // OSStatus in `Last error`, instead of a session that is gone at the next launch.
            try await auth.install(session, sender: sender)
            var acct = BlueskyAccount(did: checked.did, handle: checked.handle)
            account = acct
            endedHandle = nil
            prefs.followsOn = true
            store.save(acct, Self.accountKey)
            if let profile = try? await reader.appView("app.bsky.actor.getProfile", [("actor", checked.did)]) {
                acct.displayName = profile["displayName"].string
                acct.avatar = profile["avatar"].string
                if let h = profile["handle"].string, h != "handle.invalid" { acct.handle = h }
                account = acct
                store.save(acct, Self.accountKey)
            }
            await refreshBlocks()
            return acct
        } catch let e as AtprotoError {
            switch e {
            case .cancelled: throw SignInError.cancelled
            case .accountNotFound: throw SignInError.notFound
            case .authorizationDenied: throw SignInError.denied
            case .rateLimited(let s): throw SignInError.rateLimited(s)
            default: throw SignInError.failed(e.localizedDescription)
            }
        }
    }

    private func openAuthorization(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: config.callbackScheme) { callback, error in
                if let callback { cont.resume(returning: callback); return }
                if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
                    cont.resume(throwing: AtprotoError.cancelled); return
                }
                cont.resume(throwing: AtprotoError.authorizationDenied(error?.localizedDescription ?? "no callback"))
            }
            session.presentationContextProvider = anchor
            // Non-ephemeral: an existing bsky.social login is reused (§12.7 step 6).
            session.prefersEphemeralWebBrowserSession = false
            webAuth = session
            if !session.start() { cont.resume(throwing: AtprotoError.authFailed("Couldn't open Bluesky.")) }
        }
    }

    /// `Sign Out of Bluesky` (§2.35): revoke, then forget. The link stays — it is two public lines.
    func signOut() async {
        await auth.signOut()
        clearAccount()
    }

    /// Telegram `logOut` (§7): the session is local state and goes with the rest, no revoke call
    /// needed to leave the device clean — but it is made, best effort, so the token dies too.
    func endForTelegramSignOut() async {
        stopChecks()
        await auth.signOut()
        clearAccount()
        endedHandle = nil
        discardLocalState()
    }

    /// Everything here that is §7 local state and not the session, dropped from memory the way the
    /// app's wipe (`LocalStore.clear`) drops it from disk. Clearing only the file left the toggles
    /// in memory, so the next person to sign in to Telegram in the same run inherited the last
    /// one's `#waveloop` source — off by default (§2.35) because it is trollable.
    func discardLocalState() {
        stopChecks()
        prefs = BlueskyPrefs()
        linkChecks = [:]; profiles = [:]; firstPages = [:]; activeSources = []; scope = []
        unreachableHost = nil
        // The file is about to go with the rest; the next check reads the list again and stores it.
        blocksFetchedAt = nil
    }

    private func clearAccount() {
        account = nil
        blueskyBlocks = []
        blocksFetchedAt = nil
        firstPages.removeValue(forKey: Atproto.sourceKey(.following))
        store.save(Optional<BlueskyAccount>.none, Self.accountKey)
        store.save(Optional<BlueskyBlocks>.none, LocalStore.blueskyBlocks)
    }

    /// §2.39: a read found the session over. Once.
    private func sessionEnded() {
        guard let acct = account else { return }
        endedHandle = acct.handle
        clearAccount()
        onSessionEnded?()
    }

    // MARK: §12.3 links

    private static func linkKey(_ node: String, _ did: String) -> String { Username.key(node) + "|" + did }

    /// The DID this node is verified to, or nil — and nil is how an unverified link renders:
    /// exactly as no link (§12.3).
    func verifiedDid(_ node: NodeInfo?) -> String? {
        guard let node, let did = node.atprotoDid, let check = linkChecks[Self.linkKey(node.username, did)], check.verified else { return nil }
        return did
    }

    /// For the owner's pending states (§2.37): the cached answer, whatever it is.
    func linkCheck(node: String, did: String) -> LinkCheck? { linkChecks[Self.linkKey(node, did)] }

    /// Re-checks every node whose card names a DID: whenever its card was re-read since the last
    /// check, and at most once a day otherwise (§12.3 Caching). A definitive answer takes effect at
    /// once; no answer keeps a previous VERIFIED result for at most 24 h from its `fetchedAt`, and
    /// never turns a link verified.
    func refreshLinks(_ nodes: [NodeInfo], now: Date = Date()) async {
        var pending: [String: UUID] = [:]
        var answers: [(key: String, result: LinkCheck?, answered: Bool)] = []
        await withTaskGroup(of: (String, LinkCheck?, Bool).self) { group in
            for node in nodes {
                guard let did = node.atprotoDid else { continue }
                let key = Self.linkKey(node.username, did)
                let previous = linkChecks[key]
                if let previous, previous.fetchedAt >= node.fetchedAt, now.timeIntervalSince(previous.fetchedAt) < Self.linkRecheck { continue }
                // One check per (node, DID) per pass, however often the node appears in scope.
                guard pending[key] == nil else { continue }
                let username = node.username
                let reader = self.reader
                // PRODUCT §2.35's pending row, ended when the answer comes back below.
                pending[key] = activity.begin("Checking @\(username)'s Bluesky link")
                group.addTask {
                    do {
                        let ok = try await reader.checkLink(did: did, node: username)
                        return (key, LinkCheck(did: did, node: Username.key(username), verified: ok, fetchedAt: now), true)
                    } catch {
                        return (key, nil, false)
                    }
                }
            }
            for await (key, result, answered) in group {
                if let token = pending.removeValue(forKey: key) { activity.end(token) }
                answers.append((key, result, answered))
            }
        }
        // A Telegram sign-out while the checks were out cancelled them: its wipe stands, and
        // nothing is written back into the cache it just emptied.
        guard !Task.isCancelled else { return }
        for (key, result, answered) in answers {
            if answered { linkChecks[key] = result; continue }
            if let previous = linkChecks[key], previous.verified, now.timeIntervalSince(previous.fetchedAt) < Self.linkRecheck { continue }
            linkChecks.removeValue(forKey: key)
        }
        store.save(linkChecks, LocalStore.atprotoLinks)
    }

    /// The pairs in `scope` whose link is verified right now — what `startChecks` compares.
    private func verifiedLinks(_ scope: [NodeInfo]) -> Set<String> {
        Set(scope.compactMap { node in verifiedDid(node).map { Self.linkKey(node.username, $0) } })
    }

    // MARK: Background checks (§12.5 rule 6)

    /// The §12.3 link checks and the §12.9 block read, run BESIDE the feed refresh and never in
    /// front of it. Awaited in front, one PDS or plc.directory that accepted a connection and never
    /// answered held every reader's Telegram feed for the 20 s timeout per batch of four links —
    /// readers who never signed in included, as soon as they follow a linked node. The merge takes
    /// its sources from the cache as it stands; when a check changes what the merge would admit (a
    /// link verified or dropped, a block added or lifted), `onSourcesChanged` asks for one more pass.
    /// One run at a time; a scope asked for while one is out runs right after it, so a follow made
    /// meanwhile is not skipped.
    func startChecks(_ scope: [NodeInfo]) {
        if checking != nil { queuedScope = scope; return }
        let links = verifiedLinks(scope)
        let blocks = blueskyBlocks
        checking = Task { [weak self] in
            await self?.refreshLinks(scope)
            await self?.refreshBlocksIfDue()
            guard let self, !Task.isCancelled else { return }
            self.checking = nil
            let changed = self.verifiedLinks(scope) != links || self.blueskyBlocks != blocks
            if let next = self.queuedScope { self.queuedScope = nil; self.startChecks(next) }
            if changed { self.onSourcesChanged?() }
        }
    }

    /// Waits out the checks in flight. Nothing in the app waits on them; the tests do.
    func settleChecks() async {
        while let task = checking { await task.value }
    }

    private func stopChecks() {
        checking?.cancel()
        checking = nil
        queuedScope = nil
    }

    /// §12.8 step 3 — the check a stranger would make, now, uncached.
    func checkNow(node: String, did: String) async throws -> Bool {
        let ok = try await reader.checkLink(did: did, node: node)
        linkChecks[Self.linkKey(node, did)] = LinkCheck(did: did, node: Username.key(node), verified: ok, fetchedAt: Date())
        store.save(linkChecks, LocalStore.atprotoLinks)
        return ok
    }

    func forgetLink(node: String, did: String) {
        linkChecks.removeValue(forKey: Self.linkKey(node, did))
        store.save(linkChecks, LocalStore.atprotoLinks)
    }

    /// Handle, name and avatar of a linked account, fetched once (§2.36's profile row).
    func profile(_ did: String) async -> BlueskyAccount? {
        if let hit = profiles[did] { return hit }
        guard let p = try? await reader.appView("app.bsky.actor.getProfile", [("actor", did)]) else { return nil }
        let acct = BlueskyAccount(did: did, handle: p["handle"].string ?? "", displayName: p["displayName"].string, avatar: p["avatar"].string)
        profiles[did] = acct
        return acct
    }

    // MARK: §12.9 Bluesky blocks

    /// Reads the list and stores it with the account. A failed read keeps the list it had.
    func refreshBlocks(now: Date = Date()) async {
        guard let session = await auth.session else { blueskyBlocks = []; blocksFetchedAt = nil; return }
        guard let set = try? await reader.blockedDids(of: session.did, pds: session.pds),
              !Task.isCancelled, account?.did == session.did else { return }
        blueskyBlocks = set
        blocksFetchedAt = now
        store.save(BlueskyBlocks(did: session.did, dids: set.sorted(), fetchedAt: now), LocalStore.blueskyBlocks)
    }

    /// Blocks made on Bluesky after sign-in are picked up here, at most `blocksRecheck` late.
    func refreshBlocksIfDue(now: Date = Date()) async {
        guard isSignedIn else { return }
        if let at = blocksFetchedAt, now.timeIntervalSince(at) < Self.blocksRecheck { return }
        await refreshBlocks(now: now)
    }

    // MARK: §12.5 sources

    /// The atproto sources for this pass: the author source of every verified link on my node and
    /// on the nodes I follow; the following source while signed in with the toggle on; the tag when
    /// on. `scope` is me first, then my follows in `follows:` order — §2.3's attribution order.
    func sources(scope: [NodeInfo], isBlocked: (String) -> Bool) -> [AtprotoSourceSpec] {
        self.scope = scope
        var out: [AtprotoSourceSpec] = []
        var seen = Set<String>()
        for node in scope {
            guard let did = verifiedDid(node), !isBlocked(did), !isBlocked(node.username), seen.insert(did).inserted else { continue }
            out.append(AtprotoSourceSpec(key: Atproto.sourceKey(.author(did: did)), kind: .author(did: did), label: "@" + node.username))
        }
        if isSignedIn, prefs.followsOn {
            out.append(AtprotoSourceSpec(key: Atproto.sourceKey(.following), kind: .following, label: "your Bluesky follows"))
        }
        if prefs.tagOn {
            out.append(AtprotoSourceSpec(key: Atproto.sourceKey(.tag(Atproto.tag)), kind: .tag(Atproto.tag), label: "#" + Atproto.tag))
        }
        activeSources = out
        unreachableHost = nil
        return out
    }
}

// MARK: - The merge's reads

extension BlueskyService: AtprotoFeedSource {
    func attributedNode(did: String) -> NodeInfo? {
        scope.first { verifiedDid($0) == did }
    }

    func page(_ source: AtprotoSourceSpec, cursor: String?) async throws -> AtprotoPage {
        let raw: JSONValue
        do {
            raw = try await activity.run(Self.pendingLabel(source)) { try await self.rawPage(source, cursor: cursor) }
            await surfaceVaultFailure()
        } catch {
            await surfaceVaultFailure()
            if let e = error as? AtprotoError {
                if e == .sessionEnded { sessionEnded() }
                if let host = e.host { unreachableHost = host }
            }
            throw error
        }
        let entries = raw["feed"].array ?? raw["posts"].array ?? []
        var oldest: Int?
        var posts: [Post] = []
        for entry in entries {
            if let t = Atproto.feedTime(entry) { oldest = min(oldest ?? t, t) }
            let admitted: Atproto.Item?
            if case .tag = source.kind { admitted = Atproto.tagItem(entry) } else { admitted = Atproto.item(entry) }
            guard let item = admitted, !blueskyBlocks.contains(item.did) else { continue }
            // §12.5 rule 7: the copy of a Telegram post the reader already has renders once.
            if let node = attributedNode(did: item.did), Atproto.crossPostTarget(item.post, nodeFeeds: node.card?.feeds ?? []) != nil { continue }
            posts.append(BlueskyMapping.post(item, sourceKey: source.key))
        }
        let next = raw["cursor"].string
        return AtprotoPage(posts: posts, entryCount: entries.count, oldestFeedTime: oldest, cursor: next?.isEmpty == false ? next : nil)
    }

    /// A refresh inside that read whose new pair the Keychain refused (`BlueskyAuth.refresh`).
    private func surfaceVaultFailure() async {
        if let message = await auth.takeVaultFailure() { onError?(message) }
    }

    /// §2.35's pending rows.
    static func pendingLabel(_ source: AtprotoSourceSpec) -> String {
        switch source.kind {
        case .author: return "Loading \(source.label) on Bluesky"
        case .following: return "Loading your Bluesky follows"
        case .tag(let t): return "Loading #\(t) on Bluesky"
        }
    }

    private func rawPage(_ source: AtprotoSourceSpec, cursor: String?) async throws -> JSONValue {
        if cursor == nil, let hit = firstPages[source.key], Date().timeIntervalSince(hit.at) < Self.minRefresh { return hit.page }
        var params: [(String, String)] = [("limit", "30")]
        if let cursor { params.append(("cursor", cursor)) }
        let page: JSONValue
        switch source.kind {
        case .author(let did):
            // Never `includePins`: a pinned post would head the source forever (§12.4).
            page = try await reader.appView("app.bsky.feed.getAuthorFeed", [("actor", did), ("filter", "posts_no_replies")] + params)
        case .following:
            page = try await reader.limited { try await self.auth.get("app.bsky.feed.getTimeline", params, proxy: true) }
        case .tag(let t):
            let q: [(String, String)] = [("q", "#" + t), ("sort", "latest")] + params
            if isSignedIn, let viaPds = try? await reader.limited({ try await self.auth.get("app.bsky.feed.searchPosts", q, proxy: true) }) {
                page = viaPds
            } else {
                page = try await reader.appView("app.bsky.feed.searchPosts", q)
            }
        }
        if cursor == nil { firstPages[source.key] = (Date(), page) }
        return page
    }
}

// MARK: - Writes (§12.8)

extension BlueskyService {
    /// Link step 1: `putRecord`, not `createRecord`, so doing it twice is doing it once.
    func putLinkRecord(node: String) async throws {
        guard let session = await auth.session, let key = Atproto.linkRecordKey(node),
              let record = Atproto.linkRecord(node: node, createdAt: BlueskyText.iso(Date())) else { throw AtprotoError.sessionEnded }
        _ = try await auth.post("com.atproto.repo.putRecord", .object([
            "repo": .string(session.did), "collection": .string(Atproto.linkCollection),
            "rkey": .string(key), "record": record]))
        await surfaceVaultFailure()
    }

    /// Unlink's second half, after the card line is gone.
    func deleteLinkRecord(node: String) async throws {
        guard let session = await auth.session, let key = Atproto.linkRecordKey(node) else { throw AtprotoError.sessionEnded }
        _ = try await auth.post("com.atproto.repo.deleteRecord", .object([
            "repo": .string(session.did), "collection": .string(Atproto.linkCollection), "rkey": .string(key)]))
        await surfaceVaultFailure()
    }

    /// The cross-post (§12.8): text + facets + an external embed back to the Telegram original,
    /// with the photo as its thumb — JPEG, re-encoded down until it is at most 1,000,000 bytes.
    func crossPost(text: String, telegramLink: String, feedTitle: String, photoPath: String?) async throws {
        guard let session = await auth.session else { throw AtprotoError.sessionEnded }
        var thumb: JSONValue?
        if let photoPath, let jpeg = Self.jpegUnderLimit(path: photoPath) {
            thumb = try await auth.uploadBlob(jpeg, mimeType: "image/jpeg")
        }
        let record = BlueskyText.postRecord(text: text, telegramLink: telegramLink, feedTitle: feedTitle, thumb: thumb)
        _ = try await auth.post("com.atproto.repo.createRecord", .object([
            "repo": .string(session.did), "collection": .string(Atproto.postCollection), "record": record]))
        await surfaceVaultFailure()
    }

    static let maxThumbBytes = 1_000_000

    nonisolated static func jpegUnderLimit(path: String) -> Data? {
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        var current = image
        var quality: CGFloat = 0.85
        for _ in 0..<12 {
            if let data = current.jpegData(compressionQuality: quality), data.count <= maxThumbBytes { return data }
            if quality > 0.5 { quality -= 0.15; continue }
            let size = CGSize(width: current.size.width * 0.75, height: current.size.height * 0.75)
            current = UIGraphicsImageRenderer(size: size).image { _ in current.draw(in: CGRect(origin: .zero, size: size)) }
        }
        return nil
    }
}

/// The window Bluesky's page is presented over.
private final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first.map { UIWindow(windowScene: $0) } ?? ASPresentationAnchor()
    }
}
