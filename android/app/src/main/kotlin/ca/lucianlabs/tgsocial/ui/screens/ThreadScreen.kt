package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.model.CommentNode
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.PostCard
import ca.lucianlabs.tgsocial.ui.components.RichText
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage
import ca.lucianlabs.tgsocial.ui.media.MediaItems

/** PRODUCT §2.12 — depth beyond this renders flat. */
private const val MAX_DEPTH = 5

/**
 * PRODUCT §2.12 — the thread screen: the post at the top (full card, media playable), then the indented reply
 * tree, then the screen's one gold action.
 */
fun LazyListScope.ThreadItems(vm: AppViewModel, post: Post) {
    item(key = "thread-post") {
        val index by vm.commentIndex.collectAsStateWithLifecycle()
        Box(Modifier.columnItem()) {
            PostCard(
                post = post,
                commentCount = vm.commentCount(post, index),
                onOpenChannel = { vm.push(Screen.FeedChannel(it)) },
                onOpenThread = {},
                onComment = { vm.openSheet(Sheet.CommentComposer(vm.targetForPost(post))) },
                onOpenViewer = { vm.openViewer(post, it) },
            )
        }
    }
    item(key = "thread-mark") {
        val index by vm.commentIndex.collectAsStateWithLifecycle()
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) {
            HPSectionMark("Comments", vm.commentCount(post, index))
        }
    }
    item(key = "thread-comments") {
        val index by vm.commentIndex.collectAsStateWithLifecycle()
        val tree = vm.commentTree(post, index)
        Box(Modifier.columnItem()) {
            if (tree.isEmpty()) {
                HPMuted("No comments from your network yet.")
            } else {
                HPCard {
                    tree.forEachIndexed { i, node ->
                        CommentBlock(vm, node, depth = 0, isLastRoot = i == tree.lastIndex)
                    }
                }
            }
        }
    }
    item(key = "thread-comment-btn") {
        Box(Modifier.columnItem().padding(top = HPTokens.Space.rowGap)) {
            HPButton("Comment", { vm.openSheet(Sheet.CommentComposer(vm.targetForPost(post))) }, style = HPButtonStyle.PRIMARY)
        }
    }
}

@Composable
private fun CommentBlock(vm: AppViewModel, node: CommentNode, depth: Int, isLastRoot: Boolean) {
    CommentRow(vm, node.comment, depth, replyCount = node.replies.sumOf { it.count })
    // Replies indent one level; depth caps at MAX_DEPTH and deeper replies render flat (§2.12).
    node.replies.forEach { child ->
        CommentBlock(vm, child, depth = (depth + 1).coerceAtMost(MAX_DEPTH), isLastRoot = true)
    }
    if (!isLastRoot) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(HPTokens.BORDER_WIDTH.dp)
                .drawBehind { drawRect(HPTokens.Colors.line) },
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CommentRow(vm: AppViewModel, comment: Comment, depth: Int, replyCount: Int) {
    // One level of indent is 12pt with a hairline gutter in `line` (§2.12).
    val step = HPTokens.Space.inputBottom
    val indent = step * depth
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = indent)
            .drawBehind {
                if (depth > 0) {
                    val x = -step.toPx() / 2
                    drawLine(HPTokens.Colors.line, Offset(x, 0f), Offset(x, size.height), HPTokens.BORDER_WIDTH.dp.toPx())
                }
            }
            .combinedClickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = {},
                onLongClick = { if (comment.own && !comment.pending) vm.openSheet(Sheet.DeleteComment(comment)) },
            )
            .padding(vertical = HPTokens.Space.rowGap)
            .semantics { contentDescription = "Comment by ${comment.authorName}" },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
            val avatar = rememberTdImage(comment.authorPhoto, HPTokens.Space.avatarRow)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
                modifier = Modifier
                    .weight(1f)
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                        vm.push(Screen.Profile(comment.authorUsername))
                    }
                    .semantics { contentDescription = "Open @${comment.authorUsername}" },
            ) {
                HPAvatar(avatar, HPTokens.Space.avatarRow, comment.authorName.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·", contentDescription = comment.authorName)
                HPBody(comment.authorName, strong = true, maxLines = 1)
                if (comment.plusOne) HPPill("+1", HPPillTone.NEUTRAL)
            }
            HPMonoSmall(Format.time(comment.date.toLong()), color = HPTokens.Colors.faint, maxLines = 1)
        }
        Spacer(Modifier.height(HPTokens.Space.labelBottom))
        val body = comment.post.text
        if (body != null) RichText(body)
        if (comment.post.media.isNotEmpty() || comment.post.linkPreview != null) {
            if (body != null) Spacer(Modifier.height(HPTokens.Space.labelBottom))
            MediaItems(comment.post) { vm.openViewer(comment.post, it) }
        }
        Spacer(Modifier.height(HPTokens.Space.labelBottom))
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (comment.pending) {
                HPMonoSmall("Posting…", color = HPTokens.Colors.faint, maxLines = 1)
            } else {
                if (replyCount > 0) {
                    HPMonoSmall(if (replyCount == 1) "1 reply" else "$replyCount replies", color = HPTokens.Colors.faint, maxLines = 1)
                    HPMonoSmall(" · ", color = HPTokens.Colors.faint, maxLines = 1)
                }
                // Deleting your own comment is the long-press on the row (§2.12: swipe / long-press → Delete).
                HPButton("Reply", { vm.openSheet(Sheet.CommentComposer(vm.targetForComment(comment))) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
            }
        }
    }
}
