package ca.lucianlabs.housepour

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * Derived switch (there is none upstream): a 44×26 pill track — `bg2` + `line2` off, `accentSoft` + `accent` on —
 * with a 22pt `panel` knob carrying the contact shadow. Colour animates `Motion.color`.
 */
@Composable
fun HPToggle(
    isOn: Boolean,
    onToggle: (Boolean) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val trackW = 44.dp
    val trackH = 26.dp
    val knob = 22.dp
    val inset = (trackH - knob) / 2
    val fill by animateColorAsState(if (isOn) HPTokens.Colors.accentSoft else HPTokens.Colors.bg2, tween(HPTokens.Motion.COLOR_MS), label = "toggleFill")
    val border by animateColorAsState(if (isOn) HPTokens.Colors.accent else HPTokens.Colors.line2, tween(HPTokens.Motion.COLOR_MS), label = "toggleBorder")
    // The knob snaps: only colour animates (COMPONENTS rule 4 — no transforms except the 1pt press).
    val x = if (isOn) trackW - knob - inset else inset
    val shape = RoundedCornerShape(HPTokens.Radius.pill)
    val interaction = remember { MutableInteractionSource() }
    Box(
        modifier = modifier
            .defaultMinSize(minWidth = HPTokens.Space.touchMin, minHeight = HPTokens.Space.touchMin)
            .toggleable(value = isOn, interactionSource = interaction, indication = null, enabled = enabled, role = Role.Switch) { onToggle(it) }
            .semantics { contentDescription = label }
            .alpha(if (enabled) 1f else 0.45f),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .size(trackW, trackH)
                .background(fill, shape)
                .border(HPTokens.BORDER_WIDTH.dp, border, shape),
        ) {
            Box(
                modifier = Modifier
                    .offset(x = x, y = inset)
                    .size(knob)
                    .hpShadow(knob / 2, HPTokens.Shadow.contact)
                    .background(HPTokens.Colors.panel, CircleShape)
                    .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, CircleShape),
            )
        }
    }
}
