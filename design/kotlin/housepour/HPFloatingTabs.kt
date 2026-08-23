package ca.lucianlabs.housepour

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics

/**
 * PRODUCT §1 — the floating bottom tab bar: the `HPTabs` segmented control placed as an overlay at the bottom of
 * the column, centred, hugging its content, `cardGap` above the safe-area bottom, `panel` fill, 1pt `line`, pill
 * radius and the single card shadow so it reads as a raised pill over scrolling content. Content scrolls under it;
 * the host measures this bar and pads its lists by the bar height + `cardGap`.
 */
@Composable
fun HPFloatingTabs(
    items: List<String>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val nav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(bottom = nav + HPTokens.Space.cardGap)
            .padding(horizontal = HPTokens.Space.columnSide)
            .semantics { contentDescription = "Tabs" },
        contentAlignment = Alignment.BottomCenter,
    ) {
        HPTabs(
            items = items,
            selected = selected,
            onSelect = onSelect,
            fullWidth = false,
            fill = HPTokens.Colors.panel,
            raised = true,
        )
    }
}
