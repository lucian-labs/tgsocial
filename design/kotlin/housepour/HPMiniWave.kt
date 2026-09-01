package ca.lucianlabs.housepour

import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.floor

/**
 * PRODUCT §2.11.2 — **the mini waveform**: the now-playing dock's transport.
 *
 * The dock is not the place for a spectrogram. This is ONE polyline through the envelope's column
 * peaks — a line drawing, not the strip's mirrored filled silhouette (`HPSpectrogramStrip`) and not the
 * spectrum. Hairline weight, `muted` ahead of the playhead, `accent` behind it, no fill under the curve.
 *
 * Three consequences of that sentence, each visible below:
 *
 * - **The baseline is the centre, not the floor.** A peak displaces the line upward from the middle of
 *   the band, so an envelope of nothing — a clip whose strip degraded to the hairline — draws a **flat
 *   line** rather than nothing (§2.11.2). Off a floor baseline the same clip would draw along the bottom
 *   edge, which reads as a rule rather than as a waveform at rest.
 * - **The split is a break in one line, not two lines.** The played run ends on the boundary column and
 *   the unplayed run starts on it, so the polyline stays continuous across the colour change.
 * - **It paints thinner than it is touched.** The line is drawn `miniWaveHeight` tall inside a control
 *   whose own shape is `touchMin` (COMPONENTS rule 6: chrome that owns its space may simply *be* 40dp —
 *   the dock row is already a 40dp play circle tall, so nothing is inflated to get there and nothing is
 *   borrowed from a neighbour).
 *
 * It draws peaks; it does not compute them. Resampling belongs to the caller, because the envelope is
 * the one the **strip already analysed** — playing a clip must never trigger a second analysis
 * (§2.11.2). [HPEnvelope.peaks] is the resampler both callers use.
 *
 * [onSeek] null makes it display-only; otherwise a tap or a drag anywhere on it seeks, exactly like the
 * strip.
 */
@Composable
fun HPMiniWave(
    peaks: FloatArray?,
    progress: Float,
    modifier: Modifier = Modifier,
    onSeek: ((Float) -> Unit)? = null,
    label: String = "Progress",
    onMeasured: (widthPx: Int) -> Unit = {},
) {
    var dragging by remember { mutableStateOf(false) }
    var dragProgress by remember { mutableFloatStateOf(0f) }
    val seek by rememberUpdatedState(onSeek)
    val shown = (if (dragging) dragProgress else progress).coerceIn(0f, 1f)
    val band = HPTokens.Space.miniWaveHeight
    val stroke = HPTokens.BORDER_WIDTH.dp
    val measured by rememberUpdatedState(onMeasured)

    Box(
        modifier = modifier
            .defaultMinSize(minWidth = HPTokens.Space.touchMin, minHeight = HPTokens.Space.touchMin)
            .semantics { contentDescription = label }
            // §2.11.2 — "the same envelope array, resampled to the dock's width". The width is reported
            // rather than assumed, because the caller owns the resample and a guessed width would either
            // throw away peaks it had or invent columns it did not.
            .onSizeChanged { if (it.width > 0) measured(it.width) }
            // The seek fraction is read off the POINTER scope's own live width on every event, never off a
            // width captured at composition — the dock is resized by rotation without the composition (or
            // this block) restarting, and a stale width sends the far end of the wave past 1.0 or makes it
            // unreachable. `HPSpectrogramStrip` learned this first; the dock inherits the lesson.
            .pointerInput(onSeek != null) {
                if (onSeek == null) return@pointerInput
                detectTapGestures { p -> if (size.width > 0) seek?.invoke((p.x / size.width).coerceIn(0f, 1f)) }
            }
            .pointerInput(onSeek != null) {
                if (onSeek == null) return@pointerInput
                detectHorizontalDragGestures(
                    onDragStart = { p ->
                        val width = size.width
                        if (width > 0) {
                            dragging = true
                            dragProgress = (p.x / width).coerceIn(0f, 1f)
                        }
                    },
                    // Only a drag that actually started commits: a gesture begun on a zero-width layout has
                    // no fraction, and committing its default would seek to 0.
                    onDragEnd = { if (dragging) { dragging = false; seek?.invoke(dragProgress) } },
                    onDragCancel = { dragging = false },
                ) { change, _ ->
                    change.consume()
                    val width = size.width
                    if (width > 0) dragProgress = (change.position.x / width).coerceIn(0f, 1f)
                }
            }
            .drawBehind { miniWave(peaks, shown, band.toPx(), stroke.toPx()) },
    )
}

/**
 * The polyline itself: one line across the band, split once at the playhead. [bandPx] is the height the
 * line may move in — the control is taller, because it is touched over `touchMin`.
 */
private fun DrawScope.miniWave(peaks: FloatArray?, progress: Float, bandPx: Float, strokePx: Float) {
    if (size.width <= 0f || size.height <= 0f) return
    val midY = size.height / 2
    val half = (bandPx / 2) * HP_ENVELOPE_HEADROOM
    val playedX = size.width * progress.coerceIn(0f, 1f)
    val played = HPTokens.Colors.accent
    val ahead = HPTokens.Colors.muted

    // Fewer than two peaks is not a shape — it is the flat line, which is exactly what a clip whose strip
    // degraded to the hairline is entitled to (§2.11.2: "a flat line rather than nothing"). Same two
    // colours, same playhead.
    val n = peaks?.size ?: 0
    if (n < 2) {
        drawLine(played, Offset(0f, midY), Offset(playedX, midY), strokePx, StrokeCap.Round)
        drawLine(ahead, Offset(playedX, midY), Offset(size.width, midY), strokePx, StrokeCap.Round)
        return
    }

    val values = peaks!!
    val stepX = size.width / (n - 1)
    fun point(i: Int) = Offset(i * stepX, midY - values[i].coerceIn(0f, 1f) * half)

    // The last column at or before the playhead. The two runs SHARE it, so the line is continuous across
    // the colour change rather than showing a gap or a doubled vertex.
    val boundary = floor(playedX / stepX).toInt().coerceIn(0, n - 1)
    fun run(from: Int, to: Int, colour: Color) {
        if (to <= from) return
        val path = Path()
        path.moveTo(point(from).x, point(from).y)
        for (i in from + 1..to) path.lineTo(point(i).x, point(i).y)
        drawPath(path, colour, style = Stroke(strokePx))
    }
    run(0, boundary, played)
    run(boundary, n - 1, ahead)
}

/**
 * PRODUCT §2.11.2 — the envelope, resampled to the width it will be drawn at.
 *
 * The dock's waveform is a **view of the analysis the strip already did**, so the only work between the
 * two is this: pick one peak per drawn column out of however many columns the strip was analysed at.
 * Peak-preserving (a `max` over each source run, never an average), because an average of a source run
 * turns a transient into nothing and the whole point of the line is where the loud part is.
 */
object HPEnvelope {

    /** [source] resampled to [columns] peaks. Fewer source points than columns are returned unchanged —
     *  the polyline simply spreads them across the width rather than inventing detail. */
    fun peaks(source: FloatArray?, columns: Int): FloatArray? {
        if (source == null || source.size < 2 || columns < 2) return source
        if (source.size <= columns) return source
        return FloatArray(columns) { i ->
            val start = (i.toLong() * source.size / columns).toInt()
            val end = (((i + 1).toLong() * source.size / columns).toInt()).coerceAtLeast(start + 1)
            var peak = 0f
            for (j in start until end.coerceAtMost(source.size)) peak = maxOf(peak, source[j])
            peak
        }
    }
}
