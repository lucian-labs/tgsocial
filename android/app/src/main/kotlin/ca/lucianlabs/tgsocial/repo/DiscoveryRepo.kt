package ca.lucianlabs.tgsocial.repo

import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.protocol.Card
import ca.lucianlabs.tgsocial.protocol.CardFormat
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.td.TelegramClient
import ca.lucianlabs.tgsocial.td.orNull
import dev.g000sha256.tdl.dto.MessageText

/** PROTOCOL §5 — graph walk (+1), username prefix search, index group. */
class DiscoveryRepo(private val tg: TelegramClient, private val nodes: NodeRepo) {
    companion object {
        const val PREFIX = "tgs_"
        const val INDEX_GROUP = MyNodeRepo.INDEX_GROUP
        private val NODE_LINE = Regex("^\\s*node:\\s*(\\S+)", setOf(RegexOption.IGNORE_CASE, RegexOption.MULTILINE))
    }

    fun entry(snap: NodeSnapshot, mutual: Int = 0): NodeEntry =
        NodeEntry(username = snap.username, name = snap.displayName, feedCount = snap.card?.feeds?.size ?: 0, mutualCount = mutual, photo = snap.photo, initial = snap.initial)

    /** §5.1 — nodes followed by the nodes I follow, ranked by how many of mine list them. Excludes me and my follows. */
    suspend fun nearby(myUsername: String?, myCard: Card?): List<NodeEntry> {
        val follows = myCard?.follows ?: return emptyList()
        val counts = LinkedHashMap<String, Int>()
        val names = HashMap<String, String>()
        val skip = HashSet<String>()
        myUsername?.let { skip += Username.key(it) }
        follows.forEach { skip += Username.key(it) }
        for (f in follows) {
            val snap = runCatching { nodes.node(f) }.getOrNull() ?: continue
            for (second in snap.card?.follows.orEmpty()) {
                val k = Username.key(second)
                if (k in skip) continue
                counts[k] = (counts[k] ?: 0) + 1
                names.putIfAbsent(k, second)
            }
        }
        val ranked = counts.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
        val out = ArrayList<NodeEntry>()
        for ((k, n) in ranked.take(60)) {
            val snap = runCatching { nodes.node(names.getValue(k)) }.getOrNull() ?: continue
            if (snap.card == null || !snap.card.public) continue
            out += entry(snap, n)
        }
        return out
    }

    /** §5.2 ∪ §5.3 — minus [exclude] (nearby, my follows, me). */
    suspend fun directory(exclude: Set<String>): List<NodeEntry> {
        val found = LinkedHashMap<String, NodeSnapshot>()
        // Username prefix.
        val hits = tg.callOrNull { searchPublicChats(query = PREFIX) }?.chatIds ?: LongArray(0)
        for (id in hits) {
            val chat = tg.callOrNull { getChat(chatId = id) } ?: continue
            if (!chat.isChannel) continue
            val snap = runCatching { nodes.read(chat) }.getOrNull() ?: continue
            if (snap.username.isBlank()) continue
            if (snap.card == null && !CardFormat.descriptionLooksLikeNode(snap.description)) continue
            if (snap.card != null) { nodes.put(snap); found[Username.key(snap.username)] = snap }
        }
        // Index group.
        val group = tg.callOrNull { searchPublicChat(username = INDEX_GROUP) }
        if (group != null) {
            val msgs = ArrayList<dev.g000sha256.tdl.dto.Message>()
            var from = 0L
            var rounds = 0
            while (msgs.size < 200 && rounds++ < 8) {
                val batch = tg.callOrNull { getChatHistory(chatId = group.id, fromMessageId = from, offset = 0, limit = 100, onlyLocal = false) }?.messages?.filterNotNull().orEmpty()
                if (batch.isEmpty()) break
                msgs += batch
                from = batch.last().id
            }
            val announced = LinkedHashSet<String>()
            for (m in msgs) {
                val text = (m.content as? MessageText)?.text?.text ?: continue
                val token = NODE_LINE.find(text)?.groupValues?.get(1) ?: continue
                val u = Username.normalise(token) ?: continue
                announced += u
            }
            for (u in announced) {
                val k = Username.key(u)
                if (k in found) continue
                val snap = runCatching { nodes.node(u) }.getOrNull() ?: continue
                if (snap.card != null) found[k] = snap
            }
        }
        return found.values
            .filter { Username.key(it.username) !in exclude }
            .filter { it.card?.public == true }
            .map { entry(it) }
    }
}
