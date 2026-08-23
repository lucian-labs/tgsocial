package ca.lucianlabs.housepour

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/** Knob diameter for the scrubber (PRODUCT §2.11: 12pt `panel` knob with the contact shadow). */
val HP_SCRUBBER_KNOB = 12.dp

/**
 * The one scrubber in the look: a hairline (1pt `line2`) with a gold played segment and a 12pt `panel` knob
 * carrying the contact shadow. Drag or tap to seek. [progress] is 0–1; [onSeek] receives 0–1.
 * The hit area is `touchMin` tall even though the drawn track is a hairline.
 */
@Composable
fun HPScrubber(
    progress: Float,
    onSeek: (Float) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    trackColor: Color = HPTokens.Colors.line2,
    playedColor: Color = HPTokens.Colors.accent,
    label: String = "Seek",
) {
    var width by remember { mutableFloatStateOf(0f) }
    var dragging by remember { mutableStateOf(false) }
    var dragProgress by remember { mutableFloatStateOf(0f) }
    val seek by rememberUpdatedState(onSeek)
    val shown = (if (dragging) dragProgress else progress).coerceIn(0f, 1f)
    val knobPx = with(androidx.compose.ui.platform.LocalDensity.current) { HP_SCRUBBER_KNOB.toPx() }
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(HPTokens.Space.touchMin)
            .semantics { contentDescription = label }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectTapGestures { p -> if (width > 0f) seek((p.x / width).coerceIn(0f, 1f)) }
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectHorizontalDragGestures(
                    onDragStart = { p -> dragging = true; dragProgress = (p.x / width.coerceAtLeast(1f)).coerceIn(0f, 1f) },
                    onDragEnd = { dragging = false; seek(dragProgress) },
                    onDragCancel = { dragging = false },
                ) { change, _ ->
                    change.consume()
                    dragProgress = (change.position.x / width.coerceAtLeast(1f)).coerceIn(0f, 1f)
                }
            }
            .drawBehind {
                width = size.width
                val y = size.height / 2
                val stroke = HPTokens.BORDER_WIDTH.dp.toPx()
                drawLine(trackColor, Offset(0f, y), Offset(size.width, y), stroke, StrokeCap.Round)
                val x = size.width * shown
                if (x > 0f) drawLine(playedColor, Offset(0f, y), Offset(x, y), stroke, StrokeCap.Round)
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        // The knob: offset along the track by the shown progress, centred on the hairline.
        Box(
            modifier = Modifier
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints)
                    layout(constraints.maxWidth, placeable.height) {
                        val x = ((constraints.maxWidth - knobPx) * shown).roundToInt()
                        placeable.placeRelative(x, 0)
                    }
                }
                .size(HP_SCRUBBER_KNOB)
                .hpShadow(HP_SCRUBBER_KNOB / 2, HPTokens.Shadow.contact)
                .background(HPTokens.Colors.panel, CircleShape)
                .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line2, CircleShape),
        )
    }
}

/**
 * Voice waveform: ink bars with the played part in gold, drawn from TDLib's waveform (values 0–1). Tap or drag to
 * seek. Bar width and gap derive from the available width so the sample count never forces a scroll.
 */
@Composable
fun HPWaveform(
    samples: List<Float>,
    progress: Float,
    onSeek: (Float) -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    barColor: Color = HPTokens.Colors.ink,
    playedColor: Color = HPTokens.Colors.accent,
    label: String = "Seek",
) {
    var width by remember { mutableFloatStateOf(0f) }
    var dragging by remember { mutableStateOf(false) }
    var dragProgress by remember { mutableFloatStateOf(0f) }
    val seek by rememberUpdatedState(onSeek)
    val shown = (if (dragging) dragProgress else progress).coerceIn(0f, 1f)
    val bars = if (samples.isEmpty()) List(48) { 0.2f } else samples
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(HPTokens.Space.touchMin)
            .semantics { contentDescription = label }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectTapGestures { p -> if (width > 0f) seek((p.x / width).coerceIn(0f, 1f)) }
            }
            .pointerInput(enabled) {
                if (!enabled) return@pointerInput
                detectHorizontalDragGestures(
                    onDragStart = { p -> dragging = true; dragProgress = (p.x / width.coerceAtLeast(1f)).coerceIn(0f, 1f) },
                    onDragEnd = { dragging = false; seek(dragProgress) },
                    onDragCancel = { dragging = false },
                ) { change, _ ->
                    change.consume()
                    dragProgress = (change.position.x / width.coerceAtLeast(1f)).coerceIn(0f, 1f)
                }
            }
            .drawBehind {
                width = size.width
                val n = bars.size
                val slot = size.width / n
                val bar = (slot * 0.6f).coerceAtLeast(1f)
                val minH = HPTokens.BORDER_WIDTH.dp.toPx() * 2
                val playedX = size.width * shown
                for (i in 0 until n) {
                    val h = (minH + (size.height - minH) * bars[i].coerceIn(0f, 1f) * 0.8f)
                    val x = i * slot + (slot - bar) / 2
                    val color = if (x + bar / 2 <= playedX) playedColor else barColor
                    drawRoundRect(color, Offset(x, (size.height - h) / 2), Size(bar, h), androidx.compose.ui.geometry.CornerRadius(bar / 2))
                }
            },
    )
}

/**
 * Determinate download progress over a placeholder: a gold hairline ring on a `line2` track, `touchMin` across.
 * Tapping cancels (PRODUCT §2.11). [progress] 0–1.
 */
@Composable
fun HPDownloadRing(
    progress: Float,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
    trackColor: Color = HPTokens.Colors.line2,
    ringColor: Color = HPTokens.Colors.accent,
) {
    Box(
        modifier = modifier
            .size(HPTokens.Space.touchMin)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onCancel)
            .semantics { contentDescription = "Cancel download" }
            .drawBehind {
                val stroke = HPTokens.BORDER_WIDTH.dp.toPx()
                val inset = stroke * 2
                val arcSize = Size(size.width - inset * 2, size.height - inset * 2)
                drawArc(trackColor, 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(stroke))
                drawArc(ringColor, -90f, 360f * progress.coerceIn(0f, 1f), false, Offset(inset, inset), arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
            },
        contentAlignment = Alignment.Center,
    ) {
        // A hairline cross, not a glyph: the tap target is the whole ring.
        Box(
            Modifier
                .size(HPTokens.Space.touchMin / 4)
                .drawBehind {
                    val stroke = HPTokens.BORDER_WIDTH.dp.toPx()
                    drawLine(ringColor, Offset(0f, 0f), Offset(size.width, size.height), stroke, StrokeCap.Round)
                    drawLine(ringColor, Offset(size.width, 0f), Offset(0f, size.height), stroke, StrokeCap.Round)
                },
        )
    }
}

/** Determinate hairline bar (gold on `line2`); the horizontal form of [HPDownloadRing] for rows. */
@Composable
fun HPProgressBar(progress: Float, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(HPTokens.BORDER_WIDTH.dp)
            .drawBehind {
                val y = size.height / 2
                drawLine(HPTokens.Colors.line2, Offset(0f, y), Offset(size.width, y), size.height, StrokeCap.Round)
                val x = size.width * progress.coerceIn(0f, 1f)
                if (x > 0f) drawLine(HPTokens.Colors.accent, Offset(0f, y), Offset(x, y), size.height, StrokeCap.Round)
            },
    )
}
