package ca.lucianlabs.tgsocial.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

/**
 * PRODUCT §2.11.1 — the analysis itself: the rolling AGC ("a quiet recording still fills the strip instead of
 * reading as silence"), the duration ceiling, and the fallback that has to hold when either of those bites.
 */
class SpectrogramTest {

    private val rate = SpectrogramSpec.RATE

    private fun sine(hz: Float, amplitude: Float, seconds: Double): FloatArray =
        FloatArray((rate * seconds).toInt()) { i -> (amplitude * sin(2.0 * PI * hz * i / rate)).toFloat() }

    private fun peakRow(grid: FloatArray, columns: Int, rows: Int): Int {
        var best = 0
        var bestValue = -1f
        for (r in 0 until rows) {
            var sum = 0f
            for (c in 0 until columns) sum += grid[c * rows + r]
            if (sum > bestValue) {
                bestValue = sum
                best = r
            }
        }
        return best
    }

    // ── AGC ────────────────────────────────────────────────────────────────

    @Test
    fun `a quiet clip still spans the strip`() {
        val columns = 32
        val rows = 64
        // −60 dBFS: audible, and nowhere near full scale. Against an absolute dBFS mapping this would paint
        // the bottom quarter of the range and read as silence, which is the failure §2.11.1 names.
        val quiet = Spectrogram.spectrum(sine(1_000f, 0.001f, 2.0), rate, columns, rows)
        assertNotNull(quiet)
        assertTrue("a quiet clip must still reach the top of the range", quiet!!.max() > 0.95f)

        val loud = Spectrogram.spectrum(sine(1_000f, 0.9f, 2.0), rate, columns, rows)!!
        // The same tone 59 dB louder normalises to the same place: the AGC is rolling, not absolute.
        assertEquals(loud.max(), quiet.max(), 0.02f)
        assertEquals(
            "and lands on the same row",
            peakRow(loud, columns, rows).toFloat(),
            peakRow(quiet, columns, rows).toFloat(),
            1f,
        )
    }

    @Test
    fun `the tone lands on the row the axis puts it on`() {
        val columns = 32
        val rows = 64
        val grid = Spectrogram.spectrum(sine(1_000f, 0.5f, 2.0), rate, columns, rows)!!
        val axis = LogAxis(SpectrogramSpec.F_MIN, SpectrogramSpec.effectiveFMax(rate), rows)
        assertEquals(
            "1 kHz belongs on row ${axis.row(1_000f)}",
            axis.row(1_000f).toFloat(),
            peakRow(grid, columns, rows).toFloat(),
            1f,
        )
    }

    @Test
    fun `digital silence stays dark rather than being amplified into a wall`() {
        val grid = Spectrogram.spectrum(FloatArray(rate * 2), rate, 16, 32)!!
        assertEquals(0f, grid.max(), 1e-6f)
    }

    @Test
    fun `every cell is inside the range the ramp is defined over`() {
        val grid = Spectrogram.spectrum(sine(440f, 0.4f, 1.5), rate, 24, 48)!!
        assertTrue(grid.all { it in 0f..1f })
    }

    // ── the envelope ───────────────────────────────────────────────────────

    @Test
    fun `the envelope spans the strip for a quiet take too, and follows the shape`() {
        val columns = 64
        // A take that is loud in its middle third and near-silent either side.
        val pcm = FloatArray(rate * 3) { i ->
            val amplitude = if (i in rate until rate * 2) 0.004f else 0.00002f
            (amplitude * sin(2.0 * PI * 300 * i / rate)).toFloat()
        }
        val envelope = Spectrogram.envelope(pcm, rate, columns)
        assertEquals(columns, envelope.size)
        assertTrue("the loud third must reach the top", envelope.max() > 0.95f)
        assertTrue("the quiet thirds must not", envelope[2] < 0.2f && envelope[columns - 3] < 0.2f)
        assertTrue("the middle is the loud part", envelope[columns / 2] > 0.9f)
        assertTrue(envelope.all { it in 0f..1f })
    }

    @Test
    fun `silence stays flat instead of being normalised into noise`() {
        val envelope = Spectrogram.envelope(FloatArray(rate) { 1e-6f }, rate, 32)
        assertTrue("silence must read as silence", envelope.max() < 0.01f)
    }

    // ── bounds and degradation ─────────────────────────────────────────────

    @Test
    fun `the duration cap is ten minutes`() {
        assertTrue(SpectrogramSpec.analysable(1))
        assertTrue(SpectrogramSpec.analysable(30))
        assertTrue(SpectrogramSpec.analysable(SpectrogramSpec.MAX_DURATION_SECONDS))
        assertTrue("past the ceiling nothing is analysed", !SpectrogramSpec.analysable(601))
        assertTrue("nor is a clip of no length", !SpectrogramSpec.analysable(0))
        assertTrue("nor a negative one", !SpectrogramSpec.analysable(-5))
    }

    @Test
    fun `a clip shorter than one window falls back to the silhouette instead of failing`() {
        val short = sine(440f, 0.5f, 0.05) // 800 samples, under the 2048-point window
        assertNull("no spectrum is honest here", Spectrogram.spectrum(short, rate, 32, 64))
        val data = Spectrogram.analyse(short, rate, 32, 64)
        assertNull(data.spectrum)
        assertEquals("but the silhouette still draws", 32, data.envelope.size)
        assertTrue(data.envelope.max() > 0.5f)
    }

    @Test
    fun `nonsense geometry and empty input degrade to nothing rather than throwing`() {
        assertNull(Spectrogram.spectrum(FloatArray(0), rate, 32, 64))
        assertNull(Spectrogram.spectrum(sine(440f, 0.5f, 1.0), rate, 0, 64))
        assertNull(Spectrogram.spectrum(sine(440f, 0.5f, 1.0), rate, 32, 0))
        assertEquals(0, Spectrogram.envelope(FloatArray(0), rate, 32).size)
        assertEquals(0, Spectrogram.envelope(sine(440f, 0.5f, 1.0), rate, 0).size)
    }

    @Test
    fun `a clip with fewer frames than columns fills the strip rather than striping it`() {
        // 0.4 s at a 64 ms hop is ~6 frames across 64 columns; every column must still carry something.
        val grid = Spectrogram.spectrum(sine(1_000f, 0.5f, 0.4), rate, 64, 32)!!
        for (c in 0 until 64) {
            val column = (0 until 32).map { grid[c * 32 + it] }
            assertTrue("column $c is blank", column.max() > 0f)
        }
    }

    /**
     * The gap fill has a direction, and it is the one time runs in. §2.11.1's whole claim for the strip is
     * "you can see where the loud part is before you drag to it", which a backward hold inverts: it paints
     * each analysed column across the gap to its LEFT, so the burst draws ahead of where it happens and the
     * drag lands past it.
     */
    @Test
    fun `the gap fill holds a loud moment forward, never backward`() {
        val fftSize = SpectrogramSpec.FFT_SIZE
        val hop = SpectrogramSpec.HOP
        val columns = 64
        val rows = 32
        val frames = 8
        val mono = FloatArray(fftSize + (frames - 1) * hop)
        // Silence except for a burst over samples [4·hop, 6·hop) — the frames at hops 3, 4 and 5 see it, and
        // nothing before hop 3 does. Their columns are 24, 32 and 40.
        for (i in 4 * hop until 6 * hop) mono[i] = (0.9 * sin(2.0 * PI * 1_000 * i / rate)).toFloat()

        val grid = Spectrogram.spectrum(mono, rate, columns, rows, fftSize, hop)!!
        fun brightness(c: Int) = (0 until rows).maxOf { grid[c * rows + it] }
        val map = (0 until columns).joinToString("") { if (brightness(it) > 0.5f) "#" else "." }

        assertTrue("the burst's own column must be lit: $map", brightness(24) > 0.5f)
        assertTrue("the burst must hold forward across the gap after it: $map", brightness(46) > 0.5f)
        assertTrue("nothing may be painted before the burst's own column: $map", brightness(23) < 0.01f)
        assertTrue("nor anywhere earlier: $map", brightness(10) < 0.01f)
    }

    // ── geometry and the cache key ─────────────────────────────────────────

    @Test
    fun `geometry is quantised so the same clip keys the same in the feed and in a thread`() {
        // The feed's column and the thread's differ by a few pixels; that must not be a second analysis.
        assertEquals(SpectrogramSpec.columnsFor(481), SpectrogramSpec.columnsFor(500))
        assertEquals(
            SpectrogramSpec.cacheKey("abc", SpectrogramSpec.columnsFor(481), SpectrogramSpec.rowsFor(132)),
            SpectrogramSpec.cacheKey("abc", SpectrogramSpec.columnsFor(500), SpectrogramSpec.rowsFor(132)),
        )
        // But a different file, or a genuinely different size class, is a different strip.
        assertTrue(
            SpectrogramSpec.cacheKey("abc", 480, 128) != SpectrogramSpec.cacheKey("def", 480, 128),
        )
        assertTrue(
            SpectrogramSpec.cacheKey("abc", 480, 128) != SpectrogramSpec.cacheKey("abc", 256, 128),
        )
    }

    @Test
    fun `column and row counts stay inside the caps whatever the screen`() {
        assertEquals(SpectrogramSpec.MAX_COLUMNS, SpectrogramSpec.columnsFor(4_000))
        assertEquals(SpectrogramSpec.MAX_ROWS, SpectrogramSpec.rowsFor(4_000))
        assertTrue(SpectrogramSpec.columnsFor(1) >= SpectrogramSpec.COLUMN_QUANTUM)
        assertTrue(SpectrogramSpec.rowsFor(1) >= SpectrogramSpec.ROW_QUANTUM)
        assertEquals(SpectrogramSpec.MAX_DURATION_SECONDS * SpectrogramSpec.RATE, SpectrogramSpec.MAX_SAMPLES)
    }

    // ── decimation ─────────────────────────────────────────────────────────

    @Test
    fun `decimation averages rather than picking, so nothing aliases down the strip`() {
        val decimator = Decimator(48_000, 16_000, 16_000)
        // 24 kHz — the worst case, right at the source's Nyquist. Picking every third sample would fold it
        // straight into the strip's low rows as content that is not in the recording; a box average kills it.
        repeat(48_000) { i -> decimator.push(if (i % 2 == 0) 1f else -1f) }
        val out = decimator.result()
        assertEquals(16_000, out.size)
        assertTrue("aliased energy survived the decimation", out.all { abs(it) < 0.4f })
    }

    @Test
    fun `decimation holds the rate and the level`() {
        val decimator = Decimator(44_100, 16_000, 32_000)
        repeat(44_100) { decimator.push(0.5f) }
        val out = decimator.result()
        assertEquals(16_000f, out.size.toFloat(), 2f)
        assertTrue(out.all { abs(it - 0.5f) < 1e-5f })
    }

    @Test
    fun `decimation stops at its capacity, which is the duration cap in samples`() {
        val decimator = Decimator(48_000, 16_000, 100)
        repeat(48_000) { decimator.push(1f) }
        assertTrue(decimator.full)
        assertEquals(100, decimator.result().size)
    }

    /**
     * The capacity is a ceiling, not a reservation. Callers pass `MAX_SAMPLES` (36.6 MB of floats) as the cap,
     * so a decimator that allocated it up front charged every three-second voice note the ten-minute buffer.
     */
    @Test
    fun `a decimator sized for ten minutes does not allocate ten minutes for a three-second clip`() {
        val before = liveBytes()
        val decimator = Decimator(48_000, rate, SpectrogramSpec.MAX_SAMPLES)
        repeat(3 * 48_000) { decimator.push(0.5f) }
        // Measured while the decimator is still LIVE — read it only afterwards, or the JVM is free to
        // collect the very buffer under test before the sample is taken and the measurement means nothing.
        val grown = liveBytes() - before
        val out = decimator.result()

        assertEquals("three seconds at the strip's rate", (3 * rate).toFloat(), out.size.toFloat(), 4f)
        assertTrue("the output must still be the real signal", out.all { abs(it - 0.5f) < 1e-5f })
        // 36.6 MB is what the eager form cost; the clip's own signal is 0.19 MB. The threshold is loose on
        // purpose — this measures a heap, not an allocator — but an order of magnitude under the cap still
        // only passes if the buffer followed the clip.
        assertTrue(
            "a 3 s clip retained ${grown / 1024} KB against a ${SpectrogramSpec.MAX_SAMPLES * 4 / 1024} KB cap",
            grown < 4L * 1024 * 1024,
        )
    }

    @Test
    fun `the decode ceiling follows the clip and is still capped at ten minutes`() {
        assertEquals("a 3 s clip decodes 5 s of headroom, not 600", 5 * rate, SpectrogramSpec.samplesFor(3))
        assertEquals(SpectrogramSpec.MAX_SAMPLES, SpectrogramSpec.samplesFor(SpectrogramSpec.MAX_DURATION_SECONDS))
        assertEquals("the cap still binds a lying duration", SpectrogramSpec.MAX_SAMPLES, SpectrogramSpec.samplesFor(100_000))
        assertEquals(0, SpectrogramSpec.samplesFor(0))
        assertEquals(0, SpectrogramSpec.samplesFor(-5))
    }

    /** Retained bytes, after enough persuasion for the number to mean something. */
    private fun liveBytes(): Long {
        val runtime = Runtime.getRuntime()
        repeat(4) {
            runtime.gc()
            Thread.sleep(20)
        }
        return runtime.totalMemory() - runtime.freeMemory()
    }
}
