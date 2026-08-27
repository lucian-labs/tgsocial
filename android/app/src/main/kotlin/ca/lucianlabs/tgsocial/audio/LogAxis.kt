package ca.lucianlabs.tgsocial.audio

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.pow

/**
 * PRODUCT §2.11.1 — the strip's frequency axis: **log** spaced, low at the bottom, high at the top,
 * "because that is how pitch is spaced". One row of the strip per band.
 *
 * Row 0 is the lowest band ([fMin] upward) and row `rows - 1` the highest; the bitmap writer is what flips
 * it, since bitmap y grows downward.
 *
 * [fMax] is the *effective* ceiling, which is not always the nominal 20 kHz: the clip is decoded at a
 * decimated rate (see [SpectrogramSpec.RATE]) and there is no information above that rate's Nyquist, so the
 * axis is clamped there exactly as Wake's `LiveSpectrum.logBars` clamps to `sr / 2`. Painting rows for
 * frequencies the decode threw away would be drawing a floor and calling it silence.
 */
class LogAxis(val fMin: Float, val fMax: Float, val rows: Int) {
    init {
        require(fMin > 0f && fMax > fMin) { "need 0 < fMin < fMax, got $fMin..$fMax" }
        require(rows > 0) { "rows must be > 0" }
    }

    private val logSpan = ln(fMax / fMin).toDouble()

    /** The row [frequency] lands in. Anything at or below [fMin] clamps to 0, at or above [fMax] to the top. */
    fun row(frequency: Float): Int {
        if (frequency <= fMin) return 0
        if (frequency >= fMax) return rows - 1
        val t = ln(frequency / fMin).toDouble() / logSpan
        return floor(t * rows).toInt().coerceIn(0, rows - 1)
    }

    /** The lower edge of [row], in Hz. `edge(rows)` is [fMax]. */
    fun edge(row: Int): Float = (fMin * (fMax / fMin).toDouble().pow(row.toDouble() / rows)).toFloat()

    /** The geometric centre frequency of [row] — the frequency the row is "about". */
    fun centre(row: Int): Float =
        (fMin * (fMax / fMin).toDouble().pow((row + 0.5) / rows)).toFloat()

    /**
     * The FFT bin range `[from, until)` that falls in [row], for a transform of [fftSize] points at
     * [rate] Hz. Never empty: a band narrower than one bin still peak-picks the bin it sits in, which is
     * what keeps the bottom of a log axis from going black at low FFT resolutions.
     *
     * The lower edge floors and the upper edge **ceils**, so a bin the band only partly covers still belongs
     * to it. Flooring both is the subtly wrong version: a band from 98 Hz to 108 Hz against 7.8 Hz bins would
     * come out as bin 12 alone and quietly drop bin 13 — the one its own centre frequency sits in. Adjacent
     * rows therefore share an edge bin, which is correct for a peak-pick and is what stops a log axis
     * developing gaps where the bands are narrower than the resolution.
     */
    fun bins(row: Int, fftSize: Int, rate: Int): IntRange {
        val binHz = rate.toFloat() / fftSize
        val lo = floor(edge(row) / binHz).toInt().coerceIn(0, fftSize / 2 - 1)
        val hi = ceil(edge(row + 1) / binHz).toInt().coerceIn(lo + 1, fftSize / 2)
        return lo until hi
    }
}
