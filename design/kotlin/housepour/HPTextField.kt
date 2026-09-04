package ca.lucianlabs.housepour

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp

sealed class HPFieldKind {
    data object Text : HPFieldKind()
    data object Phone : HPFieldKind()
    data object Number : HPFieldKind()
    data object Secure : HPFieldKind()
    data object Url : HPFieldKind()
    data object Username : HPFieldKind()

    /**
     * A username typed back verbatim (PRODUCT §2.21): mono face, no autocorrect, no
     * autocapitalisation. Autocorrect on a confirmation field is a keyboard arguing with the one
     * string the field exists to match.
     */
    data object Mono : HPFieldKind()
    data class Multiline(val rows: Int) : HPFieldKind()
}

/**
 * Label above, input with `inputBg`, 1pt `line2` border, input radius, `inputY/inputX` padding, `inputBottom` below.
 * Focus: `accent` border + 3pt `accentSoft` ring — the one ring in the look.
 */
@Composable
fun HPTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    label: String? = null,
    placeholder: String? = null,
    kind: HPFieldKind = HPFieldKind.Text,
    enabled: Boolean = true,
    imeAction: ImeAction = ImeAction.Done,
    onSubmit: (() -> Unit)? = null,
    gapBelow: Boolean = true,
    contentDescription: String? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val border by animateColorAsState(
        targetValue = if (focused) HPTokens.Colors.accent else HPTokens.Colors.line2,
        animationSpec = tween(HPTokens.Motion.COLOR_MS),
        label = "fieldBorder",
    )
    val ring by animateColorAsState(
        targetValue = if (focused) HPTokens.Colors.accentSoft else HPTokens.Colors.accentSoft.copy(alpha = 0f),
        animationSpec = tween(HPTokens.Motion.COLOR_MS),
        label = "fieldRing",
    )
    val shape = RoundedCornerShape(HPTokens.Radius.input)
    val faceStyle = if (kind == HPFieldKind.Mono) HPTokens.Type.mono else HPTokens.Type.input
    val textStyle = faceStyle.toTextStyle(HPTokens.Colors.ink)
    val keyboard = when (kind) {
        HPFieldKind.Phone -> KeyboardOptions(keyboardType = KeyboardType.Phone, imeAction = imeAction)
        HPFieldKind.Number -> KeyboardOptions(keyboardType = KeyboardType.NumberPassword, imeAction = imeAction)
        HPFieldKind.Secure -> KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = imeAction)
        HPFieldKind.Url -> KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = imeAction, capitalization = KeyboardCapitalization.None)
        HPFieldKind.Username, HPFieldKind.Mono -> KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = imeAction, capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false)
        is HPFieldKind.Multiline -> KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Default, capitalization = KeyboardCapitalization.Sentences)
        HPFieldKind.Text -> KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = imeAction, capitalization = KeyboardCapitalization.Sentences)
    }
    val rows = (kind as? HPFieldKind.Multiline)?.rows ?: 1
    val ringWidth = 3.dp
    Column(modifier = modifier.fillMaxWidth().padding(bottom = if (gapBelow) HPTokens.Space.inputBottom else 0.dp)) {
        if (label != null) HPFieldLabel(label)
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier
                .fillMaxWidth()
                .drawBehind {
                    val w = ringWidth.toPx()
                    drawRoundRect(
                        color = ring,
                        topLeft = Offset(-w, -w),
                        size = Size(size.width + 2 * w, size.height + 2 * w),
                        cornerRadius = CornerRadius(HPTokens.Radius.input.toPx() + w),
                        style = Stroke(w),
                    )
                }
                .background(HPTokens.Colors.inputBg, shape)
                .border(HPTokens.BORDER_WIDTH.dp, border, shape)
                .padding(horizontal = HPTokens.Space.inputX, vertical = HPTokens.Space.inputY)
                .semantics { if (contentDescription != null) this.contentDescription = contentDescription },
            enabled = enabled,
            textStyle = textStyle,
            cursorBrush = SolidColor(HPTokens.Colors.accent),
            singleLine = rows == 1,
            minLines = rows,
            maxLines = if (rows == 1) 1 else Int.MAX_VALUE,
            keyboardOptions = keyboard,
            keyboardActions = KeyboardActions(onAny = { if (onSubmit != null) onSubmit() else defaultKeyboardAction(imeAction) }),
            visualTransformation = if (kind == HPFieldKind.Secure) PasswordVisualTransformation() else VisualTransformation.None,
            interactionSource = interaction,
            decorationBox = { inner ->
                Box {
                    if (value.isEmpty() && placeholder != null) {
                        HPText(placeholder, faceStyle, HPTokens.Colors.faint, maxLines = 1)
                    }
                    inner()
                }
            },
        )
    }
}
