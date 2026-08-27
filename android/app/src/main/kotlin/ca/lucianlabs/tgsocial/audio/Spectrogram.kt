package ca.lucianlabs.tgsocial.audio

import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.pow

/**
 * One analysed clip: the spectrum as a [columns] × [rows] grid of 0–1 cells, and the amplitude envelope as
 * one 0–1 peak per column.
 *
 * [cells] is `column * rows + row`, **row 0 lowest** in frequency. Bitmap y grows downward, so the writer
 * flips it; nothing in the analysis knows which way up a screen is.
 *
 * [spectrum] is null when the clip could not be transformed (shorter than one FFT window) — the strip then
 * draws the silhouette alone, which is §2.11.1's fallback and not an error.
 */
class StripData(
    val columns: Int,
    val rows: Int,
    val spectrum: FloatArray?,
    val envelope: FloatArray,
) {
    /** Rough retained cost, for the byte-bounded cache that holds these. */
    val floatBytes: Long get() = ((spectrum?.size ?: 0) + envelope.size).toLong() * Float.SIZE_BYTES
}

/**
 * PRODUCT §2.11.1 — the analysis behind the strip. Pure Kotlin: no Android, no Compose, no I/O, so all of it
 * is unit-testable on the JVM and none of it can accidentally touch the main thread's business.
 *
 * The instrument is Wake's (`WakeFFT.swift`), with one structural difference that changes everything about
 * the output: Wake watches a **live** microphone and scrolls a waterfall, so its history is a ring that
 * `memmove`s one row per frame. tgsocial plays a **finite file**, so the strip is the *whole clip*, computed
 * once, time on the x axis end to end — a still image that doubles as the scrubber. Nothing scrolls.
 *
 * What carries over from Wake unchanged: the log frequency fold ([LogAxis]), the pink-slope tilt, the rolling
 * AGC that normalises against a decaying peak instead of absolute dBFS, and the dB (not linear) mapping.
 */
object Spectrogram {

    /**
     * The spectrum grid, or null if [mono] is shorter than one FFT window.
     *
     * Hop is fixed at [SpectrogramSpec.HOP] (~50 % overlap) whatever the clip's length, and frames are
     * **peak-combined** into columns. Sizing the hop from `samples / columns` instead would look equivalent
     * and would quietly stop analysing most of a long clip: at 10 minutes across 480 columns that is a
     * 1.25-second window per column, of which a 128 ms transform would see a tenth.
     */
    fun spectrum(
        mono: FloatArray,
        rate: Int,
        columns: Int,
        rows: Int,
        fftSize: Int = SpectrogramSpec.FFT_SIZE,
        hop: Int = SpectrogramSpec.HOP,
    ): FloatArray? {
        if (columns <= 0 || rows <= 0 || rate <= 0) return null
        if (mono.size < fftSize) return null

        val fft = Fft(fftSize)
        val mags = FloatArray(fft.bins)
        val axis = LogAxis(SpectrogramSpec.F_MIN, SpectrogramSpec.effectiveFMax(rate), rows)

        // Per-row constants: the bin span to peak-pick, and the tilt gain at the row's centre frequency.
        val binFrom = IntArray(rows)
        val binUntil = IntArray(rows)
        val tilt = FloatArray(rows)
        for (r in 0 until rows) {
            val range = axis.bins(r, fftSize, rate)
            binFrom[r] = range.first
            binUntil[r] = range.last + 1
            tilt[r] = 10f.pow(SpectrogramSpec.TILT_DB_PER_OCT * log2(axis.centre(r) / SpectrogramSpec.TILT_PIVOT_HZ) / 20f)
        }

        val frames = 1 + (mono.size - fftSize) / hop
        val agcRelease = SpectrogramSpec.agcReleaseAt(rate, hop)
        var agcPeak = SpectrogramSpec.AGC_FLOOR

        val cells = FloatArray(columns * rows)
        val written = BooleanArray(columns)
        val tilted = FloatArray(rows)

        for (f in 0 until frames) {
            fft.magnitudes(mono, f * hop, mags)

            var frameMax = 0f
            for (r in 0 until rows) {
                var peak = 0f
                for (k in binFrom[r] until binUntil[r]) if (mags[k] > peak) peak = mags[k]
                val v = peak * tilt[r]
                tilted[r] = v
                if (v > frameMax) frameMax = v
            }

            // Wake's AGC exactly: instant attack onto the loudest tilted band, slow release, floored so
            // silence stays dark. Because the tilt is already baked in, every band's floor sits DYN_RANGE_DB
            // under the loudest content wherever it happens to be, and the low end stops falling into black.
            agcPeak = if (frameMax > agcPeak) frameMax else max(agcPeak * agcRelease, SpectrogramSpec.AGC_FLOOR)

            val column = (f.toLong() * columns / frames).toInt().coerceIn(0, columns - 1)
            val base = column * rows
            written[column] = true
            for (r in 0 until rows) {
                val rel = tilted[r] / max(agcPeak, SpectrogramSpec.AGC_FLOOR)
                val db = 20f * log10(max(rel, 1e-5f))
                val v = ((db + SpectrogramSpec.DYN_RANGE_DB) / SpectrogramSpec.DYN_RANGE_DB).coerceIn(0f, 1f)
                if (v > cells[base + r]) cells[base + r] = v
            }
        }

        // Fewer frames than columns (a clip under ~columns × 64 ms): hold the last written column FORWARD
        // rather than leaving unwritten ones black, which would stripe the strip like a picket fence.
        //
        // Forward is not a detail — it is the direction time runs, and the strip is the scrubber. Holding
        // backward instead paints each analysed column across the gap to its LEFT, so a loud moment draws
        // ahead of where it happens and §2.11.1's "you can see where the loud part is before you drag to it"
        // sends you to the wrong place: on a two-second clip the burst lands about 0.06 of the width early,
        // while the playhead and the silhouette sit where they should.
        var source = -1
        var first = -1
        for (c in 0 until columns) {
            if (written[c]) {
                source = c
                if (first < 0) first = c
            } else if (source >= 0) {
                System.arraycopy(cells, source * rows, cells, c * rows, rows)
            }
        }
        // The run before the first written column has no past to hold; seed it from the first column that
        // has one, so the head reads as the clip's opening rather than as a black notch. (Frame 0 always
        // lands on column 0, so this is a guard rather than a normal path.)
        for (c in 0 until first) System.arraycopy(cells, first * rows, cells, c * rows, rows)
        return cells
    }

    /**
     * PRODUCT §2.11.1 — the one-pole silhouette: a follower over the sample magnitudes, peak-held into one
     * value per column, then scaled to the clip's own peak so a quiet take still reads as a shape.
     *
     * Empty input gives an empty array, which the strip draws as its hairline fallback.
     */
    fun envelope(mono: FloatArray, rate: Int, columns: Int): FloatArray {
        if (columns <= 0 || mono.isEmpty() || rate <= 0) return FloatArray(0)
        val follower = OnePole(SpectrogramSpec.attackAt(rate), SpectrogramSpec.releaseAt(rate))
        val out = FloatArray(columns)
        val n = mono.size
        for (i in 0 until n) {
            val v = follower.next(abs(mono[i]))
            val column = (i.toLong() * columns / n).toInt().coerceIn(0, columns - 1)
            if (v > out[column]) out[column] = v
        }
        var peak = 0f
        for (v in out) if (v > peak) peak = v
        val norm = max(peak, SpectrogramSpec.ENVELOPE_FLOOR)
        for (i in out.indices) out[i] = (out[i] / norm).coerceIn(0f, 1f)
        return out
    }

    /** Both halves for one clip. The spectrum may come back null; the envelope never does. */
    fun analyse(mono: FloatArray, rate: Int, columns: Int, rows: Int): StripData = StripData(
        columns = columns,
        rows = rows,
        spectrum = spectrum(mono, rate, columns, rows),
        envelope = envelope(mono, rate, columns),
    )
}
