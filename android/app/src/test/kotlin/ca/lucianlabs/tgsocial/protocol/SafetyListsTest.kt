package ca.lucianlabs.tgsocial.protocol

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PROTOCOL §7.1 — **the record itself**: what it accepts, what it compares case-insensitively, and what it
 * does when the account changes.
 *
 * These are the properties the rest of the safety features stand on. A block list that missed `@TGS_Ana`
 * because Telegram usernames are case-insensitive is a filter with a hole in it; a record that a cache bump
 * could discard is a block list that quietly stops blocking.
 */
class SafetyListsTest {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test
    fun `blocking is case-insensitive, both in and out`() {
        val lists = SafetyLists().block("@TGS_Ana".removePrefix("@"))
        assertTrue("the list was written from mixed case", lists.isBlocked("tgs_ana"))
        assertTrue("and reads back through any casing", lists.isBlocked("TGS_ANA"))
        assertFalse("someone else is not blocked", lists.isBlocked("tgs_bob"))

        val lifted = lists.unblock("TgS_AnA")
        assertFalse("unblocking matches the same way", lifted.isBlocked("tgs_ana"))
        assertTrue("and leaves nothing behind", lifted.blocked.isEmpty())
    }

    @Test
    fun `blocking the same node twice does not list it twice`() {
        val once = SafetyLists().block("tgs_ana")
        val twice = once.block("TGS_ANA")
        assertEquals(listOf("tgs_ana"), twice.blocked)
    }

    @Test
    fun `muting is a feed, and is independent of blocking`() {
        val lists = SafetyLists().mute("WaveLoop_Devlog").block("tgs_ana")
        assertTrue(lists.isMuted("waveloop_devlog"))
        assertFalse("muting a feed does not block its node", lists.isBlocked("waveloop_devlog"))
        val unmuted = lists.unmute("waveloop_devlog")
        assertFalse(unmuted.isMuted("waveloop_devlog"))
        assertTrue("and the block survives it — each undo lifts only its own list", unmuted.isBlocked("tgs_ana"))
    }

    /** §2.20: "a hidden row whose channel is also blocked or muted still lists here; the lists are independent." */
    @Test
    fun `hiding keys on the target and re-reporting restates the reason rather than duplicating the row`() {
        val first = SafetyLists().hide("waveloop_devlog/144", "Spam", "2026-09-04T21:02:11Z")
        val second = first.hide("WaveLoop_Devlog/144", "Hate or harassment", "2026-09-05T08:00:00Z")
        assertEquals("one row, not two", 1, second.hidden.size)
        assertEquals("carrying the reason last picked", "Hate or harassment", second.hidden.single().reason)
        assertTrue("and still hidden", second.isHidden("waveloop_devlog/144"))
        assertFalse("nothing else is", second.isHidden("waveloop_devlog/145"))

        val back = second.unhide("waveloop_devlog/144")
        assertFalse(back.isHidden("waveloop_devlog/144"))
    }

    /**
     * §7.1 — the record survives Sign Out **for the same account**, and only for it. Both halves matter: a list
     * that evaporated would re-expose the reader to the person they blocked, and one inherited on a shared
     * device would be someone else's judgement.
     */
    @Test
    fun `the same account keeps its lists and a different one starts empty`() {
        val mine = SafetyLists(userId = 176543210).block("tgs_ana").mute("waveloop_devlog")

        val afterSignInAgain = mine.forAccount(176543210)
        assertEquals("nothing was dropped", mine, afterSignInAgain)
        assertTrue(afterSignInAgain.isBlocked("tgs_ana"))

        val someoneElse = mine.forAccount(99)
        assertTrue("their lists are not mine", someoneElse.isEmpty)
        assertEquals("and the record now belongs to them", 99L, someoneElse.userId)
    }

    /**
     * §7.1 — `v` is the record's own version, not the cache schema version. A record written by a build that
     * knew more (a higher `v`, keys this one has never heard of) is read as best it can be and never dropped.
     */
    @Test
    fun `a record from a newer build still yields its lists`() {
        val fromTheFuture = """
            {"v":7,"userId":176543210,"blocked":["tgs_ana"],"mutedFeeds":[],"hidden":[],"quarantined":["tgs_bob"]}
        """.trimIndent()
        val decoded = json.decodeFromString(SafetyLists.serializer(), fromTheFuture)
        assertTrue("the block it did carry is honoured", decoded.isBlocked("tgs_ana"))
        assertEquals("and the version it was written at is kept", 7, decoded.v)
    }

    @Test
    fun `a record round-trips through storage unchanged`() {
        val lists = SafetyLists(userId = 176543210)
            .block("tgs_ana")
            .mute("waveloop_devlog")
            .hide("waveloop_devlog/144", "Spam", "2026-09-04T21:02:11Z")
        val decoded = json.decodeFromString(SafetyLists.serializer(), json.encodeToString(SafetyLists.serializer(), lists))
        assertEquals(lists, decoded)
        assertEquals(SafetyLists.VERSION, decoded.v)
    }
}
