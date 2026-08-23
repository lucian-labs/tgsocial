package ca.lucianlabs.housepour

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

enum class HPButtonStyle { PRIMARY, ACCENT, NEUTRAL, GHOST, DANGER }
enum class HPButtonSize { REGULAR, SMALL }

private val primaryGradient = HPAngledGradient(listOf(HPTokens.Colors.primaryGradientStart, HPTokens.Colors.primaryGradientEnd), 135.0)
private val charcoalGradient = HPAngledGradient(listOf(HPTokens.Colors.charcoalGradientStart, HPTokens.Colors.charcoalGradientEnd), 150.0)

/**
 * Pill button. Full width by default; `SMALL` hugs content. One `PRIMARY` per screen.
 * Pressed: 1pt translate over `Motion.press`. Disabled: 45% opacity.
 */
@Composable
fun HPButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    style: HPButtonStyle = HPButtonStyle.NEUTRAL,
    size: HPButtonSize = HPButtonSize.REGULAR,
    enabled: Boolean = true,
    fullWidth: Boolean = size == HPButtonSize.REGULAR,
    contentDescription: String? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val translate by animateDpAsState(
        targetValue = if (pressed && enabled) HPTokens.Motion.pressTranslateY else 0.dp,
        animationSpec = tween(HPTokens.Motion.PRESS_MS),
        label = "press",
    )
    val shape = RoundedCornerShape(HPTokens.Radius.pill)
    val padY = if (size == HPButtonSize.SMALL) HPTokens.Space.buttonSmY else HPTokens.Space.buttonY
    val padX = if (size == HPButtonSize.SMALL) HPTokens.Space.buttonSmX else HPTokens.Space.buttonX
    val textStyle = if (size == HPButtonSize.SMALL) HPTokens.Type.buttonSm else HPTokens.Type.button

    val ghostColor by animateColorAsState(
        targetValue = if (pressed) HPTokens.Colors.ink else HPTokens.Colors.muted,
        animationSpec = tween(HPTokens.Motion.COLOR_MS),
        label = "ghost",
    )
    val textColor = when (style) {
        HPButtonStyle.PRIMARY -> HPTokens.Colors.primaryText
        HPButtonStyle.ACCENT -> HPTokens.Colors.charcoalText
        HPButtonStyle.NEUTRAL -> HPTokens.Colors.ink
        HPButtonStyle.GHOST -> ghostColor
        HPButtonStyle.DANGER -> HPTokens.Colors.bad
    }

    var m = modifier
        .offset(y = translate)
        .alpha(if (enabled) 1f else 0.45f)
    if (fullWidth) m = m.fillMaxWidth()
    m = when (style) {
        HPButtonStyle.PRIMARY -> m.hpShadow(HPTokens.Radius.pill, HPTokens.Shadow.primaryButton)
        HPButtonStyle.ACCENT -> m.hpShadow(HPTokens.Radius.pill, HPTokens.Shadow.charcoalButton)
        else -> m
    }
    m = m.clip(shape)
    m = when (style) {
        HPButtonStyle.PRIMARY -> m.background(primaryGradient, shape)
        HPButtonStyle.ACCENT -> m.background(charcoalGradient, shape)
        HPButtonStyle.NEUTRAL -> m.border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line2, shape)
        HPButtonStyle.GHOST -> m
        HPButtonStyle.DANGER -> m
            .background(HPTokens.Colors.bad.copy(alpha = 0.05f), shape)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.bad.copy(alpha = 0.40f), shape)
    }
    Box(
        modifier = m
            .clickable(interactionSource = interaction, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .defaultMinSize(minHeight = HPTokens.Space.touchMin, minWidth = HPTokens.Space.touchMin)
            .padding(horizontal = padX, vertical = padY)
            .semantics { if (contentDescription != null) this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        HPText(label, textStyle, textColor, maxLines = 1, textAlign = TextAlign.Center)
    }
}

/** Two buttons side by side with `btnRowGap`, equal widths. The only side-by-side layout in the look. */
@Composable
fun HPButtonRow(
    modifier: Modifier = Modifier,
    first: @Composable RowScope.(Modifier) -> Unit,
    second: @Composable RowScope.(Modifier) -> Unit,
) {
    Row(modifier = modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.btnRowGap), verticalAlignment = Alignment.CenterVertically) {
        first(Modifier.weight(1f))
        second(Modifier.weight(1f))
    }
}
