package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.Post
import kotlinx.serialization.Serializable

/**
 * PROTOCOL §7.1 — one reported thing. [key] is the §6.2 target key (`<channel>/<messageId>`, lowercased),
 * [reason] is the PRODUCT §2.15 reason string verbatim so Settings can say what was reported without keeping
 * a copy of the content, and [at] is ISO 8601 UTC.
 */
@Serializable
data class HiddenItem(val key: String, val reason: String, val at: String)

/**
 * PROTOCOL §7.1 — the reader's own block, mute and report state. One record, stored apart from every cache.
 *
 * [v] is this record's own version and deliberately **not** the cache schema version (`LocalStore.SCHEMA_VERSION`):
 * a cache bump discards caches and must never discard someone's block list. An unknown [v] is read as best it can
 * be — the decoder ignores keys it does not know — and never dropped.
 *
 * [userId] is the Telegram user id that wrote the record; [forAccount] is what a client applies on
 * `authorizationStateReady`. Nothing here is ever published: not to the card, not to Telegram, not anywhere.
 */
@Serializable
data class SafetyLists(
    val v: Int = VERSION,
    val userId: Long = 0,
    /** Node usernames, lowercased, no `@`. */
    val blocked: List<String> = emptyList(),
    /** Feed channel usernames, lowercased, no `@`. */
    val mutedFeeds: List<String> = emptyList(),
    val hidden: List<HiddenItem> = emptyList(),
) {
    companion object {
        const val VERSION = 1
    }

    // Telegram usernames are case-insensitive, so every comparison goes through the card parser's own
    // normalisation (Username.key). A list that missed @TGS_Ana would be a filter with a hole in it.
    private val blockedKeys: Set<String> by lazy { blocked.map { Username.key(it) }.toSet() }
    private val mutedKeys: Set<String> by lazy { mutedFeeds.map { Username.key(it) }.toSet() }
    private val hiddenKeys: Set<String> by lazy { hidden.map { it.key.lowercase() }.toSet() }

    val isEmpty: Boolean get() = blocked.isEmpty() && mutedFeeds.isEmpty() && hidden.isEmpty()

    fun isBlocked(username: String?): Boolean = username != null && Username.key(username) in blockedKeys
    fun isMuted(feed: String?): Boolean = feed != null && Username.key(feed) in mutedKeys
    fun isHidden(key: String?): Boolean = key != null && key.lowercase() in hiddenKeys

    fun block(username: String): SafetyLists =
        if (isBlocked(username)) this else copy(blocked = blocked + Username.key(username))

    fun unblock(username: String): SafetyLists =
        copy(blocked = blocked.filterNot { Username.same(it, username) })

    fun mute(feed: String): SafetyLists =
        if (isMuted(feed)) this else copy(mutedFeeds = mutedFeeds + Username.key(feed))

    fun unmute(feed: String): SafetyLists =
        copy(mutedFeeds = mutedFeeds.filterNot { Username.same(it, feed) })

    /** Reporting the same thing twice restates the reason rather than listing it twice in Settings. */
    fun hide(key: String, reason: String, at: String): SafetyLists {
        val k = key.lowercase()
        return copy(hidden = hidden.filterNot { it.key.lowercase() == k } + HiddenItem(k, reason, at))
    }

    fun unhide(key: String): SafetyLists =
        copy(hidden = hidden.filterNot { it.key.equals(key, ignoreCase = true) })

    /**
     * PROTOCOL §7.1 — the lists survive Sign Out **for the same account**. A list that evaporated on sign-out
     * would re-expose the reader to the person they blocked; a list inherited by a different account on a shared
     * device would be someone else's judgement. The id settles both: same account keeps the record, a different
     * one starts empty.
     */
    fun forAccount(id: Long): SafetyLists = if (id == userId) this else SafetyLists(userId = id)
}

/**
 * PRODUCT §2.18 — **the default filter**: on, with no switch behind it, applied at render on every surface that
 * paints posts, comments or nodes.
 *
 * It drops rather than marks. A tombstone in a chronological feed still reports how often the blocked person
 * posts and hands them a strip of the screen on every scroll, which is the thing the reader asked to stop — so a
 * dropped item leaves no gap, no placeholder, and no residue in a count (the comment count is derived from the
 * filtered index, not from the raw one).
 */
object SafetyFilter {

    /** The §6.2 target key of a post — the same string a `re:` line pointing at it resolves to. */
    fun key(post: Post): String = CommentFormat.postKey(post.sourceUsername, post.messageId)

    /** The §6.2 target key of a comment: comments channels are public, so a comment has a link of its own. */
    fun key(comment: Comment): String = CommentFormat.postKey(comment.channelUsername, comment.messageId)

    /**
     * [mainFeed] is the one asymmetry §2.17 asks for: a muted feed leaves the merged feed and nothing else —
     * its own channel screen stays complete, and so do its comments wherever they appear.
     */
    fun keeps(post: Post, lists: SafetyLists, mainFeed: Boolean): Boolean = when {
        lists.isBlocked(post.nodeUsername) -> false
        lists.isHidden(key(post)) -> false
        mainFeed && lists.isMuted(post.sourceUsername) -> false
        else -> true
    }

    fun posts(posts: List<Post>, lists: SafetyLists, mainFeed: Boolean): List<Post> =
        if (lists.isEmpty) posts else posts.filter { keeps(it, lists, mainFeed) }

    fun keeps(comment: Comment, lists: SafetyLists): Boolean =
        !lists.isBlocked(comment.authorUsername) && !lists.isHidden(key(comment))

    /**
     * The comment index with blocked and reported comments gone. Filtering the index rather than the rendered
     * tree is what takes the replies under a dropped comment with it — `CommentRepo.tree` walks `re:` chains
     * through this map, so a comment that is not in it has no children to find — and what keeps the post
     * footer's `N comments` honest, since that count is `tree().sumOf { it.count }` over the same map.
     */
    fun comments(index: Map<String, List<Comment>>, lists: SafetyLists): Map<String, List<Comment>> {
        if (lists.isEmpty) return index
        val out = LinkedHashMap<String, List<Comment>>(index.size)
        for ((target, list) in index) {
            val kept = list.filter { keeps(it, lists) }
            if (kept.isNotEmpty()) out[target] = kept
        }
        return out
    }

    /** Explore rows, both graph lists, the +1 walk: a blocked node is not in them, and not in their counts. */
    fun nodes(entries: List<NodeEntry>, lists: SafetyLists): List<NodeEntry> =
        if (lists.isEmpty) entries else entries.filterNot { lists.isBlocked(it.username) }
}
