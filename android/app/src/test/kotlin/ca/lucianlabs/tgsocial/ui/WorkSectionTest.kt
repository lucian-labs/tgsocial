package ca.lucianlabs.tgsocial.ui

import ca.lucianlabs.tgsocial.model.Vouch
import ca.lucianlabs.tgsocial.protocol.WorkCard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.23 — when the `WORK` section of a profile exists, and what is under `VOUCHED, NOT CLAIMED`.
 *
 * The section is absent when there is nothing in it, and that is two conditions rather than one. A vouch is
 * written in the **voucher's** channel and names its subject (PROTOCOL §10.4), so it can name a node that has
 * claimed nothing at all — and gating the section on the subject's own `work.` keys makes that vouch
 * unreachable: parsed, indexed, counted in nothing, drawn nowhere. It is invisible to the reader, invisible
 * to the subject on their own profile — the one person the heading exists to tell — and there is no
 * `( Vouch for … )` control anywhere for the first person who wants to write one about them.
 */
class WorkSectionTest {

    private fun vouch(tag: String, subject: String = "tgs_x", voucher: String = "tgs_bob") = Vouch(
        chatId = -100,
        messageId = 1L shl 20,
        date = 1_700_000_000,
        channelUsername = "${voucher}_r",
        voucherUsername = voucher,
        voucherName = "Bob Vance",
        subjectUsername = subject,
        tag = tag,
        body = "",
    )

    @Test
    fun `a node with no work keys and no vouches has no section`() {
        assertFalse(WorkSection.present(null, emptyList()))
    }

    /** The case the gate got wrong: nothing claimed, but somebody said something. */
    @Test
    fun `a node that claimed nothing still has a section once somebody vouches`() {
        val vouches = listOf(vouch("kiln repair"))

        assertTrue(WorkSection.present(null, vouches))
        assertEquals(
            "and the tag is under VOUCHED, NOT CLAIMED, because there is no claim to file it under",
            listOf("kiln repair"),
            WorkSection.unclaimed(null, vouches),
        )
    }

    @Test
    fun `a claimed tag is not unclaimed, whatever case it was written in`() {
        val work = WorkCard(does = listOf("live sound", "swift"))
        val vouches = listOf(vouch("Live Sound"), vouch("front of house"))

        assertTrue(WorkSection.present(work, emptyList()))
        assertEquals(listOf("front of house"), WorkSection.unclaimed(work, vouches))
    }

    /** Two people naming the same capability is one heading row, not two (§2.23's rows are tags). */
    @Test
    fun `the same tag from two vouchers is one row`() {
        val vouches = listOf(vouch("bad solder", voucher = "tgs_bob"), vouch("bad solder", voucher = "tgs_juno"))

        assertEquals(listOf("bad solder"), WorkSection.unclaimed(null, vouches))
    }
}
