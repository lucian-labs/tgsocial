// Protocol — shared formatting rules (PRODUCT.md §2.3): post time, compact counts, flood-wait parsing. Pure Swift.

import Foundation

public enum PostTime {
    /// `HH:mm` today, `Mon d` this year, `yyyy-MM-dd` otherwise. Derived from the calendar, never hand-formatted.
    public static func format(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MMM d"
        } else {
            formatter.dateFormat = "yyyy-MM-dd"
        }
        return formatter.string(from: date)
    }

    public static func format(unix: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        format(Date(timeIntervalSince1970: TimeInterval(unix)), now: now, calendar: calendar)
    }

    /// Media duration `m:ss`.
    public static func duration(seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return "\(m):" + (s < 10 ? "0\(s)" : "\(s)")
    }
}

public enum CompactCount {
    /// `999`, `1.2k`, `15k`, `2.4m` (the figure-compact rule).
    public static func format(_ n: Int) -> String {
        if n < 1_000 { return String(n) }
        if n < 1_000_000 { return scaled(Double(n) / 1_000) + "k" }
        return scaled(Double(n) / 1_000_000) + "m"
    }

    private static func scaled(_ v: Double) -> String {
        let rounded = (v * 10).rounded(.down) / 10
        if rounded >= 10 || rounded == rounded.rounded(.down) { return String(Int(rounded.rounded(.down))) }
        return String(format: "%.1f", rounded)
    }
}

public enum FloodWait {
    /// TDLib reports rate limits as code 429, message `Too Many Requests: retry after N`. Returns N.
    public static func seconds(code: Int, message: String) -> Int? {
        let upper = message.uppercased()
        guard code == 429 || upper.contains("FLOOD_WAIT") || upper.contains("RETRY AFTER") else { return nil }
        var digits = ""
        var best: Int?
        for ch in message.reversed() {
            if ch.isNumber { digits.insert(ch, at: digits.startIndex) }
            else if !digits.isEmpty { best = Int(digits); break }
        }
        if best == nil, !digits.isEmpty { best = Int(digits) }
        return best ?? 0
    }
}
