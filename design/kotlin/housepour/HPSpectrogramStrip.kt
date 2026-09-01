package ca.lucianlabs.housepour

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * What the strip draws: the analysed [spectrum] (already colourised through [HPRamp], one column per strip
 * pixel) and the one-pole [envelope] (one 0–1 peak per column).
 *
 * Either half may be absent, and the three combinations are the three states of §2.11.1's degradation:
 * both → the finished strip; envelope only → the amplitude silhouette (a voice note's TDLib waveform bytes,
 * drawn the instant the row appears, or a clip whose spectrum is still computing); neither → a hairline, so
 * the row is usable the moment it exists.
 */
@Immutable
class HPStrip(val spectrum: ImageBitmap? = null, val envelope: FloatArray? = null) {
    val isEmpty: Boolean get() = spectrum == null && (envelope?.size ?: 0) < 2
}

/**
 * PRODUCT §2.11.1 — **the spectrogram strip**: the audio scrubber, which is not a hairline but a spectrogram
 * of the whole clip with its amplitude envelope drawn over it, so you can see where the loud part is before
 * you drag to it.
 *
 * Time is the x axis, end to end, and the playhead sweeps it. Unlike Wake's waterfall — a live microphone
 * scrolling under a fixed present — this is a finite file, so the image is computed once and does not move.
 *
 * - **Spectrum**: blitted as one bitmap scaled to the strip. Not a path per column: Wake's comments spell out
 *   the O(bars × history) blow-up that forced the bitmap, and re-emitting a few hundred columns of rects per
 *   frame inside a scrolling feed is the same mistake with more rows on screen.
 * - **Envelope**: the connected line through the column peaks, mirrored about the centre and filled — Wake's
 *   `LZPointWave` silhouette. Played and unplayed runs are keyed by an **Int** compare so the split costs an
 *   integer comparison per column rather than a `Color` construction.
 * - **Played vs unplayed**: played carries `accent`; ahead of the playhead the silhouette is `ink` at reduced
 *   opacity. The playhead is a 1dp `accent` rule.
 *
 * The painted shape is `stripHeight` (44dp) tall, so it *is* its own hit region under COMPONENTS rule 6 — no
 * overlay, nothing to tile against, because nothing is placed after it in the player row. Tap or drag
 * anywhere on it to seek.
 *
 * [onVisible] reports the strip's pixel geometry, and only once it has actually been laid out somewhere
 * on screen — §2.11.1: "Analysis never runs for a row that has not been played or scrolled into view." A
 * `LazyColumn` composes and measures a little beyond the viewport, so composition alone is not that test;
 * a non-empty window rectangle is.
 */
@Composable
fun HPSpectrogramStrip(
    strip: HPStrip?,
    progress: Float,
    onSeek: (Float) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    label: String = "Seek",
    onVisible: (widthPx: Int, heightPx: Int) -> Unit = { _, _ -> },
) {
    var dragging by remember { mutableStateOf(false) }
    var dragProgress by remember { mutableFloatStateOf(0f) }
    var reported by remember { mutableStateOf(IntSize.Zero) }
    val seek by rememberUpdatedState(onSeek)
    val visible by rememberUpdatedState(onVisible)
    val shown = (if (dragging) dragProgress else progress).coerceIn(0f, 1f)

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(HPTokens.Space.stripHeight)
            .clip(RoundedCornerShape(HPTokens.Radius.media))
            .background(HPTokens.Colors.bg2)
            .semantics { contentDescription = label }
            .onGloballyPositioned { coordinates ->
                val bounds = coordinates.boundsInWindow()
                if (bounds.width <= 0f || bounds.height <= 0f) return@onGloballyPositioned
                val size = coordinates.size
                if (size.width <= 0 || size.height <= 0 || size == reported) return@onGloballyPositioned
                reported = size
                visible(size.width, size.height)
            }
            // The seek fraction comes off the POINTER scope's own measured width, not off a width captured
            // during a draw pass. A control that learns how wide it is only once it has painted is dead to
            // the first tap after composition, and dead for good anywhere the draw is skipped.
            //
            // And it is read LIVE, on every event, in the drag exactly as in the tap. `pointerInput(enabled)`
            // never restarts while `enabled` holds, so a width hoisted into the block is the width at the
            // first touch of the composition, forever: the manifest keeps `orientation|screenSize` out of the
            // recreate list, so a rotation resizes this strip without restarting anything, and every later
            // drag would divide by the old width — the far fifth of the strip seeking to the end, or the far
            // fifth becoming unreachable, depending which way the phone turned.
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectTapGestures { p -> if (size.width > 0) seek((p.x / size.width).coerceIn(0f, 1f)) }
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectHorizontalDragGestures(
                    onDragStart = { p ->
                        val width = size.width
                        if (width > 0) {
                            dragging = true
                            dragProgress = (p.x / width).coerceIn(0f, 1f)
                        }
                    },
                    // Only commit a drag that actually started: a gesture that began on a zero-width
                    // layout has no fraction, and committing its default would seek to 0.
                    onDragEnd = { if (dragging) { dragging = false; seek(dragProgress) } },
                    onDragCancel = { dragging = false },
                ) { change, _ ->
                    change.consume()
                    val width = size.width
                    if (width > 0) dragProgress = (change.position.x / width).coerceIn(0f, 1f)
                }
            }
            .drawBehind {
                val playedX = size.width * shown
                val image = strip?.spectrum
                if (image != null && image.width > 0 && image.height > 0) {
                    drawImage(
                        image = image,
                        srcOffset = IntOffset.Zero,
                        srcSize = IntSize(image.width, image.height),
                        dstOffset = IntOffset.Zero,
                        dstSize = IntSize(size.width.roundToInt().coerceAtLeast(1), size.height.roundToInt().coerceAtLeast(1)),
                    )
                }
                val envelope = strip?.envelope
                if (envelope != null && envelope.size >= 2) silhouette(envelope, playedX)
                else if (image == null) hairline(playedX)
                if (shown > 0f) {
                    drawLine(
                        HPTokens.Colors.accent,
                        Offset(playedX, 0f),
                        Offset(playedX, size.height),
                        HPTokens.BORDER_WIDTH.dp.toPx(),
                    )
                }
            },
    )
}

/**
 * How much of the half-height an envelope's peak claims, so peaks do not clip against the rounded edges
 * of what draws them. Shared with the dock's line drawing (`HPMiniWave`, PRODUCT §2.11.2) so the same
 * envelope reads at the same relative height in both places.
 */
internal const val HP_ENVELOPE_HEADROOM = 0.9f

/**
 * Fill and ridge opacities. The silhouette sits *over* the spectrum, so a solid fill would hide the data it
 * is describing; Wake's `LZPointWave` fills at 0.55 for the same reason. Unplayed is `ink` rather than a
 * dimmed accent — §2.11.1 is explicit that the colour ahead of the playhead is ink.
 */
private const val PLAYED_FILL = 0.55f
private const val UNPLAYED_FILL = 0.18f
private const val UNPLAYED_RIDGE = 0.45f

/** Keys for the two runs. An Int compare per column, never a `Color` compare (Wake learned that at 30 Hz). */
private const val KEY_PLAYED = 0
private const val KEY_UNPLAYED = 1

/**
 * The connected-line-through-peaks silhouette, mirrored about the strip's centre and filled — one closed
 * region per played/unplayed run, the two sharing their boundary column so the shape stays continuous
 * across the colour change.
 */
private fun DrawScope.silhouette(envelope: FloatArray, playedX: Float) {
    val n = envelope.size
    val stepX = size.width / (n - 1)
    val centreY = size.height / 2
    val amplitude = centreY * HP_ENVELOPE_HEADROOM
    val stroke = HPTokens.BORDER_WIDTH.dp.toPx()

    fun x(i: Int) = i * stepX
    fun h(i: Int) = envelope[i].coerceIn(0f, 1f) * amplitude

    fun flush(from: Int, to: Int, key: Int) {
        if (to <= from) return
        val colour: Color
        val fillAlpha: Float
        val ridgeAlpha: Float
        if (key == KEY_PLAYED) {
            colour = HPTokens.Colors.accent
            fillAlpha = PLAYED_FILL
            ridgeAlpha = 1f
        } else {
            colour = HPTokens.Colors.ink
            fillAlpha = UNPLAYED_FILL
            ridgeAlpha = UNPLAYED_RIDGE
        }
        val fill = Path()
        fill.moveTo(x(from), centreY - h(from))
        for (i in from..to) fill.lineTo(x(i), centreY - h(i))
        for (i in to downTo from) fill.lineTo(x(i), centreY + h(i))
        fill.close()
        drawPath(fill, colour, alpha = fillAlpha)

        val top = Path()
        val bottom = Path()
        top.moveTo(x(from), centreY - h(from))
        bottom.moveTo(x(from), centreY + h(from))
        for (i in from + 1..to) {
            top.lineTo(x(i), centreY - h(i))
            bottom.lineTo(x(i), centreY + h(i))
        }
        drawPath(top, colour, alpha = ridgeAlpha, style = Stroke(stroke))
        drawPath(bottom, colour, alpha = ridgeAlpha, style = Stroke(stroke))
    }

    var runStart = 0
    var runKey = if (x(0) <= playedX) KEY_PLAYED else KEY_UNPLAYED
    for (i in 1 until n) {
        val key = if (x(i) <= playedX) KEY_PLAYED else KEY_UNPLAYED
        if (key != runKey) {
            flush(runStart, i, runKey)
            runStart = i
            runKey = key
        }
    }
    flush(runStart, n - 1, runKey)
}

/** Nothing analysed yet: the hairline the strip replaces, so the row still reads as a scrubber and seeks. */
private fun DrawScope.hairline(playedX: Float) {
    val y = size.height / 2
    val stroke = HPTokens.BORDER_WIDTH.dp.toPx()
    drawLine(HPTokens.Colors.line2, Offset(0f, y), Offset(size.width, y), stroke, StrokeCap.Round)
    if (playedX > 0f) drawLine(HPTokens.Colors.accent, Offset(0f, y), Offset(playedX, y), stroke, StrokeCap.Round)
}
