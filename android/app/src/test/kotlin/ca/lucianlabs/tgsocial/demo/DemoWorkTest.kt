package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.protocol.CardFormat
import ca.lucianlabs.tgsocial.protocol.CardParse
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.protocol.WorkFormat
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.26 — the work fixtures, asserted against the figures §2.26 puts on the screen.
 *
 * Each of these is something a reviewer reads off the demo without signing in, so a fixture edited without
 * its table falls out here rather than in review. The last one is the load-bearing test: the self-vouch is in
 * the fixtures precisely so that a client which forgot PROTOCOL §10.4's rule fails visibly.
 */
class DemoWorkTest {

    private val start = 1_800_000_000L

    @Test
    fun `six of the fifteen carry work, and the reader carries none`() {
        val withWork = DemoWorld.nodes.filter { it.work != null }.map { it.username }
        assertEquals(
            listOf("tgs_demo_wren", "tgs_demo_mox", "tgs_demo_juno", "tgs_demo_pell", "tgs_demo_hask", "tgs_demo_ilka"),
            withWork,
        )
        // §2.26 — the first thing the demo shows about work is the empty state on your own card.
        assertNull(DemoWorld.reader.work)
        assertNull(DemoWorld.snapshot(DemoWorld.READER, start)?.card?.work)
    }

    /**
     * §2.26's `+N d` is N days after the demo is **entered**, computed at entry. A hardcoded date rots into
     * an expired intent and then §2.24's `OPEN NOW` is permanently empty, which is a fixture that tests
     * nothing — so this asserts the derivation, not a literal.
     */
    @Test
    fun `every fixture intent is current on the day the demo is entered`() {
        val today = java.time.LocalDate.ofEpochDay(start / 86_400L).toString()
        for (node in DemoWorld.nodes) {
            val open = DemoWorld.workCard(node, start)?.open ?: continue
            assertTrue("${node.username} is not current on $today", WorkFormat.openIsCurrent(open, today))
            val days = WorkFormat.daysLeft(open, today)
            assertEquals(node.username, node.work?.openDays?.toLong(), days)
        }
    }

    /** §2.26 — `OPEN NOW` paints, in order: Hask (+8, a +1 node), Juno (+20), Wren (+45), Pell (+60). */
    @Test
    fun `OPEN NOW is end date ascending, and Hask is the plus-one row`() {
        val today = java.time.LocalDate.ofEpochDay(start / 86_400L).toString()
        val reachable = (listOf(DemoWorld.READER) + DemoWorld.reader.follows + DemoWorld.nearby().map { it.username }).distinct()
        val open = reachable
            .mapNotNull { u -> DemoWorld.node(u)?.let { n -> DemoWorld.workCard(n, start)?.open?.let { n.username to it } } }
            .filter { WorkFormat.openIsCurrent(it.second, today) }
            .sortedWith(compareBy({ it.second.until }, { Username.key(it.first) }))
        assertEquals(
            listOf("tgs_demo_hask", "tgs_demo_juno", "tgs_demo_wren", "tgs_demo_pell"),
            open.map { it.first },
        )
        assertEquals(listOf("collab", "work", "contract", "hiring"), open.map { it.second.intent })
        // §2.24 buys the extra hop for intent only, and Hask is the row that exercises it.
        assertTrue(DemoWorld.isPlusOne("tgs_demo_hask"))
    }

    /** PROTOCOL §10.2 — a fixture's `work.feeds` entry is a channel the same card already claims in `feeds:`. */
    @Test
    fun `every work feed is one the node already claims`() {
        for (node in DemoWorld.nodes) {
            val work = DemoWorld.workCard(node, start) ?: continue
            for (feed in work.feeds) {
                assertTrue("${node.username} marks @$feed, which is not on its card", node.feeds.any { Username.same(it, feed) })
            }
        }
    }

    /**
     * PROTOCOL §10 — the fixture cards are additive in the same way real ones are: serialising one and
     * reading it back with §2's own parser yields the card §2 would have read before §10 existed, and the
     * §10 pass over the same bytes recovers the work card.
     */
    @Test
    fun `a fixture card round-trips through both passes`() {
        val wren = requireNotNull(DemoWorld.snapshot("tgs_demo_wren", start)?.card)
        val text = CardFormat.serialise(wren)
        assertTrue(text.startsWith("tgsocial v1\n"))
        assertTrue(text.contains("\nwork.role: Tide clocks, built one at a time"))
        assertTrue(text.contains("\nwork.does: electronics, tide clocks, bad solder"))
        assertTrue(text.contains("\nwork.feeds: @demo_wren_bench"))
        // A §2-only reader sees the card it has always seen — same bytes for every line it knows.
        val bare = (CardFormat.parse(text) as CardParse.Parsed).card
        assertNull("§2's parser must not know §10", bare.work)
        assertEquals(wren.copy(work = null), bare)
        assertEquals(wren.work, WorkFormat.parse(text))
    }

    /**
     * PRODUCT §2.26's fifth fixture. Wren vouches for Wren, in Wren's own comments channel, and it MUST NOT
     * render anywhere (PROTOCOL §10.4) — the format is unforgeable only because the one channel a person can
     * write is the one that cannot speak about them. Nothing here filters it by hand: the fixture builder
     * runs the same `keeps` rule the reader does, so removing that rule fails this test.
     */
    @Test
    fun `the self-vouch never reaches the index`() {
        val index = DemoWorld.vouchIndex(start)
        assertEquals(4, index.values.sumOf { it.size })
        for ((subject, list) in index) {
            for (v in list) {
                assertFalse(
                    "a self-vouch reached the index: @${v.voucherUsername} about @$subject",
                    Username.same(v.voucherUsername, v.subjectUsername),
                )
            }
        }
        val aboutWren = index[Username.key("tgs_demo_wren")].orEmpty()
        assertEquals(listOf("tgs_demo_mox", "tgs_demo_juno"), aboutWren.map { it.voucherUsername })
        assertEquals(listOf("tide clocks", "bad solder"), aboutWren.map { it.tag })
    }

    /**
     * §2.26 — `kiln repair` is the `VOUCHED, NOT CLAIMED` row: Pell says Juno does it and Juno's own card
     * does not. That is the case PROTOCOL §10.4 exists for — the subject cannot edit somebody else's
     * sentence by editing their own card — and it is how a person finds out what they are known for.
     */
    @Test
    fun `kiln repair is vouched and not claimed`() {
        val juno = requireNotNull(DemoWorld.workCard(requireNotNull(DemoWorld.node("tgs_demo_juno")), start))
        val vouches = DemoWorld.vouchIndex(start)[Username.key("tgs_demo_juno")].orEmpty()
        assertNotNull(vouches.firstOrNull { it.tag == "kiln repair" })
        assertFalse("Juno's card claims kiln repair, so the section has nothing to show", juno.does.contains("kiln repair"))
        // And `glaze chemistry` is the other half: a claimed tag that does carry a vouch.
        assertTrue(juno.does.contains("glaze chemistry"))
        assertNotNull(vouches.firstOrNull { it.tag == "glaze chemistry" })
        // …while `ceramics` is a claimed tag with none, which renders as a row that is not a control (§2.23).
        assertTrue(juno.does.contains("ceramics"))
        assertTrue(vouches.none { it.tag == "ceramics" })
    }
}
