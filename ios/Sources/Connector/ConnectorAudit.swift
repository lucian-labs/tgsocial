// Connector — the audit log (CONNECTOR.md §6, PRODUCT.md §2.14). Mac only.
//
// Every request appends one line, and the line records *what was asked and what was decided* —
// never what came back. No post text, no comment body, no card copy, no usernames beyond the one
// in the path that was already the question. That restraint is the point: an audit log that
// carried bodies would be a second, unencrypted copy of the reader's Telegram sitting in a plain
// file, which is a worse leak than the thing it was written to police.
//
// Two sinks, one entry: an in-memory ring the Connector screen paints live (last 100), and
// `~/.tgsocial/audit.log` at mode 0600, rotated at 5 MB.
//
// One line per entry, and *one* line: every field an entry carries is scrubbed of anything that
// could end a line or start another (`AuditField.clean`). The fields are caller-influenced — the
// tool column is the method plus the percent-decoded request target, and the target is audited on
// the 401 branch, before any token has been checked — so without that scrub an unauthenticated
// local process could append forged `ok` rows and truncate the genuine ones. The log is the only
// durable evidence §1 offers; a log a caller can write into is not evidence.

#if targetEnvironment(macCatalyst)

import Foundation
import Observation

/// Field hygiene for the log line (CONNECTOR.md §6).
enum AuditField {
    static let toolLimit = 96
    static let decisionLimit = 64
    static let detailLimit = 160
    /// The composed detail column: a refusal reason plus the caller's detail, both already capped.
    static let columnLimit = 2 * detailLimit + 8
    /// Appended when a field was cut, so a truncated column is visibly truncated rather than a
    /// quieter lie about what was asked.
    static let cut = "..."

    /// Scalars that are printed as they are: printable ASCII, plus anything above the C1 range
    /// that is neither a separator nor an invisible format control. Everything else — CR, LF,
    /// TAB, DEL, the C0/C1 controls, U+2028/U+2029, the bidi overrides and the zero-widths —
    /// becomes a visible escape. The test is deliberately a whitelist by codepoint rather than a
    /// Unicode property lookup: what may appear in an audit line should not depend on which ICU
    /// tables the host happens to ship.
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x20..<0x7F: return true
        case 0x00...0x1F, 0x7F, 0x80...0x9F: return false
        case 0x2028, 0x2029, 0xFEFF: return false
        case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069: return false
        default: return scalar.value >= 0xA0
        }
    }

    /// True when a string carries anything the log would have to escape.
    static func needsEscaping(_ value: String) -> Bool {
        value.unicodeScalars.contains { !isPrintable($0) }
    }

    static func clean(_ value: String, limit: Int) -> String {
        guard needsEscaping(value) || value.count > limit else { return value }
        var out = ""
        out.reserveCapacity(Swift.min(value.count, limit) + Self.cut.count)
        for scalar in value.unicodeScalars {
            guard out.count < limit else { return out + Self.cut }
            if isPrintable(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += escape(scalar)
            }
        }
        return out
    }

    private static func escape(_ scalar: Unicode.Scalar) -> String {
        scalar.value <= 0xFF ? String(format: "\\x%02x", scalar.value)
                             : String(format: "\\u{%04x}", scalar.value)
    }
}

/// One audited request.
struct AuditEntry: Identifiable, Equatable {
    enum Outcome: Equatable {
        case ok
        case refused(String)
        case failed(String)

        /// The column §6 prints: `ok` or `REFUSED`. Upper case for refusals because that is the
        /// line a person scanning the log is looking for.
        var column: String {
            switch self {
            case .ok: return "ok"
            case .refused: return "REFUSED"
            case .failed: return "ERROR"
            }
        }

        var detailSuffix: String {
            switch self {
            case .ok: return ""
            case .refused(let why), .failed(let why): return why
            }
        }

        var isRefusal: Bool { if case .refused = self { return true } else { return false } }
        var isFailure: Bool { if case .failed = self { return true } else { return false } }

        /// The reason is a fixed vocabulary today (`ConnectorError.auditReason`), but it is a
        /// string, and a string that reaches the line gets the same scrub as every other field.
        var cleaned: Outcome {
            switch self {
            case .ok: return .ok
            case .refused(let why): return .refused(AuditField.clean(why, limit: AuditField.detailLimit))
            case .failed(let why): return .failed(AuditField.clean(why, limit: AuditField.detailLimit))
            }
        }
    }

    let id = UUID()
    /// `GET /feed`, `POST /post` — the method and path, which is what §7 calls the tool.
    let tool: String
    /// `scope=graph`, `feed=waveloop_devlog` — the decision column.
    let decision: String
    let outcome: Outcome
    /// `posts=30`, `cached`, `read-only`. Counts and verdicts only; never content.
    let detail: String
    let at: Date

    /// Scrubbed at the door, not at the sink: the ring the screen paints, the `GET /audit` body and
    /// the file all read the same stored fields, so an entry that exists is already safe to print.
    init(tool: String, decision: String, outcome: Outcome, detail: String = "", at: Date = Date()) {
        self.tool = AuditField.clean(tool, limit: AuditField.toolLimit)
        self.decision = AuditField.clean(decision, limit: AuditField.decisionLimit)
        self.outcome = outcome.cleaned
        self.detail = AuditField.clean(detail, limit: AuditField.detailLimit)
        self.at = at
    }

    /// The refusal reason and the caller's detail collapse into one column, so
    /// `REFUSED read-only` reads exactly as §6 prints it.
    var detailColumn: String {
        let suffix = outcome.detailSuffix
        if suffix.isEmpty { return detail }
        if detail.isEmpty { return suffix }
        return suffix + " " + detail
    }

    /// The §6 line. Column widths are fixed so a `tail -f` stays readable, and a field wider than
    /// its column pushes the rest along rather than being truncated — a truncated audit line is a
    /// lie about what was asked.
    var line: String { AuditLine.format(self) }
}

enum AuditLine {
    static let toolWidth = 16
    static let decisionWidth = 11
    static let outcomeWidth = 7

    static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func pad(_ value: String, _ width: Int) -> String {
        value.count >= width ? value : value + String(repeating: " ", count: width - value.count)
    }

    /// `AuditEntry.init` already cleaned every field; cleaning again here costs a scan and means
    /// the file sink cannot be handed a line with a newline in it even by a caller that built an
    /// entry some other way.
    static func format(_ entry: AuditEntry) -> String {
        let stamp = timestampFormatter.string(from: entry.at)
        let fields = [pad(AuditField.clean(entry.tool, limit: AuditField.toolLimit), toolWidth),
                      pad(AuditField.clean(entry.decision, limit: AuditField.decisionLimit), decisionWidth),
                      pad(entry.outcome.column, outcomeWidth),
                      AuditField.clean(entry.detailColumn, limit: AuditField.columnLimit)]
        return (stamp + "  " + fields.joined(separator: " "))
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }
}

/// The file sink: append, 0600, rotate at 5 MB.
struct AuditLogFile {
    static let rotateAtBytes: UInt64 = 5 * 1024 * 1024
    static let fileName = "audit.log"
    static let rotatedName = "audit.log.1"
    static let mode: NSNumber = 0o600

    let directory: URL

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var rotatedURL: URL { directory.appendingPathComponent(Self.rotatedName) }

    func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: ConnectorHandshakeStore.directoryMode])
        rotateIfNeeded()
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: Self.mode])
            return
        }
        // Appending rather than rewriting: the log is evidence, and a rewrite is a chance to lose
        // the lines that were already there.
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)??.uint64Value,
              size >= Self.rotateAtBytes else { return }
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        try? fm.setAttributes([.posixPermissions: Self.mode], ofItemAtPath: rotatedURL.path)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: rotatedURL)
    }
}

/// The in-memory ring the screen paints (PRODUCT §2.14: "newest first, last 100"). Observable, so
/// Activity streams live while the screen is open. `Clear Activity` empties this and leaves the
/// file alone — the log is not the user's to rewrite.
@MainActor @Observable
final class AuditRing {
    static let capacity = 100

    private(set) var entries: [AuditEntry] = []
    @ObservationIgnored private let file: AuditLogFile?

    init(file: AuditLogFile?) { self.file = file }

    func append(_ entry: AuditEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        file?.append(entry.line)
    }

    func clear() { entries.removeAll() }
}

#endif
