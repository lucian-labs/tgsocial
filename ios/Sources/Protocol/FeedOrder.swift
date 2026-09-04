// Protocol — the one ordering rule for every list of posts (PRODUCT.md §2.3): strictly newest
// first, message id breaking date ties. Every merge, append, and live insert goes through this;
// an ascending sort anywhere in the app is a bug. Pure Swift.

import Foundation

public enum FeedOrder {
    /// `a` renders above `b`.
    public static func isNewer<T: FeedEntry>(_ a: T, than b: T) -> Bool {
        a.date != b.date ? a.date > b.date : a.messageId > b.messageId
    }

    public static func sortNewestFirst<T: FeedEntry>(_ items: inout [T]) {
        items.sort { isNewer($0, than: $1) }
    }

    public static func sortedNewestFirst<T: FeedEntry>(_ items: [T]) -> [T] {
        items.sorted { isNewer($0, than: $1) }
    }

    public static func isNewestFirst<T: FeedEntry>(_ items: [T]) -> Bool {
        guard items.count > 1 else { return true }
        for i in 1..<items.count where isNewer(items[i], than: items[i - 1]) { return false }
        return true
    }
}

/// Explore's NEARBY and the +1 list (PRODUCT §2.4, §2.7): most of my follows first, ties broken by
/// username **ascending**.
///
/// One function because two callers rank the same list — the graph walk over live cards, and the
/// demo's fixed world (PRODUCT §2.22.1, which writes the resulting order down). §2.22.1 spells the
/// tie-break out "because otherwise three platforms produce three orders", and the same argument
/// applies to two code paths inside one platform: a tuple comparison here reads as ascending and
/// sorts descending, which is exactly the drift this is here to stop. Pure, so the demo can call it
/// without reaching anything that imports TDLib.
public enum NearbyOrder {
    public static func ranked(_ counts: [String: Int]) -> [String] {
        counts.keys.sorted { a, b in
            let (ca, cb) = (counts[a] ?? 0, counts[b] ?? 0)
            return ca != cb ? ca > cb : a < b
        }
    }
}
