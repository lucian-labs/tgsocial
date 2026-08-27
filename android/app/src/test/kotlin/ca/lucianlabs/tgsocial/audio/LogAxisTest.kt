package ca.lucianlabs.tgsocial.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * PRODUCT §2.11.1 — frequency runs bottom to top on a **log** axis, "because that is how pitch is spaced".
 * The assertions are about where a known frequency lands, which is the only way a mapping bug shows up: a
 * linear axis is also monotonic, also spans the range, and looks entirely plausible until you notice every
 * voice sits in the bottom two rows.
 */
class LogAxisTest {

    private val rows = 64
    private val axis = LogAxis(SpectrogramSpec.F_MIN, SpectrogramSpec.F_MAX, rows)

    @Test
    fun `the ends of the range land on the ends of the strip`() {
        assertEquals(0, axis.row(20f))
        assertEquals(rows - 1, axis.row(20_000f))
    }

    @Test
    fun `the geometric centre of the range lands on the middle row`() {
        // sqrt(20 * 20000) = 632.46 Hz is exactly half way along a log axis, and nowhere near half way along
        // a linear one (that would be 10 010 Hz) — so this single assertion is the one that fails loudest if
        // the mapping ever goes linear.
        val middle = sqrt(20.0 * 20_000.0).toFloat()
        assertEquals(rows / 2, axis.row(middle))
    }

    @Test
    fun `each row's own centre frequency lands back on that row`() {
        for (r in 0 until rows) {
            assertEquals("row $r (centre ${axis.centre(r)} Hz)", r, axis.row(axis.centre(r)))
        }
    }

    @Test
    fun `rows are a decade apart where a decade should be`() {
        // 20 -> 20 000 is three decades over 64 rows, so a decade is 64/3 rows wide, everywhere on the axis.
        val perDecade = rows / 3
        assertEquals(perDecade, axis.row(200f) - axis.row(20f))
        assertEquals(perDecade, axis.row(2_000f) - axis.row(200f))
        // The top decade lands on the clamped last row and measures the same 21.
        assertEquals(perDecade, axis.row(20_000f) - axis.row(2_000f))
    }

    @Test
    fun `both ends clamp instead of running off the strip`() {
        assertEquals(0, axis.row(1f))
        assertEquals(0, axis.row(0f))
        assertEquals(rows - 1, axis.row(48_000f))
        assertEquals(rows - 1, axis.row(Float.MAX_VALUE))
    }

    @Test
    fun `the axis stops at Nyquist, because the decode threw the rest away`() {
        assertEquals(8_000f, SpectrogramSpec.effectiveFMax(16_000), 0f)
        assertEquals(4_000f, SpectrogramSpec.effectiveFMax(8_000), 0f)
        // A hypothetical full-rate decode keeps the nominal ceiling rather than inventing rows above it.
        assertEquals(20_000f, SpectrogramSpec.effectiveFMax(48_000), 0f)
    }

    @Test
    fun `a row's bin range brackets its own centre frequency`() {
        val fft = SpectrogramSpec.FFT_SIZE
        val rate = SpectrogramSpec.RATE
        val nyquistAxis = LogAxis(SpectrogramSpec.F_MIN, SpectrogramSpec.effectiveFMax(rate), rows)
        val binHz = rate.toFloat() / fft
        for (r in 0 until rows) {
            val range = nyquistAxis.bins(r, fft, rate)
            assertTrue("row $r has an empty bin range", !range.isEmpty())
            // Every row, including the ones whose band is narrower than a single bin: the row a frequency
            // maps to must be the row that reads that frequency's bin, or the picture is of another signal.
            val centreBin = (nyquistAxis.centre(r) / binHz).toInt()
            assertTrue("row $r: centre bin $centreBin outside $range", centreBin in range)
        }
    }
}
