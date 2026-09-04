package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.protocol.CommentThread
import ca.lucianlabs.tgsocial.model.CommentNode
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.protocol.Username
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.22.1 — the fixture world, asserted against the numbers §2.22.1 puts on the screen.
 *
 * Every one of these is a figure a reviewer can read off the app — `DIRECT · 4`, `5 comments`, `2y ago` — so a
 * fixture edited without its table falls out here rather than in review.
 */
class DemoWorldTest {

    private val start = 1_800_000_000L

    @Test
    fun `fifteen nodes, every one named as a fixture`() {
        assertEquals(15, DemoWorld.nodes.size)
        DemoWorld.nodes.forEach { assertTrue(it.username, it.username.startsWith("tgs_demo_")) }
        DemoWorld.channels.forEach { assertTrue(it.username, it.username.startsWith("demo_")) }
        // Every username is a legal Telegram username, so nothing here is a shape the parser would refuse.
        DemoWorld.nodes.forEach { assertEquals(it.username, Username.normalise(it.username)) }
        DemoWorld.channels.forEach { assertEquals(it.username, Username.normalise(it.username)) }
    }

    @Test
    fun `the reader's card is the literal PROTOCOL section 2 vector`() {
        assertEquals(
            """
            tgsocial v1
            name: Demo Reader
            bio: Looking around.
            public: no
            feeds: @demo_you_notes
            follows: @tgs_demo_wren @tgs_demo_mox @tgs_demo_juno @tgs_demo_pell
            replies: @tgs_demo_you_r
            """.trimIndent(),
            DemoWorld.readerCardText(),
        )
    }

    @Test
    fun `public no keeps the reader out of the Directory`() {
        assertFalse(DemoWorld.reader.public)
        assertTrue(DemoWorld.directory().none { Username.same(it.username, DemoWorld.READER) })
        assertTrue(DemoWorld.nearby().none { Username.same(it.username, DemoWorld.READER) })
    }

    @Test
    fun `the follow graph yields DIRECT 4 and plus one 7`() {
        assertEquals(4, DemoWorld.direct().size)
        assertEquals(7, DemoWorld.nearby().size)
    }

    @Test
    fun `NEARBY ranks by mutual count, ties broken by username ascending`() {
        assertEquals(
            listOf("tgs_demo_arto", "tgs_demo_orrin", "tgs_demo_sable", "tgs_demo_bly", "tgs_demo_crate", "tgs_demo_hask", "tgs_demo_ilka"),
            DemoWorld.nearby().map { it.username },
        )
        assertEquals(listOf(2, 2, 2, 1, 1, 1, 1), DemoWorld.nearby().map { it.mutualCount })
    }

    @Test
    fun `the DIRECTORY is the three nodes in no walk`() {
        assertEquals(listOf("tgs_demo_lume", "tgs_demo_noor", "tgs_demo_veda"), DemoWorld.directory().map { it.username })
    }

    @Test
    fun `two feeds carry the backlink so both Verified states are on screen`() {
        val verified = DemoWorld.channels.mapNotNull { DemoWorld.feedSource(it.username) }.filter { it.verifiedFor.isNotEmpty() }
        assertEquals(listOf("demo_tidewright", "demo_kiln_log"), verified.map { it.username })
        assertEquals(listOf("tgs_demo_wren"), verified.first().verifiedFor)
    }

    @Test
    fun `fifteen posts across six sources, newest first`() {
        val posts = DemoWorld.posts(start)
        assertEquals(15, posts.size)
        assertEquals(6, DemoWorld.mainFeedSources().size)
        assertEquals(6, posts.map { Username.key(it.sourceUsername) }.distinct().size)
        assertEquals(posts.map { it.date }.sortedDescending(), posts.map { it.date })
    }

    @Test
    fun `the plus one nodes' feeds are deliberately absent from the main feed`() {
        val sources = DemoWorld.mainFeedSources().map { Username.key(it) }.toSet()
        assertFalse("demo_creek_cam" in sources)
        // …but arto's profile still lists it: a feed one walk out is one the reader has to go and find.
        assertEquals(listOf("demo_creek_cam"), DemoWorld.node("tgs_demo_arto")?.feeds)
    }

    @Test
    fun `every rung of the relative-time ladder is on the list`() {
        val ages = DemoWorld.posts(start).map { Format.relative(it.date.toLong(), start) }
        assertEquals(
            listOf(
                "now", "6m ago", "22m ago", "2h ago", "5h ago", "9h ago", "14h ago",
                "1d ago", "2d ago", "3d ago", "6d ago", "2w ago", "5w ago", "4mo ago", "2y ago",
            ),
            ages,
        )
    }

    @Test
    fun `reactions and views derive from the message id`() {
        for (post in DemoWorld.posts(start)) {
            val id = post.messageId shr 20
            assertEquals("views for $id", (60 + (id * 37) % 900).toInt(), post.views)
            assertEquals("reactions for $id", ((id * 7) % 23).toInt(), post.reactions.sumOf { it.count })
        }
    }

    @Test
    fun `the first thread is five comments with a three-deep re chain`() {
        val index = DemoWorld.commentIndex(start)
        assertEquals(5, CommentThread.count("demo_tidewright/144", index))
        val roots = CommentThread.of("demo_tidewright/144", index)
        assertEquals(3, roots.size)
        assertEquals(3, depth(roots))
    }

    @Test
    fun `the second thread is one chain six deep, so the depth-5 cap flattens its last row`() {
        val index = DemoWorld.commentIndex(start)
        assertEquals(6, CommentThread.count("demo_kiln_log/219", index))
        val roots = CommentThread.of("demo_kiln_log/219", index)
        assertEquals(1, roots.size)
        assertEquals(6, depth(roots))
    }

    @Test
    fun `the spam comment is reached at plus one and carries the pill`() {
        val crate = DemoWorld.commentIndex(start).getValue("demo_tidewright/144").first { it.channelUsername == "demo_crate_r" }
        assertTrue(crate.plusOne)
        assertEquals("tgs_demo_crate", crate.authorUsername)
    }

    @Test
    fun `the reader has never commented, so the first-comment card never appears`() {
        val index = DemoWorld.commentIndex(start)
        assertTrue(index.values.flatten().none { Username.same(it.channelUsername, DemoWorld.READER_REPLIES) })
        assertEquals(DemoWorld.READER_REPLIES, DemoWorld.reader.card.replies)
    }

    @Test
    fun `a comment's target key is the key its post builds for itself`() {
        val post = DemoWorld.posts(start).first { it.messageId shr 20 == 144L }
        assertEquals("demo_tidewright/144", DemoWorld.postKey(post))
        assertTrue(DemoWorld.commentIndex(start).containsKey(DemoWorld.postKey(post)))
    }

    @Test
    fun `an unknown username is not a node`() {
        assertNull(DemoWorld.node("tgs_someone_real"))
        assertNull(DemoWorld.snapshot("tgs_someone_real"))
    }

    private fun depth(nodes: List<CommentNode>): Int =
        if (nodes.isEmpty()) 0 else 1 + nodes.maxOf { depth(it.replies) }
}
