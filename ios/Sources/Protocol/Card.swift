// Protocol — the card (PROTOCOL.md §2). Parse and serialise. Pure Swift; no platform imports.

import Foundation

public struct Card: Equatable, Codable, Hashable {
    public var name: String?
    public var bio: String?
    public var link: String?
    public var isPublic: Bool
    public var feeds: [String]
    public var follows: [String]
    /// The node's comments channel (PROTOCOL §6.1); nil means the node doesn't comment, or hasn't yet.
    public var replies: String?

    public init(name: String? = nil, bio: String? = nil, link: String? = nil, isPublic: Bool = true,
                feeds: [String] = [], follows: [String] = [], replies: String? = nil) {
        self.name = name; self.bio = bio; self.link = link; self.isPublic = isPublic
        self.feeds = feeds; self.follows = follows; self.replies = replies
    }

    public func follows(_ username: String) -> Bool {
        let k = Username.key(username)
        return follows.contains { Username.key($0) == k }
    }

    public func lists(feed username: String) -> Bool {
        let k = Username.key(username)
        return feeds.contains { Username.key($0) == k }
    }

    /// Appends (chronological order; PROTOCOL §2) unless already present.
    public func following(_ username: String) -> Card {
        guard !follows(username) else { return self }
        var c = self; c.follows.append(username); return c
    }

    public func unfollowing(_ username: String) -> Card {
        let k = Username.key(username)
        var c = self; c.follows.removeAll { Username.key($0) == k }; return c
    }
}

public enum CardParseResult: Equatable {
    case card(Card)
    case newerVersion
    case notACard

    public var card: Card? { if case .card(let c) = self { return c } else { return nil } }
}

public enum CardCodec {
    public static let marker = "tgsocial v1"
    public static let version = 1
    public static let maxLength = 4096
    /// Description prefix (PROTOCOL §2): `tgsocial v1 · <bio>`.
    public static let descriptionSeparator = " \u{00B7} "

    public static func parse(_ text: String) -> CardParseResult {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return .notACard }
        let markerLine = first.trimmingCharacters(in: .whitespaces)
        if markerLine != marker {
            if let v = versionNumber(of: markerLine), v > version { return .newerVersion }
            return .notACard
        }
        var values: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if let existing = values[key], !existing.isEmpty {
                values[key] = value.isEmpty ? existing : existing + " " + value
            } else {
                values[key] = value
            }
        }
        func value(for key: String) -> String? {
            guard let v = values[key], !v.isEmpty else { return nil }
            return v
        }
        let isPublic = (values["public"] ?? "yes").lowercased() != "no"
        return .card(Card(
            name: value(for: "name"), bio: value(for: "bio"), link: value(for: "link"), isPublic: isPublic,
            feeds: Username.list(from: values["feeds"] ?? ""),
            follows: Username.list(from: values["follows"] ?? ""),
            replies: Username.list(from: values["replies"] ?? "").first
        ))
    }

    /// `tgsocial vN` → N.
    static func versionNumber(of markerLine: String) -> Int? {
        let prefix = "tgsocial v"
        guard markerLine.hasPrefix(prefix) else { return nil }
        let rest = markerLine.dropFirst(prefix.count)
        guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(rest)
    }

    /// Marker, then name, bio, link, public, feeds, follows, replies; empty optionals omitted; `public` always written.
    public static func serialise(_ card: Card) -> String {
        var lines = [marker]
        if let name = card.name, !name.isEmpty { lines.append("name: \(name)") }
        if let bio = card.bio, !bio.isEmpty { lines.append("bio: \(bio)") }
        if let link = card.link, !link.isEmpty { lines.append("link: \(link)") }
        lines.append("public: \(card.isPublic ? "yes" : "no")")
        if !card.feeds.isEmpty { lines.append("feeds: " + card.feeds.map { "@" + $0 }.joined(separator: " ")) }
        if !card.follows.isEmpty { lines.append("follows: " + card.follows.map { "@" + $0 }.joined(separator: " ")) }
        if let replies = card.replies, !replies.isEmpty { lines.append("replies: @" + replies) }
        return lines.joined(separator: "\n")
    }

    /// True when the serialised card would exceed Telegram's message limit.
    public static func isFull(_ card: Card) -> Bool { serialise(card).count > maxLength }

    /// Whether a message text is this client's own card (to hide it from feeds).
    public static func isCard(_ text: String) -> Bool {
        if case .notACard = parse(text) { return false }
        return true
    }

    /// The node channel description: `tgsocial v1 · bio` (255 chars max on Telegram).
    public static func description(bio: String?) -> String {
        guard let bio, !bio.isEmpty else { return marker }
        let full = marker + descriptionSeparator + bio
        return String(full.prefix(255))
    }

    /// Whether a channel description marks it as a node without fetching the pin.
    public static func descriptionLooksLikeNode(_ description: String) -> Bool {
        description.hasPrefix(marker)
    }
}
