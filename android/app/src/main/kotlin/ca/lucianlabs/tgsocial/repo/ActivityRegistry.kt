package ca.lucianlabs.tgsocial.repo

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicLong

/**
 * PRODUCT §2.10 — the live list of in-flight operations the status pill and the Status sheet derive from.
 *
 * Every operation registers with [begin] and must leave with [end]; [track] does both around a block with a
 * `finally`, so success, failure, and cancellation all clear the entry. On top of that every entry carries its own
 * [TIMEOUT_MS] auto-clear, so a `Syncing` pill that never resolves is impossible by construction: even an operation
 * that forgets to end (or a TDLib request that never answers) falls out of the list after 30 s.
 */
class ActivityRegistry(private val scope: CoroutineScope) {
    companion object {
        const val TIMEOUT_MS = 30_000L
    }

    data class Entry(val id: Long, val label: String, val startedAt: Long = System.currentTimeMillis())
    data class LastError(val message: String, val at: Long = System.currentTimeMillis())

    private val ids = AtomicLong(0)
    private val timeouts = HashMap<Long, Job>()

    private val _entries = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = _entries.asStateFlow()

    private val _lastError = MutableStateFlow<LastError?>(null)
    val lastError: StateFlow<LastError?> = _lastError.asStateFlow()

    val busy: Boolean get() = _entries.value.isNotEmpty()

    /** Registers an operation (`Reading card @tgs_ana`, `Downloading photo`, …). Returns the handle for [end]. */
    fun begin(label: String): Long {
        val id = ids.incrementAndGet()
        synchronized(this) {
            _entries.value = _entries.value + Entry(id, label)
            timeouts[id] = scope.launch {
                delay(TIMEOUT_MS)
                end(id)
            }
        }
        return id
    }

    fun end(id: Long) {
        synchronized(this) {
            timeouts.remove(id)?.cancel()
            _entries.value = _entries.value.filterNot { it.id == id }
        }
    }

    /** Runs [block] as a named operation; the entry clears on success, throw, or cancellation. */
    suspend fun <T> track(label: String, block: suspend () -> T): T {
        val id = begin(label)
        try {
            return block()
        } finally {
            end(id)
        }
    }

    fun recordError(message: String) {
        _lastError.value = LastError(message)
    }

    fun clear() {
        synchronized(this) {
            timeouts.values.forEach { it.cancel() }
            timeouts.clear()
            _entries.value = emptyList()
            _lastError.value = null
        }
    }
}
