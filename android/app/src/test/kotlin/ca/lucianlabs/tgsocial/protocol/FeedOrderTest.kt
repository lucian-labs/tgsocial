package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Post
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.3 — every list of posts is strictly newest first, end to end: the k-way merge, live inserts, and
 * load-more appends. Three interleaved sources drive the merge and the emitted order is asserted exactly.
 */
class FeedOrderTest {
    private fun post(source: String, id: Long, date: Int) = Post(
        chatId = source.hashCode().toLong(),
        messageId = id,
        date = date,
        sourceUsername = source,
        sourceTitle = source,
    )

    @Test
    fun threeInterleavedSourcesEmitNewestFirst() {
        val merger = FeedMerger<Post>(dateOf = { it.date }, idOf = { it.messageId })
        merger.setSources(listOf("a", "b", "c"))
        // Interleaved dates across sources: a = 900, 500, 100 · b = 800, 600, 200 · c = 700, 400, 300.
        val pages = mapOf(
            "a" to listOf(post("a", 9, 900), post("a", 5, 500), post("a", 1, 100)),
            "b" to listOf(post("b", 8, 800), post("b", 6, 600), post("b", 2, 200)),
            "c" to listOf(post("c", 7, 700), post("c", 4, 400), post("c", 3, 300)),
        )
        val emitted = ArrayList<Post>()
        while (true) {
            val refill = merger.nextRefill()
            if (refill != null) {
                val page = pages.getValue(refill).filter { p -> merger.state(refill)!!.cursor == 0L || p.messageId < merger.state(refill)!!.cursor }
                merger.offer(refill, page.take(1), cursor = page.firstOrNull()?.messageId, exhausted = page.isEmpty())
                continue
            }
            emitted += merger.pop() ?: break
        }
        assertEquals(listOf(900, 800, 700, 600, 500, 400, 300, 200, 100), emitted.map { it.date })
        assertTrue(FeedOrder.isNewestFirst(emitted))
    }

    @Test
    fun liveInsertLandsAtTheTop() {
        val posts = FeedOrder.sort(listOf(post("a", 2, 200), post("a", 1, 100)))
        val next = FeedOrder.insertLive(posts, post("b", 3, 300))
        assertEquals(listOf(300, 200, 100), next.map { it.date })
        assertTrue(FeedOrder.isNewestFirst(next))
    }

    @Test
    fun lateArrivingOlderLivePostOrdersByDateNotArrival() {
        val posts = FeedOrder.sort(listOf(post("a", 3, 300), post("a", 1, 100)))
        val next = FeedOrder.insertLive(posts, post("b", 2, 200))
        assertEquals(listOf(300, 200, 100), next.map { it.date })
    }

    @Test
    fun loadMoreAppendsOlderBelowAndDropsDuplicates() {
        val posts = FeedOrder.sort(listOf(post("a", 4, 400), post("b", 3, 300)))
        val more = listOf(post("b", 3, 300), post("c", 2, 200), post("a", 1, 100))
        val next = FeedOrder.append(posts, more)
        assertEquals(listOf(400, 300, 200, 100), next.map { it.date })
        assertEquals(4, next.size)
        assertTrue(FeedOrder.isNewestFirst(next))
    }

    @Test
    fun dateTiesBreakByMessageId() {
        val a = post("a", 10, 500)
        val b = post("a", 20, 500)
        val sorted = FeedOrder.sort(listOf(a, b))
        assertEquals(listOf(20L, 10L), sorted.map { it.messageId })
    }

    @Test
    fun albumMembersCollapseIntoOneNewestFirstCard() {
        val one = post("a", 1, 100).copy(albumId = 7)
        val two = post("a", 2, 101).copy(albumId = 7)
        val other = post("b", 3, 50)
        val merged = FeedOrder.mergeAlbums(listOf(one, two, other))
        assertEquals(2, merged.size)
        assertEquals(101, merged.first().date)
        assertTrue(FeedOrder.isNewestFirst(merged))
    }
}
