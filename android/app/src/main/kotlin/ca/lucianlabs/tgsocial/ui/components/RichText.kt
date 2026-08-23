package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.sp
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.LocalHPFonts
import ca.lucianlabs.tgsocial.model.PostText
import ca.lucianlabs.tgsocial.protocol.DeepLink

/**
 * COMPONENTS — text entities: bold → bodyStrong weight, italic → body italic, code → mono,
 * link/mention/url → accent underlined. Everything else is plain.
 */
@Composable
fun RichText(text: PostText, modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE) {
    val fonts = LocalHPFonts.current
    val context = LocalContext.current
    val annotated: AnnotatedString = remember(text, fonts) {
        val link = TextLinkStyles(style = SpanStyle(color = HPTokens.Colors.accent, textDecoration = TextDecoration.Underline))
        buildAnnotatedString {
            append(text.text)
            val n = text.text.length
            for (run in text.runs) {
                val start = run.start.coerceIn(0, n)
                val end = run.end.coerceIn(start, n)
                if (end <= start) continue
                when (run.kind) {
                    "bold" -> addStyle(SpanStyle(fontWeight = FontWeight(HPTokens.Type.bodyStrong.weight)), start, end)
                    "italic" -> addStyle(SpanStyle(fontStyle = FontStyle.Italic), start, end)
                    "code" -> addStyle(SpanStyle(fontFamily = fonts.mono, fontSize = HPTokens.Type.mono.size.sp, color = HPTokens.Colors.muted), start, end)
                    "url" -> addLink(LinkAnnotation.Url(text.text.substring(start, end), link) { openLink(context, (it as LinkAnnotation.Url).url) }, start, end)
                    "email" -> addLink(LinkAnnotation.Url("mailto:" + text.text.substring(start, end), link) { openLink(context, (it as LinkAnnotation.Url).url) }, start, end)
                    "link" -> run.url?.let { url -> addLink(LinkAnnotation.Url(url, link) { openLink(context, (it as LinkAnnotation.Url).url) }, start, end) }
                    "mention" -> {
                        val handle = text.text.substring(start, end).removePrefix("@")
                        addLink(LinkAnnotation.Url(DeepLink.channel(handle), link) { openLink(context, (it as LinkAnnotation.Url).url) }, start, end)
                    }
                }
            }
        }
    }
    HPText(annotated, HPTokens.Type.body, HPTokens.Colors.ink, modifier, maxLines = maxLines)
}
