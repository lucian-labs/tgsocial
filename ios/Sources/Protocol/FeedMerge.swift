// Protocol — main feed k-way merge with per-source cursors (PROTOCOL.md §4.8). Pure Swift.
//
// Each source holds a buffer of items sorted newest-first plus a cursor (oldest message id fetched).
// `drain` pops the newest item across sources as long as every non-exhausted source still has a
// buffered item (otherwise an unseen newer item could exist). When it stops, `sourceToRefill` names
// the empty, non-exhausted source whose last-known item was newest — that is the one "Load more" fills.

import Foundation

public protocol FeedEntry {
    /// Source key (channel username, lowercased).
    var sourceKey: String { get }
    var messageId: Int64 { get }
    /// Unix seconds.
    var date: Int { get }
}

public struct FeedSourceState<Item: FeedEntry>: Equatable where Item: Equatable {
    public let key: String
    public var buffer: [Item] = []
    /// Oldest message id fetched so far; 0 = nothing fetched yet.
    public var cursor: Int64 = 0
    /// Date of the last item fetched (newest unseen boundary) — used to pick the refill order.
    public var lastKnownDate: Int = .max
    public var exhausted = false
    public var fetchedOnce = false

    public init(key: String) { self.key = key }
}

public struct FeedMerger<Item: FeedEntry & Equatable>: Equatable {
    public private(set) var sources: [String: FeedSourceState<Item>] = [:]

    public init(sourceKeys: [String]) {
        for k in sourceKeys { sources[k] = FeedSourceState(key: k) }
    }

    public var sourceKeys: [String] { sources.keys.sorted() }

    /// Replace the set of sources, keeping state for ones that remain.
    public mutating func setSources(_ keys: [String]) {
        var next: [String: FeedSourceState<Item>] = [:]
        for k in keys { next[k] = sources[k] ?? FeedSourceState(key: k) }
        sources = next
    }

    public mutating func reset() {
        for k in sources.keys { sources[k] = FeedSourceState(key: k) }
    }

    /// Feed a page of items (any order) for one source. `oldestFetchedId` advances the cursor even when the
    /// page held only service messages; `exhausted` marks the end of that source's history.
    public mutating func add(_ items: [Item], to key: String, oldestFetchedId: Int64? = nil, exhausted: Bool) {
        guard var s = sources[key] else { return }
        s.fetchedOnce = true
        let known = Set(s.buffer.map(\.messageId))
        let fresh = items.filter { !known.contains($0.messageId) && $0.sourceKey == key }
        s.buffer.append(contentsOf: fresh)
        FeedOrder.sortNewestFirst(&s.buffer)
        if let oldest = [oldestFetchedId, items.map(\.messageId).min()].compactMap({ $0 }).min(), oldest > 0 {
            s.cursor = s.cursor == 0 ? oldest : min(s.cursor, oldest)
        }
        if let oldestDate = fresh.map(\.date).min() { s.lastKnownDate = oldestDate }
        if exhausted { s.exhausted = true }
        sources[key] = s
    }

    /// Whether the merge can safely emit: every non-exhausted source has at least one buffered item.
    public var canEmit: Bool {
        sources.values.allSatisfy { $0.exhausted || !$0.buffer.isEmpty }
            && sources.values.contains { !$0.buffer.isEmpty }
    }

    /// Pops up to `count` items newest-first while the merge is safe.
    public mutating func drain(_ count: Int) -> [Item] {
        var out: [Item] = []
        while out.count < count, canEmit {
            guard let bestKey = sources.values
                .filter({ !$0.buffer.isEmpty })
                .max(by: { a, b in FeedOrder.isNewer(b.buffer[0], than: a.buffer[0]) })?.key else { break }
            out.append(sources[bestKey]!.buffer.removeFirst())
        }
        return out
    }

    /// The empty, non-exhausted source whose last-known item was newest; nil when none needs a refill.
    public var sourceToRefill: String? {
        sources.values
            .filter { !$0.exhausted && $0.buffer.isEmpty }
            .sorted { a, b in
                if a.fetchedOnce != b.fetchedOnce { return !a.fetchedOnce }
                return a.lastKnownDate != b.lastKnownDate ? a.lastKnownDate > b.lastKnownDate : a.key < b.key
            }
            .first?.key
    }

    /// Every source exhausted and every buffer empty.
    public var isExhausted: Bool {
        sources.values.allSatisfy { $0.exhausted && $0.buffer.isEmpty }
    }

    public func cursor(for key: String) -> Int64 { sources[key]?.cursor ?? 0 }
}
