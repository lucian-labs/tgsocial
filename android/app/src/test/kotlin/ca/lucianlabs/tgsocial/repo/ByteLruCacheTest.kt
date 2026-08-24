package ca.lucianlabs.tgsocial.repo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bug this file exists for: the decoded-image cache was bounded by COUNT and not by BYTES, so 120 entries
 * of full-resolution photos was over a gigabyte of pixels and the OS killed the app. Every assertion here is
 * about cost accounting — that a decode is charged what it actually costs, and that the total never exceeds
 * the budget the device gave us.
 */
class ByteLruCacheTest {
    /** Stand-in for a decoded bitmap: width x height x 4 bytes, exactly what ARGB_8888 costs. */
    private data class Decoded(val width: Int, val height: Int)

    private fun cache(maxBytes: Long, maxCount: Int = Int.MAX_VALUE) =
        ByteLruCache<String, Decoded>(maxBytes, maxCount) { _, d -> MediaBudget.bitmapBytes(d.width, d.height) }

    @Test
    fun costIsBytesNotEntries() {
        val cache = cache(maxBytes = 10L * 1024 * 1024)
        cache.put("a", Decoded(1080, 1080)) // 4,665,600 B
        assertEquals(1, cache.count)
        assertEquals(1080L * 1080 * 4, cache.bytes)
    }

    @Test
    fun oneOversizeDecodeCannotParkMoreThanTheBudget() {
        // A 12 MP photo decoded at sensor resolution is ~48 MB on its own. A count-bounded cache accepted 120
        // of these; a byte-bounded one accepts it and then immediately trims back inside the budget.
        val cache = cache(maxBytes = 8L * 1024 * 1024)
        cache.put("huge", Decoded(4032, 3024))
        assertTrue("cache must never hold more than its budget", cache.bytes <= 8L * 1024 * 1024)
        assertEquals(0, cache.count)
    }

    @Test
    fun evictsLeastRecentlyUsedUntilItFits() {
        // Budget = three 1 MB entries exactly.
        val oneMb = Decoded(512, 512) // 512*512*4 = 1,048,576 B
        val cache = cache(maxBytes = 3L * 1024 * 1024)
        cache.put("a", oneMb)
        cache.put("b", oneMb)
        cache.put("c", oneMb)
        assertEquals(3, cache.count)

        // Touch "a" so "b" becomes the least recently used, then overflow by one.
        assertNotNull(cache["a"])
        cache.put("d", oneMb)

        assertEquals(3, cache.count)
        assertEquals(3L * 1024 * 1024, cache.bytes)
        assertNull("least recently used entry is the one that goes", cache["b"])
        assertEquals(listOf("c", "a", "d"), cache.keysLruFirst())
    }

    @Test
    fun replacingAKeySwapsItsCostRatherThanAddingToIt() {
        val cache = cache(maxBytes = 64L * 1024 * 1024)
        cache.put("photo", Decoded(1080, 1920))
        cache.put("photo", Decoded(256, 256)) // the same photo re-decoded smaller
        assertEquals(1, cache.count)
        assertEquals(256L * 256 * 4, cache.bytes)
    }

    @Test
    fun countLimitStillGuardsAgainstAFloodOfTinyEntries() {
        val cache = cache(maxBytes = 64L * 1024 * 1024, maxCount = 4)
        repeat(50) { i -> cache.put("t$i", Decoded(8, 8)) }
        assertEquals(4, cache.count)
        assertEquals(listOf("t46", "t47", "t48", "t49"), cache.keysLruFirst())
    }

    @Test
    fun trimToBytesShedsDownToTheTarget() {
        val oneMb = Decoded(512, 512)
        val cache = cache(maxBytes = 8L * 1024 * 1024)
        repeat(8) { i -> cache.put("k$i", oneMb) }
        assertEquals(8L * 1024 * 1024, cache.bytes)

        cache.trimToBytes(4L * 1024 * 1024) // TRIM_MEMORY_RUNNING_LOW → half the budget
        assertEquals(4L * 1024 * 1024, cache.bytes)
        assertEquals(4, cache.count)
        assertNull(cache["k0"])
        assertNotNull(cache["k7"])
    }

    @Test
    fun evictAllZeroesTheAccounting() {
        val cache = cache(maxBytes = 8L * 1024 * 1024)
        repeat(4) { i -> cache.put("k$i", Decoded(512, 512)) }
        cache.evictAll()
        assertEquals(0, cache.count)
        assertEquals(0L, cache.bytes)
        // And it stays consistent afterwards — a stale cost must not leak into the next generation.
        cache.put("fresh", Decoded(512, 512))
        assertEquals(1024L * 1024, cache.bytes)
    }

    @Test
    fun removeGivesTheBytesBack() {
        val cache = cache(maxBytes = 8L * 1024 * 1024)
        cache.put("a", Decoded(512, 512))
        cache.put("b", Decoded(512, 512))
        cache.remove("a")
        assertEquals(1024L * 1024, cache.bytes)
        assertEquals(1, cache.count)
        cache.remove("missing")
        assertEquals(1024L * 1024, cache.bytes)
    }
}
