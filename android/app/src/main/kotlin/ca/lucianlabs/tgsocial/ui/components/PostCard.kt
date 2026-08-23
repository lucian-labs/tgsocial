package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPMedia
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostMedia
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.Format

/** PRODUCT §2.3 — the post card. Title opens the channel; the body opens the post on Telegram. */
@Composable
fun PostCard(post: Post, onOpenChannel: (String) -> Unit) {
    val context = LocalContext.current
    val link = remember(post.key) { DeepLink.post(post.sourceUsername, post.messageId) }
    val avatar = rememberTdImage(post.sourcePhoto, HPTokens.Space.avatarRow)
    val openPost = { openLink(context, link) }
    HPCard {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
            HPAvatar(avatar, HPTokens.Space.avatarRow, post.sourceTitle.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·", contentDescription = post.sourceTitle)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) { onOpenChannel(post.sourceUsername) }
                    .semantics { contentDescription = "Open ${post.sourceTitle}" },
            ) {
                HPBody(post.sourceTitle, strong = true, maxLines = 1)
                HPMonoSmall("@${post.sourceUsername}", maxLines = 1)
            }
            HPMonoSmall(Format.time(post.date.toLong()), color = HPTokens.Colors.faint, maxLines = 1)
        }
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = openPost)
                .semantics { contentDescription = "Open post on Telegram" },
        ) {
            if (post.forwardedFrom != null) {
                HPMuted("Forwarded from ${post.forwardedFrom}", maxLines = 1)
                Spacer(Modifier.height(HPTokens.Space.labelBottom))
            }
            if (post.text != null) {
                RichText(post.text)
            }
            val media = post.media
            if (media != null) {
                if (post.text != null) Spacer(Modifier.height(HPTokens.Space.rowGap))
                Media(media)
            }
        }
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            val parts = ArrayList<String>()
            if (post.views > 0) parts += "${Format.compact(post.views)} views"
            for (r in post.reactions) parts += "${r.emoji} ${Format.compact(r.count)}"
            HPMonoSmall(parts.joinToString(" · "), color = HPTokens.Colors.faint, modifier = Modifier.weight(1f), maxLines = 1)
            HPButton("Open in Telegram", openPost, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
        }
    }
}

@Composable
private fun Media(media: PostMedia) {
    val width = LocalConfiguration.current.screenWidthDp.dp.coerceAtMost(HPTokens.Space.columnMax) - HPTokens.Space.columnSide * 2 - HPTokens.Space.cardPad * 2
    when (media) {
        is PostMedia.Photo -> {
            val image = rememberTdImage(media.file, width)
            HPMedia(image, aspect(media.width, media.height), contentDescription = "Photo")
        }
        is PostMedia.Video -> {
            val image = rememberTdImage(media.thumb, width)
            HPMedia(image, aspect(media.width, media.height), contentDescription = "Video") {
                Badge(Format.duration(media.durationSeconds))
            }
        }
        is PostMedia.Animation -> {
            val image = rememberTdImage(media.thumb, width)
            HPMedia(image, aspect(media.width, media.height), contentDescription = "Animation") { Badge("GIF") }
        }
        is PostMedia.Document -> Attachment("File", media.fileName)
        is PostMedia.Audio -> {
            val title = listOf(media.performer, media.title).filter { it.isNotBlank() }.joinToString(" — ").ifBlank { media.fileName }
            Attachment("Audio · ${Format.duration(media.durationSeconds)}", title)
        }
    }
}

private fun aspect(w: Int, h: Int): Float = if (w > 0 && h > 0) w.toFloat() / h.toFloat() else 16f / 9f

/** Duration / GIF mark over media: a neutral pill — the toast is the one dark surface (PRODUCT §1). */
@Composable
private fun Badge(text: String) {
    HPPill(text, HPPillTone.NEUTRAL, modifier = Modifier.padding(HPTokens.Space.rowGap))
}

@Composable
private fun Attachment(kind: String, name: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(HPTokens.Colors.bg2, RoundedCornerShape(HPTokens.Radius.media))
            .padding(HPTokens.Space.rowPad),
    ) {
        HPMonoSmall(kind, maxLines = 1)
        HPBody(name, maxLines = 2)
    }
}
