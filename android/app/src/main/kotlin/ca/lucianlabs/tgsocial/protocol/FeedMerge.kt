package ca.lucianlabs.tgsocial.protocol

/**
 * PROTOCOL §4.8 — k-way merge by date descending with a per-source cursor.
 *
 * Pure: the repository fetches pages and feeds them in with [offer]; [nextRefill] names the
 * source that must be refilled before the merge can safely continue (its buffer is empty and it
 * is not exhausted — its next item could be newer than every other head). [pop] yields the newest
 * buffered item once no refill is pending.
 */
class FeedMerger<T>(
    private val dateOf: (T) -> Int,
    private val idOf: (T) -> Long,
) {
    class SourceState<T> internal constructor(val key: String) {
        internal val buffer = ArrayDeque<T>()
        /** Oldest message id fetched so far (TDLib `fromMessageId` for the next page); 0 = start. */
        var cursor: Long = 0L
            internal set
        var exhausted: Boolean = false
            internal set
        /** Date of the oldest item fetched; Int.MAX_VALUE before the first page. */
        var lastDate: Int = Int.MAX_VALUE
            internal set
        val buffered: Int get() = buffer.size
    }

    private val sources = LinkedHashMap<String, SourceState<T>>()
    private val seen = HashSet<Long>()

    val keys: Set<String> get() = sources.keys

    /** Replace the source set. New sources start fresh; removed sources are dropped; kept sources keep their cursor. */
    fun setSources(keys: Collection<String>) {
        val wanted = keys.map { Username.key(it) }.toSet()
        sources.keys.retainAll(wanted)
        for (k in wanted) sources.getOrPut(k) { SourceState(k) }
    }

    fun reset() {
        for (k in sources.keys.toList()) sources[k] = SourceState(k)
        seen.clear()
    }

    fun state(key: String): SourceState<T>? = sources[Username.key(key)]

    /** Feed a fetched page. [exhausted] should be true when TDLib returned no raw messages. */
    fun offer(key: String, items: List<T>, cursor: Long?, exhausted: Boolean) {
        val s = sources[Username.key(key)] ?: return
        val sorted = items.sortedWith(compareByDescending<T> { dateOf(it) }.thenByDescending { idOf(it) })
        for (item in sorted) {
            if (seen.add(idKey(key, idOf(item)))) s.buffer.addLast(item)
        }
        if (cursor != null) s.cursor = cursor
        if (sorted.isNotEmpty()) s.lastDate = dateOf(sorted.last())
        if (exhausted) s.exhausted = true
    }

    /** The source to refill before popping, or null when the merge can continue. */
    fun nextRefill(): String? =
        sources.values
            .filter { !it.exhausted && it.buffer.isEmpty() }
            .maxByOrNull { it.lastDate }
            ?.key

    /** Newest buffered item across all sources. Null when every source is exhausted and empty. */
    fun pop(): T? {
        check(nextRefill() == null) { "refill ${nextRefill()} before popping" }
        val best = sources.values
            .filter { it.buffer.isNotEmpty() }
            .maxWithOrNull(compareBy<SourceState<T>> { dateOf(it.buffer.first()) }.thenBy { idOf(it.buffer.first()) })
            ?: return null
        return best.buffer.removeFirst()
    }

    val allExhausted: Boolean get() = sources.values.all { it.exhausted && it.buffer.isEmpty() }

    private fun idKey(key: String, id: Long): Long = (Username.key(key).hashCode().toLong() shl 32) xor id
}
