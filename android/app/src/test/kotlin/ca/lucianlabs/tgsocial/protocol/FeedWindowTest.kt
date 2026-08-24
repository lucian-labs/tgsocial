package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Post
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The in-memory feed used to grow for as long as the user kept scrolling. It is now a bounded window; these
 * tests hold the three properties that make the window safe: the list stays strictly newest first (PRODUCT
 * §2.3), load-more keeps making progress after a trim instead of stalling in place, and the run of posts held
 * stays contiguous — there is one trimming end, so nothing can fall out of the middle.
 */
class FeedWindowTest {
    private fun post(source: String, id: Long, date: Int) = Post(
        chatId = source.hashCode().toLong(),
        messageId = id,
        date = date,
        sourceUsername = source,
        sourceTitle = source,
    )

    /** A page of [count] posts older than [from], newest first — what `FeedRepo.loadMore` hands back. */
    private fun page(from: Int, count: Int) = (1..count).map { post("a", (from - it).toLong(), from - it) }

    @Test
    fun theWindowKeepsTheTailAndDropsAlreadyReadPosts() {
        val posts = FeedOrder.sort((1..10).map { post("a", it.toLong(), it * 10) })
        val windowed = FeedOrder.window(posts, max = 4)
        assertEquals(listOf(40, 30, 20, 10), windowed.map { it.date })
        assertTrue(FeedOrder.isNewestFirst(windowed))
    }

    @Test
    fun windowingIsANoOpBelowTheCap() {
        val posts = FeedOrder.sort((1..10).map { post("a", it.toLong(), it * 10) })
        assertEquals(posts, FeedOrder.window(posts, max = 300))
    }

    @Test
    fun loadMoreStillMakesProgressAfterTheWindowFills() {
        // 20 posts per page, a 50-post window: after the third page the window is full and every further page
        // must still land — a trim that discarded the page just fetched would stall the feed forever.
        val cap = 50
        var feed = emptyList<Post>()
        var cursor = 1_000
        repeat(10) {
            val fetched = page(cursor, 20)
            cursor -= 20
            val before = feed
            feed = FeedOrder.append(feed, fetched, max = cap)
            assertTrue("order is re-asserted on every append", FeedOrder.isNewestFirst(feed))
            assertTrue("window never grows past the cap", feed.size <= cap)
            assertTrue("every append must change the list", feed != before)
            assertTrue("the newest post of the fetched page is present", feed.any { it.key == fetched.first().key })
            assertTrue("the oldest post of the fetched page is present", feed.any { it.key == fetched.last().key })
        }
        // 200 posts fetched, 50 held: the window ends at the oldest post the repo returned.
        assertEquals(cap, feed.size)
        assertEquals(849, feed.first().date)
        assertEquals(800, feed.last().date)
    }

    @Test
    fun appendStillDedupesAndReordersInsideTheWindow() {
        val first = FeedOrder.append(emptyList(), page(1_000, 10), max = 6)
        val overlapping = page(1_000, 10) + page(990, 4)
        val next = FeedOrder.append(first, overlapping, max = 6)
        assertEquals(next.map { it.key }.distinct().size, next.size)
        assertTrue(FeedOrder.isNewestFirst(next))
        assertEquals(6, next.size)
    }

    @Test
    fun liveInsertsLandAtTheTopAndCannotGrowTheWindow() {
        val cap = 5
        var feed = FeedOrder.sort(page(1_000, 3))
        // Room in the window: the live post lands at the head, as it always has.
        feed = FeedOrder.insertLive(feed, post("b", 5_000L, 2_000), max = cap)
        assertEquals(2_000, feed.first().date)
        assertEquals(4, feed.size)
        feed = FeedOrder.insertLive(feed, post("b", 5_001L, 2_001), max = cap)
        assertEquals(cap, feed.size)
        // Full: further live posts are reported (isAboveFullWindow), never traded for the pagination anchor.
        val anchor = feed.last()
        repeat(10) { i -> feed = FeedOrder.insertLive(feed, post("b", 6_000L + i, 3_000 + i), max = cap) }
        assertEquals(cap, feed.size)
        assertEquals("the oldest post held is the merge cursor's neighbour", anchor.key, feed.last().key)
        assertTrue(FeedOrder.isNewestFirst(feed))
    }

    /**
     * The bug this window used to have: `insertLive` trimmed the oldest post while `append` trimmed the newest,
     * so a live post arriving after the window filled deleted the post sitting exactly at the pagination
     * cursor. The next page began strictly older than it and the feed skipped it, permanently and silently.
     */
    @Test
    fun aLiveInsertNeverPunchesAHoleInThePagination() {
        val cap = 40
        var feed = emptyList<Post>()
        var cursor = 1_000
        // Page until the window is full and the head has started sliding.
        repeat(4) {
            feed = FeedOrder.append(feed, page(cursor, 20), max = cap)
            cursor -= 20
        }
        assertEquals(cap, feed.size)
        val boundary = feed.last() // the post FeedRepo's cursor sits directly behind

        // A live post from another channel arrives while the reader is deep in the feed.
        val live = post("b", 9_000L, 5_000)
        assertTrue("the window is full and the post is newer than the head", FeedOrder.isAboveFullWindow(feed, live, max = cap))
        feed = FeedOrder.insertLive(feed, live, max = cap)
        assertTrue("the pagination anchor survives the live insert", feed.any { it.key == boundary.key })

        // The next page continues from where the cursor already was: strictly older than the anchor.
        feed = FeedOrder.append(feed, page(cursor, 20), max = cap)
        cursor -= 20

        // Every held post from source "a" must be a contiguous run of message ids — no gap.
        val ids = feed.filter { it.sourceUsername == "a" }.map { it.messageId }
        assertTrue(FeedOrder.isNewestFirst(feed))
        assertEquals("the run of loaded posts has no hole in it", ids.first() - ids.last() + 1, ids.size.toLong())
    }

    @Test
    fun aFullWindowReportsNewerPostsInsteadOfSwallowingThem() {
        val cap = 10
        val feed = FeedOrder.append(emptyList(), page(1_000, 40), max = cap)
        assertEquals(cap, feed.size)
        // Newer than the head, window full: the caller has to surface it, not insert it.
        assertTrue(FeedOrder.isAboveFullWindow(feed, post("b", 9_000L, 5_000), max = cap))
        // Below the cap there is room, so it is an ordinary insert.
        assertFalse(FeedOrder.isAboveFullWindow(feed.take(3), post("b", 9_000L, 5_000), max = cap))
        // Already held, or older than the head: nothing to report either way.
        assertFalse(FeedOrder.isAboveFullWindow(feed, feed.first(), max = cap))
        assertFalse(FeedOrder.isAboveFullWindow(feed, post("b", 1L, 1), max = cap))
    }

    @Test
    fun defaultWindowIsAFewHundredPosts() {
        assertTrue(FeedOrder.WINDOW in 100..500)
        var feed = emptyList<Post>()
        var cursor = 100_000
        repeat(40) {
            feed = FeedOrder.append(feed, page(cursor, 20))
            cursor -= 20
        }
        assertEquals(FeedOrder.WINDOW, feed.size)
    }
}
