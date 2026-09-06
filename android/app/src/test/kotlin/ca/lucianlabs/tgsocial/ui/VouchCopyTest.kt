package ca.lucianlabs.tgsocial.ui

import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.protocol.Card
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * PRODUCT §2.23 / §2.25, under §3 — copy is shared across the three builds, and these five strings are the
 * ones a build gets subtly wrong, because each of them has a person's name in the middle of a sentence.
 *
 * The spec prints them with `Ana`: the subject's **first** name, the way somebody would say it out loud.
 * Passing the display name whole gives `Say one thing Wren Alderiss does.` and `WHAT WREN ALDERISS DOES`
 * where iOS and web say `Wren` — five strings differing between builds on one screen. Passing the username
 * where a card has no `name` gives `Say one thing @tgs_bob does.`, which is worse: it is not a name at all.
 */
class VouchCopyTest {

    private fun node(name: String?) = NodeSnapshot(
        username = "tgs_wren",
        chatId = -100,
        supergroupId = 100,
        title = "Wren's channel",
        card = Card(name = name),
    )

    @Test
    fun `the name a sentence uses is the card's first name`() {
        val wren = node("Wren Alderiss")

        assertEquals("Wren", wren.firstName)
        assertNotEquals("and not the whole of it", wren.displayName, wren.firstName)
    }

    /** Repeated or leading whitespace in a `name` is somebody's typing, not a second word. */
    @Test
    fun `whitespace does not make a name`() {
        assertEquals("Wren", node("  Wren   Alderiss ").firstName)
        assertNull(node("   ")?.firstName)
        assertNull("a card with no name has none to give", node(null).firstName)
        assertNull("and the channel title is not one either", node(null).card?.name)
    }

    @Test
    fun `the five strings, verbatim`() {
        val wren = node("Wren Alderiss")
        val name = wren.firstName

        assertEquals("Vouch for Wren", VouchCopy.button(name, wren.username))
        assertEquals("Say one thing Wren does.", VouchCopy.ask(name))
        assertEquals(
            "This goes in your comments channel, under your name. Wren can't edit it or take it down.",
            VouchCopy.ownership(name),
        )
        assertEquals("What Wren does", VouchCopy.fieldLabel(name))
        assertEquals("You already vouched Wren for tide clocks.", VouchCopy.already(name, "tide clocks"))
    }

    /**
     * A card with no `name`. Each of these is worded rather than filled in: the app does not know a pronoun
     * for anybody, so it uses the one English hands it for a person it cannot name, and the button — which
     * has nothing to say instead — falls back to the username plainly rather than mid-sentence.
     */
    @Test
    fun `a card with no name gets a sentence, not a username`() {
        val nameless = node(null).firstName

        assertEquals("Vouch for @tgs_wren", VouchCopy.button(nameless, "tgs_wren"))
        assertEquals("Say one thing they do.", VouchCopy.ask(nameless))
        assertEquals(
            "This goes in your comments channel, under your name. They can't edit it or take it down.",
            VouchCopy.ownership(nameless),
        )
        assertEquals("What they do", VouchCopy.fieldLabel(nameless))
        assertEquals("You already vouched them for tide clocks.", VouchCopy.already(nameless, "tide clocks"))
    }
}
