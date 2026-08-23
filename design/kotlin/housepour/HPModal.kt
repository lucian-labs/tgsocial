package ca.lucianlabs.housepour

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp

/** A card centred over the `scrim`, cast shadow deepened ×1.5, fading in `Motion.toast`. Never dark. */
@Composable
fun HPModal(
    isPresented: Boolean,
    onDismiss: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    AnimatedVisibility(
        visible = isPresented,
        enter = fadeIn(tween(HPTokens.Motion.TOAST_MS)),
        exit = fadeOut(tween(HPTokens.Motion.TOAST_MS)),
    ) {
        val shape = RoundedCornerShape(HPTokens.Radius.card)
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(HPTokens.Colors.scrim)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss)
                .systemBarsPadding()
                .imePadding(),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier = Modifier
                    .padding(HPTokens.Space.columnSide)
                    .widthIn(max = HPTokens.Space.columnMax)
                    .fillMaxWidth()
                    .hpShadow(HPTokens.Radius.card, HPTokens.Shadow.contact)
                    .hpShadow(HPTokens.Radius.card, HPTokens.Shadow.cast, alphaScale = 1.5f)
                    .clip(shape)
                    .background(HPTokens.Colors.panel, shape)
                    .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, shape)
                    .pointerInput(Unit) { detectTapGestures { } }
                    .verticalScroll(rememberScrollState())
                    .padding(HPTokens.Space.cardPad),
                content = content,
            )
        }
    }
}
