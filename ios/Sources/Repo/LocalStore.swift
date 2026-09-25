// Repo — the small serialisable local state (PROTOCOL.md §6). JSON files under Application Support/tgsocial.
// Signing out wipes the directory.

import Foundation

final class LocalStore {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("tgsocial", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".json") }

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T?, _ name: String) {
        guard let value else { try? FileManager.default.removeItem(at: url(name)); return }
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }

    /// Wipe everything (sign out) — except the safety lists, which survive by design.
    ///
    /// PROTOCOL §7.1: the block, mute and report record protects the person holding the phone, not
    /// the session. This wipes the directory, so the record is read out first and written back
    /// after; `adopt(userId:)` is what decides on the next sign-in whether it still belongs to
    /// whoever signs in. Delete my node (PRODUCT §2.21) comes through here too, and keeps it for
    /// the same reason.
    ///
    /// `blockedWith` rides along: it is the half of a node block that remembers which DID was
    /// written beside the node (PROTOCOL §12.9), so it survives exactly when the list does.
    func clear() {
        let kept = Self.survivesSignOut.map { ($0, try? Data(contentsOf: url($0))) }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in kept { if let data { try? data.write(to: url(name), options: .atomic) } }
    }

    static let survivesSignOut = [moderation, blockedWith]

    // MARK: Versioned caches (PRODUCT §2.3)

    /// A page cached by an earlier build must not paint: the persisted payload carries a schema
    /// version and a mismatch discards it. Bump on any change to the cached models or their
    /// ordering rules. 2: attribution fields on Post, relative-time card redesign. 3: private
    /// sources (PROTOCOL §11) — `privateSupergroupId` on Post and FeedInfo, `privateId` on NodeInfo.
    static let schemaVersion = 3

    private struct Versioned<T: Codable>: Codable {
        var schemaVersion: Int
        var value: T
    }

    /// Nil on a missing file, an unversioned (pre-versioning) payload, or a version mismatch —
    /// the stale cache is discarded rather than painted.
    func loadVersioned<T: Codable>(_ type: T.Type, _ name: String) -> T? {
        guard let wrapped = load(Versioned<T>.self, name), wrapped.schemaVersion == Self.schemaVersion else { return nil }
        return wrapped.value
    }

    func saveVersioned<T: Codable>(_ value: T?, _ name: String) {
        guard let value else { save(Optional<Versioned<T>>.none, name); return }
        save(Versioned(schemaVersion: Self.schemaVersion, value: value), name)
    }

    // Keys
    static let myNode = "myNode"
    static let myCard = "myCard"
    /// PROTOCOL §10.2: my work card, cached beside my card so §10.6's write-back survives a relaunch.
    static let myWork = "myWork"
    /// PROTOCOL §12.2: my card's `atproto.did`, cached for the same write-back reason.
    static let myAtprotoDid = "myAtprotoDid"
    /// PROTOCOL §12.3: the link-verification cache. Discardable (§7).
    static let atprotoLinks = "atprotoLinks"
    /// PRODUCT §2.35: the two Bluesky toggles — preferences, device-local.
    static let blueskyPrefs = "blueskyPrefs"
    /// PROTOCOL §12.9: the signed-in account's Bluesky blocks, with the DID they belong to.
    /// Discardable (§7): a later read rebuilds it.
    static let blueskyBlocks = "blueskyBlocks"
    static let myTitle = "myTitle"
    static let nodeCache = "nodes"
    static let feedCache = "feeds"
    static let postCache = "posts"
    static let setupSkipped = "setupSkipped"
    static let feedCandidates = "candidates"
    static let commentIndex = "comments"
    /// PROTOCOL §10.4: built by the same scan as the comment index, stored beside it.
    static let vouchIndex = "vouches"
    /// PROTOCOL §7: a UI preference, not a cache. Feed's All / Work mode (PRODUCT §2.24).
    static let feedMode = "feedMode"
    /// PROTOCOL §7.2: the private record — my private node, my private feeds, and the pending
    /// requests Telegram does not hold for the requester. Discardable: everything but `pending`
    /// is recovered from the chat list (§11.4.9), and losing `pending` costs one repeated request.
    static let privateRecord = "private"
    /// PRODUCT §2.33: `Confirm on public card`. A preference, on by default; stored only when the
    /// owner turns it off, so its absence reads as on.
    static let privateConfirmOff = "privateConfirmOff"
    /// PROTOCOL §7.1: stored apart from every cache and never versioned with them — a cache bump
    /// discards caches and must never discard a block list.
    static let moderation = "moderation"
    /// PROTOCOL §12.9 "Unblock lifts both": node → the DID its block wrote beside it. Kept beside
    /// the §7.1 record rather than in it, because that record's shape is shared with Android and
    /// web and §12.9 grows its key grammar, not its fields.
    static let blockedWith = "blockedWith"
}
