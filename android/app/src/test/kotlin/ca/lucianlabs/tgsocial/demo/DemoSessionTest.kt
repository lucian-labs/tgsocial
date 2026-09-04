package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.protocol.CommentThread
import ca.lucianlabs.tgsocial.protocol.SafetyFilter
import ca.lucianlabs.tgsocial.protocol.Username
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.22.2 — "what still works, because it has to", asserted the way §2.22.2 says it is checkable: by
 * counting. Every number here is one a reviewer reads off the screen before and after one tap.
 */
class DemoSessionTest {

    private fun session() = DemoRepo(startedAt = 1_800_000_000L)

    // ------------------------------------------------------------------ pagination

    @Test
    fun `the demo pages eight at a time, then says there is nothing more`() {
        val d = session()
        assertEquals(8, d.feedPage().size)
        assertFalse(d.feedExhausted)
        assertEquals(7, d.feedPage().size)
        assertTrue(d.feedExhausted)
        assertEquals(0, d.feedPage().size)
    }

    @Test
    fun `a refresh rebuilds the window from the newest post down`() {
        val d = session()
        val first = d.feedPage()
        d.resetFeed()
        assertEquals(first.map { it.key }, d.feedPage().map { it.key })
    }

    // ------------------------------------------------------------------ compose (PRODUCT §2.22.3 / §2.22.4)

    /**
     * §2.22.4 — the sheet a reviewer opens with `Compose` must be answerable **from the fixture world**.
     * Every feed on the reader's card resolves here, so the view model's "some feed did not resolve, go
     * look it up" branch never fires; a card naming a channel the demo has no source for is the shape of
     * the bug that had Compose ask TDLib to resolve `@demo_you_notes` against Telegram.
     */
    @Test
    fun `every feed on the reader's card resolves inside the demo, so nothing has to be looked up`() {
        val d = session()
        val feeds = d.me.card?.feeds.orEmpty()
        assertEquals(listOf("demo_you_notes"), feeds)
        assertEquals(feeds.size, feeds.mapNotNull { d.feedSource(it) }.size)
        assertEquals("My Notes", d.feedSource("demo_you_notes")?.title)
    }

    // ------------------------------------------------------------------ the filter (PRODUCT §2.18 / §2.22.2)

    @Test
    fun `blocking the spam node takes the post from five comments to four`() {
        val d = session()
        val key = "demo_tidewright/144"
        assertEquals(5, CommentThread.count(key, d.comments))
        d.updateSafety { it.block("tgs_demo_crate") }
        assertEquals(4, CommentThread.count(key, SafetyFilter.comments(d.comments, d.safety)))
    }

    @Test
    fun `blocking the spam node drops it from NEARBY and takes plus one from seven to six`() {
        val d = session()
        assertEquals(7, d.nearby().size)
        d.updateSafety { it.block("tgs_demo_crate") }
        val visible = SafetyFilter.nodes(d.nearby(), d.safety)
        assertEquals(6, visible.size)
        assertTrue(visible.none { Username.same(it.username, "tgs_demo_crate") })
    }

    @Test
    fun `muting Slow Radio takes the feed from fifteen to twelve and leaves its own screen complete`() {
        val d = session()
        val all = d.feedPage() + d.feedPage()
        assertEquals(15, all.size)
        d.updateSafety { it.mute("demo_slow_radio") }
        assertEquals(12, SafetyFilter.posts(all, d.safety, mainFeed = true).size)
        // §2.17 — the channel's own screen stays complete when muted.
        val own = d.channelPosts("demo_slow_radio")
        assertEquals(3, own.size)
        assertEquals(3, SafetyFilter.posts(own, d.safety, mainFeed = false).size)
        assertTrue(d.safety.isMuted("demo_slow_radio"))
    }

    @Test
    fun `reporting a post hides it everywhere and Settings can put it back`() {
        val d = session()
        val all = d.feedPage() + d.feedPage()
        val post = all.first { it.sourceUsername == "demo_kiln_log" }
        val key = SafetyFilter.key(post)
        d.updateSafety { it.hide(key, "Spam", "2026-09-04T00:00:00Z") }
        assertFalse(SafetyFilter.keeps(post, d.safety, mainFeed = false))
        assertEquals(1, d.safety.hidden.size)
        assertEquals("Spam", d.safety.hidden.single().reason)
        d.updateSafety { it.unhide(key) }
        assertTrue(SafetyFilter.keeps(post, d.safety, mainFeed = false))
    }

    // ------------------------------------------------------------------ PROTOCOL §7.1 — no user id, no home

    @Test
    fun `a demo record can never carry an account id`() {
        val d = session()
        assertEquals(DemoRepo.NO_ACCOUNT, d.safety.userId)
        // Even a transform that names an account — the shape `forAccount` writes — comes back accountless, so
        // a demo record can never be mistaken for a real one that happens to be on disk.
        d.updateSafety { it.copy(userId = 176_543_210L).block("tgs_demo_crate") }
        assertEquals(DemoRepo.NO_ACCOUNT, d.safety.userId)
        assertEquals(listOf("tgs_demo_crate"), d.safety.blocked)
    }

    @Test
    fun `the session starts with empty lists rather than the reader's own`() {
        assertTrue(session().safety.isEmpty)
    }

    // ------------------------------------------------------------------ shape

    @Test
    fun `the reader's node and card are the ones Delete My Node names`() {
        val d = session()
        assertEquals(DemoWorld.READER, d.myNode.username)
        assertEquals(DemoWorld.READER_REPLIES, d.me.card?.replies)
        assertFalse(d.nodeDeleted)
        d.deleteNode()
        assertTrue(d.nodeDeleted)
    }

    @Test
    fun `an exact fixture username opens a profile and anything else does not`() {
        val d = session()
        assertEquals("tgs_demo_wren", d.find("@tgs_demo_wren"))
        assertEquals("tgs_demo_wren", d.find("https://t.me/tgs_demo_wren"))
        assertEquals(null, d.find("tgs_ana"))
    }

    @Test
    fun `a profile resolves its feeds and its follows`() {
        val d = session()
        assertEquals(listOf("demo_tidewright", "demo_wren_bench"), d.feedsOf("tgs_demo_wren").map { it.username })
        assertEquals(4, d.followsOf("tgs_demo_wren").size)
        assertEquals("Tidewright", d.feedSource("demo_tidewright")?.title)
    }
}
