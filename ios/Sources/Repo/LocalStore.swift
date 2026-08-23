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

    /// Wipe everything (sign out).
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Versioned caches (PRODUCT §2.3)

    /// A page cached by an earlier build must not paint: the persisted payload carries a schema
    /// version and a mismatch discards it. Bump on any change to the cached models or their
    /// ordering rules. 2: attribution fields on Post, relative-time card redesign.
    static let schemaVersion = 2

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
    static let myTitle = "myTitle"
    static let nodeCache = "nodes"
    static let feedCache = "feeds"
    static let postCache = "posts"
    static let setupSkipped = "setupSkipped"
    static let feedCandidates = "candidates"
    static let commentIndex = "comments"
}
