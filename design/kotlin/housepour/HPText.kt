package ca.lucianlabs.housepour

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** Base text view: one token style, one colour. Applies the style's uppercase rule. */
@Composable
fun HPText(
    text: String,
    style: HPTextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    maxLines: Int = Int.MAX_VALUE,
    overflow: TextOverflow = TextOverflow.Ellipsis,
    textAlign: TextAlign? = null,
) {
    val ts = style.toTextStyle(color)
    BasicText(
        text = style.text(text),
        modifier = modifier,
        style = if (textAlign != null) ts.copy(textAlign = textAlign) else ts,
        maxLines = maxLines,
        overflow = overflow,
    )
}

@Composable
fun HPText(
    text: AnnotatedString,
    style: HPTextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    maxLines: Int = Int.MAX_VALUE,
    overflow: TextOverflow = TextOverflow.Ellipsis,
) {
    BasicText(text = text, modifier = modifier, style = style.toTextStyle(color), maxLines = maxLines, overflow = overflow)
}

/** Brand face, never uppercase. `wordmark` (3rem) on Sign in, `brand` in the topbar. */
@Composable
fun HPWordmark(text: String = "tgsocial", modifier: Modifier = Modifier, large: Boolean = false) =
    HPText(text, if (large) HPTokens.Type.wordmark else HPTokens.Type.brand, HPTokens.Colors.ink, modifier, maxLines = 1)

@Composable
fun HPH1(text: String, modifier: Modifier = Modifier, textAlign: TextAlign? = null) =
    HPText(text, HPTokens.Type.h1, HPTokens.Colors.ink, modifier, textAlign = textAlign)

@Composable
fun HPH2(text: String, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE) =
    HPText(text, HPTokens.Type.h2, HPTokens.Colors.ink, modifier, maxLines = maxLines)

@Composable
fun HPBody(text: String, modifier: Modifier = Modifier, strong: Boolean = false, maxLines: Int = Int.MAX_VALUE, color: Color = HPTokens.Colors.ink) =
    HPText(text, if (strong) HPTokens.Type.bodyStrong else HPTokens.Type.body, color, modifier, maxLines = maxLines)

@Composable
fun HPMuted(text: String, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE, textAlign: TextAlign? = null) =
    HPText(text, HPTokens.Type.body, HPTokens.Colors.muted, modifier, maxLines = maxLines, textAlign = textAlign)

@Composable
fun HPSmall(text: String, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE, color: Color = HPTokens.Colors.muted) =
    HPText(text, HPTokens.Type.small, color, modifier, maxLines = maxLines)

@Composable
fun HPMono(text: String, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE, color: Color = HPTokens.Colors.muted) =
    HPText(text, HPTokens.Type.mono, color, modifier, maxLines = maxLines)

@Composable
fun HPMonoSmall(text: String, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE, color: Color = HPTokens.Colors.muted) =
    HPText(text, HPTokens.Type.monoSmall, color, modifier, maxLines = maxLines)

/** Lining numerals; the serif does the numbers. */
@Composable
fun HPFigure(text: String, modifier: Modifier = Modifier, color: Color = HPTokens.Colors.ink) =
    HPText(text, HPTokens.Type.figure, color, modifier, maxLines = 1)

@Composable
fun HPFieldLabel(text: String, modifier: Modifier = Modifier) =
    HPText(text, HPTokens.Type.fieldLabel, HPTokens.Colors.muted, modifier.padding(bottom = HPTokens.Space.labelBottom), maxLines = 1)

/**
 * Section mark: uppercase label, optional count set in the serif (`totals`, ink), then a trailing hairline
 * that fades `line2 → transparent`.
 */
@Composable
fun HPSectionMark(text: String, count: Int? = null, modifier: Modifier = Modifier, trailing: (@Composable () -> Unit)? = null) {
    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        HPText(text, HPTokens.Type.sectionMark, HPTokens.Colors.muted, maxLines = 1)
        if (count != null) {
            HPText(" · ", HPTokens.Type.sectionMark, HPTokens.Colors.muted, maxLines = 1)
            HPText(count.toString(), HPTokens.Type.totals, HPTokens.Colors.ink, maxLines = 1)
        }
        Spacer(Modifier.width(HPTokens.Space.rowGap))
        Spacer(
            Modifier
                .weight(1f)
                .height(HPTokens.BORDER_WIDTH.dp)
                .drawBehind {
                    drawRect(Brush.horizontalGradient(listOf(HPTokens.Colors.line2, Color.Transparent)))
                },
        )
        if (trailing != null) {
            Spacer(Modifier.width(HPTokens.Space.rowGap))
            trailing()
        }
    }
}
