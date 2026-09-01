package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.12 + PROTOCOL §6.2 — **the `re:` chain made direct**: the target is whatever was tapped.
 *
 * A reply is a message in your own comments channel whose first line points at what it answers, so "tapping a
 * comment selects it as the reply target" is, in the end, a claim about which link ends up on that line. That
 * is what this asserts — for a comment, for the post, and across the tap that clears the selection again.
 */
class ReplyTargetTest {

    private val post = Post(
        chatId = -100,
        messageId = 34L shl 20,
        date = 1_700_000_000,
        sourceUsername = "waveloop",
        sourceTitle = "WaveLoop devlog",
        text = PostText("Cut the tape at the transient."),
    )

    private fun comment(author: String, channel: String, id: Int, body: String) = Comment(
        chatId = -200,
        messageId = id.toLong() shl 20,
        date = 1_700_000_100,
        channelUsername = channel,
        authorUsername = author.lowercase(),
        authorName = author,
        targetKey = CommentFormat.postKey(post.sourceUsername, post.messageId),
        link = DeepLink.post(channel, id.toLong() shl 20),
        post = Post(
            chatId = -200,
            messageId = id.toLong() shl 20,
            date = 1_700_000_100,
            sourceUsername = channel,
            sourceTitle = author,
            text = PostText(body),
        ),
    )

    private val ana = comment("Ana Iliovic", "ana_r", 12, "The bass is huge.")
    private val bob = comment("Bob", "bob_r", 3, "Agreed.")

    @Test
    fun `nothing selected sends the reply to the post`() {
        val target = ReplyTarget.resolve(selected = null, post = post)
        assertEquals("re: https://t.me/waveloop/34", ReplyTarget.firstLine(target))
        assertEquals("Say it.", ReplyTarget.placeholder(target))
    }

    @Test
    fun `tapping a comment sends the reply to that comment`() {
        val selected = ReplyTarget.toggle(current = null, tapped = ReplyTarget.forComment(ana))
        val target = ReplyTarget.resolve(selected, post)
        assertEquals("re: https://t.me/ana_r/12", ReplyTarget.firstLine(target))
        assertEquals("Reply to Ana Iliovic.", ReplyTarget.placeholder(target))
        assertTrue("the quote names the person and their words", ReplyTarget.quote(target).startsWith("re: Ana Iliovic — 'The bass is huge."))
    }

    @Test
    fun `tapping a second comment moves the target rather than stacking one`() {
        var selected = ReplyTarget.toggle(null, ReplyTarget.forComment(ana))
        selected = ReplyTarget.toggle(selected, ReplyTarget.forComment(bob))
        assertEquals("re: https://t.me/bob_r/3", ReplyTarget.firstLine(ReplyTarget.resolve(selected, post)))
    }

    /** §2.12: "tapping it again, or the quote's ×, clears the target and the reply goes to the post instead." */
    @Test
    fun `tapping the selected comment again aims back at the post`() {
        val selected = ReplyTarget.toggle(null, ReplyTarget.forComment(ana))
        val cleared = ReplyTarget.toggle(selected, ReplyTarget.forComment(ana))
        assertNull("the selection is gone", cleared)
        assertEquals("re: https://t.me/waveloop/34", ReplyTarget.firstLine(ReplyTarget.resolve(cleared, post)))
        assertEquals("Say it.", ReplyTarget.placeholder(cleared))
    }

    /** The line the message actually carries, both ways round — PROTOCOL §6.2's format, byte for byte. */
    @Test
    fun `the written comment leads with re and the target's own link`() {
        val body = "Right? Listen at 1:12."
        val toComment = CommentFormat.serialise(ReplyTarget.forComment(ana).link, body)
        assertEquals("re: https://t.me/ana_r/12\n$body", toComment)
        val toPost = CommentFormat.serialise(ReplyTarget.forPost(post).link, body)
        assertEquals("re: https://t.me/waveloop/34\n$body", toPost)

        // And each round-trips through the parser that indexes it — a reply hangs off the comment, a comment
        // off the post, which is the chain §6.2 describes.
        assertEquals("ana_r/12", CommentFormat.parse(toComment)?.target?.let { CommentFormat.targetKey(it) })
        assertEquals("waveloop/34", CommentFormat.parse(toPost)?.target?.let { CommentFormat.targetKey(it) })
        assertEquals(body, CommentFormat.parse(toComment)?.body)
    }

    @Test
    fun `a long excerpt is cut rather than wrapped, and an empty one is dropped`() {
        val wordy = comment("Cy", "cy_r", 5, "x".repeat(ReplyTarget.EXCERPT_LIMIT * 2))
        val quote = ReplyTarget.quote(ReplyTarget.forComment(wordy))
        assertTrue("cut with an ellipsis", quote.endsWith("…'"))
        assertTrue("and only just past the limit", quote.length < ReplyTarget.EXCERPT_LIMIT + "re: Cy — '…'".length + 1)

        val silent = comment("Dee", "dee_r", 6, "")
        assertEquals("re: Dee", ReplyTarget.quote(ReplyTarget.forComment(silent)))
    }
}
