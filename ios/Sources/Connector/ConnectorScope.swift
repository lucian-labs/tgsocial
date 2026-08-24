// Connector — scope (CONNECTOR.md §3). Mac only; the bridge is not compiled in anywhere else.
//
// This file is the whole of the answer to "what can the assistant see". Two rules make it hold:
//
//  1. A scope is *derived*, never *supplied*. `ScopeResolver.resolve` reads the preset, my card
//     and the cards of the nodes I follow. Nothing in an HTTP request reaches it — there is no
//     parameter, header or body field anywhere in §4 that widens a scope, and no endpoint that
//     writes one. Widening happens in the app, by a person, or not at all.
//
//  2. A username the resolver did not admit cannot be read, because the reading functions do not
//     take usernames. They take `ScopedSource`, whose initialiser is private to this file, and the
//     only way to obtain one is `ScopeResolution.admit(_:)` — which throws `out of scope` for
//     anything outside the resolved set. A handler that "forgets" the check does not compile.
//
// Private chats, group chats and DMs are unreachable under every preset: every key in the set
// comes from a card's `feeds:`, `follows:` or `replies:` list, all of which are public channel
// usernames, and the service additionally refuses any resolved chat that is not a channel — which
// is what closes the one hole a hand-typed `custom` entry could otherwise open.

#if targetEnvironment(macCatalyst)

import Foundation

/// The three presets plus the custom list (CONNECTOR.md §3).
enum ScopePreset: String, Codable, CaseIterable, Equatable {
    case graph, mine, custom

    /// The §2.14 tab labels.
    var label: String {
        switch self {
        case .graph: return "Graph"
        case .mine: return "Mine"
        case .custom: return "Custom"
        }
    }
}

/// Why a username is in scope. Only ever informational — membership is what enforces.
enum ScopeSourceKind: String, Equatable {
    /// A node's card channel.
    case node
    /// A feed channel listed by an in-scope card.
    case feed
    /// A node's comments channel (PROTOCOL §6.1), reachable because its card is.
    case replies
    /// A username the user typed into the custom list.
    case listed
}

struct ScopeSource: Equatable, Identifiable {
    let username: String
    let kind: ScopeSourceKind
    var id: String { Username.key(username) }
}

/// The facts scope resolution needs from one card. Deliberately not the whole `Card`: scope has no
/// business reading a bio, and a smaller input is a smaller thing to get wrong.
struct ScopeCardFacts: Equatable {
    var feeds: [String] = []
    var replies: String?

    init(feeds: [String] = [], replies: String? = nil) {
        self.feeds = feeds
        self.replies = replies
    }

    init(_ card: Card?) {
        self.init(feeds: card?.feeds ?? [], replies: card?.replies)
    }
}

/// Everything the resolver reads. Assembled by the service from app state; never from a request.
struct ScopeInputs: Equatable {
    var myNode: String?
    var myCard: ScopeCardFacts = ScopeCardFacts()
    var follows: [String] = []
    /// Cards of the nodes I follow, keyed by `Username.key`. A follow with no cached card
    /// contributes itself and nothing else — its feeds are simply not in scope yet.
    var followCards: [String: ScopeCardFacts] = [:]
    /// The usernames the user typed under the `custom` preset.
    var custom: [String] = []
}

/// A username that has been proved in scope. The initialiser is private to this file, so the only
/// way to hold one is to have gone through `ScopeResolution.admit(_:)`.
struct ScopedSource: Equatable, Hashable {
    let username: String
    var key: String { Username.key(username) }
    fileprivate init(username: String) { self.username = username }
}

/// The resolved scope for one request: the ordered source list the app shows under
/// `Review Sources`, and the key set every read is checked against.
struct ScopeResolution: Equatable {
    let preset: ScopePreset
    let sources: [ScopeSource]
    let keys: Set<String>

    init(preset: ScopePreset, sources: [ScopeSource]) {
        self.preset = preset
        self.sources = sources
        self.keys = Set(sources.map { Username.key($0.username) })
    }

    var count: Int { sources.count }

    func contains(_ username: String) -> Bool { keys.contains(Username.key(username)) }

    /// The one door. Everything a request can read passes through here or is unreachable.
    ///
    /// The refusal carries the *normalised* username, never the raw input: that detail is echoed
    /// in the 403 body and written to the audit log, and `Username.normalise` is what guarantees
    /// it is 5–32 characters of `[A-Za-z0-9_]`. An input that does not normalise is named by its
    /// shape rather than quoted back, so nothing a caller typed reaches either sink.
    func admit(_ username: String) throws -> ScopedSource {
        guard let normalised = Username.normalise(username) else {
            throw ConnectorError.outOfScope("not a username")
        }
        guard contains(normalised) else { throw ConnectorError.outOfScope(normalised) }
        return ScopedSource(username: normalised)
    }

    /// The usernames of a given kind, in order. Used for the merged feed and `GET /feeds`.
    func usernames(ofKind kind: ScopeSourceKind) -> [String] {
        sources.filter { $0.kind == kind }.map(\.username)
    }

    /// PRODUCT §2.14: the muted line under the preset tabs. The count is live; the sentence is
    /// the preset's own description, and every one of them ends the same way.
    var summary: String {
        let n = count
        let noun = n == 1 ? "source" : "sources"
        let what: String
        switch preset {
        case .graph: what = "your feeds and the feeds of the nodes you follow"
        case .mine: what = "your own feeds and your own card"
        case .custom: what = "exactly the usernames you list"
        }
        return "\(n) \(noun) \u{2014} \(what). Private chats are never included."
    }
}

enum ScopeResolver {
    /// Resolves a preset to its source list. Ordered — me first, then each follow in card order —
    /// so `Review Sources` reads the same way twice running, and deduped case-insensitively.
    static func resolve(preset: ScopePreset, inputs: ScopeInputs) -> ScopeResolution {
        var sources: [ScopeSource] = []
        var seen = Set<String>()

        func add(_ username: String?, _ kind: ScopeSourceKind) {
            guard let username, let normalised = Username.normalise(username) else { return }
            guard seen.insert(Username.key(normalised)).inserted else { return }
            sources.append(ScopeSource(username: normalised, kind: kind))
        }

        func addCard(node: String?, facts: ScopeCardFacts) {
            add(node, .node)
            for feed in facts.feeds { add(feed, .feed) }
            add(facts.replies, .replies)
        }

        switch preset {
        case .mine:
            addCard(node: inputs.myNode, facts: inputs.myCard)
        case .graph:
            addCard(node: inputs.myNode, facts: inputs.myCard)
            for follow in inputs.follows {
                addCard(node: follow, facts: inputs.followCards[Username.key(follow)] ?? ScopeCardFacts())
            }
        case .custom:
            // Exactly what was listed. No card is walked, so a custom entry never drags a feed,
            // a follow or a comments channel in behind it.
            for username in inputs.custom { add(username, .listed) }
        }
        return ScopeResolution(preset: preset, sources: sources)
    }
}

#endif
