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
