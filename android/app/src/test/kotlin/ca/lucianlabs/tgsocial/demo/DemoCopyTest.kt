package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.protocol.ReportEmail
import ca.lucianlabs.tgsocial.protocol.ReportSubject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §3 — copy is shared across the three builds: the same control says the same words everywhere. These
 * are the strings verbatim, so a reworded control on Android fails here instead of quietly disagreeing with
 * iOS and web.
 */
class DemoCopyTest {

    @Test
    fun `the entry point`() {
        assertEquals("Look Around First", DemoCopy.ENTER)
        assertEquals("Invented people, invented posts. Nothing is sent to Telegram.", DemoCopy.ENTER_NOTE)
    }

    @Test
    fun `the three persistent indicators`() {
        assertEquals("Demo", DemoCopy.PILL)
        assertEquals("Demo. Everyone here is invented. Nothing leaves this device.", DemoCopy.STRIP)
    }

    @Test
    fun `three refusals, because each names a different truth`() {
        assertEquals("The demo doesn't write to Telegram.", DemoCopy.NO_WRITE)
        assertEquals("Nothing here is on Telegram.", DemoCopy.NOT_ON_TELEGRAM)
        assertEquals("Links don't open in the demo.", DemoCopy.NO_LINKS)
        assertEquals(3, setOf(DemoCopy.NO_WRITE, DemoCopy.NOT_ON_TELEGRAM, DemoCopy.NO_LINKS).size)
    }

    @Test
    fun `the demo sheet`() {
        assertEquals("Demo", DemoCopy.SHEET_MARK)
        assertEquals("You're in the demo.", DemoCopy.SHEET_TITLE)
        assertEquals(
            "Everyone here is invented. Nothing is sent to Telegram and nothing is saved on this device. " +
                "Report, block and mute are real and work on these fixtures.",
            DemoCopy.SHEET_BODY,
        )
        assertEquals("Telegram", DemoCopy.ROW_TELEGRAM)
        assertEquals("Not connected", DemoCopy.ROW_TELEGRAM_VALUE)
        assertEquals("Leave Demo", DemoCopy.LEAVE)
        assertEquals("Close", DemoCopy.CLOSE)
    }

    @Test
    fun `the exits`() {
        assertEquals("Left the demo.", DemoCopy.LEFT)
        assertEquals("Your node is gone. The demo is over.", DemoCopy.NODE_GONE)
    }

    /** PRODUCT §3's word list: `demo`, and never these four. */
    @Test
    fun `no banned word appears in any demo string`() {
        val strings = listOf(
            DemoCopy.ENTER, DemoCopy.ENTER_NOTE, DemoCopy.PILL, DemoCopy.STRIP,
            DemoCopy.NO_WRITE, DemoCopy.NOT_ON_TELEGRAM, DemoCopy.NO_LINKS,
            DemoCopy.SHEET_MARK, DemoCopy.SHEET_TITLE, DemoCopy.SHEET_BODY,
            DemoCopy.LEAVE, DemoCopy.CLOSE, DemoCopy.LEFT, DemoCopy.NODE_GONE, DemoCopy.REPORT_PREFIX,
        )
        val banned = listOf("sandbox", "sample", "test mode", "fake", "friends", "subscribe", "timeline", "algorithm", "flag", "ban ", "moderation")
        for (s in strings) {
            for (word in banned) assertFalse("$word in \"$s\"", s.lowercase().contains(word))
            assertFalse("no exclamation marks: $s", s.contains('!'))
        }
    }

    // ------------------------------------------------------------------ the one §2.15 deviation

    private val subject = ReportSubject.forPost(
        Post(chatId = -1, messageId = 144L shl 20, date = 0, sourceUsername = "demo_tidewright", sourceTitle = "Tidewright", nodeUsername = "tgs_demo_wren"),
    )

    @Test
    fun `a real report carries nothing the app added`() {
        val mail = ReportEmail.compose(subject, "Spam", "tgsocial 1.0.0 (1) · Android")
        assertEquals(mail, DemoCopy.report(mail, inDemo = false))
        assertFalse(mail.body.contains(DemoCopy.REPORT_PREFIX))
    }

    @Test
    fun `a demo report prepends exactly one line and changes nothing else`() {
        val mail = ReportEmail.compose(subject, "Spam", "tgsocial 1.0.0 (1) · Android")
        val demo = DemoCopy.report(mail, inDemo = true)
        assertEquals(mail.to, demo.to)
        assertEquals(mail.subject, demo.subject)
        assertEquals("Demo: this report is from the demo and the link is invented.", demo.body.lineSequence().first())
        assertEquals(mail.body, demo.body.substringAfter('\n'))
        assertEquals(mail.body.lines().size + 1, demo.body.lines().size)
        assertTrue(demo.body.contains("Link: https://t.me/demo_tidewright/144"))
    }
}
