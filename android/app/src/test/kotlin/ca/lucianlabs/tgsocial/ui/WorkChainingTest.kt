package ca.lucianlabs.tgsocial.ui

import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.24 over §2.18 — the work column is a second filter across the same merged window, so it owes
 * the same answer: "a page whose items are all filtered fetches the next one rather than rendering an empty
 * list."
 *
 * Nothing on the screen can see this. The pager fires off the LazyColumn's item count, and a page that goes
 * entirely into the work filter does not change it — the predicate never leaves `true`, never emits again,
 * and the mode stalls after exactly one extra page. What the reader gets is `No work posts yet.` with `Mark
 * one of your feeds as work, or follow someone who has.` under it: advice that is already satisfied, because
 * the mode control is only drawn when somebody in the network marked a feed, with the work posts sitting
 * unfetched below the window. [WorkUi.chaining] is that state named, asserted through [WorkUi.column], which
 * is what the view model renders.
 */
class WorkChainingTest {

    private fun post(id: Long, feed: String) = Post(
        chatId = -100,
        messageId = id shl 20,
        date = 1_700_000_000 + id.toInt(),
        sourceUsername = feed,
        sourceTitle = feed,
        nodeUsername = "tgs_ana",
        text = PostText("post $id"),
    )

    /** One chatty feed nobody marked, and one work feed that posts monthly. */
    private val chatter = listOf(post(1, "ana_daily"), post(2, "ana_daily"), post(3, "ana_daily"))
    private val marked = setOf("ana_bench")

    @Test
    fun `a page with no work post in it is a chain, not an empty column`() {
        val work = WorkUi(available = true).column(FeedUi(posts = chatter, ready = true), marked)

        assertTrue("nothing survives the filter", work.posts.isEmpty())
        assertEquals("and the filter says how much it took", 3, work.filteredOut)
        assertTrue("so the next page is owed rather than an empty state", work.chaining)
    }

    @Test
    fun `one work post ends the chain`() {
        val mixed = WorkUi(available = true)
            .column(FeedUi(posts = chatter + post(4, "ana_bench"), ready = true), marked)

        assertEquals(1, mixed.posts.size)
        assertFalse("the reader has something to scroll, and the scroll asks for the rest", mixed.chaining)
    }

    @Test
    fun `a merge that has run out is empty, not chaining`() {
        val done = WorkUi(available = true).column(FeedUi(posts = chatter, ready = true, exhausted = true), marked)

        assertTrue(done.posts.isEmpty())
        assertTrue("the column reads the merge's own exhaustion", done.exhausted)
        assertFalse("there is no next page to fetch, so the empty state is the truth", done.chaining)
    }

    /**
     * Nothing loaded and nothing suppressed: this is a network with marked feeds that have not posted, and
     * `No work posts yet.` is the honest screen. Asking for another page would be asking for a second helping
     * of nothing — and the safety filter's own chain (FeedUi.chaining) covers a window emptied before this.
     */
    @Test
    fun `an empty window is not chaining`() {
        val empty = WorkUi(available = true).column(FeedUi(posts = emptyList(), ready = true), marked)

        assertEquals(0, empty.filteredOut)
        assertFalse(empty.chaining)
    }

    @Test
    fun `nothing chains while the merge is still arriving`() {
        val cold = WorkUi(available = true).column(FeedUi(posts = chatter), marked)
        assertTrue("`ready` is what says a page actually landed", cold.loading)
        assertFalse(cold.chaining)

        val fetching = WorkUi(available = true).column(FeedUi(posts = chatter, ready = true, loading = true), marked)
        assertFalse("a page is already on its way in", fetching.chaining)
    }

    @Test
    fun `marking every feed leaves the window and its count untouched`() {
        val all = WorkUi(available = true).column(FeedUi(posts = chatter, ready = true), setOf("ana_daily"))

        assertEquals(chatter, all.posts)
        assertEquals(0, all.filteredOut)
        assertFalse(all.chaining)
    }
}
