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
