package ca.lucianlabs.tgsocial.protocol

import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.15 — the report email, byte for byte.
 *
 * It is the only thing about a report that ever leaves the device, it is written by hand into three clients,
 * and the person on the other end sorts an inbox by its subject line. So this asserts the whole body as one
 * string rather than a line at a time: a reordered field or a lost blank line is a change to the artefact.
 */
class ReportEmailTest {

    private val app = "tgsocial 1.0.0 (12) · Android"

    private val post = Post(
        chatId = -100,
        messageId = 144L shl 20,
        date = 1_700_000_000,
        sourceUsername = "waveloop_devlog",
        sourceTitle = "WaveLoop devlog",
        nodeUsername = "tgs_ana",
        text = PostText("Cut the tape at the transient."),
    )

    private val comment = Comment(
        chatId = -200,
        messageId = 12L shl 20,
        date = 1_700_000_100,
        channelUsername = "tgs_bob_r",
        authorUsername = "tgs_bob",
        authorName = "Bob",
        targetKey = "waveloop_devlog/144",
        link = DeepLink.post("tgs_bob_r", 12L shl 20),
        post = Post(chatId = -200, messageId = 12L shl 20, date = 1_700_000_100, sourceUsername = "tgs_bob_r", sourceTitle = "Bob"),
    )

    @Test
    fun `the seven reasons are the whole list, in order`() {
        assertEquals(
            listOf(
                "Spam",
                "Nudity or sexual content",
                "Violence or threats",
                "Hate or harassment",
                "Child safety",
                "Illegal content",
                "Something else",
            ),
            ReportEmail.REASONS,
        )
    }

    @Test
    fun `the subject is the reason verbatim, behind an em dash`() {
        assertEquals("tgsocial report — Spam", ReportEmail.subject("Spam"))
        assertEquals("tgsocial report — Nudity or sexual content", ReportEmail.subject(ReportEmail.REASONS[1]))
    }

    @Test
    fun `a reported post composes the whole mail`() {
        val mail = ReportEmail.compose(ReportSubject.forPost(post), "Spam", app)
        assertEquals("elijah@lucianlabs.ca", mail.to)
        assertEquals("tgsocial report — Spam", mail.subject)
        assertEquals(
            """
            Reason: Spam
            Link: https://t.me/waveloop_devlog/144
            Channel: @waveloop_devlog
            Message: 144
            Node: @tgs_ana
            Kind: post
            App: tgsocial 1.0.0 (12) · Android

            Anything you want to add:

            """.trimIndent() + "\n",
            mail.body,
        )
        // The body ends on a blank line so the composer's cursor lands under the prompt.
        assertTrue(mail.body.endsWith("Anything you want to add:\n\n"))
    }

    @Test
    fun `a reported comment names the commenter's own channel and reads as a comment`() {
        val mail = ReportEmail.compose(ReportSubject.forComment(comment), "Hate or harassment", app)
        assertEquals("tgsocial report — Hate or harassment", mail.subject)
        assertEquals(
            """
            Reason: Hate or harassment
            Link: https://t.me/tgs_bob_r/12
            Channel: @tgs_bob_r
            Message: 12
            Node: @tgs_bob
            Kind: comment
            App: tgsocial 1.0.0 (12) · Android

            Anything you want to add:

            """.trimIndent() + "\n",
            mail.body,
        )
    }

    @Test
    fun `an unattributed post says so rather than inventing a node`() {
        val orphan = post.copy(nodeUsername = null)
        val body = ReportEmail.body(ReportSubject.forPost(orphan), "Illegal content", app)
        assertTrue(body.contains("\nNode: unattributed\n"))
    }

    /** PROTOCOL §7.1 — the same subject that mints the mail mints the hidden-list key. */
    @Test
    fun `the subject's key is the target key the filter hides on`() {
        assertEquals("waveloop_devlog/144", ReportSubject.forPost(post).key)
        assertEquals("tgs_bob_r/12", ReportSubject.forComment(comment).key)
    }
}
