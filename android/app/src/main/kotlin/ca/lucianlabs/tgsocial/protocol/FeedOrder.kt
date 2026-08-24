package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Post

/**
 * PRODUCT §2.3 — every list of posts is strictly newest first, end to end: the merge, live inserts, load-more
 * appends, and the channel screen all come through here. A reversed list or an ascending sort anywhere is a bug.
 */
object FeedOrder {
    /**
     * How many posts the in-memory feed may hold. A `Post` is small (a few kB of strings and file refs), but an
     * infinite scroll session used to grow the list forever and, worse, kept every one of those posts' media
     * refs reachable. 300 is ~15 pages of load-more, far more than the ~15 items the LazyColumn composes, so
     * the trim never touches the viewport.
     *
     * It does eventually touch what the reader can scroll *back* to: the window is a contiguous run of posts
     * ending at the pagination cursor, and its head slides down as pages are loaded (see [window]). Getting
     * back to the newest post is a refresh, not a scroll.
     */
    const val WINDOW = 300

    /**
     * Keep the oldest [max] — i.e. drop already-read posts off the top.
     *
     * **There is exactly one trimming end and this is it.** The window is anchored at its *tail*: the last post
     * held is the oldest post `FeedRepo` has fetched, the post its pagination cursor sits directly behind.
     * Trimming that end — as a live insert that kept the newest [max] would — strands the cursor: the next
     * load-more returns posts strictly older than the one just dropped, so the feed silently skips a post and
     * nothing in the session can refill it. Trimming the head only drops posts the reader has already scrolled
     * past, and pull-to-refresh (`AppViewModel.refreshFeed`) is the way back to the top.
     *
     * The LazyColumn is keyed by `post.key`, so removing items above the viewport re-anchors instead of jumping.
     */
    fun window(posts: List<Post>, max: Int = WINDOW): List<Post> =
        if (posts.size <= max) posts else posts.subList(posts.size - max, posts.size).toList()

    /** Newest first; message id breaks date ties (later ids are later posts). */
    val newestFirst: Comparator<Post> = compareByDescending<Post> { it.date }.thenByDescending { it.messageId }

    /** True when [posts] is already strictly newest first. */
    fun isNewestFirst(posts: List<Post>): Boolean =
        posts.zipWithNext().all { (a, b) -> newestFirst.compare(a, b) <= 0 }

    fun sort(posts: List<Post>): List<Post> = posts.sortedWith(newestFirst)

    /**
     * A post arriving live lands at the top (or wherever its date orders it, if an older post arrives late).
     * A member of an album already on screen merges into that album's post instead of adding a card.
     *
     * The trim is [window]'s, the same end load-more uses, so a live insert can never drop the pagination
     * anchor. Once the window is full that means a post newer than the head has nowhere to go — check
     * [isAboveFullWindow] first and surface it instead of handing it here to be trimmed straight back off.
     */
    fun insertLive(posts: List<Post>, post: Post, max: Int = WINDOW): List<Post> {
        if (posts.any { it.key == post.key }) return posts
        if (post.albumId != 0L) {
            val i = posts.indexOfFirst { it.albumId == post.albumId && it.chatId == post.chatId }
            if (i >= 0) {
                val merged = mergeAlbumPair(posts[i], post)
                return sort(posts.toMutableList().apply { this[i] = merged })
            }
        }
        return window(sort(posts + post), max)
    }

    /**
     * True when [post] arrives above a window that is already full: it sorts newer than everything held, and
     * the only room for it would come from dropping the tail — the pagination anchor (see [window]). The
     * caller flags "newer posts" and lets a refresh jump back to the top rather than losing either end.
     */
    fun isAboveFullWindow(posts: List<Post>, post: Post, max: Int = WINDOW): Boolean {
        if (posts.isEmpty() || posts.size < max) return false
        if (posts.any { it.key == post.key }) return false
        // An album member merges into a card already held — it adds nothing to trim.
        if (post.albumId != 0L && posts.any { it.albumId == post.albumId && it.chatId == post.chatId }) return false
        return newestFirst.compare(post, posts.first()) < 0
    }

    /**
     * Load-more: older posts append below; anything already present is dropped; order re-asserted; the window
     * slides so the list cannot grow without bound. The merge cursors live in `FeedRepo` and are untouched by
     * the trim, so the next page still continues from where the last one ended.
     */
    fun append(posts: List<Post>, more: List<Post>, max: Int = WINDOW): List<Post> {
        val seen = posts.mapTo(HashSet()) { it.key }
        val fresh = more.filter { seen.add(it.key) }
        if (fresh.isEmpty()) return posts
        return window(sort(posts + fresh), max)
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
