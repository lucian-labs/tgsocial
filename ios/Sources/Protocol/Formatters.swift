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

    /// Media duration `m:ss`, `h:mm:ss` from an hour up.
    public static func duration(seconds: Int) -> String {
        let clamped = max(seconds, 0)
        let h = clamped / 3600, m = (clamped % 3600) / 60, s = clamped % 60
        let ss = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 {
            let mm = m < 10 ? "0\(m)" : "\(m)"
            return "\(h):\(mm):\(ss)"
        }
        return "\(m):\(ss)"
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

public enum FileSize {
    /// `812 B`, `48 KB`, `2.4 MB`, `1.2 GB` — the document-row size (PRODUCT §2.11).
    public static func format(_ bytes: Int64) -> String {
        let b = Double(max(bytes, 0))
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if b < kb { return "\(Int(b)) B" }
        if b < mb { return "\(Int((b / kb).rounded())) KB" }
        if b < gb { return String(format: "%.1f MB", b / mb) }
        return String(format: "%.1f GB", b / gb)
    }
}

public enum PhoneMask {
    /// `+1 604 ••• 0199` — country and area kept, the middle masked, the last four kept
    /// (Status sheet, PRODUCT §2.10).
    public static func format(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return "" }
        guard digits.count >= 9 else { return "+" + digits }
        let last = String(digits.suffix(4))
        let head = String(digits.dropLast(7))
        let area = String(head.suffix(3))
        let country = String(head.dropLast(3))
        let mask = "\u{2022}\u{2022}\u{2022}"
        var parts: [String] = []
        if !country.isEmpty { parts.append("+" + country) }
        if !area.isEmpty { parts.append(country.isEmpty ? "+" + area : area) }
        parts.append(mask)
        parts.append(last)
        return parts.joined(separator: " ")
    }
}

public enum RelativeTime {
    /// `just now`, `2 min ago`, `3 h ago`, `5 d ago` — derived, never recalled.
    public static func format(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min ago" }
        if s < 86400 { return "\(s / 3600) h ago" }
        return "\(s / 86400) d ago"
    }
}

public enum WaveformCodec {
    /// TDLib voice waveforms are 5-bit samples packed little-endian. Returns 0…1 heights.
    public static func decode(_ data: Data) -> [Double] {
        guard !data.isEmpty else { return [] }
        let bytes = [UInt8](data)
        let count = bytes.count * 8 / 5
        var out: [Double] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let bit = i * 5
            let byteIndex = bit / 8
            let shift = bit % 8
            var value = Int(bytes[byteIndex]) >> shift
            if shift > 3, byteIndex + 1 < bytes.count {
                value |= Int(bytes[byteIndex + 1]) << (8 - shift)
            }
            out.append(Double(value & 0x1F) / 31.0)
        }
        return out
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
