package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
 * PRODUCT §2.3 — the post card. The header **name** is the attribution NODE (the person the post reaches you
 * through) and the channel is the mono subheading, but the header **avatar is the source channel** — see
 * [PostHeading] for the fallback chain and [PostHeader] for the metrics. Time is relative, with Share right of
 * it. The footer is counts + `( Comment )` only — Views and `Open in Telegram` live in the long-press post
 * sheet now.
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
    // Attribution (PRODUCT §2.3): the name is the node when one attributes the post, else the channel with no
    // subheading — but the avatar is always the source channel, falling back to the node's photo then the initial.
    val heading = remember(post) { PostHeading.of(post) }
    val avatar = rememberTdImage(heading.photo, HPTokens.Space.avatarRow)
    val openHeader = {
        val node = heading.nodeUsername
        if (node != null) onOpenProfile(node) else onOpenChannel(post.sourceUsername)
    }
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
        PostHeader(
            avatar = avatar,
            name = heading.name,
            initial = heading.initial,
            channelTitle = heading.channelTitle,
            time = timeText,
            onOpenName = openHeader,
            onOpenChannel = { onOpenChannel(post.sourceUsername) },
            onShare = { shareLink(context, link) },
        )
        // Not `rowGap`: the channel subheading's hit target hangs below its line box and the first clickable
        // sibling must not start inside it, or it wins those points and the channel ships under `touchMin`
        // (COMPONENTS rule 6 tiling — see [PostHeaderBottomGap] and `PostCardHitRegionTest`).
        Spacer(Modifier.height(PostHeaderBottomGap))
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
