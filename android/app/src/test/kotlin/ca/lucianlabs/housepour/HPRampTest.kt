package ca.lucianlabs.housepour

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.11.1 — the ramp. Its stops are generated from `design/tokens.json`, so what is asserted here is
 * the *interpolation* and the two clamps, plus the one structural fact the strip depends on: the low end is
 * transparent, so it fades into `bg2` rather than into a colour.
 *
 * Zero hex appears in this file. Every expected value is read back out of the token set, which is the point —
 * a test that restated the colours would pass a ramp that had drifted from the palette.
 */
class HPRampTest {

    private val stops = HPTokens.Ramp.stops

    private fun a(argb: Int) = (argb shr 24) and 0xFF
    private fun r(argb: Int) = (argb shr 16) and 0xFF
    private fun g(argb: Int) = (argb shr 8) and 0xFF
    private fun b(argb: Int) = argb and 0xFF

    @Test
    fun `the ramp is the five stops the tokens declare`() {
        assertEquals(5, stops.size)
        assertEquals(0f, stops.first().at, 0f)
        assertEquals(1f, stops.last().at, 0f)
        // Strictly increasing, or the walk in HPRamp has no defined answer in the overlap.
        for (i in 1 until stops.size) assertTrue(stops[i].at > stops[i - 1].at)
    }

    @Test
    fun `each stop returns itself exactly`() {
        for (stop in stops) assertEquals("stop at ${stop.at}", stop.argb, HPRamp.argb(stop.at))
    }

    @Test
    fun `between two stops the ramp interpolates`() {
        for (i in 1 until stops.size) {
            val lo = stops[i - 1]
            val hi = stops[i]
            val mid = HPRamp.argb((lo.at + hi.at) / 2f)
            for (channel in listOf(::a, ::r, ::g, ::b)) {
                val expected = (channel(lo.argb) + channel(hi.argb)) / 2
                assertEquals("halfway between ${lo.at} and ${hi.at}", expected.toFloat(), channel(mid).toFloat(), 1f)
            }
            // A quarter of the way is a quarter of the way, not the midpoint again.
            val quarter = HPRamp.argb(lo.at + (hi.at - lo.at) * 0.25f)
            val expectedR = r(lo.argb) + (r(hi.argb) - r(lo.argb)) * 0.25f
            assertEquals(expectedR, r(quarter).toFloat(), 1.5f)
        }
    }

    @Test
    fun `both ends clamp`() {
        assertEquals(stops.first().argb, HPRamp.argb(0f))
        assertEquals(stops.first().argb, HPRamp.argb(-0.5f))
        assertEquals(stops.first().argb, HPRamp.argb(Float.NEGATIVE_INFINITY))
        assertEquals(stops.last().argb, HPRamp.argb(1f))
        assertEquals(stops.last().argb, HPRamp.argb(4f))
        assertEquals(stops.last().argb, HPRamp.argb(Float.POSITIVE_INFINITY))
        // NaN is a value a normalised magnitude can take if a divisor ever goes to zero upstream; it must
        // read as the bottom of the ramp, not as a transparent hole in the middle of the strip.
        assertEquals(stops.first().argb, HPRamp.argb(Float.NaN))
    }

    @Test
    fun `the low end is transparent and the high end is not`() {
        assertEquals("the floor of the ramp fades into bg2", 0, a(HPRamp.argb(0f)))
        assertEquals(255, a(HPRamp.argb(1f)))
        // Alpha comes up over the first stretch and is solid from the third stop onward.
        assertTrue(a(HPRamp.argb(0.1f)) in 1..254)
        assertEquals(255, a(HPRamp.argb(0.7f)))
    }

    @Test
    fun `alpha never goes backwards along the ramp`() {
        var previous = -1
        var v = 0f
        while (v <= 1f) {
            val alpha = a(HPRamp.argb(v))
            assertTrue("alpha dipped at $v", alpha >= previous)
            previous = alpha
            v += 0.01f
        }
    }

    @Test
    fun `the ramp tops out at accent-2, over accent`() {
        // §2.11.1 names the two ends of the hot half; read them from the palette rather than restating them.
        assertEquals(HPTokens.Colors.accent2, stops.last().color)
        assertEquals(HPTokens.Colors.accent, stops[stops.size - 2].color)
    }
}
