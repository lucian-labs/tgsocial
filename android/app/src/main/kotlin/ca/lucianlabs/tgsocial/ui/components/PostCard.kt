package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.ui.media.MediaItems

/**
 * PRODUCT §2.3 — the post card. The title opens the feed's channel screen; the text and the comments count open
 * the thread (§2.12); media opens in the app (§2.11); `Open in Telegram` remains the one hand-off.
 */
@Composable
fun PostCard(
    post: Post,
    commentCount: Int,
    onOpenChannel: (String) -> Unit,
    onOpenThread: () -> Unit,
    onComment: () -> Unit,
    onOpenViewer: (Int) -> Unit,
) {
    val context = LocalContext.current
    val link = remember(post.key) { DeepLink.post(post.sourceUsername, post.messageId) }
    val avatar = rememberTdImage(post.sourcePhoto, HPTokens.Space.avatarRow)
    val openTelegram = { openLink(context, link) }
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
        if (post.forwardedFrom != null) {
            HPMuted("Forwarded from ${post.forwardedFrom}", maxLines = 1)
            Spacer(Modifier.height(HPTokens.Space.labelBottom))
        }
        if (post.text != null) {
            // Tapping the text opens the thread (PRODUCT §2.3).
            RichText(
                post.text,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onOpenThread)
                    .semantics { contentDescription = "Open thread" },
            )
        }
        if (post.media.isNotEmpty() || post.linkPreview != null) {
            if (post.text != null) Spacer(Modifier.height(HPTokens.Space.rowGap))
            MediaItems(post, onOpenViewer)
        }
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        val parts = ArrayList<String>()
        if (post.views > 0) parts += "${Format.compact(post.views)} views"
        for (r in post.reactions) parts += "${r.emoji} ${Format.compact(r.count)}"
        parts += if (commentCount == 1) "1 comment" else "$commentCount comments"
        // Footer counts: mono faint; the comments count is tappable and opens the thread (§2.12).
        Box(
            modifier = Modifier
                .defaultMinSize(minHeight = HPTokens.Space.touchMin)
                .fillMaxWidth()
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onOpenThread)
                .semantics { contentDescription = "Comments" },
            contentAlignment = Alignment.CenterStart,
        ) {
            HPMonoSmall(parts.joinToString(" · "), color = HPTokens.Colors.faint, maxLines = 1)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            HPButton("Comment", onComment, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
            HPButton("Open in Telegram", openTelegram, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
        }
    }
}
