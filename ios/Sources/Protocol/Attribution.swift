// Protocol — post attribution (PRODUCT.md §2.3): the person leads, the channel follows. The header
// of a post card is the NODE the post reaches you through, not the channel. Pure Swift.

import Foundation

public enum Attribution {
    /// The node a post from `feed` reaches me through:
    /// - me, when the feed is one of my feeds;
    /// - else the node I follow whose card lists the feed — when several list it, the earliest
    ///   in my `follows:` order;
    /// - nil when no node attributes it (the card falls back to the channel itself).
    public static func node(feed: String, me: String?,
                            myFeeds: [String],
                            follows: [(username: String, feeds: [String])]) -> String? {
        let key = Username.key(feed)
        if let me, myFeeds.contains(where: { Username.key($0) == key }) { return me }
        for follow in follows where follow.feeds.contains(where: { Username.key($0) == key }) {
            return follow.username
        }
        return nil
    }
}
