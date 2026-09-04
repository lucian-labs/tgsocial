package ca.lucianlabs.tgsocial.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PROTOCOL §4.11 / §6.1 / §6.4 — what a `delete my node` aims step one at, and how it knows a channel is the
 * node's.
 *
 * The order in §4.11 exists to stop one outcome: the node channel deleted, `@<node>_r` left public and
 * backlinking to a node that no longer exists, with no route back to it from an app now sitting at Setup.
 * Skipping step one produces that outcome just as surely as running it out of order, so "is there a comments
 * channel" has to answer *unknown* differently from *no* — which is the whole reason [RepliesTarget] has
 * three cases rather than being a nullable string.
 */
class RepliesTest {

    private val card = Card(name = "Elijah", replies = "tgs_elijah_r")

    @Test
    fun `a card that names a comments channel declares it`() {
        assertEquals(RepliesTarget.Declared("tgs_elijah_r"), Replies.target(card, "tgs_elijah"))
    }

    @Test
    fun `a card that parses and names none means none`() {
        // The card is the record (§6.1): read, and silent about `replies:`, is an answer, not a gap.
        assertEquals(RepliesTarget.None, Replies.target(card.copy(replies = null), "tgs_elijah"))
    }

    @Test
    fun `an unreadable card is not an answer, so the convention is guessed`() {
        // PROTOCOL §9 — a `tgsocial v2` card leaves NodeRepo with a node and no card, and so does a pinned
        // message that would not load. Both still reach Settings' Delete My Node.
        assertEquals(RepliesTarget.Guessed("tgs_elijah_r"), Replies.target(null, "tgs_elijah"))
    }

    @Test
    fun `the convention stays inside Telegram's 32-character username limit`() {
        val long = "tgs_" + "a".repeat(28) // 32 chars already
        assertEquals(32, Replies.convention(long).length)
        assertEquals("tgs_ana_r", Replies.convention("tgs_ana"))
    }

    @Test
    fun `a guess with nothing to guess from is no target at all`() {
        assertEquals(RepliesTarget.None, Replies.target(null, ""))
    }

    @Test
    fun `the description written on creation is the one that verifies the channel`() {
        val written = Replies.description("tgs_elijah")
        assertEquals("tgsocial v1 replies · @tgs_elijah", written)
        assertTrue(Replies.describesRepliesFor(written, "tgs_elijah"))
        assertTrue("Telegram usernames are case-insensitive", Replies.describesRepliesFor(written, "TGS_Elijah"))
    }

    @Test
    fun `the backlink names whose channel it is, not merely that it is one`() {
        val ana = Replies.description("tgs_ana")
        assertFalse("@tgs_ana's replies channel is not @tgs_elijah's", Replies.describesRepliesFor(ana, "tgs_elijah"))
    }

    @Test
    fun `a channel that is not a comments channel never verifies`() {
        // The two ways a channel can sit on the `<node>_r` username without being the node's comments channel:
        // someone else's channel entirely, and one of the owner's own with a description of their own.
        assertFalse(Replies.describesRepliesFor("Rare records, weekly.", "tgs_elijah"))
        assertFalse("a node's own card description is not a replies description",
            Replies.describesRepliesFor(CardFormat.description("bass and coffee"), "tgs_elijah"))
    }

    @Test
    fun `an owner who added their own words to the description keeps their channel verifiable`() {
        assertTrue(Replies.describesRepliesFor("tgsocial v1 replies · @tgs_elijah · say hello", "tgs_elijah"))
    }
}
