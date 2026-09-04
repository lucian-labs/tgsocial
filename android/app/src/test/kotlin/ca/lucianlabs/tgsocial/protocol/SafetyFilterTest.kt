package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.18 — **the default filter**, asserted where it is claimed: on the lists a screen renders, and on
 * the count under a post.
 *
 * The claims are specific, so the assertions are too. Dropping leaves "no gap, no placeholder, and no residue
 * in a count", which means the comment count has to fall by the replies under a blocked commenter as well as
 * by their own comment — so this runs the real [CommentThread] over the filtered index rather than trusting
 * that the map got smaller. Muting is main-feed-only, so the same post list is filtered twice and compared.
 */
class SafetyFilterTest {

    private fun post(id: Long, channel: String, node: String?) = Post(
        chatId = -100,
        messageId = id shl 20,
        date = 1_700_000_000 + id.toInt(),
        sourceUsername = channel,
        sourceTitle = "WaveLoop devlog",
        nodeUsername = node,
        text = PostText("post $id"),
    )

    /** A comment in [channel] owned by [author], pointing at [target]. */
    private fun comment(id: Long, channel: String, author: String, target: String) = Comment(
        chatId = -200,
        messageId = id shl 20,
        date = 1_700_000_100 + id.toInt(),
        channelUsername = channel,
        authorUsername = author,
        authorName = author,
        targetKey = target,
        link = DeepLink.post(channel, id shl 20),
        post = Post(
            chatId = -200,
            messageId = id shl 20,
            date = 1_700_000_100 + id.toInt(),
            sourceUsername = channel,
            sourceTitle = author,
            text = PostText("comment $id"),
        ),
    )

    private fun index(vararg comments: Comment): Map<String, List<Comment>> =
        comments.groupBy { it.targetKey }

    private val anasPost = post(144, "waveloop_devlog", "tgs_ana")
    private val bobsPost = post(145, "waveloop_devlog", "tgs_bob")
    private val unattributed = post(146, "some_channel", null)

    @Test
    fun `a blocked node's posts leave the feed and everyone else's stay`() {
        val feed = listOf(anasPost, bobsPost, unattributed)
        val blocked = SafetyLists().block("TGS_Ana")
        val visible = SafetyFilter.posts(feed, blocked, mainFeed = true)
        assertEquals("only the blocked node's post went", listOf(bobsPost, unattributed), visible)
    }

    @Test
    fun `a muted feed leaves the main feed and stays complete on its own screen`() {
        val feed = listOf(anasPost, bobsPost, unattributed)
        val muted = SafetyLists().mute("waveloop_devlog")
        assertEquals(
            "the muted channel's posts are gone from the merged feed",
            listOf(unattributed),
            SafetyFilter.posts(feed, muted, mainFeed = true),
        )
        assertEquals(
            "and the channel's own screen is untouched — §2.17 mutes a feed, it does not hide a channel",
            feed,
            SafetyFilter.posts(feed, muted, mainFeed = false),
        )
    }

    @Test
    fun `a reported post is hidden everywhere, its own channel screen included`() {
        val key = SafetyFilter.key(anasPost)
        assertEquals("the key is the §6.2 target key", "waveloop_devlog/144", key)
        val hidden = SafetyLists().hide(key, "Spam", "2026-09-04T21:02:11Z")
        assertFalse(SafetyFilter.keeps(anasPost, hidden, mainFeed = true))
        assertFalse("no surface is exempt", SafetyFilter.keeps(anasPost, hidden, mainFeed = false))
        assertTrue("and nothing else is touched", SafetyFilter.keeps(bobsPost, hidden, mainFeed = true))
    }

    /**
     * §2.18: "every comment whose commenter node is blocked, **including replies under it**" — and "a hidden
     * comment is not in the post footer's `N comments`".
     */
    @Test
    fun `blocking a commenter takes their comment, the replies under it, and the count with them`() {
        val postKey = CommentFormat.postKey(anasPost.sourceUsername, anasPost.messageId)
        val ana = comment(12, "tgs_ana_r", "tgs_ana", postKey)
        val bobUnderAna = comment(3, "tgs_bob_r", "tgs_bob", CommentFormat.targetKey(ana.link)!!)
        val bobOnThePost = comment(4, "tgs_bob_r", "tgs_bob", postKey)
        val index = index(ana, bobUnderAna, bobOnThePost)

        assertEquals("three comments before anything is blocked", 3, CommentThread.count(postKey, index))

        val blocked = SafetyLists().block("tgs_ana")
        val filtered = SafetyFilter.comments(index, blocked)
        assertEquals("the count falls by two: the comment and the reply hanging off it", 1, CommentThread.count(postKey, filtered))
        val roots = CommentThread.of(postKey, filtered)
        assertEquals(1, roots.size)
        assertEquals("and what is left is the comment on the post itself", bobOnThePost.key, roots.single().comment.key)
    }

    @Test
    fun `a reported comment is keyed exactly like a reported post`() {
        val postKey = CommentFormat.postKey(anasPost.sourceUsername, anasPost.messageId)
        val ana = comment(12, "tgs_ana_r", "tgs_ana", postKey)
        assertEquals(
            "one lookup filters a hidden post and a hidden comment alike (PROTOCOL §7.1)",
            CommentFormat.targetKey(ana.link),
            SafetyFilter.key(ana),
        )

        val index = index(ana)
        val hidden = SafetyLists().hide(SafetyFilter.key(ana), "Something else", "2026-09-04T21:02:11Z")
        assertEquals("reporting a comment removes it from its post's count", 0, CommentThread.count(postKey, SafetyFilter.comments(index, hidden)))
    }

    @Test
    fun `a blocked node is not in Explore, the graph lists, or their counts`() {
        val entries = listOf(
            NodeEntry(username = "tgs_ana", name = "Ana Iliovic", feedCount = 2),
            NodeEntry(username = "tgs_bob", name = "Bob", feedCount = 1),
        )
        val visible = SafetyFilter.nodes(entries, SafetyLists().block("tgs_ana"))
        assertEquals(1, visible.size)
        assertEquals("tgs_bob", visible.single().username)
    }

    @Test
    fun `empty lists change nothing at all`() {
        val feed = listOf(anasPost, bobsPost, unattributed)
        val fresh = SafetyLists()
        assertEquals(feed, SafetyFilter.posts(feed, fresh, mainFeed = true))
        val postKey = CommentFormat.postKey(anasPost.sourceUsername, anasPost.messageId)
        val index = index(comment(12, "tgs_ana_r", "tgs_ana", postKey))
        assertEquals(index, SafetyFilter.comments(index, fresh))
    }
}
