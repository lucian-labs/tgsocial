// Protocol — the private extension (PROTOCOL.md §11). Parse, serialise, verify. Pure Swift.
//
// §11 is built the way §10 was built, and this file has the same shape as `Work.swift` for the
// same reason: `Card.swift` is §2 and knows nothing about anything here. Delete this file and
// every card on the network still parses byte-identically — a public card carrying `private.id`
// is a §2 card with one unknown key, and a private card is a §2 card with two. §11 is read by a
// SECOND pass over the same text (§11.2), and the two meet in exactly one place, the
// `CardCodec.serialise(_:work:privateId:private:)` overload at the bottom (§11.6).
//
// Nothing in here touches TDLib, and nothing in here is a capability: an invite link is a string
// this file can recognise and normalise, and the only thing it ever puts on the wire is what the
// owner asked it to.

import Foundation

/// The invite link grammar (§11.2). Three written forms, one canonical form; the hash is a token,
/// not a username, and is compared byte for byte — case is part of it.
public enum InviteLink {
    public static let canonicalPrefix = "https://t.me/+"

    /// `[A-Za-z0-9_-]{8,64}` — base64url, and Telegram has issued 16- and 22-character ones.
    public static func isHash(_ s: String) -> Bool {
        guard s.count >= 8, s.count <= 64 else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(scalar)) || ("A"..."Z").contains(Character(scalar)) ||
            ("0"..."9").contains(Character(scalar)) || scalar == "_" || scalar == "-"
        }
    }

    /// `https://t.me/+HASH`, `t.me/+HASH`, `https://t.me/joinchat/HASH`, `tg://join?invite=HASH`
    /// → `https://t.me/+HASH`; anything else — a username, a `t.me/c/` link, a post link — nil.
    public static func normalise(_ input: String) -> String? {
        guard let hash = hash(input) else { return nil }
        return canonicalPrefix + hash
    }

    /// The hash alone — what §7.2's pending list keys on.
    public static func hash(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        var candidate: String?
        if lower.hasPrefix("tg://join?invite=") {
            let rest = String(s.dropFirst("tg://join?invite=".count))
            guard !rest.contains("&"), !rest.contains(" ") else { return nil }
            candidate = rest
        } else {
            var body = s
            for prefix in ["https://", "http://"] where body.lowercased().hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count))
            }
            if body.lowercased().hasPrefix("www.") { body = String(body.dropFirst("www.".count)) }
            guard body.lowercased().hasPrefix("t.me/") else { return nil }
            body = String(body.dropFirst("t.me/".count))
            if body.hasPrefix("+") {
                body = String(body.dropFirst())
            } else if body.lowercased().hasPrefix("joinchat/") {
                body = String(body.dropFirst("joinchat/".count))
            } else {
                return nil
            }
            // One trailing slash is tolerated; anything else after the hash is not an invite.
            if body.hasSuffix("/") { body.removeLast() }
            guard !body.contains("/"), !body.contains("?"), !body.contains("#") else { return nil }
            candidate = body
        }
        guard let candidate, isHash(candidate) else { return nil }
        return candidate
    }

    /// Whitespace-separated invite links; invalid dropped, duplicates collapse to the first (§11.2).
    public static func list(from value: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            guard let link = normalise(String(token)), seen.insert(link).inserted else { continue }
            out.append(link)
        }
        return out
    }
}

/// The two §11.2 keys a PRIVATE card carries, parsed. `node` is what makes a pinned message a
/// private card at all — a card without it is a §2 card, not a private one.
public struct PrivateCard: Codable, Equatable, Hashable {
    /// The public node this is the private half of, without the `@`.
    public var node: String
    /// Further private feeds, as canonical invite links, in the owner's display order.
    public var feeds: [String]

    public init(node: String, feeds: [String] = []) { self.node = node; self.feeds = feeds }
}

public enum PrivateCodec {
    static let privateKeys: Set<String> = ["private.node", "private.feeds"]
    static let publicKey = "private.id"

    /// The §2 repetition rule over the §11 keys only: a repeated key concatenates with a space.
    private static func raw(_ text: String, keys: Set<String>) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard keys.contains(key) else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = out[key], !existing.isEmpty {
                out[key] = value.isEmpty ? existing : existing + " " + value
            } else {
                out[key] = value
            }
        }
        return out
    }

    /// The §11 pass over a PRIVATE card's text. Nil when the text is not a v1 card, or carries no
    /// usable `private.node` — a reader that found such a message in a private channel has found
    /// nothing this section can use (§11.2).
    public static func parse(_ text: String) -> PrivateCard? {
        guard CardCodec.parse(text).card != nil else { return nil }
        let raw = raw(text, keys: privateKeys)
        guard let node = Username.list(from: raw["private.node"] ?? "").first else { return nil }
        return PrivateCard(node: node, feeds: InviteLink.list(from: raw["private.feeds"] ?? ""))
    }

    /// The one §11 key a PUBLIC card carries: the private node's supergroup id, as the string of
    /// digits that appears in a `t.me/c/<id>/…` link. Kept as digits rather than an integer so the
    /// comparison is the byte comparison the web client makes and a 20-digit value cannot overflow
    /// into a different number. Not a capability — nothing can be joined or read with it — which is
    /// why it is the thing that may be published (§11.3). Absent or malformed → nil.
    public static func publicId(_ text: String) -> String? {
        guard CardCodec.parse(text).card != nil else { return nil }
        let value = raw(text, keys: [publicKey])[publicKey] ?? ""
        let first = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        return isPublicId(first) ? first : nil
    }

    /// `[1-9][0-9]{0,19}` — a positive integer with no sign and no leading zero.
    public static func isPublicId(_ s: String) -> Bool {
        guard let first = s.first, first != "0", s.count <= 20 else { return false }
        return s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// §11.3 — is the private card in supergroup `supergroupId` the private half of the node it
    /// names? Only the direction public → private is provable: the public card is the one message
    /// only that node's owner can write, so the check is that `@N`'s public card names this very
    /// channel. `publicNode` is the username the reader resolved `private.node` through, so a
    /// private card naming `@tgs_elijah` is checked against `@tgs_elijah`'s card and no other.
    public static func verified(privateText: String, supergroupId: Int64, publicText: String, publicNode: String) -> Bool {
        guard let priv = parse(privateText), !publicNode.isEmpty,
              Username.key(priv.node) == Username.key(publicNode) else { return false }
        return verified(publicId: publicId(publicText), supergroupId: supergroupId)
    }

    /// The same check on already-parsed parts — what the app has in hand once both cards are cached.
    public static func verified(publicId: String?, supergroupId: Int64) -> Bool {
        guard let publicId else { return false }
        return publicId == String(supergroupId)
    }

    /// The §11 lines, in §11.2 order — `private.id`, `private.node`, `private.feeds` — for
    /// `CardCodec.serialise` to append after every §2 and §10 key. Every value is re-normalised on
    /// the way out: a malformed id never reaches the wire, and `private.feeds` without a usable
    /// `private.node` is nothing.
    public static func lines(privateId: String?, private priv: PrivateCard?) -> [String] {
        var out: [String] = []
        if let id = privateId?.trimmingCharacters(in: .whitespaces), isPublicId(id) {
            out.append("private.id: " + id)
        }
        if let priv, let node = Username.normalise(priv.node.hasPrefix("@") ? priv.node : "@" + priv.node) {
            out.append("private.node: @" + node)
            let feeds = InviteLink.list(from: priv.feeds.joined(separator: " "))
            if !feeds.isEmpty { out.append("private.feeds: " + feeds.joined(separator: " ")) }
        }
        return out
    }
}

// MARK: - Where §11 meets §2 (§11.6)

public extension CardCodec {
    /// §2's serialiser with the §10 lines and then the §11 lines appended, each omitted when
    /// empty. §2's own order and output are unchanged. This is the one place the private
    /// extension touches the protocol's own codec, and it is the whole of §11.6: a client that read
    /// `private.id` has to write it back, or a follow — which rewrites the entire pinned message —
    /// silently makes every member's client see the owner's private card as unconfirmed.
    static func serialise(_ card: Card, work: Work?, privateId: String?, private priv: PrivateCard? = nil) -> String {
        let base = serialise(card, work: work)
        let lines = PrivateCodec.lines(privateId: privateId, private: priv)
        return lines.isEmpty ? base : base + "\n" + lines.joined(separator: "\n")
    }

    /// §2's 4096 cap, unmoved, now counting every line the same write would carry.
    static func isFull(_ card: Card, work: Work?, privateId: String?, private priv: PrivateCard? = nil) -> Bool {
        serialise(card, work: work, privateId: privateId, private: priv).count > maxLength
    }
}

// MARK: - Links and keys for channels with no username (§11.4.8, §7.2)

public enum PrivateLink {
    /// `https://t.me/c/<supergroupId>/<serverMessageId>` — opens for members and for nobody else.
    /// Not a `t.me/<username>/…` link, so §6.2 does not accept it as a comment target.
    public static func post(supergroupId: Int64, messageId: Int64) -> String {
        "https://t.me/c/\(supergroupId)/\(DeepLink.serverMessageId(messageId))"
    }

    public static func chat(supergroupId: Int64) -> String { "https://t.me/c/\(supergroupId)" }

    /// The §7.2 safety-list grammar for a channel with no username: `c/<supergroupId>` for a mute,
    /// `c/<supergroupId>/<serverMessageId>` for a hidden post — the `t.me/c/` path without the
    /// host, which no username can collide with (a username cannot contain `/`) and which an older
    /// client's username comparison simply never matches.
    public static func sourceKey(supergroupId: Int64) -> String { "c/\(supergroupId)" }

    public static func hiddenKey(supergroupId: Int64, serverMessageId: Int64) -> String {
        sourceKey(supergroupId: supergroupId) + "/" + String(serverMessageId)
    }

    /// `c/<id>` → the id; nil for a username key.
    public static func supergroupId(fromSourceKey key: String) -> Int64? {
        guard key.hasPrefix("c/") else { return nil }
        let rest = key.dropFirst(2)
        guard !rest.contains("/"), let id = Int64(rest), id > 0 else { return nil }
        return id
    }
}
