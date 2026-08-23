package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Post

/**
 * PRODUCT §2.3 — every list of posts is strictly newest first, end to end: the merge, live inserts, load-more
 * appends, and the channel screen all come through here. A reversed list or an ascending sort anywhere is a bug.
 */
object FeedOrder {
    /** Newest first; message id breaks date ties (later ids are later posts). */
    val newestFirst: Comparator<Post> = compareByDescending<Post> { it.date }.thenByDescending { it.messageId }

    /** True when [posts] is already strictly newest first. */
    fun isNewestFirst(posts: List<Post>): Boolean =
        posts.zipWithNext().all { (a, b) -> newestFirst.compare(a, b) <= 0 }

    fun sort(posts: List<Post>): List<Post> = posts.sortedWith(newestFirst)

    /**
     * A post arriving live lands at the top (or wherever its date orders it, if an older post arrives late).
     * A member of an album already on screen merges into that album's post instead of adding a card.
     */
    fun insertLive(posts: List<Post>, post: Post): List<Post> {
        if (posts.any { it.key == post.key }) return posts
        if (post.albumId != 0L) {
            val i = posts.indexOfFirst { it.albumId == post.albumId && it.chatId == post.chatId }
            if (i >= 0) {
                val merged = mergeAlbumPair(posts[i], post)
                return sort(posts.toMutableList().apply { this[i] = merged })
            }
        }
        return sort(posts + post)
    }

    /** Load-more: older posts append below; anything already present is dropped; order re-asserted. */
    fun append(posts: List<Post>, more: List<Post>): List<Post> {
        val seen = posts.mapTo(HashSet()) { it.key }
        val fresh = more.filter { seen.add(it.key) }
        if (fresh.isEmpty()) return posts
        return sort(posts + fresh)
    }

    /**
     * Collapses album members (shared non-zero `mediaAlbumId` in one chat) into one post: media in posting order
     * (oldest first, so the viewer pages left to right), card dated and keyed by the newest member.
     */
    fun mergeAlbums(posts: List<Post>): List<Post> {
        if (posts.none { it.albumId != 0L }) return sort(posts)
        val out = ArrayList<Post>(posts.size)
        val albums = LinkedHashMap<Pair<Long, Long>, Int>()
        for (post in sort(posts).asReversed()) { // oldest first so album media accumulates in posting order
            if (post.albumId == 0L) {
                out += post
                continue
            }
            val key = post.chatId to post.albumId
            val at = albums[key]
            if (at == null) {
                albums[key] = out.size
                out += post
            } else {
                out[at] = mergeAlbumPair(out[at], post)
            }
        }
        return sort(out)
    }

    private fun mergeAlbumPair(a: Post, b: Post): Post {
        val (older, newer) = if (newestFirst.compare(a, b) <= 0) b to a else a to b
        val caption = a.text ?: b.text
        return newer.copy(
            text = caption,
            media = older.media + newer.media,
            linkPreview = a.linkPreview ?: b.linkPreview,
            views = maxOf(a.views, b.views),
            reactions = if (a.reactions.isNotEmpty()) a.reactions else b.reactions,
        )
    }
}
