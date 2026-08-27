package ca.lucianlabs.tgsocial.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

/**
 * The hand-written radix-2 transform. It replaces a dependency, so it gets the assertions a dependency's own
 * test suite would have given us: a tone lands on its bin, at the amplitude the window's coherent gain says
 * it should, and silence stays silent.
 */
class FftTest {

    private val size = 1024
    private val rate = 16_000

    private fun tone(bin: Int, amplitude: Float = 1f) =
        FloatArray(size) { i -> (amplitude * sin(2.0 * PI * bin * i / size)).toFloat() }

    @Test
    fun `a tone lands on its own bin`() {
        val fft = Fft(size)
        val out = FloatArray(fft.bins)
        for (bin in intArrayOf(4, 64, 200, 501)) {
            fft.magnitudes(tone(bin), 0, out)
            val peak = out.indices.maxByOrNull { out[it] }
            assertEquals("tone at bin $bin", bin, peak)
        }
    }

    @Test
    fun `bin index and frequency agree`() {
        val fft = Fft(size)
        val out = FloatArray(fft.bins)
        // 1 kHz at 16 kHz over 1024 points is bin 64 exactly.
        val bin = (1_000f / (rate.toFloat() / size)).toInt()
        assertEquals(64, bin)
        fft.magnitudes(tone(bin), 0, out)
        assertEquals(bin, out.indices.maxByOrNull { out[it] })
    }

    @Test
    fun `a full-scale sine reads at the Hann window's coherent gain`() {
        val fft = Fft(size)
        val out = FloatArray(fft.bins)
        fft.magnitudes(tone(64), 0, out)
        // 2|X[k]|/N with a Hann window (coherent gain 0.5) puts a unit sine at 0.5.
        assertEquals(0.5f, out[64], 0.02f)
        // And half the amplitude reads half as loud — the mapping is linear before the dB stage.
        fft.magnitudes(tone(64, 0.5f), 0, out)
        assertEquals(0.25f, out[64], 0.02f)
    }

    @Test
    fun `silence stays silent, and reads past the end are zero-filled`() {
        val fft = Fft(size)
        val out = FloatArray(fft.bins)
        fft.magnitudes(FloatArray(size), 0, out)
        assertTrue(out.all { it < 1e-6f })
        // The last hop of a clip reads past the end; that must be zeros, not a crash or garbage.
        fft.magnitudes(FloatArray(10) { 1f }, 0, out)
        assertTrue(out.all { it.isFinite() })
    }

    @Test
    fun `the size must be a power of two`() {
        var threw = false
        try {
            Fft(1000)
        } catch (e: IllegalArgumentException) {
            threw = true
        }
        assertTrue(threw)
    }
}
