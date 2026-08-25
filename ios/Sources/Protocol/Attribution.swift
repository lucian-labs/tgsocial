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

    /// The photo the post card's avatar wears (PRODUCT §2.3 "The avatar is the source channel").
    /// A node is an *aggregate* of a person's channels, so the avatar says which channel the post
    /// came from — it is the only thing telling two posts by the same person from different feeds
    /// apart. The name beside it stays the person.
    ///
    /// The chain, since any of these can be missing:
    /// 1. the source channel's photo;
    /// 2. else the node's own photo;
    /// 3. else nil — the card draws the initial in the display serif.
    ///
    /// Telegram serves a **generated letter avatar** for a channel with no photo. On the public web
    /// page that arrives as a `data:image/svg+xml` image on a `bgcolorN` element and has to be
    /// detected and discarded; the app never sees it at all, because TDLib reports `chat.photo` as
    /// null and `Mapping.photoRef(nil)` maps that to nil. Either way a generated letter is *not* a
    /// photo and falls through to the node, so an unphotographed channel renders our initial rather
    /// than Telegram's.
    static func avatarPhoto(sourcePhoto: PhotoRef?, nodePhoto: PhotoRef?) -> PhotoRef? {
        sourcePhoto ?? nodePhoto
    }
}
