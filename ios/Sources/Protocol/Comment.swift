// Protocol — the comment format (PROTOCOL.md §6.2). A comment is an ordinary message in a
// comments channel whose first line is `re: ` + a t.me post link; everything after the first
// newline is the body. Byte-compatible across clients (§6.5): `re: ` prefix, one space, full
// `https://t.me/...` link, newline, body. Pure Swift; no platform imports.

import Foundation

public enum CommentCodec {
    public static let prefix = "re: "
    static let linkHost = "https://t.me/"

    /// `re: <link>\n<body>` → (target, body); nil when the message is not a comment.
    public static func parse(_ text: String) -> (target: String, body: String)? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        let target: String
        let body: String
        if let newline = rest.firstIndex(of: "\n") {
            target = String(rest[..<newline]).trimmingCharacters(in: .whitespaces)
            body = String(rest[rest.index(after: newline)...])
        } else {
            target = String(rest).trimmingCharacters(in: .whitespaces)
            body = ""
        }
        guard components(of: target) != nil else { return nil }
        return (target, body)
    }

    /// `re: <link>` alone for an empty body; otherwise link, newline, body (§6.5).
    public static func serialise(target: String, body: String) -> String {
        body.isEmpty ? prefix + target : prefix + target + "\n" + body
    }

    /// A `t.me` post link in the §4.8 deep-link form: `https://t.me/<username>/<serverMessageId>`.
    public static func components(of link: String) -> (username: String, serverMessageId: Int64)? {
        guard link.hasPrefix(linkHost) else { return nil }
        let parts = link.dropFirst(linkHost.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Username.isValid(String(parts[0])),
              let id = Int64(parts[1]), id > 0 else { return nil }
        return (String(parts[0]), id)
    }

    /// Canonical index key for a target link (usernames are case-insensitive).
    public static func targetKey(_ link: String) -> String? {
        guard let (username, id) = components(of: link) else { return nil }
        return linkHost + username.lowercased() + "/" + String(id)
    }

    /// Threads are `re:` chains capped at depth 5; deeper replies render flattened (§6.2).
    public static let maxDepth = 5
}
