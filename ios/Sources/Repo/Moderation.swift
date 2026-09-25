// Repo — the safety lists (PROTOCOL.md §7.1) and the filter they feed (PRODUCT.md §2.18).
//
// There is no server (PROTOCOL §1), so block, mute and report are one local record and a filter
// applied at render. The record is stored apart from every cache because a cache bump must never
// discard someone's block list, and it survives sign-out for the same account — a list that
// evaporated would re-expose the reader to the person they blocked the next time they signed in.
//
// Nothing here is published: never written to the card, never sent to Telegram, never notified to
// the blocked node. The only thing that leaves the device is the report email (see Mail.swift),
// which carries a link and a reason and nothing about any list.

import Foundation
import Observation

/// One reported post or comment (PROTOCOL §7.1). `reason` is the §2.15 string verbatim so Settings
/// can say what was reported without keeping a copy of the content.
struct HiddenItem: Codable, Equatable, Hashable {
    /// The §6.2 target key, `<channel>/<messageId>`, lowercased.
    var key: String
    var reason: String
    /// ISO 8601 UTC.
    var at: String
}

/// The record (PROTOCOL §7.1). Field names are the wire shape shared with Android and web — the
/// same JSON is read by all three, so they are spelled here exactly as they are spelled there.
struct SafetyLists: Codable, Equatable {
    /// This record's own version, deliberately NOT `LocalStore.schemaVersion` (PRODUCT §2.3).
    var v: Int
    /// The Telegram user id that wrote the record, `0` for none (`null` on the wire). With `did`,
    /// the keys §7.1 compares whenever a network signs in — a record whose keys all belong to
    /// accounts that are not here is emptied rather than handed to someone else on a shared device.
    var userId: Int64
    /// PROTOCOL §7.1: the Bluesky DID of a §12.7 session that wrote the record, or nil. One record
    /// for both networks, so a block made signed in to one survives the other joining.
    var did: String?
    /// Node usernames, lowercased, no `@`.
    var blocked: [String]
    /// Feed channel usernames, lowercased, no `@`.
    var mutedFeeds: [String]
    var hidden: [HiddenItem]

    static let currentVersion = 1

    init(v: Int = SafetyLists.currentVersion, userId: Int64 = 0, did: String? = nil,
         blocked: [String] = [], mutedFeeds: [String] = [], hidden: [HiddenItem] = []) {
        self.v = v; self.userId = userId; self.did = did
        self.blocked = blocked; self.mutedFeeds = mutedFeeds; self.hidden = hidden
    }

    /// Every field defaulted. "Unknown `v` is read as best it can be and never dropped" (PROTOCOL
    /// §7.1): a record written by a later version whose shape moved on still yields the lists it
    /// does carry, instead of throwing and taking a block list with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, or fallback: T) -> T {
            ((try? c.decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
        }
        v = value(Int.self, .v, or: Self.currentVersion)
        userId = value(Int64.self, .userId, or: 0)
        // Absent reads as null: every record written before §12.11 has no `did`.
        did = (try? c.decodeIfPresent(String.self, forKey: .did)) ?? nil
        blocked = value([String].self, .blocked, or: [])
        mutedFeeds = value([String].self, .mutedFeeds, or: [])
        hidden = value([HiddenItem].self, .hidden, or: [])
    }

    /// Every field, under the spec's names. `userId` 0 goes out as `null` — a Bluesky-only
    /// reader's record has no Telegram id (PROTOCOL §12.11) — and `did` as `null` when unset, so
    /// Android and web read one shape whichever network wrote it.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        if userId == 0 { try c.encodeNil(forKey: .userId) } else { try c.encode(userId, forKey: .userId) }
        if let did { try c.encode(did, forKey: .did) } else { try c.encodeNil(forKey: .did) }
        try c.encode(blocked, forKey: .blocked)
        try c.encode(mutedFeeds, forKey: .mutedFeeds)
        try c.encode(hidden, forKey: .hidden)
    }

    private enum CodingKeys: String, CodingKey { case v, userId, did, blocked, mutedFeeds, hidden }

    var isEmpty: Bool { blocked.isEmpty && mutedFeeds.isEmpty && hidden.isEmpty }

    /// PROTOCOL §7.1's table, as a value: what the record becomes when these keys are held. `nil`
    /// for a network not signed in — its field neither matches nor conflicts.
    func adopted(userId held: Int64?, did heldDid: String?) -> SafetyLists {
        let tg = held.flatMap { $0 == 0 ? nil : $0 }
        let bs = heldDid.flatMap(Atproto.normaliseDid)
        guard tg != nil || bs != nil else { return self }
        let matches = (tg != nil && userId == tg) || (bs != nil && did.flatMap(Atproto.normaliseDid) == bs)
        let keyed = userId != 0 || did != nil
        var next = self
        if !matches, keyed {
            // Replace: every key belongs to an account that is not here — someone else's judgement.
            next = SafetyLists(v: v)
        }
        // Keep (a key matched) and adopt (no key at all) both keep the lists; all three write every
        // held key into its field and leave a field whose network is not held as it was.
        if let tg { next.userId = tg }
        if let bs { next.did = bs }
        return next
    }
}

// MARK: - Queries

extension SafetyLists {
    /// Compared through `Username.key`, the card parser's own normalisation: Telegram usernames are
    /// case-insensitive and a list that missed `@TGS_Ana` would be a filter with a hole in it.
    func isBlocked(_ username: String?) -> Bool {
        guard let username else { return false }
        return blocked.contains(Moderation.listKey(username))
    }

    func isMuted(feed username: String?) -> Bool {
        guard let username else { return false }
        return mutedFeeds.contains(Moderation.listKey(username))
    }

    /// A source key as `FeedInfo.key` / `Post.sourceKey` spell it — a username key or `c/<id>`.
    func isMuted(sourceKey: String) -> Bool {
        mutedFeeds.contains(sourceKey.lowercased())
    }

    func isHidden(key: String?) -> Bool {
        guard let key else { return false }
        return hidden.contains { $0.key == key.lowercased() }
    }
}

// MARK: - The filter (PRODUCT §2.18)

extension SafetyLists {
    /// A post is dropped when its attributed node is blocked, when it was reported, and — on the
    /// main feed only — when it comes from a muted feed. Nothing is left behind: no tombstone, no
    /// placeholder, no residue in a count.
    func allows(post: Post, inMainFeed: Bool) -> Bool {
        if isBlocked(post.authorUsername) { return false }
        // PROTOCOL §12.9: a Bluesky post is blocked by its author's DID too — how a blocked node's
        // posts stay gone when they arrive through the follows source or the tag, or after the card
        // line is dropped — and an account with no node is blocked by DID alone.
        if let b = post.bluesky, blocked.contains(b.authorDid.lowercased()) { return false }
        if isHidden(key: Moderation.key(post: post)) { return false }
        if inMainFeed, isMuted(sourceKey: Moderation.muteKey(post: post)) { return false }
        return true
    }

    func filtered(posts: [Post], inMainFeed: Bool) -> [Post] {
        posts.filter { allows(post: $0, inMainFeed: inMainFeed) }
    }

    /// Comments, transitively. A reply whose parent was dropped would otherwise render flat at the
    /// top of the thread (`CommentTree.rows` promotes orphans), which is exactly the blocked node's
    /// words back on screen one indent to the left — so replies under a dropped comment go too.
    func filtered(comments: [Comment]) -> [Comment] {
        guard !blocked.isEmpty || !hidden.isEmpty else { return comments }
        var kept: [Comment] = []
        var droppedKeys = Set<String>()
        for c in comments where isBlocked(c.ownerUsername) || isHidden(key: Moderation.key(comment: c)) {
            if let key = CommentCodec.targetKey(c.link) { droppedKeys.insert(key) }
        }
        kept = comments.filter { !isBlocked($0.ownerUsername) && !isHidden(key: Moderation.key(comment: $0)) }
        guard !droppedKeys.isEmpty else { return kept }
        var settled = false
        while !settled {
            settled = true
            var next: [Comment] = []
            for c in kept {
                if let target = c.targetKey, droppedKeys.contains(target) {
                    if let key = CommentCodec.targetKey(c.link) { droppedKeys.insert(key) }
                    settled = false
                } else {
                    next.append(c)
                }
            }
            kept = next
        }
        return kept
    }

    /// Vouches (PRODUCT §2.25). No transitive pass: a vouch points at a node, never at another
    /// vouch, so there is no chain for a dropped one to orphan.
    func filtered(vouches: [Vouch]) -> [Vouch] {
        guard !blocked.isEmpty || !hidden.isEmpty else { return vouches }
        return vouches.filter { !isBlocked($0.ownerUsername) && !isHidden(key: Moderation.key(vouch: $0)) }
    }

    /// Explore rows, both graph lists, the +1 walk (PRODUCT §2.16).
    func filtered(nodes: [NodeInfo]) -> [NodeInfo] {
        blocked.isEmpty ? nodes : nodes.filter { !isBlocked($0.username) }
    }

    func filtered(entries: [DirectoryEntry]) -> [DirectoryEntry] {
        blocked.isEmpty ? entries : entries.filter { !isBlocked($0.node.username) }
    }

    /// The graph's edges: a blocked node is neither an endpoint nor a neighbour.
    func filtered(edges: [String: [String]]) -> [String: [String]] {
        guard !blocked.isEmpty else { return edges }
        var out: [String: [String]] = [:]
        for (key, list) in edges where !isBlocked(key) {
            out[key] = list.filter { !isBlocked($0) }
        }
        return out
    }
}

// MARK: - Keys, reasons, and the delete-confirm match

enum Moderation {
    /// The published address (PRODUCT §2.19, docs/PRIVACY.md).
    static let contactAddress = "elijah@lucianlabs.ca"

    /// PRODUCT §2.15: the whole list, in this order, on every platform. They are the email's
    /// subject line verbatim, which is what keeps them from being reworded per build.
    static let reasons = [
        "Spam",
        "Nudity or sexual content",
        "Violence or threats",
        "Hate or harassment",
        "Child safety",
        "Illegal content",
        "Something else",
    ]

    /// A list entry (PROTOCOL §7.1): lowercased, no `@`. One place enforces the shape, so a
    /// `@TGS_Ana` typed anywhere lands on the list as `tgs_ana` and matches like everything else.
    static func listKey(_ username: String) -> String {
        Username.key(Username.normalise(username) ?? username)
    }

    /// The §6.2 target key, `<channel>/<messageId>` lowercased — the same string a `re:` line
    /// resolves to, so one lookup filters a hidden post and a hidden comment alike.
    static func key(channel: String, serverMessageId: Int64) -> String {
        listKey(channel) + "/" + String(serverMessageId)
    }

    /// From a `t.me` post link; nil when the link is not one.
    static func key(link: String) -> String? {
        guard let (username, id) = CommentCodec.components(of: link) else { return nil }
        return key(channel: username, serverMessageId: id)
    }

    /// A private post keys as `c/<supergroupId>/<serverMessageId>` (PROTOCOL §7.2): the `t.me/c/`
    /// path without the host, which no username can collide with, and which an older client's
    /// username comparison never matches — the correct result, since it could not read the post.
    static func key(post: Post) -> String {
        // PROTOCOL §12.9: a Bluesky post's hidden key is its at-uri. A `:` never occurs in a
        // username or a `c/` key, so nothing collides and an older client simply never matches.
        if let b = post.bluesky { return Atproto.postKey(b.uri) ?? b.uri.lowercased() }
        if let id = post.privateSupergroupId {
            return PrivateLink.hiddenKey(supergroupId: id, serverMessageId: DeepLink.serverMessageId(post.messageId))
        }
        return key(channel: post.sourceUsername, serverMessageId: DeepLink.serverMessageId(post.messageId))
    }

    /// What `mutedFeeds` holds for a post's source: its username key, or `c/<id>` for a private
    /// channel (PROTOCOL §7.2).
    static func muteKey(post: Post) -> String {
        // §12.9: an account's DID in `mutedFeeds` takes its posts out of the merged feed.
        if let b = post.bluesky { return b.authorDid.lowercased() }
        if let id = post.privateSupergroupId { return PrivateLink.sourceKey(supergroupId: id) }
        return listKey(post.sourceUsername)
    }

    static func key(comment: Comment) -> String {
        key(channel: comment.channelUsername, serverMessageId: DeepLink.serverMessageId(comment.messageId))
    }

    static func key(vouch: Vouch) -> String {
        key(channel: vouch.channelUsername, serverMessageId: DeepLink.serverMessageId(vouch.messageId))
    }

    /// The date Settings shows on a hidden row (PRODUCT §2.20: `Spam · reported 2026-09-04`). The
    /// stored value is ISO 8601 UTC, so its own date part is the answer — reformatting it through
    /// the device calendar would move the row's date under a reader who travels.
    static func reportedDate(_ at: String) -> String {
        let date = String(at.prefix(10))
        return date.count == 10 ? date : at
    }

    /// PRODUCT §2.21: "case-insensitive and tolerates a missing `@`".
    static func confirmsDelete(_ typed: String, username: String) -> Bool {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("@") { s.removeFirst() }
        guard !s.isEmpty else { return false }
        return Username.key(s) == Username.key(username)
    }
}

// MARK: - The store

/// Owns the record and writes it through on every change. Observable, so a block repaints every
/// surface on the next render without anything having to reload (PRODUCT §2.18).
@MainActor @Observable
final class ModerationStore {
    @ObservationIgnored private let store: LocalStore
    private(set) var lists: SafetyLists
    /// PROTOCOL §12.9: node key → the DID that node's block wrote beside it, so `Unblock` lifts both
    /// whatever has happened to the link since. Asking the link at unblock time instead failed
    /// exactly when it mattered: once the card line was dropped, the cache lapsed or a sign-out
    /// emptied it, the DID stayed blocked with nothing left that knew why. Follows the record's
    /// life — same demo rule, same `adopt`, same survival of sign-out (`LocalStore.clear`).
    private(set) var blockedWith: [String: String]

    /// PROTOCOL §7.1: "The demo has no user id, and no home."
    ///
    /// Block, mute and report are real in the demo (PRODUCT §2.22.2) and have to survive a screen
    /// change, so the demo keeps a record of the same shape — in memory, with no user id — and a
    /// record with no user id is never written to `moderation.json`. The reverse holds too: the
    /// stored record is not loaded into a demo session. Both directions matter. A demo block of
    /// `@tgs_demo_crate` must not turn up in a real account's list, and a real block list is not a
    /// demo's to show.
    private(set) var isDemo = false

    /// `userId` is `Int64` on this platform, and `0` is already what the record means by "written
    /// before there was an id" — `adopt` reads it that way. A demo record carries it and never
    /// reaches disk, so the two can never be confused for one another.
    static let noUserId: Int64 = 0

    init(store: LocalStore) {
        self.store = store
        lists = store.load(SafetyLists.self, LocalStore.moderation) ?? SafetyLists()
        blockedWith = store.load([String: String].self, LocalStore.blockedWith) ?? [:]
    }

    /// Swaps the reader's record out for an empty one that has no home. The stored record is not
    /// held anywhere here — `leaveDemo` re-reads it from disk, which it never stopped being.
    func enterDemo() {
        isDemo = true
        lists = SafetyLists(userId: Self.noUserId)
        blockedWith = [:]
    }

    func leaveDemo() {
        isDemo = false
        lists = store.load(SafetyLists.self, LocalStore.moderation) ?? SafetyLists()
        blockedWith = store.load([String: String].self, LocalStore.blockedWith) ?? [:]
    }

    private func save() {
        guard !isDemo else { return }
        store.save(lists, LocalStore.moderation)
        store.save(blockedWith.isEmpty ? nil : blockedWith, LocalStore.blockedWith)
    }

    // Queries the views ask through the model.
    func isBlocked(_ username: String?) -> Bool { lists.isBlocked(username) }
    func isMuted(feed username: String?) -> Bool { lists.isMuted(feed: username) }
    func isHidden(key: String?) -> Bool { lists.isHidden(key: key) }

    /// PROTOCOL §7.1: whenever a network becomes signed in — `authorizationStateReady`, a completed
    /// Bluesky sign-in, a launch that finds either held — the record's keys are compared with the
    /// held ones (`SafetyLists.adopted`). One key matching is the same person, and the lists follow
    /// them onto the second network; no key matching a keyed record empties it — the record survives
    /// sign-out for the same person, not for the next one to sign in on this device.
    func adopt(userId: Int64?, did: String?) {
        // A demo is signed in to nothing, so this cannot fire from inside one; the guard says so
        // rather than relying on that.
        guard !isDemo else { return }
        let next = lists.adopted(userId: userId, did: did)
        guard next != lists else { return }
        lists = next
        // A replaced record takes its node → DID pairs with it (they are the half of a block that
        // remembers which DID it wrote); with no block left there is nothing for one to describe.
        if next.blocked.isEmpty { blockedWith = [:] }
        save()
    }

    /// Telegram alone — the shape every caller had before §12.11.
    func adopt(userId: Int64) { adopt(userId: userId, did: nil) }

    /// `did` is the node's verified Bluesky account (PROTOCOL §12.9), written beside it. A DID that
    /// is already on the list because of another node's block is tied to this node too, so it stays
    /// until both are unblocked. One that was blocked on its own is not tied to any node: unblocking
    /// the node leaves it where the reader put it.
    func block(_ username: String, did: String? = nil) {
        let key = Moderation.listKey(username)
        var changed = false
        if !lists.blocked.contains(key) { lists.blocked.append(key); changed = true }
        if let did = Atproto.normaliseDid(did).map(Moderation.listKey), did != key {
            if !lists.blocked.contains(did) {
                lists.blocked.append(did)
                blockedWith[key] = did
                changed = true
            } else if blockedWith.values.contains(did), blockedWith[key] != did {
                blockedWith[key] = did
                changed = true
            }
        }
        if changed { save() }
    }

    /// A node or a DID. A node takes the DID its block wrote with it (`Unblock` lifts both, §12.9),
    /// unless another blocked node wrote the same one — one DID may be linked from several nodes
    /// (§12.3). A DID lifted on its own row unties it from every node.
    func unblock(_ username: String) {
        let key = Moderation.listKey(username)
        var lift: Set<String> = [key]
        if let did = blockedWith.removeValue(forKey: key), !blockedWith.values.contains(did) { lift.insert(did) }
        blockedWith = blockedWith.filter { $0.value != key }
        lists.blocked.removeAll { lift.contains($0) }
        save()
    }

    func mute(feed username: String) { mute(sourceKey: Moderation.listKey(username)) }

    func unmute(feed username: String) { unmute(sourceKey: Moderation.listKey(username)) }

    /// PROTOCOL §7.2: a private channel is muted by its `c/<id>` key. Same list, second grammar.
    func mute(sourceKey: String) {
        let key = sourceKey.lowercased()
        guard !lists.mutedFeeds.contains(key) else { return }
        lists.mutedFeeds.append(key)
        save()
    }

    func unmute(sourceKey: String) {
        let key = sourceKey.lowercased()
        guard lists.mutedFeeds.contains(key) else { return }
        lists.mutedFeeds.removeAll { $0 == key }
        save()
    }

    /// PRODUCT §2.15: hiding is immediate and unconditional — it does not wait on the mail being
    /// sent, because the app cannot know whether it was and the reader has already said they do
    /// not want to see it.
    func hide(key: String, reason: String, at: Foundation.Date = Foundation.Date()) {
        let key = key.lowercased()
        lists.hidden.removeAll { $0.key == key }
        lists.hidden.append(HiddenItem(key: key, reason: reason, at: Moderation.iso8601(at)))
        save()
    }

    func unhide(key: String) {
        let key = key.lowercased()
        guard lists.hidden.contains(where: { $0.key == key }) else { return }
        lists.hidden.removeAll { $0.key == key }
        save()
    }
}

extension Moderation {
    /// `2026-09-04T21:02:11Z` — the record's `at` format (PROTOCOL §7.1).
    static func iso8601(_ date: Foundation.Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
