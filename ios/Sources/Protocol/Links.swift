// Protocol — deep links, backlinks, index-group lines (PROTOCOL.md §3, §4.8, §5). Pure Swift.

import Foundation

public enum DeepLink {
    /// TDLib shifts server message ids by 20 bits.
    public static func serverMessageId(_ messageId: Int64) -> Int64 { messageId >> 20 }

    /// `https://t.me/<username>/<serverMessageId>`
    public static func post(username: String, messageId: Int64) -> String {
        "https://t.me/\(username)/\(serverMessageId(messageId))"
    }

    public static func chat(username: String) -> String { "https://t.me/\(username)" }

    public static func url(_ string: String) -> URL? {
        if let u = URL(string: string), u.scheme != nil { return u }
        return URL(string: "https://" + string)
    }

    public static func isTelegram(_ url: URL) -> Bool {
        if url.scheme == "tg" { return true }
        let host = url.host?.lowercased() ?? ""
        return host == "t.me" || host == "telegram.me" || host == "telegram.dog"
    }
}

/// The tgsocial web addresses (PRODUCT §2.13) — optional configuration, unset by default.
///
/// There is no hosted tgsocial. The repo ships source and you run your own build against your
/// own Telegram credentials (README "Run it"), so a public origin is *configuration*, not a
/// constant: `TGS_PUBLIC_ORIGIN` in Secrets.xcconfig, surfaced through Info.plist beside
/// `TGApiId`/`TGApiHash`, read once at launch. A fresh clone has none, and that is the normal
/// state — the public reader (`PUBLIC.md`) is something a self-hoster chooses to stand up.
///
/// With no origin configured, `Copy Link` copies the **t.me link** instead. That is the honest
/// fallback for a network whose storage layer is Telegram: it points at where the post actually
/// lives, it works with nobody's server running, and a node or a feed *is* a public channel
/// (PROTOCOL §3). Configure an origin and the absolute `/f/` and `/n/` links of §2.13 come back
/// exactly as they were.
public enum PublicLink {
    /// The Info.plist key that `TGS_PUBLIC_ORIGIN` lands on (project.yml `info.properties`).
    static let infoKey = "TGSPublicOrigin"

    /// The configured origin, or nil. A `static let` because the bundle cannot change under a
    /// running process — re-reading it per link would be the same answer, slower.
    public static let origin: String? = fromBundle()

    /// Reads `TGSPublicOrigin` the way `TGSecrets.fromBundle` reads the api credentials. Nil unless
    /// the value is a usable origin — the key is routinely missing, blank (an xcconfig key nobody
    /// defined substitutes to empty), the literal `$(TGS_PUBLIC_ORIGIN)` (an unexpanded build
    /// setting can survive verbatim), or mangled by the xcconfig parser; `normalise` decides.
    public static func fromBundle(_ bundle: Bundle = .main) -> String? {
        normalise(bundle.infoDictionary?[infoKey] as? String)
    }

    /// Trims, drops trailing slashes so `<origin>` + `/f/x` cannot double the separator, and then
    /// accepts scheme-and-host only — the shape `setPublicOrigin` accepts in `web/js/protocol.js`,
    /// for the same reason: the public routes are root-anchored (`/u/`, `/f/`, `/n/`), so an origin
    /// carrying a path mints links the reader cannot route back.
    ///
    /// Everything else is unset: blank, an unexpanded `$(…)`, a bare host, a `javascript:` URL —
    /// and the one that bites hardest on this platform, a bare `https:`. xcconfig begins a comment
    /// at `//`, so `TGS_PUBLIC_ORIGIN = https://host` is the *value* `https:` and the rest is a
    /// comment; without this check that truncation reaches the clipboard as `https:/f/<channel>`.
    /// `Secrets.xcconfig.example` documents the `https:/$()/host` form that survives the parser.
    ///
    /// Refusing is not fatal. A rejected origin is no origin, which leaves sharing on the t.me
    /// link — a working link is the whole point of the fallback.
    public static func normalise(_ value: String?) -> String? {
        guard var s = value?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        let isOrigin = s.range(of: #"^https?://[^/?#\s]+$"#, options: .regularExpression) != nil
        return isOrigin ? s : nil
    }

    /// `<origin>/f/<channel>` — the link `Copy Link` copies (§2.6). With no origin configured,
    /// `https://t.me/<channel>`: the channel is the feed.
    public static func feed(username: String, origin: String? = PublicLink.origin) -> String {
        guard let origin else { return DeepLink.chat(username: username) }
        return "\(origin)/f/\(username)"
    }

    /// `<origin>/n/<node>` — the card view. With no origin configured, `https://t.me/<node>`:
    /// the card is that channel's pinned message, readable in plain Telegram.
    public static func node(username: String, origin: String? = PublicLink.origin) -> String {
        guard let origin else { return DeepLink.chat(username: username) }
        return "\(origin)/n/\(username)"
    }
}

public enum Backlink {
    public static let prefix = "tgsocial:"

    /// The line a feed channel's description carries to verify ownership.
    public static func line(node: String) -> String { "\(prefix) @\(node)" }

    /// `tgsocial: @node` present (case-insensitive, whole username).
    public static func verifies(description: String, node: String) -> Bool {
        let lower = description.lowercased()
        let target = Username.key(node)
        var search = lower.startIndex
        while let range = lower.range(of: prefix, range: search..<lower.endIndex) {
            var i = range.upperBound
            while i < lower.endIndex, lower[i] == " " { i = lower.index(after: i) }
            guard i < lower.endIndex, lower[i] == "@" else { search = range.upperBound; continue }
            i = lower.index(after: i)
            var j = i
            while j < lower.endIndex, lower[j].isLetter || lower[j].isNumber || lower[j] == "_" { j = lower.index(after: j) }
            if lower[i..<j] == target { return true }
            search = range.upperBound
        }
        return false
    }

    /// Appends the backlink to a description unless already present; stays inside Telegram's 255-char limit.
    public static func appended(to description: String, node: String) -> String {
        if verifies(description: description, node: node) { return description }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? line(node: node) : " \u{00B7} " + line(node: node)
        let budget = 255 - suffix.count
        let head = trimmed.count > budget ? String(trimmed.prefix(max(0, budget))) : trimmed
        return head + suffix
    }
}

public enum IndexGroup {
    public static let username = "tgsocial_index"

    /// The announcement message: `node: @tgs_x`.
    public static func announcement(node: String) -> String { "node: @\(node)" }

    /// Parses `node: @tgs_x` from an index-group message; nil when the message is not an announcement.
    public static func parse(_ text: String) -> String? {
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("node:") else { continue }
            let value = line.dropFirst("node:".count).trimmingCharacters(in: .whitespaces)
            return Username.normalise(value)
        }
        return nil
    }
}
