package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBars
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HPViewerChrome
import ca.lucianlabs.tgsocial.demo.DemoCopy

/**
 * PRODUCT §2.22 item 2 — the three persistent indicators, none of them dismissible. This file is two of them;
 * the third is the fixtures naming themselves, which lives in the world rather than in the chrome.
 */

/**
 * The status pill's stand-in. Same shape, same 40 dp target, same "it is a button" — but it reads `Demo` and
 * it is **never gold**, because gold on that pill means a live Telegram connection (§1). It opens the demo
 * sheet (§2.22.5) in the status sheet's place.
 */
@Composable
fun DemoPill(onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .defaultMinSize(minHeight = HPTokens.Space.touchMin, minWidth = HPTokens.Space.touchMin)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = DemoCopy.PILL },
        contentAlignment = Alignment.Center,
    ) {
        HPPill(DemoCopy.PILL, HPPillTone.NEUTRAL)
    }
}

/**
 * The strip docked under the topbar and sticky with it: full column width, `bg2` fill, hairline `line` below,
 * mono small in `muted`. On every screen that has a topbar, which is every screen in the shell.
 */
@Composable
fun DemoStrip(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(HPTokens.Colors.bg2)
            .drawBehind {
                val y = size.height - HPTokens.BORDER_WIDTH.dp.toPx() / 2
                drawLine(HPTokens.Colors.line, Offset(0f, y), Offset(size.width, y), HPTokens.BORDER_WIDTH.dp.toPx())
            }
            .padding(horizontal = HPTokens.Space.columnSide, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        HPText(DemoCopy.STRIP, HPTokens.Type.monoSmall, HPTokens.Colors.muted, maxLines = 2, textAlign = TextAlign.Center)
    }
}

/**
 * The same sentence over a full-screen viewer, where the topbar is gone (§2.11). Drawn on the dark surface in
 * the same mono small, because an unmarked full-screen photo is exactly the screenshot that could be mistaken
 * for someone's real Telegram.
 */
@Composable
fun DemoViewerStrip(modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            // Under the viewer's own chrome row, not over it: `Close` and the action buttons keep their
            // 40 dp targets, and the sentence sits directly beneath them where the strip sits everywhere else.
            .padding(top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding() + HPViewerChrome.height)
            .background(Color(0x99000000))
            .padding(horizontal = HPTokens.Space.columnSide, vertical = 6.dp),
        contentAlignment = Alignment.Center,
    ) {
        HPText(DemoCopy.STRIP, HPTokens.Type.monoSmall, Color(0xCCFFFFFF), maxLines = 2, textAlign = TextAlign.Center)
    }
}
