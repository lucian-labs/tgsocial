package ca.lucianlabs.housepour

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

private val backdropGradient = HPAngledGradient(listOf(HPTokens.Colors.backdropTop, HPTokens.Colors.backdropMid, HPTokens.Colors.backdropBottom), 165.0)

/** Page background: three-stop ivory gradient at 165° plus the gold wash (20%/-10%) and violet wash (90%/8%). Fixed. */
@Composable
fun HPBackdrop(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .drawBehind {
                drawRect(backdropGradient)
                val washRadius = size.width * 0.9f
                drawRect(
                    Brush.radialGradient(
                        colors = listOf(HPTokens.Colors.washGold, Color.Transparent),
                        center = Offset(size.width * 0.2f, -size.height * 0.1f),
                        radius = washRadius,
                    ),
                )
                drawRect(
                    Brush.radialGradient(
                        colors = listOf(HPTokens.Colors.washViolet, Color.Transparent),
                        center = Offset(size.width * 0.9f, size.height * 0.08f),
                        radius = washRadius,
                    ),
                )
            },
        content = content,
    )
}

/** The single column: max `columnMax`, side padding `columnSide`, bottom padding `bottomSafe`. */
@Composable
fun HPColumn(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    Box(modifier = modifier.fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
        Column(
            modifier = Modifier
                .widthIn(max = HPTokens.Space.columnMax)
                .fillMaxWidth()
                .padding(horizontal = HPTokens.Space.columnSide),
            content = content,
        )
    }
}

/** Content padding for a LazyColumn that plays the HPColumn role. */
@Composable
fun hpColumnContentPadding(top: Dp = 0.dp): PaddingValues {
    val nav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    return PaddingValues(
        start = HPTokens.Space.columnSide,
        end = HPTokens.Space.columnSide,
        top = top,
        bottom = HPTokens.Space.bottomSafe + nav,
    )
}

/** Width constraint for items inside a LazyColumn so they stay within the column. */
fun Modifier.hpColumnWidth(): Modifier = this.widthIn(max = HPTokens.Space.columnMax).fillMaxWidth()

/** `panel` fill, 1pt `line` border, card radius, cardPad padding, cardGap below, contact + cast shadow. */
@Composable
fun HPCard(
    modifier: Modifier = Modifier,
    gapBelow: Boolean = true,
    padding: PaddingValues = PaddingValues(HPTokens.Space.cardPad),
    content: @Composable ColumnScope.() -> Unit,
) {
    val shape = RoundedCornerShape(HPTokens.Radius.card)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(bottom = if (gapBelow) HPTokens.Space.cardGap else 0.dp)
            .hpShadow(HPTokens.Radius.card, HPTokens.Shadow.contact, HPTokens.Shadow.cast)
            .clip(shape)
            .background(HPTokens.Colors.panel, shape)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, shape)
            .padding(padding),
        content = content,
    )
}

/** A row inside a card: `rowPad` vertical, hairline `line` below except on the last row. */
@Composable
fun HPListItem(
    modifier: Modifier = Modifier,
    isLast: Boolean = false,
    trailing: (@Composable RowScope.() -> Unit)? = null,
    leading: @Composable RowScope.() -> Unit,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .drawBehind {
                if (!isLast) {
                    val y = size.height - HPTokens.BORDER_WIDTH.dp.toPx() / 2
                    drawLine(HPTokens.Colors.line, Offset(0f, y), Offset(size.width, y), HPTokens.BORDER_WIDTH.dp.toPx())
                }
            }
            .padding(vertical = HPTokens.Space.rowPad),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
    ) {
        leading()
        if (trailing != null) trailing()
    }
}

/**
 * Sticky, translucent topbar: wordmark or `‹ Back` leading, status pill trailing, hairline underneath. Meant to be
 * overlaid on the scroll container so content passes under `topbarBg`; it swallows touches in its own area so
 * nothing beneath it is tapped through the bar. Android has no cross-version backdrop blur — the bar is the
 * translucent fill without the blur(14) (platform exception, see COMPONENTS.md).
 */
@Composable
fun HPTopbar(
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
    leading: @Composable RowScope.() -> Unit,
) {
    val status = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(HPTokens.Colors.topbarBg)
            .pointerInput(Unit) { detectTapGestures { } }
            .drawBehind {
                val y = size.height - HPTokens.BORDER_WIDTH.dp.toPx() / 2
                drawLine(HPTokens.Colors.line, Offset(0f, y), Offset(size.width, y), HPTokens.BORDER_WIDTH.dp.toPx())
            }
            .padding(top = status),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier
                .widthIn(max = HPTokens.Space.columnMax)
                .fillMaxWidth()
                .padding(horizontal = HPTokens.Space.topbarX, vertical = HPTokens.Space.topbarY),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) { leading() }
            Row(verticalAlignment = Alignment.CenterVertically) { trailing() }
        }
    }
}
