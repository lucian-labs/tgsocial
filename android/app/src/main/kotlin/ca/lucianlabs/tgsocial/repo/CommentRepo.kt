package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.CommentNode
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostText
import ca.lucianlabs.tgsocial.protocol.Card
import ca.lucianlabs.tgsocial.protocol.CommentFormat
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.td.TelegramClient
import dev.g000sha256.tdl.dto.Message
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * PROTOCOL §6.3 — the local comment index, network-scoped by design: the comments channels of me, my follows,
 * and my cached +1 nodes are paged with the same `getChatHistory` loop as feeds, `re:` lines are parsed, and
 * comments are indexed by target link. Refreshed alongside the feed; discardable (§7).
 */
class CommentRepo(
    private val tg: TelegramClient,
    private val nodes: NodeRepo,
    private val activity: ActivityRegistry,
) {
    companion object {
        const val PAGE = 50
        /** Messages read per channel per scan; comments channels are shallow by construction. */
        const val SCAN_LIMIT = 200
        /** A channel scanned this recently is not re-read unless the refresh is forced. */
        const val FRESH_MS = 60_000L
    }

    var displayWidthPx: Int = 1080

    /** Normalised target key (`username/serverId`) → comments pointing at it, newest first. */
    private val _index = MutableStateFlow<Map<String, List<Comment>>>(emptyMap())
    val index: StateFlow<Map<String, List<Comment>>> = _index.asStateFlow()

    /** Comments channel username (key form) → owning node + resolved chat. */
    private data class Channel(val username: String, val chatId: Long, val owner: NodeSnapshot, val plusOne: Boolean)

    private val scannedAt = HashMap<String, Long>()
    private val byChannel = HashMap<String, List<Comment>>()
    private val lock = Mutex()

    fun clear() {
        _index.value = emptyMap()
        scannedAt.clear()
        byChannel.clear()
    }

    /** Every comments channel my network lists: mine, my follows', and my cached +1 nodes' (`§6.3`). */
    private fun channels(myUsername: String?, myCard: Card?): List<Pair<String, Boolean>> {
        val followKeys = myCard?.follows.orEmpty().map { Username.key(it) }.toSet()
        val out = LinkedHashMap<String, Boolean>() // replies channel key → plusOne
        fun add(node: NodeSnapshot?, plusOne: Boolean) {
            val r = node?.card?.replies ?: return
            val k = Username.key(r)
            if (k !in out || !plusOne) out[k] = (out[k] ?: plusOne) && plusOne
        }
        myUsername?.let { add(nodes.cached(it), plusOne = false) }
        // +1 = the nodes my follows list (distance 2), read from cached cards only — best-effort by design.
        val plusOneKeys = HashSet<String>()
        for (f in myCard?.follows.orEmpty()) {
            val snap = nodes.cached(f)
            add(snap, plusOne = false)
            snap?.card?.follows.orEmpty().forEach { plusOneKeys += Username.key(it) }
        }
        plusOneKeys.removeAll(followKeys)
        myUsername?.let { plusOneKeys.remove(Username.key(it)) }
        for (k in plusOneKeys) add(nodes.cached(k), plusOne = true)
        return out.entries.map { it.key to it.value }
    }

    /** Re-scan the network's comments channels and rebuild the index. Runs alongside the feed refresh. */
    suspend fun refresh(myUsername: String?, myCard: Card?, force: Boolean = false) {
        val wanted = channels(myUsername, myCard)
        for ((channel, plusOne) in wanted) {
            val fresh = (System.currentTimeMillis() - (scannedAt[channel] ?: 0L)) < FRESH_MS
            if (fresh && !force) continue
            if (tg.isOffline) break
            val owner = ownerOf(channel, myUsername, myCard) ?: continue
            val resolved = resolve(channel) ?: continue
            val comments = runCatching { scan(Channel(channel, resolved, owner, plusOne), myUsername) }.getOrNull() ?: continue
            lock.withLock {
                scannedAt[channel] = System.currentTimeMillis()
                byChannel[channel] = comments
                // A successful scan of a channel supersedes its pending entries: the real message is either in
                // [comments] or gone, so the `Posting…` ghost must not survive to duplicate it.
                dropPendingFor(channel)
            }
        }
        // Drop channels that left the network (an unfollow withdraws their comments from my view).
        val keep = wanted.map { it.first }.toSet()
        lock.withLock {
            byChannel.keys.retainAll { it in keep || it.startsWith("#pending") }
            rebuild()
        }
    }

    private fun ownerOf(channel: String, myUsername: String?, myCard: Card?): NodeSnapshot? =
        nodes.cards.value.values.firstOrNull { it.card?.replies?.let { r -> Username.key(r) } == channel }

    private suspend fun resolve(channel: String): Long? =
        nodes.cached(channel)?.chatId ?: tg.callOrNull { searchPublicChat(username = channel) }?.id

    /** The same repeat-until-filled `getChatHistory` loop as feeds (§4.8), newest first. */
    private suspend fun scan(channel: Channel, myUsername: String?): List<Comment> =
        activity.track("Reading comments @${channel.username}") {
            val raw = ArrayList<Message>()
            var cursor = 0L
            var rounds = 0
            while (raw.size < SCAN_LIMIT && rounds++ < 8) {
                val batch = tg.callOrNull {
                    getChatHistory(chatId = channel.chatId, fromMessageId = cursor, offset = 0, limit = PAGE, onlyLocal = false)
                }?.messages?.filterNotNull() ?: break
                if (batch.isEmpty()) break
                raw += batch
                cursor = batch.last().id
            }
            raw.mapNotNull { toComment(it, channel, myUsername) }
        }

    /** A channel message is a comment only when its first text/caption line is a `re:` pointer (§6.2). */
    private suspend fun toComment(m: Message, channel: Channel, myUsername: String?): Comment? {
        val post = m.toPost(channel.owner.username, channel.owner.displayName, channel.owner.photo, displayWidthPx) { null }
            ?: return null
        val text = post.text?.text ?: return null
        val pointer = CommentFormat.parse(text) ?: return null
        val targetKey = CommentFormat.targetKey(pointer.target) ?: return null
        return Comment(
            chatId = m.chatId,
            messageId = m.id,
            date = m.date,
            channelUsername = channel.username,
            authorUsername = channel.owner.username,
            authorName = channel.owner.displayName,
            authorPhoto = channel.owner.photo,
            targetKey = targetKey,
            link = DeepLink.post(channel.username, m.id),
            post = stripPointer(post),
            plusOne = channel.plusOne,
            own = myUsername != null && Username.same(channel.owner.username, myUsername),
        )
    }

    /** Remove the `re:` first line from the rendered body and shift the entity runs with it. */
    private fun stripPointer(post: Post): Post {
        val t = post.text ?: return post
        val newline = t.text.indexOf('\n')
        if (newline < 0) return post.copy(text = null)
        val cut = newline + 1
        val body = t.text.substring(cut)
        if (body.isBlank()) return post.copy(text = null)
        val runs = t.runs.mapNotNull { r ->
            val start = (r.start - cut).coerceAtLeast(0)
            val end = r.end - cut
            if (end <= 0) null else r.copy(start = start, end = end)
        }
        return post.copy(text = PostText(body, runs))
    }

    private fun rebuild() {
        val map = LinkedHashMap<String, MutableList<Comment>>()
        for (comments in byChannel.values) {
            for (c in comments) map.getOrPut(c.targetKey) { mutableListOf() } += c
        }
        for (list in map.values) list.sortWith(compareByDescending<Comment> { it.date }.thenByDescending { it.messageId })
        _index.value = map
    }

    // ------------------------------------------------------------------ threads

    /**
     * PRODUCT §2.12 — the reply tree for one post: roots target the post, replies target a comment's own link
     * (`re:` chains, §6.2). Oldest first within a level so a thread reads top-down; cycles cannot recurse.
     */
    fun tree(postTargetKey: String, index: Map<String, List<Comment>> = _index.value): List<CommentNode> {
        val visited = HashSet<String>()
        fun nodesFor(key: String): List<CommentNode> {
            val here = index[key] ?: return emptyList()
            return here
                .filter { visited.add(it.key) }
                .sortedWith(compareBy<Comment> { it.date }.thenBy { it.messageId })
                .map { c -> CommentNode(c, CommentFormat.targetKey(c.link)?.let { nodesFor(it) } ?: emptyList()) }
        }
        return nodesFor(postTargetKey)
    }

    /** The post footer's honest number: every comment in the post's thread, from my network (§6.3). */
    fun countFor(postTargetKey: String, index: Map<String, List<Comment>> = _index.value): Int =
        tree(postTargetKey, index).sumOf { it.count }

    // ------------------------------------------------------------------ optimistic entries

    /** Insert an optimistic pending comment; it is dropped by the next successful scan of my channel (refresh or rescan). */
    fun addPending(comment: Comment) {
        val key = "#pending:${comment.key}"
        byChannel[key] = listOf(comment)
        rebuild()
    }

    fun removePending(comment: Comment) {
        byChannel.remove("#pending:${comment.key}")
        rebuild()
    }

    private fun dropPendingFor(channel: String) {
        byChannel.keys.removeAll { key ->
            key.startsWith("#pending") && byChannel[key]?.firstOrNull()?.channelUsername?.let { Username.key(it) } == Username.key(channel)
        }
    }

    /** Delete my own comment: the message in my channel goes, and the index entry with it (§6.2). */
    suspend fun delete(comment: Comment) {
        tg.call { deleteMessages(chatId = comment.chatId, messageIds = longArrayOf(comment.messageId), revoke = true) }
        lock.withLock {
            byChannel[Username.key(comment.channelUsername)] =
                byChannel[Username.key(comment.channelUsername)].orEmpty().filterNot { it.key == comment.key }
            byChannel.remove("#pending:${comment.key}")
            rebuild()
        }
    }

    /** Force re-scan of one channel (mine, after posting) and drop its pending entries. */
    suspend fun rescan(channel: String, myUsername: String?, myCard: Card?) {
        val k = Username.key(channel)
        val owner = ownerOf(k, myUsername, myCard) ?: return
        val chatId = resolve(k) ?: return
        val comments = runCatching { scan(Channel(k, chatId, owner, plusOne = false), myUsername) }.getOrNull() ?: return
        lock.withLock {
            scannedAt[k] = System.currentTimeMillis()
            byChannel[k] = comments
            dropPendingFor(k)
            rebuild()
        }
    }
}
