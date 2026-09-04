package ca.lucianlabs.tgsocial.ui

import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostText
import ca.lucianlabs.tgsocial.protocol.SafetyLists
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.18 — "Pagination compensates: a page whose items are all filtered fetches the next one rather
 * than rendering an empty list."
 *
 * The reason this needs a state of its own is that nothing else can see it. The screen's pager fires off the
 * LazyColumn's item count, and a page that goes entirely into the filter does not change that count — so the
 * pager's predicate never leaves `true`, never emits again, and one flick fetches exactly one extra page
 * before the feed stops for good. [FeedUi.chaining] is that condition named: posts loaded, none of them
 * visible, more to fetch. Asserted on the real [FeedUi.filtered] the view model renders through, so a feed
 * that stopped counting what the filter took would fail here.
 */
class FeedChainingTest {

    private fun post(id: Long, node: String?) = Post(
        chatId = -100,
        messageId = id shl 20,
        date = 1_700_000_000 + id.toInt(),
        sourceUsername = "waveloop_devlog",
        sourceTitle = "WaveLoop devlog",
        nodeUsername = node,
        text = PostText("post $id"),
    )

    /** One prolific node supplies the whole page; the reader blocks them. */
    private val page = listOf(post(1, "tgs_ana"), post(2, "tgs_ana"), post(3, "tgs_ana"))
    private val blockedAna = SafetyLists().block("tgs_ana")

    @Test
    fun `a page the filter takes whole is a chain, not an empty feed`() {
        val loaded = FeedUi(posts = page, ready = true).filtered(blockedAna)

        assertTrue("nothing is left to paint", loaded.posts.isEmpty())
        assertEquals("and the filter says how much it took", 3, loaded.filteredOut)
        assertTrue("so the next page is owed", loaded.chaining)
    }

    @Test
    fun `one survivor ends the chain`() {
        val mixed = FeedUi(posts = page + post(4, "tgs_bob"), ready = true).filtered(blockedAna)

        assertEquals(1, mixed.posts.size)
        assertFalse("the reader has something to scroll, and the scroll asks for the rest", mixed.chaining)
    }

    @Test
    fun `a feed that has run out is empty, not chaining`() {
        val done = FeedUi(posts = page, ready = true, exhausted = true).filtered(blockedAna)

        assertTrue(done.posts.isEmpty())
        assertFalse("there is no next page to fetch, so the empty state is the truth", done.chaining)
    }

    @Test
    fun `a genuinely empty feed is not chaining`() {
        // Nothing loaded and nothing filtered: `Nothing here yet.` is the honest screen, and asking for
        // another page would be asking for a second helping of nothing.
        val empty = FeedUi(posts = emptyList(), ready = true).filtered(SafetyLists())

        assertEquals(0, empty.filteredOut)
        assertFalse(empty.chaining)
    }

    @Test
    fun `nothing chains before the first page has landed`() {
        val cold = FeedUi(posts = page).filtered(blockedAna)

        assertFalse("`ready` is what says a page was actually loaded", cold.chaining)
    }

    @Test
    fun `an empty safety list leaves the feed and its count untouched`() {
        val unfiltered = FeedUi(posts = page, ready = true).filtered(SafetyLists())

        assertEquals(page, unfiltered.posts)
        assertEquals(0, unfiltered.filteredOut)
    }
}
