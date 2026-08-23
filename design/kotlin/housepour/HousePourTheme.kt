package ca.lucianlabs.housepour

import android.content.Context
import android.os.Build
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

/** The three self-hosted faces plus the body sans. Body is the platform sans on Android (tokens.json `font.body.android`). */
class HPFonts(
    val display: FontFamily,
    val brand: FontFamily,
    val mono: FontFamily,
    val body: FontFamily,
) {
    fun family(face: HPFace): FontFamily = when (face) {
        HPFace.DISPLAY -> display
        HPFace.BRAND -> brand
        HPFace.MONO -> mono
        HPFace.BODY -> body
    }
}

val LocalHPFonts = staticCompositionLocalOf<HPFonts> { error("Wrap the tree in HousePourTheme") }

/** Font scale is respected but clamped at 1.4× so the layout holds (COMPONENTS rule 7). */
const val HP_MAX_FONT_SCALE = 1.4f

/** Resolves a `res/font` resource id by its HPTokens.FontRes name, keeping the kit free of the app's R class. */
fun interface HPFontResolver {
    fun resolve(name: String): Int?
}

fun contextFontResolver(context: Context): HPFontResolver = HPFontResolver { name ->
    val id = context.resources.getIdentifier(name, "font", context.packageName)
    if (id == 0) null else id
}

fun buildHPFonts(resolver: HPFontResolver): HPFonts {
    fun font(name: String, weight: Int, italic: Boolean = false): Font? {
        val id = resolver.resolve(name) ?: return null
        return Font(id, FontWeight(weight), if (italic) FontStyle.Italic else FontStyle.Normal)
    }
    fun family(vararg fonts: Font?, fallback: FontFamily): FontFamily {
        val present = fonts.filterNotNull()
        return if (present.isEmpty()) fallback else FontFamily(present)
    }
    return HPFonts(
        display = family(
            font(HPTokens.FontRes.CORMORANTGARAMONDMEDIUM, 500),
            font(HPTokens.FontRes.CORMORANTGARAMONDSEMIBOLD, 600),
            font(HPTokens.FontRes.CORMORANTGARAMONDBOLD, 700),
            font(HPTokens.FontRes.CORMORANTGARAMONDMEDIUMITALIC, 500, italic = true),
            fallback = FontFamily.Serif,
        ),
        brand = family(font(HPTokens.FontRes.KAUSHANSCRIPTREGULAR, 400), fallback = FontFamily.Cursive),
        mono = family(
            font(HPTokens.FontRes.INCONSOLATAREGULAR, 400),
            font(HPTokens.FontRes.INCONSOLATASEMIBOLD, 600),
            fallback = FontFamily.Monospace,
        ),
        body = FontFamily.SansSerif,
    )
}

@Composable
fun HousePourTheme(
    resolver: HPFontResolver? = null,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val fonts = remember(resolver, context) { buildHPFonts(resolver ?: contextFontResolver(context)) }
    val density = LocalDensity.current
    val clamped = remember(density) {
        if (density.fontScale > HP_MAX_FONT_SCALE) Density(density.density, HP_MAX_FONT_SCALE) else density
    }
    val selection = TextSelectionColors(handleColor = HPTokens.Colors.accent, backgroundColor = HPTokens.Colors.accentSoft)
    CompositionLocalProvider(
        LocalHPFonts provides fonts,
        LocalDensity provides clamped,
        LocalTextSelectionColors provides selection,
        content = content,
    )
}

/** Maps a token text style onto a Compose TextStyle. Uppercasing is applied by the text composables, not here. */
@Composable
fun HPTextStyle.toTextStyle(color: androidx.compose.ui.graphics.Color): TextStyle {
    val fonts = LocalHPFonts.current
    return remember(this, color, fonts) {
        TextStyle(
            color = color,
            fontFamily = fonts.family(face),
            fontSize = size.sp,
            fontWeight = FontWeight(weight),
            fontStyle = FontStyle.Normal,
            lineHeight = (size * lineHeight).sp,
            letterSpacing = tracking.em,
            lineHeightStyle = LineHeightStyle(LineHeightStyle.Alignment.Center, LineHeightStyle.Trim.None),
        )
    }
}

fun HPTextStyle.text(value: String): String = if (uppercase) value.uppercase() else value

internal val supportsBlurMask: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
