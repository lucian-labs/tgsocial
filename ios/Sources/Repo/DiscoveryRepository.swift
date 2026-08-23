// Repo — discovery (PROTOCOL.md §5): graph walk (+1), username prefix search, index group. Results are unioned.

import Foundation
import TDLibKit

@MainActor
final class DiscoveryRepository {
    private let td: TDClient
    private let nodes: NodeRepository

    static let prefix = "tgs_"

    /// Distance-2 nodes ranked by how many of my follows list them.
    private(set) var nearby: [DirectoryEntry] = []
    /// Prefix search ∪ index group, minus nearby, follows, me.
    private(set) var directory: [DirectoryEntry] = []
    /// Direct follows, resolved.
    private(set) var direct: [NodeInfo] = []
    /// Edges for the Graph screen: follow username (key) → its follows (keys).
    private(set) var edges: [String: [String]] = [:]

    init(td: TDClient, nodes: NodeRepository) { self.td = td; self.nodes = nodes }

    private var api: TDLibClient { td.api }

    func clear() { nearby = []; directory = []; direct = []; edges = [:] }

    /// Discovery is best-effort per chat — a hit that fails to load is skipped — but a FLOOD_WAIT is
    /// never swallowed: it propagates so AppModel.perform can toast and back off (PRODUCT §4).
    private func tolerant<T>(_ op: () async throws -> T) async throws -> T? {
        do { return try await op() } catch {
            if TDFailure.isFloodWait(error) { throw error }
            return nil
        }
    }

    // MARK: 1. Graph walk

    func walk(me: String?, follows: [String], force: Bool = false) async throws {
        let followed = try await nodes.readNodes(follows, force: force)
        let order = follows.map(Username.key)
        direct = followed.sorted { (order.firstIndex(of: $0.key) ?? .max) < (order.firstIndex(of: $1.key) ?? .max) }
        var counts: [String: Int] = [:]
        var nextEdges: [String: [String]] = [:]
        let myKey = me.map(Username.key)
        let followKeys = Set(order)
        for n in followed {
            let theirs = n.card?.follows ?? []
            nextEdges[n.key] = theirs.map(Username.key)
            for f in theirs {
                let k = Username.key(f)
                guard k != myKey, !followKeys.contains(k) else { continue }
                counts[k, default: 0] += 1
            }
        }
        edges = nextEdges
        let ranked = counts.keys.sorted { (counts[$0]!, $0) > (counts[$1]!, $1) }
        let infos = try await nodes.readNodes(Array(ranked.prefix(60)))
        var byKey: [String: NodeInfo] = [:]
        for i in infos where i.state == .ok { byKey[i.key] = i }
        nearby = ranked.compactMap { k in byKey[k].map { DirectoryEntry(node: $0, followedByCount: counts[k] ?? 0) } }
    }

    // MARK: 2 + 3. Prefix search and index group

    func loadDirectory(me: String?, follows: [String]) async throws {
        var candidates: [String] = []
        if let found = try await tolerant({ try await api.searchPublicChats(query: Self.prefix, typeFilter: .searchChatTypeFilterChannel) }) {
            for id in found.chatIds {
                guard let chat = try await tolerant({ try await api.getChat(chatId: id) }), Mapping.isChannel(chat),
                      let sgId = Mapping.supergroupId(of: chat),
                      let sg = try await tolerant({ try await api.getSupergroup(supergroupId: sgId) }),
                      let username = Mapping.username(of: chat, supergroup: sg) else { continue }
                // Prefer the description marker to skip a pinned-message fetch.
                if let full = try await tolerant({ try await api.getSupergroupFullInfo(supergroupId: sgId) }),
                   CardCodec.descriptionLooksLikeNode(full.description) {
                    candidates.append(username)
                } else {
                    let info = try await tolerant { try await nodes.nodeInfo(chat: chat, username: username) }
                    if info?.state == .ok { candidates.append(username) }
                }
            }
        }
        // Index group (PROTOCOL §5.3): the last 200 `node: @x` lines.
        if let (_, entries) = try await tolerant({ try await nodes.indexEntries() }) ?? nil {
            candidates += entries.map(\.node)
        }
        let exclude = Set(follows.map(Username.key) + [me.map(Username.key) ?? ""] + nearby.map(\.id))
        var seen = Set<String>()
        let unique = candidates.filter { !exclude.contains(Username.key($0)) && seen.insert(Username.key($0)).inserted }
        let infos = try await nodes.readNodes(unique)
        directory = infos
            .filter { $0.state == .ok && ($0.card?.isPublic ?? false) }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
            .map { DirectoryEntry(node: $0, followedByCount: 0) }
    }

    // MARK: Find a node (Explore input)

    func lookup(_ input: String) async -> NodeInfo? {
        guard let username = Username.normalise(input) else { return nil }
        guard let info = try? await nodes.readNode(username: username, force: true), info.state == .ok else { return nil }
        return info
    }
}
