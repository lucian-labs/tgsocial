package ca.lucianlabs.tgsocial.repo

/**
 * A byte-bounded LRU with the same contract as `android.util.LruCache`: access-ordered, evicts the least
 * recently used entry until the total reported cost fits. Written in plain Kotlin rather than subclassing
 * `android.util.LruCache` for one reason — the framework class is a `Stub!` throw in JVM unit tests, and the
 * cost accounting is the part that has to be proved (see `ByteLruCacheTest`).
 *
 * [maxCount] stays as a secondary guard so a pathological stream of 1-pixel images cannot grow the map itself
 * without bound, but **bytes are the binding constraint** — a count limit alone is what let 300 full-resolution
 * decodes park a gigabyte of pixels on a phone.
 */
class ByteLruCache<K : Any, V : Any>(
    val maxBytes: Long,
    val maxCount: Int = Int.MAX_VALUE,
    private val sizeOf: (K, V) -> Long,
) {
    init {
        require(maxBytes > 0) { "maxBytes must be > 0" }
        require(maxCount > 0) { "maxCount must be > 0" }
    }

    // accessOrder = true: iteration starts at the least recently used entry, which is what trimming wants.
    private val entries = LinkedHashMap<K, V>(0, 0.75f, true)
    private val costs = HashMap<K, Long>()

    private var bytesUsed = 0L
    private var evicted = 0

    /** Total reported cost of everything currently held. */
    val bytes: Long get() = synchronized(this) { bytesUsed }

    val count: Int get() = synchronized(this) { entries.size }

    /** Entries dropped to stay inside the budget — surfaced by [MediaRepo.cacheStats] for diagnosis. */
    val evictions: Int get() = synchronized(this) { evicted }

    operator fun get(key: K): V? = synchronized(this) { entries[key] }

    operator fun set(key: K, value: V) {
        put(key, value)
    }

    /** Inserts [value], charging its real cost, then trims back to [maxBytes] / [maxCount]. */
    fun put(key: K, value: V): V? = synchronized(this) {
        val cost = sizeOf(key, value).coerceAtLeast(0L)
        val previous = entries.put(key, value)
        if (previous != null) bytesUsed -= costs[key] ?: 0L
        costs[key] = cost
        bytesUsed += cost
        trimLocked(maxBytes)
        previous
    }

    fun remove(key: K): V? = synchronized(this) {
        val removed = entries.remove(key)
        if (removed != null) bytesUsed -= costs.remove(key) ?: 0L
        removed
    }

    /** Drop everything — the memory-pressure path. */
    fun evictAll() = synchronized(this) {
        evicted += entries.size
        entries.clear()
        costs.clear()
        bytesUsed = 0L
    }

    /** Shed least-recently-used entries until at most [target] bytes remain. */
    fun trimToBytes(target: Long) = synchronized(this) { trimLocked(target.coerceAtLeast(0L)) }

    /** Keys from least to most recently used; test/diagnostic only. */
    fun keysLruFirst(): List<K> = synchronized(this) { entries.keys.toList() }

    private fun trimLocked(targetBytes: Long) {
        val iterator = entries.entries.iterator()
        while ((bytesUsed > targetBytes || entries.size > maxCount) && iterator.hasNext()) {
            val entry = iterator.next()
            iterator.remove()
            bytesUsed -= costs.remove(entry.key) ?: 0L
            evicted++
        }
    }
}
