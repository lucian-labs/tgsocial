// App — the activity registry (PRODUCT.md §2.10). Every in-flight operation registers itself
// with a label ("Reading card @tgs_ana", "Downloading photo"); the status pill says `Syncing`
// exactly while this list is non-empty. Removal is impossible to forget by construction:
// `run` pairs begin/end in a defer (success, throw, and cancellation all pass through it),
// and every entry self-expires after 30 s regardless — a stuck pill cannot happen.

import Foundation
import Observation

@MainActor @Observable
final class ActivityRegistry {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let label: String
        let startedAt: Date
    }

    /// PRODUCT §2.10: every in-flight operation must remove itself on success, failure,
    /// or timeout (30 s).
    static let timeout: Duration = .seconds(30)

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// Registers an operation. Prefer `run`; use begin/end only when the operation's
    /// lifetime cannot be a single scope (and pair them in a defer there too).
    @discardableResult
    func begin(_ label: String) -> UUID {
        let id = UUID()
        entries.append(Entry(id: id, label: label, startedAt: Date()))
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.end(id)
        }
        return id
    }

    func end(_ id: UUID) {
        timers.removeValue(forKey: id)?.cancel()
        entries.removeAll { $0.id == id }
    }

    /// Runs `op` registered under `label`. The defer runs on success, throw, and task
    /// cancellation alike, so the entry can never outlive the operation.
    func run<T>(_ label: String, _ op: () async throws -> T) async rethrows -> T {
        let id = begin(label)
        defer { end(id) }
        return try await op()
    }

    /// The Pending rows for the Status sheet: known families collapse to one line
    /// ("Reading 3 cards…"), everything else is listed verbatim, deduped.
    var summary: [String] {
        guard !entries.isEmpty else { return [] }
        var lines: [String] = []
        var counted: [(prefix: String, plural: (Int) -> String, count: Int, first: String)] = [
            ("Reading card ", { "Reading \($0) cards\u{2026}" }, 0, ""),
            ("Reading comments ", { "Reading \($0) comments channels\u{2026}" }, 0, ""),
            ("Loading @", { "Loading \($0) feeds\u{2026}" }, 0, ""),
            ("Downloading photo", { "Downloading \($0) photos\u{2026}" }, 0, ""),
        ]
        var others: [String] = []
        for e in entries {
            if let i = counted.firstIndex(where: { e.label.hasPrefix($0.prefix) }) {
                counted[i].count += 1
                if counted[i].first.isEmpty { counted[i].first = e.label }
            } else if !others.contains(e.label) {
                others.append(e.label)
            }
        }
        for c in counted where c.count > 0 {
            lines.append(c.count == 1 ? c.first : c.plural(c.count))
        }
        lines.append(contentsOf: others)
        if lines.count > 4 {
            let more = lines.count - 3
            lines = Array(lines.prefix(3)) + ["and \(more) more\u{2026}"]
        }
        return lines
    }
}
