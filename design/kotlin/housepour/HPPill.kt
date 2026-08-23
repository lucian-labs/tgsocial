package ca.lucianlabs.housepour

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

enum class HPPillTone { NEUTRAL, GOLD, BAD }

/** `neutral`: muted on bg2 / line2 border. `gold`: accent on accentSoft / accent 35%. `bad`: bad on bad 6% / bad 45%. */
@Composable
fun HPPill(text: String, tone: HPPillTone = HPPillTone.NEUTRAL, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(HPTokens.Radius.pill)
    val (fill, border, color) = when (tone) {
        HPPillTone.NEUTRAL -> Triple(HPTokens.Colors.bg2, HPTokens.Colors.line2, HPTokens.Colors.muted)
        HPPillTone.GOLD -> Triple(HPTokens.Colors.accentSoft, HPTokens.Colors.accent.copy(alpha = 0.35f), HPTokens.Colors.accent)
        HPPillTone.BAD -> Triple(HPTokens.Colors.bad.copy(alpha = 0.06f), HPTokens.Colors.bad.copy(alpha = 0.45f), HPTokens.Colors.bad)
    }
    HPText(
        text = text,
        style = HPTokens.Type.pill,
        color = color,
        modifier = modifier
            .background(fill, shape)
            .border(HPTokens.BORDER_WIDTH.dp, border, shape)
            .padding(horizontal = HPTokens.Space.pillX, vertical = HPTokens.Space.pillY),
        maxLines = 1,
    )
}
