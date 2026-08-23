// Protocol — username normalisation (PROTOCOL.md §2). Pure Swift; no platform imports.

import Foundation

public enum Username {
    /// Valid Telegram username: 5–32 chars, `[A-Za-z0-9_]`, no leading digit.
    public static func isValid(_ s: String) -> Bool {
        guard s.count >= 5, s.count <= 32 else { return false }
        guard let first = s.unicodeScalars.first, !("0"..."9").contains(Character(first)) else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(Character(scalar)) || ("A"..."Z").contains(Character(scalar)) ||
            ("0"..."9").contains(Character(scalar)) || scalar == "_"
        }
    }

    /// `@name`, `name`, `https://t.me/name`, `t.me/name/` → `name`; nil when not a valid username.
    /// Casing is preserved (comparison is the caller's job via `key`).
    public static func normalise(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.lowercased().hasPrefix("t.me/") { s = String(s.dropFirst("t.me/".count)) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasPrefix("@") { s.removeFirst() }
        guard isValid(s) else { return nil }
        return s
    }

    /// Case-insensitive comparison key.
    public static func key(_ username: String) -> String { username.lowercased() }

    /// Card-list token: must carry a leading `@` or be a `t.me/<name>` link (PROTOCOL §2); bare names are dropped.
    public static func listToken(_ token: String) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("@") || t.lowercased().contains("t.me/") else { return nil }
        return normalise(t)
    }

    /// Splits a whitespace-separated token list, normalises, drops invalid, collapses duplicates to the first.
    public static func list(from value: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in value.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            guard let name = listToken(String(token)) else { continue }
            let k = key(name)
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(name)
        }
        return out
    }
}
