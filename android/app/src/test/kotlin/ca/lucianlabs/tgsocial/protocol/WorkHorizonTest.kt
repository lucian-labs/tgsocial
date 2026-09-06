package ca.lucianlabs.tgsocial.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.23 — the `FOR` tabs, seeded from the card rather than defaulted.
 *
 * The Edit Card modal writes `work.open` from `OPEN TO` and `FOR` on **every** save, whatever the save was
 * for. So a modal that opens on `30 days` over a card that says `until <today+90>` is not merely showing the
 * wrong tab: it reports a horizon the card does not have, contradicts the intent pill on the profile beside
 * it, and then makes itself true the moment the reader edits their bio — shortening published intent
 * (PROTOCOL §10.3) with no refusal and no note. These assert the seed, and the property that matters more
 * than any single value: opening and saving without touching the tabs never moves the end date closer.
 */
class WorkHorizonTest {

    private val today = "2026-09-06"

    private fun open(days: Int) = WorkOpen("contract", WorkFormat.horizonDate(days, today))

    @Test
    fun `the seed is the shortest horizon that still covers what is left`() {
        assertEquals(30, WorkFormat.horizonFor(open(30), today))
        assertEquals(30, WorkFormat.horizonFor(open(20), today))
        assertEquals(60, WorkFormat.horizonFor(open(45), today))
        assertEquals(60, WorkFormat.horizonFor(open(60), today))
        assertEquals(90, WorkFormat.horizonFor(open(61), today))
        assertEquals(90, WorkFormat.horizonFor(open(90), today))
    }

    /** `Nothing` selected, or a card with no readable intent: the writer starts at the first horizon. */
    @Test
    fun `no intent opens on the first horizon`() {
        assertEquals(30, WorkFormat.horizonFor(null, today))
        assertEquals(30, WorkFormat.horizonFor(WorkOpen("contract", "2026-02-30"), today))
    }

    /**
     * Longer than the writer offers — a card written by a client with other horizons, or by hand — takes the
     * longest one on offer. It shortens, and that is the honest floor: the tabs are the whole vocabulary the
     * modal has, so it cannot show a horizon it cannot also write.
     */
    @Test
    fun `an intent longer than the tabs offer takes the longest tab`() {
        assertEquals(90, WorkFormat.horizonFor(open(120), today))
        assertEquals(90, WorkFormat.horizonFor(open(WorkFormat.OPEN_HORIZON_DAYS.toInt()), today))
    }

    /**
     * The defect, as arithmetic: for every horizon the writer offers, opening the modal over that card and
     * saving it back untouched leaves the end date where it was. With the seed defaulted to 30 this fails at
     * 60 and 90 — two months of somebody's published intent, deleted by an edit to their bio.
     */
    @Test
    fun `opening and saving untouched never moves the end date closer`() {
        for (days in WorkFormat.HORIZONS) {
            val card = open(days)
            val reopened = WorkFormat.horizonDate(WorkFormat.horizonFor(card, today), today)
            assertEquals("a $days-day intent survives the round trip", card.until, reopened)
            assertTrue(
                "and is still a statement about now",
                WorkFormat.openIsCurrent(WorkOpen(card.intent, reopened), today),
            )
        }
    }
}
