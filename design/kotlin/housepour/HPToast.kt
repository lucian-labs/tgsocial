package ca.lucianlabs.housepour

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

enum class HPToastTone { NEUTRAL, GOOD, BAD }

data class HPToastMessage(val text: String, val tone: HPToastTone = HPToastTone.NEUTRAL, val id: Long = System.nanoTime())

@Stable
class HPToastState {
    var current: HPToastMessage? by mutableStateOf(null)
        private set

    fun show(text: String, tone: HPToastTone = HPToastTone.NEUTRAL) {
        current = HPToastMessage(text, tone)
    }

    fun dismiss(id: Long) {
        if (current?.id == id) current = null
    }
}

@Composable
fun rememberHPToastState(): HPToastState = remember { HPToastState() }

const val HP_TOAST_AUTO_DISMISS_MS = 2800L

/** The one dark surface. Fixed bottom centre 26pt up; fades `Motion.toast`; never slides; auto-dismisses after 2.8 s. */
@Composable
fun BoxScope.HPToastHost(state: HPToastState) {
    val message = state.current
    LaunchedEffect(message?.id) {
        val id = message?.id ?: return@LaunchedEffect
        delay(HP_TOAST_AUTO_DISMISS_MS)
        state.dismiss(id)
    }
    var shown by remember { mutableStateOf<HPToastMessage?>(null) }
    if (message != null) shown = message
    val nav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    AnimatedVisibility(
        visible = message != null,
        modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 26.dp + nav).padding(horizontal = HPTokens.Space.columnSide),
        enter = fadeIn(tween(HPTokens.Motion.TOAST_MS)),
        exit = fadeOut(tween(HPTokens.Motion.TOAST_MS)),
    ) {
        val m = shown ?: return@AnimatedVisibility
        HPToast(m)
    }
}

@Composable
fun HPToast(message: HPToastMessage, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(HPTokens.Radius.pill)
    val line = when (message.tone) {
        HPToastTone.NEUTRAL -> HPTokens.Colors.toastLine
        HPToastTone.GOOD -> HPTokens.Colors.good
        HPToastTone.BAD -> HPTokens.Colors.bad
    }
    Box(
        modifier = modifier
            .widthIn(max = HPTokens.Space.columnMax)
            .hpShadow(HPTokens.Radius.pill, HPTokens.Shadow.toast)
            .background(HPTokens.Colors.toastBg, shape)
            .border(HPTokens.BORDER_WIDTH.dp, line, shape)
            .padding(horizontal = HPTokens.Space.buttonX, vertical = HPTokens.Space.inputY)
            .semantics { liveRegion = LiveRegionMode.Polite },
    ) {
        HPText(message.text, HPTokens.Type.toast, HPTokens.Colors.toastText, textAlign = TextAlign.Center)
    }
}
