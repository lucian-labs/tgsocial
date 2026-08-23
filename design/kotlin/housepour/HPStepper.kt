package ca.lucianlabs.housepour

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/** Upstream stepper: two `touchMin` circles with a serif figure between. Not used in tgsocial v1; kept in the kit. */
@Composable
fun HPStepper(value: Int, onChange: (Int) -> Unit, modifier: Modifier = Modifier, min: Int = 0, max: Int = Int.MAX_VALUE) {
    Row(modifier = modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
        StepperCircle("−", "Decrease", enabled = value > min) { onChange(value - 1) }
        HPText(value.toString(), HPTokens.Type.totalsAmount, HPTokens.Colors.ink, maxLines = 1)
        StepperCircle("+", "Increase", enabled = value < max) { onChange(value + 1) }
    }
}

@Composable
private fun StepperCircle(glyph: String, label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(HPTokens.Space.touchMin)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line2, CircleShape)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        HPText(glyph, HPTokens.Type.bodyStrong, if (enabled) HPTokens.Colors.ink else HPTokens.Colors.faint, maxLines = 1)
    }
}
