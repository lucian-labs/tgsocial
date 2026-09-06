// Protocol — the work extension (PROTOCOL.md §10). Parse, serialise, and the vouch format.
// Pure Swift; no platform imports beyond Foundation.
//
// §10 is an extension, and the shape of this file is the argument for it. `Card.swift` is §2 and
// knows nothing about anything here: delete this file and every card on the network still parses
// byte-identically, work keys included, because §2 already says unknown keys are ignored. §10 is
// read by a SECOND pass over the same text.
//
// The two meet in exactly one place — the `CardCodec.serialise(_:work:)` overload at the bottom,
// which emits work lines when, and only when, the caller hands it a `Work`. That is §10.6: a
// client that read the keys has to write them back, or a follow would quietly delete somebody's
// work card.

import Foundation

/// The closed intent set (§10.3). Unknown intents are dropped rather than shown — a client cannot
/// render a word it has no copy for.
public enum WorkIntent: String, Codable, Equatable, Hashable, CaseIterable {
    case work, contract, hiring, collab

    /// The four strings, verbatim (PRODUCT §2.23). Not derived from the raw value: these are copy.
    public var label: String {
        switch self {
        case .work: return "Open to work"
        case .contract: return "Open to contract"
        case .hiring: return "Hiring"
        case .collab: return "Open to collaborate"
        }
    }

    /// The Edit Card tab label (PRODUCT §2.23).
    public var editLabel: String {
        switch self {
        case .work: return "Work"
        case .contract: return "Contract"
        case .hiring: return "Hiring"
        case .collab: return "Collab"
        }
    }
}

/// `<intent> until <YYYY-MM-DD>`, the one time-sensitive thing on a card (§10.3).
public struct WorkOpen: Codable, Equatable, Hashable {
    public var intent: WorkIntent
    /// `YYYY-MM-DD`, interpreted UTC.
    public var until: String

    public init(intent: WorkIntent, until: String) { self.intent = intent; self.until = until }
}

/// The four §10.2 keys, parsed. `nil` from `WorkCodec.parse` means the node has no work card, so
/// "has a work card" is one optional check and a card whose every work line is malformed is the
/// same as a card with none.
public struct Work: Codable, Equatable, Hashable {
    public var role: String?
    public var does: [String]
    public var open: WorkOpen?
    /// Which of the card's own `feeds:` are work (PRODUCT §2.24: the marking is per feed).
    public var feeds: [String]

    public init(role: String? = nil, does: [String] = [], open: WorkOpen? = nil, feeds: [String] = []) {
        self.role = role; self.does = does; self.open = open; self.feeds = feeds
    }

    public var isEmpty: Bool { role == nil && does.isEmpty && open == nil && feeds.isEmpty }

    public func lists(feed username: String) -> Bool {
        let k = Username.key(username)
        return feeds.contains { Username.key($0) == k }
    }
}

public enum WorkCodec {
    public static let roleMax = 80
    public static let doesMax = 12
    public static let tagMin = 2
    public static let tagMax = 24
    /// §10.3: a date further out than this is not a statement about now. `until 2099-01-01` is an
    /// expiry nobody ever has to renew, which is the same as no expiry at all.
    public static let openHorizonDays = 180
    /// PRODUCT §2.23: the horizons the writer offers, well inside the cap.
    public static let openHorizons = [30, 60, 90]

    static let keys: Set<String> = ["work.role", "work.does", "work.open", "work.feeds"]

    // MARK: Tags (§10.2)

    /// One capability tag, normalised: trimmed, inner whitespace collapsed, lowercased. Invalid → nil.
    ///
    /// The grammar is `[a-z0-9][a-z0-9 +#.-]{0,22}[a-z0-9+#]` — the punctuation real trades carry,
    /// so `c++`, `c#`, `node.js` and `front of house` are tags and `live/sound` is not. Written out
    /// rather than as a regex because every character class here is a decision worth reading.
    public static func tag(_ input: String) -> String? {
        var collapsed = ""
        var lastWasSpace = false
        for ch in input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            let isSpace = ch == " " || ch == "\t" || ch == "\n"
            if isSpace {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(ch)
                lastWasSpace = false
            }
        }
        let chars = Array(collapsed)
        guard chars.count >= tagMin, chars.count <= tagMax else { return nil }
        guard isEdgeStart(chars[0]), isEdgeEnd(chars[chars.count - 1]) else { return nil }
        for ch in chars.dropFirst().dropLast() where !isInner(ch) { return nil }
        return collapsed
    }

    private static func isEdgeStart(_ ch: Character) -> Bool { ch.isASCII && (ch.isLowercase || ch.isNumber) }
    private static func isEdgeEnd(_ ch: Character) -> Bool { isEdgeStart(ch) || ch == "+" || ch == "#" }
    private static func isInner(_ ch: Character) -> Bool { isEdgeEnd(ch) || ch == " " || ch == "." || ch == "-" }

    /// `a, b, c` → up to `doesMax` tags. Invalid tags are dropped, never fatal (§10.2); duplicates
    /// collapse to the first.
    public static func does(from value: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard let t = tag(String(part)), seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count == doesMax { break }
        }
        return out
    }

    // MARK: Dates (§10.3)

    /// A real calendar day in `YYYY-MM-DD` — `2026-02-30` is not one.
    public static func isCalendarDay(_ s: String) -> Bool { civil(s) != nil }

    /// Whole days from `a` to `b`, both `YYYY-MM-DD`. Negative when `b` is behind `a`; nil when
    /// either is not a day. Integer arithmetic on the proleptic Gregorian calendar rather than
    /// `Calendar`, because §10.3 is UTC and a reader's time zone must not move an expiry.
    public static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let x = civil(a), let y = civil(b) else { return nil }
        return daysFromCivil(y) - daysFromCivil(x)
    }

    /// Today as `YYYY-MM-DD`, UTC — the `today` every reader-side expiry check takes.
    public static func today(_ now: Date = Date()) -> String {
        day(from: Int(floor(now.timeIntervalSince1970 / 86_400)))
    }

    /// `<intent> until <YYYY-MM-DD>` → the open intent; anything else → nil (§10.3).
    public static func open(from value: String) -> WorkOpen? {
        let parts = value.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 3, parts[1].lowercased() == "until" else { return nil }
        guard parts[0].allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        guard let intent = WorkIntent(rawValue: parts[0].lowercased()) else { return nil }
        let until = String(parts[2])
        guard isCalendarDay(until) else { return nil }
        return WorkOpen(intent: intent, until: until)
    }

    public static func serialise(open: WorkOpen?) -> String {
        guard let open else { return "" }
        return "\(open.intent.rawValue) until \(open.until)"
    }

    /// Is this intent a statement about now? Expired is obvious; the far-future cap is the other
    /// half, and it is the one that makes the first rule mean something (§10.3). `today` is
    /// `YYYY-MM-DD`.
    public static func isCurrent(_ open: WorkOpen?, today: String) -> Bool {
        guard let open, let days = daysBetween(today, open.until) else { return false }
        return days >= 0 && days <= openHorizonDays
    }

    /// `YYYY-MM-DD` `horizon` days after `today` — what the writer's `FOR` tabs mint (PRODUCT §2.23).
    public static func day(after horizon: Int, from today: String = WorkCodec.today()) -> String? {
        guard let c = civil(today) else { return nil }
        return day(from: daysFromCivil(c) + horizon)
    }

    /// The `FOR` tab that covers `left` days (PRODUCT §2.23). A card carries the end DATE, never
    /// the horizon that produced it, so reopening Edit Card has to recover one — and a control
    /// showing a horizon the card does not have is not cosmetic: the next Save writes it, so an
    /// edit to the bio alone would move the one date §10.3 makes the reader enforce.
    public static func horizon(remainingDays left: Int) -> Int {
        openHorizons.first { $0 >= left } ?? openHorizons.last ?? left
    }

    // MARK: The card pass (§10.2)

    /// The §10 pass over a card's text. Returns the work card, or nil when the text is not a v1
    /// card or carries nothing §10 can use.
    ///
    /// `work.feeds` is intersected with `feeds:` here rather than trusted: `feeds:` is the
    /// ownership claim (§3, which needs post rights), and a marking line has no business
    /// introducing a channel the owner never claimed.
    public static func parse(_ text: String) -> Work? {
        guard let card = CardCodec.parse(text).card else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var raw: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard keys.contains(key) else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // §2's repetition rule, unchanged: a repeated key concatenates with a space.
            if let existing = raw[key], !existing.isEmpty {
                raw[key] = value.isEmpty ? existing : existing + " " + value
            } else {
                raw[key] = value
            }
        }
        var work = Work()
        work.role = role(from: raw["work.role"] ?? "")
        work.does = does(from: raw["work.does"] ?? "")
        work.open = open(from: raw["work.open"] ?? "")
        work.feeds = Username.list(from: raw["work.feeds"] ?? "").filter { card.lists(feed: $0) }
        return work.isEmpty ? nil : work
    }

    /// One line, whitespace collapsed, capped. A longer role keeps its first 80 characters and
    /// never rejects the card (§10.2).
    static func role(from value: String) -> String? {
        let collapsed = value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(roleMax))
    }

    /// The §10 lines, in §10.2 order, for `CardCodec.serialise(_:work:)` to append after `replies`.
    /// Every value is re-normalised on the way out, so a card written from a hand-built `Work` is
    /// the same bytes as one round-tripped from the network.
    ///
    /// `feeds` is the card's own `feeds:`. §10.2 says `work.feeds` is a marking on channels the card
    /// already claims, so the intersection is enforced on the write side here exactly as `parse`
    /// enforces it on the read side: no caller can put an entry on the wire the card does not list.
    /// It matters because a stale marking is latent, not harmless — readers ignore it today and it
    /// re-marks the channel as work the moment the owner lists it again, with nobody touching the
    /// toggle.
    public static func lines(_ work: Work?, feeds: [String] = []) -> [String] {
        guard let work else { return [] }
        var out: [String] = []
        if let role = role(from: work.role ?? "") { out.append("work.role: " + role) }
        let tags = does(from: work.does.joined(separator: ","))
        if !tags.isEmpty { out.append("work.does: " + tags.joined(separator: ", ")) }
        if let open = open(from: serialise(open: work.open)) { out.append("work.open: " + serialise(open: open)) }
        let marked = Username.list(from: work.feeds.map { $0.hasPrefix("@") ? $0 : "@" + $0 }.joined(separator: " "))
            .filter { m in feeds.contains { Username.key($0) == Username.key(m) } }
        if !marked.isEmpty { out.append("work.feeds: " + marked.map { "@" + $0 }.joined(separator: " ")) }
        return out
    }

    // MARK: Civil date arithmetic

    /// `YYYY-MM-DD` → (y, m, d), nil when it is not a real calendar day.
    static func civil(_ s: String) -> (y: Int, m: Int, d: Int)? {
        let chars = Array(s)
        guard chars.count == 10, chars[4] == "-", chars[7] == "-" else { return nil }
        for (i, ch) in chars.enumerated() where i != 4 && i != 7 {
            guard ch.isASCII, ch.isNumber else { return nil }
        }
        guard let y = Int(String(chars[0..<4])), let m = Int(String(chars[5..<7])), let d = Int(String(chars[8..<10])) else { return nil }
        guard m >= 1, m <= 12, d >= 1, d <= daysIn(month: m, year: y) else { return nil }
        return (y, m, d)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeap(year) ? 29 : 28
        }
    }

    static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    /// Days from 1970-01-01. Howard Hinnant's `days_from_civil`, which is exact for every year the
    /// proleptic Gregorian calendar covers and needs no calendar object.
    static func daysFromCivil(_ c: (y: Int, m: Int, d: Int)) -> Int {
        let y = c.y - (c.m <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (c.m + (c.m > 2 ? -3 : 9)) + 2) / 5 + c.d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The inverse: days from 1970-01-01 → `YYYY-MM-DD`.
    static func day(from days: Int) -> String {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        let year = y + (m <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, m, d)
    }
}

// MARK: - The vouch (§10.4)

/// One vouch as written: the subject node, the one capability, and an optional body.
public struct VouchBody: Equatable, Hashable {
    public var node: String
    public var does: String
    public var body: String
}

public enum VouchCodec {
    public static let prefix = "vouch: "
    public static let doesPrefix = "does: "
    static let linkHost = "https://t.me/"

    /// §10.4, exactly. Both lines are mandatory: a `vouch:` with no `does:` would assert "I vouch
    /// for this person", which nobody can weigh and which decays into a like button inside a week.
    /// A message missing either line is not a vouch and readers skip it, the same way §6.2 skips a
    /// message with no `re:` line.
    public static func parse(_ text: String) -> VouchBody? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : String($0)
        }
        guard lines.count >= 2 else { return nil }
        guard let node = target(lines[0]) else { return nil }
        guard lines[1].hasPrefix(doesPrefix) else { return nil }
        let rest = String(lines[1].dropFirst(doesPrefix.count))
        guard !rest.isEmpty, let does = WorkCodec.tag(rest) else { return nil }
        let body = lines.count > 2 ? lines[2...].joined(separator: "\n") : ""
        return VouchBody(node: node, does: does, body: body)
    }

    /// Line 1: `vouch: ` — one space — then the NODE channel's link, no message id and no trailing
    /// slash. A link with a message id is a §6.2 comment, not a vouch, and this is the line that
    /// keeps the two apart in one channel.
    static func target(_ line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var rest = String(line.dropFirst(prefix.count))
        while rest.hasSuffix(" ") || rest.hasSuffix("\t") { rest.removeLast() }
        guard rest.hasPrefix(linkHost) else { return nil }
        let name = String(rest.dropFirst(linkHost.count))
        guard Username.isValid(name) else { return nil }
        return name
    }

    /// §10.4, exact bytes. Nil when the tag is one §10.2 would drop — the caller's refusal is
    /// `Pick one thing.` (PRODUCT §2.25).
    public static func serialise(node: String, does: String, body: String) -> String? {
        guard let tag = WorkCodec.tag(does), let name = Username.normalise(node) else { return nil }
        let head = prefix + linkHost + name + "\n" + doesPrefix + tag
        return body.isEmpty ? head : head + "\n" + body
    }

    /// §10.4: a vouch for the channel's own owner is not a vouch. Unforgeable-by-construction is
    /// the whole value of the format, and it holds only because the one channel a person can write
    /// is the one that cannot speak about them. A client that renders a self-vouch has given that
    /// away, so the check sits at the parse boundary and a self-vouch never reaches an index.
    public static func keeps(_ vouch: VouchBody?, voucherNode: String) -> Bool {
        guard let vouch, !voucherNode.isEmpty else { return false }
        return Username.key(vouch.node) != Username.key(voucherNode)
    }
}

// MARK: - Where §10 meets §2 (§10.6)

public extension CardCodec {
    /// §2's serialiser with the §10 lines appended, in §10.2 order, each omitted when empty. §2's
    /// own order and output are unchanged, so a card written before this section and one written
    /// after differ by an append.
    ///
    /// This is the ONE place the extension touches the protocol's own codec, and it is the whole of
    /// §10.6: a client that implements §10 must write back the work lines it read, or a follow —
    /// which rewrites the entire pinned message — quietly deletes somebody's work card.
    static func serialise(_ card: Card, work: Work?) -> String {
        let lines = WorkCodec.lines(work, feeds: card.feeds)
        let base = serialise(card)
        return lines.isEmpty ? base : base + "\n" + lines.joined(separator: "\n")
    }

    /// §2's 4096 cap, unmoved, now counting the work lines the same write would carry.
    static func isFull(_ card: Card, work: Work?) -> Bool { serialise(card, work: work).count > maxLength }
}

// MARK: - Work dates on screen (PRODUCT §2.23, §2.25)

public enum WorkDate {
    /// `until 1 Dec` — day and month, the year appended only when it is not this one (§2.23).
    /// Derived from the date, never typed.
    public static func short(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let c = WorkCodec.civil(day) else { return nil }
        let thisYear = calendar.component(.year, from: now)
        return "\(c.d) \(monthAbbrev(c.m))" + (c.y == thisYear ? "" : " \(c.y)")
    }

    /// `5 Dec 2026` — the Edit Card `FOR` line, which always carries the year because it is a date
    /// the writer is choosing rather than reading.
    public static func full(_ day: String) -> String? {
        guard let c = WorkCodec.civil(day) else { return nil }
        return "\(c.d) \(monthAbbrev(c.m)) \(c.y)"
    }

    /// `Mar 2026` — a vouch's date (§2.25). Everywhere else in this app time is relative, because a
    /// post's recency is what matters; a vouch is the opposite, and `2y ago` buries exactly the
    /// thing a reader is weighing.
    public static func monthYear(unix: Int, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let m = calendar.component(.month, from: date)
        let y = calendar.component(.year, from: date)
        return "\(monthAbbrev(m)) \(y)"
    }

    static func monthAbbrev(_ m: Int) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard m >= 1, m <= 12 else { return "" }
        return names[m - 1]
    }
}
