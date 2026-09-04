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
    /// The Telegram user id that wrote the record. A mismatch on sign-in empties the lists rather
    /// than handing one account someone else's judgement on a shared device.
    var userId: Int64
    /// Node usernames, lowercased, no `@`.
    var blocked: [String]
    /// Feed channel usernames, lowercased, no `@`.
    var mutedFeeds: [String]
    var hidden: [HiddenItem]

    static let currentVersion = 1

    init(v: Int = SafetyLists.currentVersion, userId: Int64 = 0,
         blocked: [String] = [], mutedFeeds: [String] = [], hidden: [HiddenItem] = []) {
        self.v = v; self.userId = userId
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
        blocked = value([String].self, .blocked, or: [])
        mutedFeeds = value([String].self, .mutedFeeds, or: [])
        hidden = value([HiddenItem].self, .hidden, or: [])
    }

    var isEmpty: Bool { blocked.isEmpty && mutedFeeds.isEmpty && hidden.isEmpty }
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
        if isHidden(key: Moderation.key(post: post)) { return false }
        if inMainFeed, isMuted(feed: post.sourceUsername) { return false }
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

    static func key(post: Post) -> String {
        key(channel: post.sourceUsername, serverMessageId: DeepLink.serverMessageId(post.messageId))
    }

    static func key(comment: Comment) -> String {
        key(channel: comment.channelUsername, serverMessageId: DeepLink.serverMessageId(comment.messageId))
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
    }

    /// Swaps the reader's record out for an empty one that has no home. The stored record is not
    /// held anywhere here — `leaveDemo` re-reads it from disk, which it never stopped being.
    func enterDemo() {
        isDemo = true
        lists = SafetyLists(userId: Self.noUserId)
    }

    func leaveDemo() {
        isDemo = false
        lists = store.load(SafetyLists.self, LocalStore.moderation) ?? SafetyLists()
    }

    private func save() {
        guard !isDemo else { return }
        store.save(lists, LocalStore.moderation)
    }

    // Queries the views ask through the model.
    func isBlocked(_ username: String?) -> Bool { lists.isBlocked(username) }
    func isMuted(feed username: String?) -> Bool { lists.isMuted(feed: username) }
    func isHidden(key: String?) -> Bool { lists.isHidden(key: key) }

    /// PROTOCOL §7.1: on `authorizationStateReady` the record's `userId` is compared with the
    /// signed-in account. A mismatch replaces the lists with empty ones — the record survives sign
    /// out for the same account, not for the next person to sign in on this device.
    func adopt(userId: Int64) {
        // A demo has no Telegram session to reach `authorizationStateReady`, so this cannot fire
        // from inside one; the guard says so rather than relying on that.
        guard !isDemo, userId != 0 else { return }
        if lists.userId == userId { return }
        if lists.userId == 0, !lists.isEmpty {
            // Written before there was an id to write (or by a build that did not record one):
            // it is this account's own list until something says otherwise.
            lists.userId = userId
        } else {
            lists = SafetyLists(userId: userId)
        }
        save()
    }

    func block(_ username: String) {
        let key = Moderation.listKey(username)
        guard !lists.blocked.contains(key) else { return }
        lists.blocked.append(key)
        save()
    }

    func unblock(_ username: String) {
        let key = Moderation.listKey(username)
        guard lists.blocked.contains(key) else { return }
        lists.blocked.removeAll { $0 == key }
        save()
    }

    func mute(feed username: String) {
        let key = Moderation.listKey(username)
        guard !lists.mutedFeeds.contains(key) else { return }
        lists.mutedFeeds.append(key)
        save()
    }

    func unmute(feed username: String) {
        let key = Moderation.listKey(username)
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
