package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import kotlinx.coroutines.delay

/**
 * PRODUCT §2.3 — the post card. The header is the attribution NODE (the person the post reaches you through);
 * the channel is the mono subheading. Time is relative, with Share right of it. The footer is counts +
 * `( Comment )` only — Views and `Open in Telegram` live in the long-press post sheet now.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PostCard(
    post: Post,
    commentCount: Int,
    onOpenChannel: (String) -> Unit,
    onOpenProfile: (String) -> Unit,
    onOpenThread: () -> Unit,
    onComment: () -> Unit,
    onOpenViewer: (Int) -> Unit,
    onLongPress: () -> Unit,
) {
    val context = LocalContext.current
    val link = remember(post.key) { DeepLink.post(post.sourceUsername, post.messageId) }
    // Attribution (PRODUCT §2.3): the node when one attributes the post; else the channel, with no subheading.
    val nodeUsername = post.nodeUsername
    val headerName = if (nodeUsername != null) post.nodeName ?: "@$nodeUsername" else post.sourceTitle
    val avatar = rememberTdImage(if (nodeUsername != null) post.nodePhoto else post.sourcePhoto, HPTokens.Space.avatarRow)
    val initial = headerName.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·"
    val openHeader = { if (nodeUsername != null) onOpenProfile(nodeUsername) else onOpenChannel(post.sourceUsername) }
    // Relative time re-derives on a minute ticker so an open feed never goes stale (PRODUCT §2.3: derive, never hand-format).
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(60_000); tick++ } }
    val timeText = remember(post.date, tick) { Format.relative(post.date.toLong()) }
    HPCard(
        // Long-press anywhere on the card face opens the post sheet; children (media, buttons) keep their own
        // gestures, so players still work.
        modifier = Modifier.combinedClickable(
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
            onClick = {},
            onLongClickLabel = "Post details",
            onLongClick = onLongPress,
        ),
    ) {
        Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
            HPAvatar(
                avatar,
                HPTokens.Space.avatarRow,
                initial,
                modifier = Modifier.clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = openHeader),
                contentDescription = headerName,
            )
            Column(modifier = Modifier.weight(1f)) {
                // The name is the node (tap → node profile); on fallback it is the channel title (tap → channel).
                HPBody(
                    headerName,
                    strong = true,
                    maxLines = 1,
                    modifier = Modifier
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = openHeader)
                        .semantics { contentDescription = "Open $headerName" },
                )
                if (nodeUsername != null) {
                    // Subheading = the channel title, mono small muted, tap → feed channel screen (§2.6).
                    HPMonoSmall(
                        post.sourceTitle,
                        maxLines = 1,
                        modifier = Modifier
                            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) { onOpenChannel(post.sourceUsername) }
                            .semantics { contentDescription = "Open ${post.sourceTitle}" },
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
                HPMonoSmall(timeText, color = HPTokens.Colors.faint, maxLines = 1)
                HPButton("Share", { shareLink(context, link) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Share")
            }
        }
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        if (post.forwardedFrom != null) {
            HPMuted("Forwarded from ${post.forwardedFrom}", maxLines = 1)
            Spacer(Modifier.height(HPTokens.Space.labelBottom))
        }
        if (post.text != null) {
            // Tapping the text opens the thread (PRODUCT §2.3); long-press opens the post sheet.
            RichText(
                post.text,
                modifier = Modifier
                    .fillMaxWidth()
                    .combinedClickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        role = Role.Button,
                        onClick = onOpenThread,
                        onLongClickLabel = "Post details",
                        onLongClick = onLongPress,
                    )
                    .semantics { contentDescription = "Open thread" },
            )
        }
        if (post.media.isNotEmpty() || post.linkPreview != null) {
            if (post.text != null) Spacer(Modifier.height(HPTokens.Space.rowGap))
            MediaItems(post, onOpenViewer)
        }
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        // Footer: `N reactions · N comments` mono faint left (tappable → thread), `( Comment )` ghost sm right.
        // Reactions render as the emoji + count when few, the summed count otherwise (§2.3). Views moved to the sheet.
        val parts = ArrayList<String>()
        if (post.reactions.isEmpty()) {
            parts += "0 reactions"
        } else if (post.reactions.size <= 2) {
            for (r in post.reactions) parts += "${r.emoji} ${Format.compact(r.count)}"
        } else {
            val total = post.reactions.sumOf { it.count.toLong() }
            parts += if (total == 1L) "1 reaction" else "${Format.compact(total)} reactions"
        }
        parts += if (commentCount == 1) "1 comment" else "$commentCount comments"
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap), modifier = Modifier.fillMaxWidth()) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .defaultMinSize(minHeight = HPTokens.Space.touchMin)
                    .combinedClickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        role = Role.Button,
                        onClick = onOpenThread,
                        onLongClickLabel = "Post details",
                        onLongClick = onLongPress,
                    )
                    .semantics { contentDescription = "Comments" },
                contentAlignment = Alignment.CenterStart,
            ) {
                HPMonoSmall(parts.joinToString(" · "), color = HPTokens.Colors.faint, maxLines = 1)
            }
            HPButton("Comment", onComment, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
        }
    }
}
