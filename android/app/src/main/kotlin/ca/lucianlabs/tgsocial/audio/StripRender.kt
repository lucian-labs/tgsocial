package ca.lucianlabs.tgsocial.audio

import android.graphics.Bitmap
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import ca.lucianlabs.housepour.HPRamp
import ca.lucianlabs.housepour.HPStrip

/**
 * One analysed clip as the strip actually holds it: the spectrum already colourised into a bitmap, plus the
 * envelope. [bytes] is what it costs the process, so the byte-bounded cache in `MediaRepo` can charge it
 * honestly rather than counting it as "one entry".
 */
class AudioStrip(val spectrum: ImageBitmap?, val envelope: FloatArray, val bytes: Long) {
    fun toHPStrip(): HPStrip = HPStrip(spectrum, envelope.takeIf { it.size >= 2 })
}

/** [StripData] → pixels. The one place the analysis meets the palette. */
object StripRender {

    /**
     * Colourise the grid through [HPRamp] into a `columns × rows` bitmap.
     *
     * A bitmap, not a path: the strip is static once computed, so this runs **once per clip** and every
     * subsequent frame — including every frame of a fling past the card — is a single scaled blit. Wake
     * reached the same conclusion from the other direction (`WakeFFT.swift`: re-emitting the waterfall as a
     * path was O(bars × history) rect ops per redraw).
     *
     * The grid's row 0 is the lowest frequency and bitmap y grows downward, so the write flips it here —
     * the only place in the pipeline that knows which way up a screen is.
     */
    fun render(data: StripData): AudioStrip {
        val envelopeBytes = data.envelope.size.toLong() * Float.SIZE_BYTES
        val grid = data.spectrum ?: return AudioStrip(null, data.envelope, envelopeBytes)
        val columns = data.columns
        val rows = data.rows
        val bitmap = runCatching {
            val pixels = IntArray(columns * rows)
            for (r in 0 until rows) {
                val y = rows - 1 - r
                val line = y * columns
                for (c in 0 until columns) pixels[line + c] = HPRamp.argb(grid[c * rows + r])
            }
            // setPixels takes straight (non-premultiplied) ARGB, which is exactly what HPRamp emits — the
            // ramp's low end is transparent so the strip fades into `bg2` rather than into a colour.
            Bitmap.createBitmap(columns, rows, Bitmap.Config.ARGB_8888)
                .apply { setPixels(pixels, 0, columns, 0, 0, columns, rows) }
                .asImageBitmap()
        }.getOrNull() ?: return AudioStrip(null, data.envelope, envelopeBytes)

        val pixelBytes = runCatching { bitmap.asAndroidBitmap().allocationByteCount.toLong() }
            .getOrElse { columns.toLong() * rows * 4 }
        return AudioStrip(bitmap, data.envelope, pixelBytes + envelopeBytes)
    }
}
