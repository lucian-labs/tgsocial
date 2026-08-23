package ca.lucianlabs.housepour

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/** The segmented control. `bg2` track, `line` border, pill radius; selected item is a `panel` pill with a contact shadow. */
@Composable
fun HPTabs(
    items: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(HPTokens.Radius.pill)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(HPTokens.Colors.bg2, shape)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, shape)
            .padding(HPTokens.Space.tabsPad),
        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.tabsGap),
    ) {
        items.forEachIndexed { index, label ->
            val isSelected = index == selected
            val fill by animateColorAsState(
                targetValue = if (isSelected) HPTokens.Colors.panel else HPTokens.Colors.panel.copy(alpha = 0f),
                animationSpec = tween(HPTokens.Motion.COLOR_MS),
                label = "tabFill",
            )
            val text by animateColorAsState(
                targetValue = if (isSelected) HPTokens.Colors.ink else HPTokens.Colors.muted,
                animationSpec = tween(HPTokens.Motion.COLOR_MS),
                label = "tabText",
            )
            val interaction = remember { MutableInteractionSource() }
            var m = Modifier
                .weight(1f)
            if (isSelected) {
                m = m.hpShadow(HPTokens.Radius.pill, HPShadow(HPTokens.Colors.ink.copy(alpha = 0.12f), 0.dp, 1.dp, 3.dp, 0.dp))
            }
            Box(
                modifier = m
                    .clip(shape)
                    .background(fill, shape)
                    .then(if (isSelected) Modifier.border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, shape) else Modifier)
                    .selectable(selected = isSelected, interactionSource = interaction, indication = null, role = Role.Tab) { onSelect(index) }
                    .defaultMinSize(minHeight = HPTokens.Space.touchMin)
                    .padding(horizontal = HPTokens.Space.tabX, vertical = HPTokens.Space.tabY),
                contentAlignment = Alignment.Center,
            ) {
                HPText(label, HPTokens.Type.tab, text, maxLines = 1, textAlign = TextAlign.Center)
            }
        }
    }
}
