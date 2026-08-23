package ca.lucianlabs.housepour

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/** Ink at 96% — the full-screen viewer surface (PRODUCT §1: the one dark surface besides the toast). */
val HPViewerBackground = HPTokens.Colors.ink.copy(alpha = 0.96f)

/** Swipe-down-to-dismiss bookkeeping shared by the viewer chrome and its pages. */
@Stable
class HPViewerDismissState internal constructor(
    private val scope: CoroutineScope,
    private val onDismiss: () -> Unit,
    private val thresholdPx: Float,
) {
    internal val offsetY = Animatable(0f)
    val offset: Float get() = offsetY.value
    val fade: Float get() = 1f - (abs(offsetY.value) / (thresholdPx * 3f)).coerceIn(0f, 0.6f)

    fun drag(dy: Float) {
        scope.launch { offsetY.snapTo(offsetY.value + dy) }
    }

    fun release() {
        if (offsetY.value > thresholdPx) onDismiss()
        else scope.launch { offsetY.animateTo(0f, tween(HPTokens.Motion.TOAST_MS)) }
    }
}

/** Vertical drag-to-dismiss for viewer pages that have no zoom of their own. */
fun Modifier.hpViewerDismiss(state: HPViewerDismissState): Modifier = this.pointerInput(state) {
    detectVerticalDragGestures(
        onDragEnd = { state.release() },
        onDragCancel = { state.release() },
    ) { change, dy ->
        change.consume()
        state.drag(dy)
    }
}

/** Ghost button for the ink surface: `charcoalText`, no fill — the viewer's `Close` / `Save`. */
@Composable
fun HPViewerButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(HPTokens.Radius.pill))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onClick)
            .defaultMinSize(minHeight = HPTokens.Space.touchMin, minWidth = HPTokens.Space.touchMin)
            .padding(horizontal = HPTokens.Space.buttonSmX, vertical = HPTokens.Space.buttonSmY)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        HPText(label, HPTokens.Type.button, HPTokens.Colors.charcoalText, maxLines = 1)
    }
}

/**
 * PRODUCT §2.11 — the full-screen media viewer: ink 96% background over everything (it hides the topbar and the
 * floating tab bar by covering them), a top row with `Close` leading and [actions] trailing, swipe between the
 * album items of one post, caption below in `charcoalText`, swipe down or `Close` to dismiss.
 */
@Composable
fun HPViewer(
    pageCount: Int,
    initialPage: Int,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    caption: String? = null,
    onPage: (Int) -> Unit = {},
    actions: @Composable RowScope.(page: Int) -> Unit = {},
    content: @Composable (page: Int, dismiss: HPViewerDismissState) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val threshold = with(LocalDensity.current) { (HPTokens.Space.touchMin * 3).toPx() }
    val dismissState = remember(onDismiss) { HPViewerDismissState(scope, onDismiss, threshold) }
    val pager = rememberPagerState(initialPage = initialPage.coerceIn(0, (pageCount - 1).coerceAtLeast(0))) { pageCount }
    LaunchedEffect(pager) {
        snapshotPage(pager.currentPage)
        androidx.compose.runtime.snapshotFlow { pager.currentPage }.collect { onPage(it) }
    }
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(HPViewerBackground.copy(alpha = HPViewerBackground.alpha * dismissState.fade))
            // Swallow stray touches so nothing under the viewer is tapped through it.
            .pointerInput(Unit) { detectTapGestures { } }
            .semantics { contentDescription = "Media viewer" },
    ) {
        HorizontalPager(
            state = pager,
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer { translationY = dismissState.offset },
        ) { page ->
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                content(page, dismissState)
            }
        }
        Row(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .statusBarsPadding()
                .widthIn(max = HPTokens.Space.columnMax)
                .fillMaxWidth()
                .padding(horizontal = HPTokens.Space.columnSide, vertical = HPTokens.Space.rowGap),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            HPViewerButton("Close", onDismiss)
            Row(verticalAlignment = Alignment.CenterVertically) { actions(pager.currentPage) }
        }
        if (!caption.isNullOrBlank()) {
            Box(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .widthIn(max = HPTokens.Space.columnMax)
                    .fillMaxWidth()
                    .padding(horizontal = HPTokens.Space.columnSide + HPTokens.Space.rowGap, vertical = HPTokens.Space.cardGap)
                    .graphicsLayer { alpha = dismissState.fade },
            ) {
                HPText(caption, HPTokens.Type.body, HPTokens.Colors.charcoalText, maxLines = 4, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

private fun snapshotPage(@Suppress("UNUSED_PARAMETER") page: Int) = Unit

/**
 * Pinch-zoom + double-tap zoom + pan for the viewer's photo pages. When unzoomed, a vertical drag hands off to
 * [dismiss] and horizontal drags stay unconsumed so the pager can page. [onTap] fires on a single tap.
 */
@Composable
fun HPZoomable(
    dismiss: HPViewerDismissState,
    modifier: Modifier = Modifier,
    onTap: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    var size by remember { mutableStateOf(androidx.compose.ui.unit.IntSize.Zero) }

    fun clampOffset() {
        val maxX = (size.width * (scale - 1f)) / 2f
        val maxY = (size.height * (scale - 1f)) / 2f
        offset = Offset(offset.x.coerceIn(-maxX, maxX), offset.y.coerceIn(-maxY, maxY))
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .onSizeChanged { size = it }
            .pointerInput(dismiss) {
                detectTapGestures(
                    onDoubleTap = { tap ->
                        if (scale > 1f) {
                            scale = 1f; offset = Offset.Zero
                        } else {
                            scale = 2.5f
                            offset = Offset((size.width / 2f - tap.x) * (scale - 1f), (size.height / 2f - tap.y) * (scale - 1f))
                            clampOffset()
                        }
                    },
                    onTap = { onTap?.invoke() },
                )
            }
            .pointerInput(dismiss) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    var dismissing = false
                    var pastSlop = false
                    var accumulated = Offset.Zero
                    val slop = viewConfiguration.touchSlop
                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.any { it.pressed }
                        if (!pressed) break
                        val zoom = event.calculateZoom()
                        val pan = event.calculatePan()
                        val centroid = event.calculateCentroid()
                        val pinching = event.changes.count { it.pressed } > 1
                        if (scale > 1f || pinching) {
                            if (zoom != 1f) {
                                val next = (scale * zoom).coerceIn(1f, 5f)
                                if (next != scale && centroid.isSpecified) {
                                    val centre = Offset(size.width / 2f, size.height / 2f)
                                    offset = (offset + centre - centroid) * (next / scale) + centroid - centre
                                }
                                scale = next
                            }
                            offset += pan
                            if (scale <= 1f) offset = Offset.Zero
                            clampOffset()
                            event.changes.forEach { if (it.positionChanged()) it.consume() }
                        } else {
                            accumulated += pan
                            if (!pastSlop && (abs(accumulated.y) > slop || abs(accumulated.x) > slop)) {
                                pastSlop = true
                                dismissing = abs(accumulated.y) > abs(accumulated.x)
                            }
                            if (dismissing) {
                                dismiss.drag(pan.y)
                                event.changes.forEach { if (it.positionChanged()) it.consume() }
                            }
                        }
                    }
                    if (dismissing) dismiss.release()
                }
            }
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
                translationX = offset.x
                translationY = offset.y
            },
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

private val Offset.isSpecified: Boolean get() = this != Offset.Unspecified
