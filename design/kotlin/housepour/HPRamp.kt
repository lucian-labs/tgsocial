package ca.lucianlabs.housepour

import androidx.compose.ui.graphics.Color

/**
 * PRODUCT §2.11.1 — the spectrogram ramp: the one place in the look where a gradient carries **data** rather
 * than decoration.
 *
 * The stops are generated into [HPTokens.Ramp] from `design/tokens.json`, so all three platforms interpolate
 * the same five colours and the ramp is one edit. This is only the interpolation, and it is the same
 * stop-walking shape as Wake's `LZ.heatRGB` — with House Pour's colours instead of Wake's Console-family
 * near-black → cyan → gold → white, which would be a different app's language on this surface.
 *
 * Values come out as **straight** (non-premultiplied) ARGB ints, which is what `Bitmap.setPixels` wants and
 * what keeps the transparent low end of the ramp fading into `bg2` rather than into a colour.
 */
object HPRamp {

    private val stops = HPTokens.Ramp.stops

    /** The ramp colour for [v] (0–1), as straight ARGB. Both ends clamp. */
    fun argb(v: Float): Int {
        if (stops.isEmpty()) return 0
        val x = if (v.isNaN()) 0f else v.coerceIn(0f, 1f)
        if (x <= stops.first().at) return stops.first().argb
        for (i in 1 until stops.size) {
            val hi = stops[i]
            if (x > hi.at) continue
            val lo = stops[i - 1]
            val span = hi.at - lo.at
            val t = if (span > 0f) (x - lo.at) / span else 0f
            return lerpArgb(lo.argb, hi.argb, t)
        }
        return stops.last().argb
    }

    /** The same colour as a Compose [Color], for the parts of the strip that are drawn rather than blitted. */
    fun color(v: Float): Color = Color(argb(v))

    /** Channel-wise lerp on straight ARGB, alpha included — the ramp's low end is transparent by design. */
    private fun lerpArgb(from: Int, to: Int, t: Float): Int {
        val k = t.coerceIn(0f, 1f)
        var out = 0
        for (shift in intArrayOf(24, 16, 8, 0)) {
            val a = (from shr shift) and 0xFF
            val b = (to shr shift) and 0xFF
            val v = (a + (b - a) * k).toInt().coerceIn(0, 255)
            out = out or (v shl shift)
        }
        return out
    }
}
