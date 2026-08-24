package ca.lucianlabs.housepour

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntRect
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupPositionProvider
import androidx.compose.ui.window.PopupProperties

/**
 * The kebab: a vertical three-dot button. Ghost styling — no fill, no border — with the dots drawn from tokens
 * (three `faint` circles, never a glyph or an icon font), a `touchMin` hit target, and the ghost button's own
 * press behaviour: colour to ink over `Motion.color`, 1pt translate over `Motion.press`.
 */
@Composable
fun HPKebabButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    contentDescription: String = "More",
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val dotColor by animateColorAsState(
        targetValue = if (pressed) HPTokens.Colors.ink else HPTokens.Colors.faint,
        animationSpec = tween(HPTokens.Motion.COLOR_MS),
        label = "kebab",
    )
    val translate by animateDpAsState(
        targetValue = if (pressed) HPTokens.Motion.pressTranslateY else 0.dp,
        animationSpec = tween(HPTokens.Motion.PRESS_MS),
        label = "press",
    )
    // COMPONENTS.md: a `kebabDot` (4) dot, `kebabDotGap` (3) apart — an 18pt column of dots inside the 40pt target.
    val dot = HPTokens.Space.kebabDot
    val step = dot + HPTokens.Space.kebabDotGap
    Box(
        modifier = modifier
            .offset(y = translate)
            .size(HPTokens.Space.touchMin)
            .clip(RoundedCornerShape(HPTokens.Radius.pill))
            .clickable(interactionSource = interaction, indication = null, role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.size(width = dot, height = dot + step * 2)) {
            val radius = size.width / 2f
            val stepPx = step.toPx()
            for (i in 0..2) drawCircle(dotColor, radius = radius, center = Offset(radius, radius + stepPx * i))
        }
    }
}

/**
 * A menu: the `panel` card at the card radius with the one card shadow, holding one [HPMenuItem] per action.
 *
 * Call it inside the `Box` that holds its button — on a regular width the card is a `Popup` anchored under that
 * button, right edges aligned, flipping above it when there is no room below. On a compact width (narrower than
 * `columnMax` — every phone) it is a bottom sheet over the `scrim` instead.
 *
 * Dismissal: a tap outside, the system back gesture, or — on the sheet — a swipe down. Nothing animates on
 * appear beyond the `Motion.toast` fade.
 */
@Composable
fun HPMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    // Kept mounted through the fade out, so the card does not vanish the frame it is dismissed.
    val visible = remember { MutableTransitionState(false) }
    visible.targetState = expanded
    if (!visible.currentState && !visible.targetState) return

    val compact = LocalConfiguration.current.screenWidthDp.dp < HPTokens.Space.columnMax
    if (compact) HPMenuSheet(visible, onDismissRequest, modifier, content)
    else HPMenuAnchored(visible, onDismissRequest, modifier, content)
}

/** One action in a menu: an `HPListItem` row, body text in ink (accent while pressed), `touchMin` minimum height. */
@Composable
fun HPMenuItem(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    isLast: Boolean = false,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val color by animateColorAsState(
        targetValue = if (pressed) HPTokens.Colors.accent else HPTokens.Colors.ink,
        animationSpec = tween(HPTokens.Motion.COLOR_MS),
        label = "menuItem",
    )
    HPListItem(
        modifier = modifier
            .clickable(interactionSource = interaction, indication = null, role = Role.Button, onClick = onClick)
            .defaultMinSize(minHeight = HPTokens.Space.touchMin)
            .semantics { contentDescription = label },
        isLast = isLast,
    ) {
        HPBody(label, color = color, maxLines = 1)
    }
}

/** The menu surface itself: `panel`, card radius, 1pt `line`, the one card shadow. */
@Composable
private fun HPMenuCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(HPTokens.Radius.card)
    Column(
        modifier = modifier
            .widthIn(min = HPTokens.Space.menuWidth, max = HPTokens.Space.columnMax)
            .hpShadow(HPTokens.Radius.card, HPTokens.Shadow.contact, HPTokens.Shadow.cast)
            .clip(shape)
            .background(HPTokens.Colors.panel, shape)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, shape)
            .padding(horizontal = HPTokens.Space.cardPad, vertical = HPTokens.Space.rowGap),
        content = content,
    )
}

@Composable
private fun HPMenuAnchored(
    visible: MutableTransitionState<Boolean>,
    onDismissRequest: () -> Unit,
    modifier: Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val gap = with(LocalDensity.current) { HPTokens.Space.rowGap.roundToPx() }
    val provider = remember(gap) { HPMenuPositionProvider(gap) }
    Popup(
        popupPositionProvider = provider,
        onDismissRequest = onDismissRequest,
        properties = PopupProperties(focusable = true),
    ) {
        AnimatedVisibility(
            visibleState = visible,
            enter = fadeIn(tween(HPTokens.Motion.TOAST_MS)),
            exit = fadeOut(tween(HPTokens.Motion.TOAST_MS)),
        ) {
            HPMenuCard(modifier, content)
        }
    }
}

@Composable
private fun HPMenuSheet(
    visible: MutableTransitionState<Boolean>,
    onDismissRequest: () -> Unit,
    modifier: Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    // A swipe past `menuDismissDrag` (one hit target) dismisses; the card itself never moves (no transforms in the look).
    val threshold = with(LocalDensity.current) { HPTokens.Space.menuDismissDrag.toPx() }
    val dragged = remember { mutableFloatStateOf(0f) }
    Popup(
        popupPositionProvider = HPMenuSheetPositionProvider,
        onDismissRequest = onDismissRequest,
        properties = PopupProperties(focusable = true),
    ) {
        AnimatedVisibility(
            visibleState = visible,
            enter = fadeIn(tween(HPTokens.Motion.TOAST_MS)),
            exit = fadeOut(tween(HPTokens.Motion.TOAST_MS)),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(HPTokens.Colors.scrim)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismissRequest)
                    .systemBarsPadding(),
                contentAlignment = Alignment.BottomCenter,
            ) {
                HPMenuCard(
                    modifier
                        .padding(HPTokens.Space.columnSide)
                        .fillMaxWidth()
                        .pointerInput(threshold) {
                            detectVerticalDragGestures(
                                onDragStart = { dragged.floatValue = 0f },
                                onDragEnd = { if (dragged.floatValue > threshold) onDismissRequest() },
                                onDragCancel = { dragged.floatValue = 0f },
                            ) { change, dy ->
                                change.consume()
                                dragged.floatValue += dy
                            }
                        }
                        .pointerInput(Unit) { detectTapGestures { } },
                    content,
                )
            }
        }
    }
}

/** Under the button, right edges aligned; above it when the card would fall off the bottom. */
private class HPMenuPositionProvider(private val gap: Int) : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset {
        val maxX = (windowSize.width - popupContentSize.width).coerceAtLeast(0)
        val x = (anchorBounds.right - popupContentSize.width).coerceIn(0, maxX)
        val below = anchorBounds.bottom + gap
        val y = if (below + popupContentSize.height <= windowSize.height) below
        else (anchorBounds.top - gap - popupContentSize.height).coerceAtLeast(0)
        return IntOffset(x, y)
    }
}

/** The sheet covers the window; the scrim inside it does the rest. */
private object HPMenuSheetPositionProvider : PopupPositionProvider {
    override fun calculatePosition(
        anchorBounds: IntRect,
        windowSize: IntSize,
        layoutDirection: LayoutDirection,
        popupContentSize: IntSize,
    ): IntOffset = IntOffset.Zero
}
