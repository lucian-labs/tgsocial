package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.protocol.Card
import ca.lucianlabs.tgsocial.protocol.FeedMerger
import ca.lucianlabs.tgsocial.protocol.FeedOrder
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.td.TelegramClient
import ca.lucianlabs.tgsocial.td.orNull
import dev.g000sha256.tdl.dto.Message
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** PROTOCOL §4.8 — the main feed: sources = my feeds ∪ feeds of every node I follow; k-way merge by date. */
class FeedRepo(
    private val tg: TelegramClient,
    private val nodes: NodeRepo,
    private val store: LocalStore,
    private val activity: ActivityRegistry,
) {
    companion object {
        const val PAGE = 30
    }

    var displayWidthPx: Int = 1080

    private val merger = FeedMerger<Post>(dateOf = { it.date }, idOf = { it.messageId })
    private val sources = LinkedHashMap<String, FeedSource>()
    private val lock = Mutex()

    val sourceList: List<FeedSource> get() = sources.values.toList()

    /** Resolve sources from my card and the cards of my follows. Cards that cannot be read are skipped. */
    suspend fun resolveSources(myUsername: String?, myCard: Card?, fresh: Boolean = false): List<FeedSource> {
        val wanted = LinkedHashMap<String, MutableList<String>>() // feed → listed by
        fun add(feed: String, node: String?) {
            wanted.getOrPut(Username.key(feed)) { mutableListOf() }.let { if (node != null && node !in it) it += node }
        }
        myCard?.feeds?.forEach { add(it, myUsername) }
        myCard?.follows?.forEach { follow ->
            // Offline: reads serve cache (PRODUCT §4) — never wait out a request timeout per follow.
            val snap = when {
                tg.isOffline -> nodes.cached(follow)
                fresh -> runCatching { nodes.fetch(follow) }.getOrNull() ?: nodes.cached(follow)
                else -> runCatching { nodes.node(follow) }.getOrNull()
            } ?: return@forEach
            snap.card?.feeds?.forEach { add(it, snap.username) }
        }
        val resolved = LinkedHashMap<String, FeedSource>()
        for ((feed, listedBy) in wanted) {
            val src = nodes.feedSource(feed, listedBy) ?: continue
            resolved[Username.key(src.username)] = src
        }
        lock.withLock {
            sources.clear()
            sources.putAll(resolved)
            merger.setSources(resolved.keys)
        }
        return resolved.values.toList()
    }

    suspend fun reset() = lock.withLock { merger.reset() }

    /** Continue the merge; fetches pages on demand. Returns the next [count] posts, fewer when everything is exhausted. */
    suspend fun loadMore(count: Int = 20): List<Post> = lock.withLock {
        val out = ArrayList<Post>(count)
        while (out.size < count) {
            val key = merger.nextRefill()
            if (key != null) {
                val src = sources[key]
                if (src == null) { merger.offer(key, emptyList(), null, exhausted = true); continue }
                val page = fetchPage(src, merger.state(key)?.cursor ?: 0L)
                merger.offer(key, page.posts, page.cursor, page.exhausted)
                continue
            }
            out += merger.pop() ?: break
        }
        out
    }

    val exhausted: Boolean get() = merger.allExhausted

    private class Page(val posts: List<Post>, val cursor: Long?, val exhausted: Boolean)

    /** One source page: TDLib may return fewer than asked (cache only) — repeat from the last id until 30 or empty. */
    private suspend fun fetchPage(src: FeedSource, from: Long): Page = activity.track("Loading @${src.username}") {
        fetchPageInner(src, from)
    }

    private suspend fun fetchPageInner(src: FeedSource, from: Long): Page {
        val raw = ArrayList<Message>()
        var cursor = from
        var rounds = 0
        while (raw.size < PAGE && rounds++ < 6) {
            // Offline, ask TDLib for what it already has instead of waiting on the network.
            val local = tg.isOffline
            val batch = runCatching {
                tg.call { getChatHistory(chatId = src.chatId, fromMessageId = cursor, offset = 0, limit = PAGE - raw.size, onlyLocal = local) }
            }.getOrNull()?.messages?.filterNotNull() ?: break
            if (batch.isEmpty()) break
            raw += batch
            cursor = batch.last().id
        }
        // Strictly newest first (PRODUCT §2.3): album members collapse into one card and the page is re-asserted
        // descending even though TDLib already answers that way.
        val posts = FeedOrder.mergeAlbums(raw.mapNotNull { m -> m.toPost(src.username, src.title, src.photo, displayWidthPx) { nodes.originName(it) } })
        return Page(posts = posts, cursor = raw.lastOrNull()?.id, exhausted = raw.isEmpty())
    }

    /** One channel's own posts (Feed channel screen), newest first, from [from]. */
    suspend fun channelPosts(src: FeedSource, from: Long = 0L): Pair<List<Post>, Long?> {
        val page = fetchPage(src, from)
        return page.posts to page.cursor?.takeIf { !page.exhausted }
    }

    suspend fun cachedFeed(): List<Post> = store.loadFeed()
    suspend fun cacheFeed(posts: List<Post>) = store.saveFeed(posts)

    /** A new channel post from one of my sources arrives live. */
    suspend fun liveToPost(m: Message): Post? {
        val src = sources.values.firstOrNull { it.chatId == m.chatId } ?: return null
        return m.toPost(src.username, src.title, src.photo, displayWidthPx) { nodes.originName(it) }
    }

    fun sourceFor(chatId: Long): FeedSource? = sources.values.firstOrNull { it.chatId == chatId }

}
