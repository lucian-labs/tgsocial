package ca.lucianlabs.housepour

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Play (triangle) or pause (two bars) drawn as hairline-free solid glyphs in [color]; no icon font, no emoji. */
@Composable
fun HPPlayGlyph(playing: Boolean, color: Color, modifier: Modifier = Modifier, size: Dp = 14.dp) {
    Box(
        modifier = modifier.size(size).drawBehind {
            if (playing) {
                val w = this.size.width * 0.28f
                val gap = this.size.width * 0.16f
                val x0 = (this.size.width - (w * 2 + gap)) / 2
                drawRect(color, Offset(x0, 0f), Size(w, this.size.height))
                drawRect(color, Offset(x0 + w + gap, 0f), Size(w, this.size.height))
            } else {
                val path = Path().apply {
                    val x0 = this@drawBehind.size.width * 0.18f
                    moveTo(x0, 0f)
                    lineTo(this@drawBehind.size.width, this@drawBehind.size.height / 2)
                    lineTo(x0, this@drawBehind.size.height)
                    close()
                }
                drawPath(path, color)
            }
        },
    )
}

/**
 * The 40pt play/pause circle in the stepper style: 1pt `line2` ring on `panel`, ink glyph. [raised] adds the
 * contact shadow (used over media posters). [dark] inverts for the ink viewer.
 */
@Composable
fun HPPlayCircle(
    playing: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    raised: Boolean = false,
    dark: Boolean = false,
    label: String = if (playing) "Pause" else "Play",
) {
    var m = modifier.size(HPTokens.Space.touchMin)
    if (raised) m = m.hpShadow(HPTokens.Space.touchMin / 2, HPTokens.Shadow.contact)
    val fill = if (dark) HPTokens.Colors.toastBg else HPTokens.Colors.panel
    val ring = if (dark) HPTokens.Colors.toastLine else HPTokens.Colors.line2
    val glyph = if (dark) HPTokens.Colors.charcoalText else if (enabled) HPTokens.Colors.ink else HPTokens.Colors.faint
    Box(
        modifier = m
            .background(fill, CircleShape)
            .border(HPTokens.BORDER_WIDTH.dp, ring, CircleShape)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, enabled = enabled, role = Role.Button, onClick = onToggle)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        HPPlayGlyph(playing, glyph)
    }
}

/** Serif time figures (`totals` style): the serif does the numbers (PRODUCT §2.11). */
@Composable
fun HPTime(text: String, modifier: Modifier = Modifier, color: Color = HPTokens.Colors.ink) =
    HPText(text, HPTokens.Type.totals, color, modifier, maxLines = 1)

/**
 * PRODUCT §2.11 — the audio / voice player row: play-pause circle 40pt, title (body) + subtitle (mono), serif
 * elapsed / total, and below them either the hairline scrubber (audio) or the waveform (voice). Sits on `bg2`
 * with the media radius like the other attachment rows. [progressOverlay] draws determinate download progress
 * (0–1) under the title while the file is fetched; null when nothing is downloading.
 */
@Composable
fun HPPlayerRow(
    title: String,
    subtitle: String?,
    playing: Boolean,
    progress: Float,
    elapsed: String,
    total: String,
    onToggle: () -> Unit,
    onSeek: (Float) -> Unit,
    modifier: Modifier = Modifier,
    waveform: List<Float>? = null,
    downloadProgress: Float? = null,
    enabled: Boolean = true,
) {
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(HPTokens.Colors.bg2, shape)
            .padding(HPTokens.Space.rowPad),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
            HPPlayCircle(playing, onToggle, enabled = enabled)
            Column(Modifier.weight(1f)) {
                HPBody(title, maxLines = 1)
                if (!subtitle.isNullOrBlank()) HPMonoSmall(subtitle, maxLines = 1)
            }
            Row(verticalAlignment = Alignment.Bottom) {
                HPTime(elapsed)
                HPText(" / ", HPTokens.Type.monoSmall, HPTokens.Colors.faint, maxLines = 1)
                HPTime(total, color = HPTokens.Colors.muted)
            }
        }
        if (downloadProgress != null) {
            Spacer(Modifier.height(HPTokens.Space.labelBottom))
            HPProgressBar(downloadProgress)
        }
        Spacer(Modifier.height(HPTokens.Space.labelBottom))
        if (waveform != null) {
            HPWaveform(waveform, progress, onSeek, enabled = enabled)
        } else {
            HPScrubber(progress, onSeek, enabled = enabled)
        }
    }
}

/**
 * PRODUCT §2.11 — the slim now-playing row docked above the floating tab bar while audio plays: title, play/pause,
 * elapsed in the serif, and a ghost `Stop`. A raised `panel` pill like the bar it sits on.
 */
@Composable
fun HPNowPlaying(
    title: String,
    playing: Boolean,
    elapsed: String,
    onToggle: () -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(HPTokens.Radius.pill)
    Row(
        modifier = modifier
            .widthInColumn()
            .hpShadow(HPTokens.Radius.pill, HPTokens.Shadow.contact, HPTokens.Shadow.cast)
            .background(HPTokens.Colors.panel, shape)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, shape)
            .padding(start = HPTokens.Space.tabsPad, end = HPTokens.Space.rowGap, top = HPTokens.Space.tabsPad, bottom = HPTokens.Space.tabsPad)
            .semantics { contentDescription = "Now playing" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
    ) {
        HPPlayCircle(playing, onToggle)
        HPBody(title, Modifier.weight(1f), strong = true, maxLines = 1)
        HPTime(elapsed, color = HPTokens.Colors.muted)
        Spacer(Modifier.width(HPTokens.Space.tabsGap))
        HPButton("Stop", onStop, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
    }
}

private fun Modifier.widthInColumn(): Modifier = this.hpColumnWidth()
