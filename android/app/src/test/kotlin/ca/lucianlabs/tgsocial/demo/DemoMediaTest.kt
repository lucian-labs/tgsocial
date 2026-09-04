package ca.lucianlabs.tgsocial.demo

import ca.lucianlabs.tgsocial.audio.OnePole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * PRODUCT §2.22.1 — "media is generated, never bundled", and generated to be worth analysing: the audio has
 * broadband and tonal content so the spectrogram has structure to draw and the one-pole envelope has a
 * silhouette rather than a rectangle.
 *
 * A test that only asserted "the generator returned some floats" would pass over a flat noise bed, which is
 * exactly the fixture §2.22.1 rules out. These measure the signal.
 */
class DemoMediaTest {

    private val key = "demo_slow_radio/101·1"

    @Test
    fun `the same key is the same world every run`() {
        assertEquals(DemoMedia.seed(key), DemoMedia.seed(key))
        assertNotEquals(DemoMedia.seed(key), DemoMedia.seed("demo_kiln_log/219·1"))
        assertTrue(DemoMedia.pcm(key, 2).contentEquals(DemoMedia.pcm(key, 2)))
    }

    @Test
    fun `a fixture reference is a demo reference and carries its own key`() {
        val ref = DemoMedia.ref(key, 640, 360)
        assertTrue(DemoMedia.isDemo(ref))
        assertEquals(key, DemoMedia.keyOf(ref))
        // §2.22.4 — no TDLib file id. Real ones are positive; nothing can mistake this for one.
        assertTrue(ref.id < 0)
        assertEquals(ref.id, DemoMedia.ref(key, 640, 360).id)
        assertNotEquals(ref.id, DemoMedia.ref("demo_kiln_log/219·1", 8, 8).id)
    }

    @Test
    fun `the sweep is where the spec puts it, and the bed is not`() {
        val rate = DemoMedia.SAMPLE_RATE
        val pcm = DemoMedia.pcm(key, 60, rate)
        fun rms(fromSec: Double, toSec: Double): Double {
            var sum = 0.0
            val a = (fromSec * rate).toInt()
            val b = (toSec * rate).toInt()
            for (i in a until b) sum += pcm[i] * pcm[i].toDouble()
            return sqrt(sum / (b - a))
        }
        val sweep = rms(31.0, 37.0)
        val bed = rms(10.0, 16.0)
        assertTrue("the 220→880 Hz sweep should stand well above the bed: sweep=$sweep bed=$bed", sweep > bed * 3)
        assertTrue("the bed is near −24 dBFS, not silence: $bed", bed > 0.002)
    }

    @Test
    fun `the envelope has a silhouette rather than a rectangle`() {
        val rate = DemoMedia.SAMPLE_RATE
        val pcm = DemoMedia.pcm(key, 60, rate)
        // The same follower §2.11.1 draws the mini waveform with, at its own attack and release. A flat noise
        // bed would come back flat, which is the fixture §2.22.1 rules out.
        val follower = OnePole(OnePole.coefficient(0.005, rate), OnePole.coefficient(0.150, rate))
        val columns = 120
        val per = pcm.size / columns
        val env = FloatArray(columns) { c ->
            var peak = 0f
            for (i in c * per until (c + 1) * per) peak = maxOf(peak, follower.next(kotlin.math.abs(pcm[i])))
            peak
        }
        val min = env.min()
        val max = env.max()
        assertTrue("a flat clip would fail this: min=$min max=$max", max > min * 2.5f)
    }

    @Test
    fun `the voice waveform is a hundred five-bit buckets that are not all the same`() {
        val packed = java.util.Base64.getDecoder().decode(DemoMedia.voiceWaveform("demo_press_run/71·1"))
        assertEquals((100 * 5 + 7) / 8, packed.size)
        val values = ArrayList<Int>()
        var bit = 0
        repeat(100) {
            var v = 0
            repeat(5) {
                val byte = packed[bit / 8].toInt() and 0xFF
                v = (v shl 1) or ((byte shr (7 - bit % 8)) and 1)
                bit++
            }
            values += v
        }
        assertTrue(values.all { it in 0..31 })
        assertTrue("a constant waveform draws a rectangle: ${values.distinct().size} distinct", values.distinct().size > 8)
    }

    @Test
    fun `plate colours are seeded, opaque, and never both the same`() {
        // Across the key space, not one key: the fallback in `plateColors` for "the seed picked the same
        // colour twice" is only reachable by breadth, and a plate that gradients to itself is a flat rectangle.
        for (id in 1..200) {
            val k = "demo_kiln_log/$id·1"
            val (a, b) = DemoMedia.plateColors(k)
            assertNotEquals(k, a, b)
            assertEquals(0xFF, (a ushr 24) and 0xFF)
            assertEquals(0xFF, (b ushr 24) and 0xFF)
            assertEquals(a to b, DemoMedia.plateColors(k))
        }
    }
}
