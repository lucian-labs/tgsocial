// Protocol — the bound on how much of a feed is held in memory at once. Pure Swift.
//
// The main feed is strictly newest-first (FeedOrder) and pages *into the past*: "Load more"
// appends older posts at the tail and the viewport travels down with them. Left alone, a long
// scroll grows the array without limit, so the array is capped — but only where the list is
// rebuilt from the top with nothing scrolled into it: a cold start off the disk cache, or a
// refresh that redraws the window. Never underneath a live viewport.
//
// Both halves of that rule are load-bearing:
//
//   * Evicting the **tail** (the numerically oldest posts) would delete the page that "Load more"
//     just appended — the window would snap back to the same contents on every call and pagination
//     would dead-end at the cap. The user could never read past post N.
//   * Evicting the **head** removes content from *above* the viewport. The feed is a plain
//     `ScrollView` + `LazyVStack` and the deployment target (iOS 17) offers no way to anchor
//     contentOffset across that mutation: the offset survives while the content above it shrinks,
//     so the reader is thrown forward by exactly the number of cards dropped. Done during paging it
//     is self-sustaining — "Load more" only ever fires with the viewport near the tail, so the trim
//     lands the reader back at the tail and immediately triggers the next page, and the feed
//     auto-pages until it is exhausted. It also strands live posts: `apply(newMessage:)` inserts at
//     index 0, which in a head-trimmed window puts today's post directly above content from
//     hundreds of posts earlier with no gap indicator.
//
// So `FeedRepository` applies this cap at rebuild points only, and `loadMore` never touches the
// head. The array is the cheap term anyway — a `Post` holds refs, text and a ~1 KB minithumbnail —
// while the bytes that actually caused jetsam are the decoded bitmaps, and those are bounded
// independently by `ImageMemoryCache`'s byte budget and its memory-warning purge. This is a ceiling
// on a pathological rebuild, not a scroll-time collector.

import Foundation

public enum FeedWindow {
    /// The ceiling on a window rebuilt from the top. High enough that it is a backstop rather than
    /// something ordinary reading meets — the entries are ~1 KB each, so the cap is order-1 MB of
    /// structs, and unlike the decoded bitmaps it was never the term that mattered.
    public static let maxPosts = 1000

    /// What `LocalStore` persists — unchanged; the disk cache was already capped.
    public static let cacheSize = 60

    /// How many entries have to leave the front for the window to fit `limit`.
    public static func overflow(_ count: Int, limit: Int = maxPosts) -> Int {
        guard limit > 0 else { return count }
        return max(0, count - limit)
    }

    /// The bounded window: the last `limit` entries, in the order they were given. Applied to a
    /// newest-first list this keeps it newest-first — it only drops from the front.
    ///
    /// Call this only where nothing is scrolled into the list (see the note above): it is a rebuild
    /// primitive, and applying it to a window the reader is inside teleports them forward.
    public static func trimmed<T: FeedEntry>(_ items: [T], limit: Int = maxPosts) -> [T] {
        let drop = overflow(items.count, limit: limit)
        guard drop > 0 else { return items }
        return Array(items.dropFirst(drop))
    }
}
