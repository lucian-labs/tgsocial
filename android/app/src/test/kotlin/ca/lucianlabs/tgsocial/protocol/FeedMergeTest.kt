package ca.lucianlabs.tgsocial.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FeedMergeTest {
    private data class Item(val source: String, val id: Long, val date: Int)

    private fun merger() = FeedMerger<Item>(dateOf = { it.date }, idOf = { it.id })

    @Test
    fun mergesByDateDescendingAndAsksForRefillBeforePopping() {
        val m = merger()
        m.setSources(listOf("a", "b"))
        // both empty → a refill is required before popping; the one with the newest last-known item wins (both MAX → first)
        assertEquals("a", m.nextRefill())
        m.offer("a", listOf(Item("a", 30, 300), Item("a", 20, 200)), cursor = 20, exhausted = false)
        assertEquals("b", m.nextRefill())
        m.offer("b", listOf(Item("b", 25, 250)), cursor = 25, exhausted = false)
        assertNull(m.nextRefill())
        assertEquals(300, m.pop()!!.date)
        assertEquals(250, m.pop()!!.date)
        // b is empty and not exhausted → must refill b before popping a's 200
        assertEquals("b", m.nextRefill())
        m.offer("b", emptyList(), cursor = null, exhausted = true)
        assertNull(m.nextRefill())
        assertEquals(200, m.pop()!!.date)
        assertEquals("a", m.nextRefill())
        m.offer("a", emptyList(), cursor = null, exhausted = true)
        assertNull(m.pop())
        assertTrue(m.allExhausted)
    }

    @Test
    fun refillPrefersTheSourceWhoseLastItemWasNewest() {
        val m = merger()
        m.setSources(listOf("a", "b"))
        m.offer("a", listOf(Item("a", 1, 100)), cursor = 1, exhausted = false)
        m.offer("b", listOf(Item("b", 2, 500)), cursor = 2, exhausted = false)
        assertEquals(500, m.pop()!!.date)
        // b emptied with a newer last-known item than a still holds → b is the refill even though a has items
        assertEquals("b", m.nextRefill())
        m.offer("b", emptyList(), cursor = null, exhausted = true)
        assertEquals(100, m.pop()!!.date)
        assertEquals("a", m.nextRefill())
    }

    @Test
    fun duplicatesWithinASourceCollapse() {
        val m = merger()
        m.setSources(listOf("a"))
        m.offer("a", listOf(Item("a", 5, 50)), cursor = 5, exhausted = false)
        m.offer("a", listOf(Item("a", 5, 50), Item("a", 4, 40)), cursor = 4, exhausted = true)
        assertEquals(2, m.state("a")!!.buffered)
    }

    @Test
    fun sourceKeysAreCaseInsensitive() {
        val m = merger()
        m.setSources(listOf("Feed_A"))
        m.offer("feed_a", listOf(Item("a", 1, 1)), cursor = 1, exhausted = true)
        assertEquals(1, m.state("FEED_A")!!.buffered)
    }
}
