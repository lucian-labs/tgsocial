package ca.lucianlabs.tgsocial.demo

import androidx.compose.ui.graphics.toArgb
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.FileRef
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.exp
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/**
 * PRODUCT §2.22.1 — "media is generated, never bundled". Every image, clip and waveform is produced in-process
 * from the item's key as a seed, so the world is the same everywhere without shipping a byte of anyone's
 * content, and no fixture carries a photograph of a person.
 *
 * This half is the part with no Android framework in it: the file references, the seeds, the synthesised PCM,
 * the packed waveform, and the House Pour tokens a plate is painted from. [DemoFiles] is the half that turns
 * those into bytes on disk.
 */
object DemoMedia {

    /** Every demo file reference carries this prefix in its `uniqueId`; it is what the repos branch on. */
    const val PREFIX = "demo:"

    private val ids = HashMap<String, Int>()
    private var nextId = -1

    /**
     * A [FileRef] for one fixture item. TDLib file ids are positive, so the demo's are negative and unique:
     * nothing that takes one can mistake it for a real file, and `MediaRepo` keys its download state by id.
     */
    @Synchronized
    fun ref(key: String, width: Int, height: Int): FileRef {
        val id = ids.getOrPut(key) { nextId-- }
        return FileRef(id = id, uniqueId = PREFIX + key, width = width, height = height, size = 0L)
    }

    fun isDemo(ref: FileRef?): Boolean = ref?.uniqueId?.startsWith(PREFIX) == true

    fun isDemo(uniqueId: String?): Boolean = uniqueId?.startsWith(PREFIX) == true

    /** The fixture key a generated plate prints in its corner — `demo_kiln_log/224·1` (§2.22 item 3). */
    fun keyOf(ref: FileRef): String = ref.uniqueId.removePrefix(PREFIX)

    /** A stable 64-bit seed for a key. Same key, same world, on every run and every platform. */
    fun seed(key: String): Long {
        var h = -3750763034362895579L // FNV-1a 64 offset basis
        for (ch in key) {
            h = h xor ch.code.toLong()
            h *= 1099511628211L
        }
        return h
    }

    // ------------------------------------------------------------------ audio (PRODUCT §2.11.1)

    const val SAMPLE_RATE = 24_000

    /** 1 / the RMS of the mean of eight uniform(−1, 1) draws — the Voss generator's own level. */
    private const val PINK_TO_UNIT = 4.9f

    /**
     * §2.22.1 — a pink-noise bed near −24 dBFS, a 220 Hz → 880 Hz log sweep from 0:30 to 0:38, and two 40 ms
     * clicks a minute. Broadband plus tonal, so the spectrogram has structure to draw and the one-pole envelope
     * has a silhouette rather than a rectangle; a flat noise bed would prove the analyser ran and nothing else.
     *
     * Shorter clips (the voice note) get the sweep scaled into their own length rather than losing it.
     */
    fun pcm(key: String, durationSeconds: Int, rate: Int = SAMPLE_RATE): FloatArray {
        val n = durationSeconds * rate
        val out = FloatArray(n)
        val rnd = Random(seed(key))
        // A seeded contour at roughly syllable rate, so the bed is a take rather than a test tone: without it
        // the one-pole envelope is a rectangle and the voice note's waveform is a solid bar (§2.22.1).
        // Two steps a second: slower than syllables, and deliberately slower than one waveform bucket (a 47 s
        // voice note is 100 buckets, so ~0.5 s each). A faster contour averages out inside the bucket and the
        // waveform comes back flat — which is the fixture §2.22.1 rules out.
        val contourRate = 2
        val contour = FloatArray(durationSeconds * contourRate + 2) { 0.12f + rnd.nextFloat() * rnd.nextFloat() * 0.88f }
        // Voss-McCartney pink noise: cheap, and its 1/f tilt is what makes a spectrogram look like a room
        // rather than like a test signal.
        val rows = FloatArray(8)
        var running = 0f
        var counter = 0
        val bed = 0.063f // ≈ −24 dBFS
        val sweepStart = if (durationSeconds > 40) 30.0 else durationSeconds * 0.35
        val sweepEnd = if (durationSeconds > 40) 38.0 else durationSeconds * 0.55
        var phase = 0.0
        for (i in 0 until n) {
            counter++
            var mask = counter
            var row = 0
            while (row < rows.size && mask and 1 == 0) { mask = mask shr 1; row++ }
            if (row < rows.size) {
                running -= rows[row]
                rows[row] = rnd.nextFloat() * 2f - 1f
                running += rows[row]
            }
            val at = i.toFloat() * contourRate / rate
            val c0 = contour[at.toInt()]
            val c1 = contour[at.toInt() + 1]
            val gain = c0 + (c1 - c0) * (at - at.toInt())
            // `running / rows.size` is the mean of eight uniforms and lands near 0.204 RMS, so it is brought to
            // unit RMS before the bed level is applied — otherwise "−24 dBFS" is really −40 and the sweep sits
            // sixteen times above the bed instead of two and a half, which flattens the waveform.
            var s = (running / rows.size) * PINK_TO_UNIT * bed * (0.35f + gain)

            val t = i.toDouble() / rate
            if (t >= sweepStart && t < sweepEnd) {
                val u = (t - sweepStart) / (sweepEnd - sweepStart)
                val f = 220.0 * exp(u * ln(880.0 / 220.0))
                phase += 2 * PI * f / rate
                s += (0.22 * sin(phase)).toFloat()
            }
            // Two clicks a minute, 40 ms each — transients the envelope can actually show.
            val inMinute = t % 30.0
            if (inMinute < 0.04) s += (0.5 * (1.0 - inMinute / 0.04) * sin(2 * PI * 1400 * t)).toFloat()
            out[i] = s.coerceIn(-1f, 1f)
        }
        return out
    }

    /**
     * PRODUCT §2.11.2 — Telegram's voice waveform: 5-bit amplitudes, MSB-first, base64. Shipping it in the
     * fixture is what puts the voice note on the draw-immediately-then-analyse path rather than the cold one.
     */
    fun voiceWaveform(key: String, durationSeconds: Int = 47, buckets: Int = 100): String {
        val samples = pcm(key, durationSeconds, rate = 8_000)
        val per = (samples.size / buckets).coerceAtLeast(1)
        val rms = DoubleArray(buckets) { b ->
            var sum = 0.0
            var count = 0
            for (i in b * per until minOf((b + 1) * per, samples.size)) { sum += samples[i] * samples[i].toDouble(); count++ }
            if (count == 0) 0.0 else sqrt(sum / count)
        }
        // Normalised to the loudest bucket, the way Telegram's own waveform is. An absolute scale over a clip
        // recorded at −24 dBFS would put every bucket in the bottom sixth of the range and draw a flat bar.
        val peak = rms.max().takeIf { it > 0.0 } ?: 1.0
        val values = IntArray(buckets) { b -> (rms[b] / peak * 31).toInt().coerceIn(0, 31) }
        val bytes = ByteArray((buckets * 5 + 7) / 8)
        var bit = 0
        for (v in values) {
            for (b in 4 downTo 0) {
                if ((v shr b) and 1 == 1) {
                    val idx = bit / 8
                    bytes[idx] = (bytes[idx].toInt() or (0x80 shr (bit % 8))).toByte()
                }
                bit++
            }
        }
        return java.util.Base64.getEncoder().encodeToString(bytes)
    }

    // ------------------------------------------------------------------ plates

    /**
     * The two House Pour token colours a plate gradients between, chosen by the seed. Kept here as ARGB ints
     * so the pure half owns the choice and [DemoFiles] only paints it.
     */
    fun plateColors(key: String): Pair<Int, Int> {
        val s = seed(key)
        val a = PLATE_INK[(abs((s ushr 8).toInt())) % PLATE_INK.size]
        val b = PLATE_INK[(abs((s ushr 32).toInt()) + 3) % PLATE_INK.size]
        return a to (if (b == a) PLATE_INK[(PLATE_INK.indexOf(a) + 2) % PLATE_INK.size] else b)
    }

    /**
     * §2.22.1 — "a linear gradient between two House Pour tokens chosen by the seed". Tokens, literally: every
     * entry is read out of [HPTokens], so a palette that moves in `design/tokens.json` moves the plates with
     * it and no hex is retyped here (`DemoPlateTest` holds this to it). A look-alike palette invented at this
     * layer is how three builds end up with three different worlds while each one insists it is House Pour.
     *
     * The seven are the dark half of the ramp — the corner key and the animated bar are drawn in near-white
     * over them (`DemoFiles.drawPlate`), so `faint` and `accent2` are deliberately not in here.
     */
    private val PLATE_INK = intArrayOf(
        HPTokens.Colors.ink.toArgb(),
        HPTokens.Colors.charcoalGradientStart.toArgb(),
        HPTokens.Colors.charcoalGradientEnd.toArgb(),
        HPTokens.Colors.muted.toArgb(),
        HPTokens.Colors.accent.toArgb(),
        HPTokens.Colors.primaryGradientEnd.toArgb(),
        HPTokens.Colors.violet.toArgb(),
    )
}
