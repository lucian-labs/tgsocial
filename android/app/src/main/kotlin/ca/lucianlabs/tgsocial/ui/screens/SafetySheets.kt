package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonRow
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPFieldKind
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPListItem
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTextField
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.protocol.ReportEmail
import ca.lucianlabs.tgsocial.protocol.Replies
import ca.lucianlabs.tgsocial.protocol.ReportSubject
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.components.openInTelegram
import ca.lucianlabs.tgsocial.ui.components.openMail

/**
 * PRODUCT §2.15 — the report confirm. The sheet body is separated from the wiring because what is worth
 * asserting about it — a reason is single-select, and `Send Report` does not exist as an action until one is
 * picked — is a claim about this composable, not about TDLib.
 */
@Composable
fun ColumnScope.ReportSheet(vm: AppViewModel) {
    val context = LocalContext.current
    val report by vm.report.collectAsStateWithLifecycle()
    ReportSheetBody(
        isComment = report.subject?.isComment == true,
        selected = report.reason,
        canSend = report.canSend,
        onPick = vm::pickReportReason,
        onSend = {
            // §2.15 — the mail is the reader's to send or not; the hide happens either way.
            val mail = vm.reportMail()
            val opened = mail != null && openMail(context, mail.to, mail.subject, mail.body)
            vm.confirmReport(opened)
        },
        onCancel = vm::closeSheet,
    )
}

@Composable
fun ColumnScope.ReportSheetBody(
    isComment: Boolean,
    selected: String?,
    canSend: Boolean,
    onPick: (String) -> Unit,
    onSend: () -> Unit,
    onCancel: () -> Unit,
) {
    HPSectionMark("Report")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPH2(if (isComment) "Report this comment." else "Report this post.")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPMuted("This sends an email from your mail app to the person who maintains tgsocial, with a link to it. It disappears from this device as soon as you send.")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPSectionMark("Why")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
        // The seven reasons are the whole list on every platform, in this order: they are the email's subject
        // line verbatim (PRODUCT §2.15), so a reworded row would be a reworded inbox.
        ReportEmail.REASONS.forEachIndexed { i, reason ->
            ReasonRow(
                reason = reason,
                picked = reason == selected,
                isLast = i == ReportEmail.REASONS.lastIndex,
                onPick = { onPick(reason) },
            )
        }
    }
    HPButton("Send Report", onSend, style = HPButtonStyle.DANGER, enabled = canSend)
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPButton("Cancel", onCancel, style = HPButtonStyle.GHOST)
}

/** One reason: a 40pt row carrying the whole tap, with a gold check when it is the picked one. */
@Composable
private fun ReasonRow(reason: String, picked: Boolean, isLast: Boolean, onPick: () -> Unit) {
    HPListItem(
        modifier = Modifier
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.RadioButton, onClick = onPick)
            .defaultMinSize(minHeight = HPTokens.Space.touchMin)
            .semantics { contentDescription = reason; selected = picked },
        isLast = isLast,
        trailing = { if (picked) HPText("✓", HPTokens.Type.body, HPTokens.Colors.accent, maxLines = 1) },
    ) {
        HPBody(reason, Modifier.weight(1f), maxLines = 1)
    }
}

/**
 * PRODUCT §2.16 — the block confirm. It says what stops arriving and what does not happen: nobody is told,
 * because there is nowhere for a notification to come from.
 */
@Composable
fun ColumnScope.BlockSheet(vm: AppViewModel, username: String) {
    HPSectionMark("Block")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPH2("Block @$username?")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPMuted("Their posts and their comments disappear from your feed, your threads, your graph, and search. They are not told. Undo it in Settings.")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButtonRow(
        first = { m -> HPButton("Block", { vm.block(username) }, modifier = m, style = HPButtonStyle.DANGER) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST) },
    )
}

/**
 * PRODUCT §2.12 / §2.15 — the long-press comment sheet. No `Mute Feed` here: mute is about a channel's posts
 * and a comment is not one (§2.17). On your own comment the first row reads `Delete` instead of
 * `Report Comment`, and there is nobody to block.
 */
@Composable
fun ColumnScope.CommentSheet(vm: AppViewModel, comment: Comment) {
    val context = LocalContext.current
    HPSectionMark("Comment")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    StatusRow("Posted", Format.exact(comment.date.toLong()))
    StatusRow("From", "@${comment.authorUsername}")
    StatusRow("Channel", "@${comment.channelUsername}", isLast = true)
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButton("Open in Telegram", { openInTelegram(context, comment.link.ifEmpty { DeepLink.channel(comment.channelUsername) }) }, style = HPButtonStyle.NEUTRAL)
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPSectionMark("Safety")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    if (comment.own) {
        HPButton("Delete", { vm.openSheet(Sheet.DeleteComment(comment)) }, style = HPButtonStyle.DANGER, size = HPButtonSize.SMALL)
    } else {
        HPButton("Report Comment", { vm.openReport(ReportSubject.forComment(comment)) }, style = HPButtonStyle.DANGER, size = HPButtonSize.SMALL)
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPButton("Block @${comment.authorUsername}", { vm.openSheet(Sheet.Block(comment.authorUsername)) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
    }
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButton("Close", vm::closeSheet, style = HPButtonStyle.GHOST)
}

/**
 * PRODUCT §2.21 — Delete my node. Type-the-username rather than tap-to-confirm: this destroys two public
 * channels and releases their names, and a tap is not proportional to that.
 */
@Composable
fun ColumnScope.DeleteNodeSheet(vm: AppViewModel) {
    val context = LocalContext.current
    val state by vm.deleteNode.collectAsStateWithLifecycle()
    val node by vm.myNode.collectAsStateWithLifecycle()
    val me by vm.me.collectAsStateWithLifecycle()
    val username = node?.username ?: return
    // PRODUCT §2.21 / PROTOCOL §6.1 — the same judgement the delete itself makes (`Replies.target`), so the
    // sentence names exactly what is about to go. An unreadable card is not "no comments channel": promising
    // one channel and destroying two is the one direction this modal must never fail in.
    val replies = Replies.target(me?.card, username).username

    HPSectionMark("Delete my node")
    Spacer(Modifier.height(HPTokens.Space.rowGap))

    val message = state.message
    if (message != null) {
        HPMuted(message)
        Spacer(Modifier.height(HPTokens.Space.cardGap))
        val open = state.openUsername
        if (open != null) {
            // Not the owner: the answer is in Telegram, not in trying again.
            HPButton("Open in Telegram", { openInTelegram(context, DeepLink.channel(open)) }, style = HPButtonStyle.NEUTRAL)
        } else {
            HPButton("Try Again", vm::deleteMyNode, style = HPButtonStyle.DANGER)
        }
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPButton("Close", vm::closeSheet, style = HPButtonStyle.GHOST)
        return
    }

    HPH2("Delete my node.")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    // A card that parses and names no `replies:` is the one case where there is nothing to say about a
    // channel that was never made (§2.21), so the sentence names only what actually exists.
    HPMuted(
        if (replies != null) {
            "This deletes the channel @$username and your comments channel @$replies from Telegram. The public card other people read disappears, every post and comment in those two channels goes with it, and the names are released for anyone to take. This cannot be undone."
        } else {
            "This deletes the channel @$username from Telegram. The public card other people read disappears, every post and comment in that channel go with it, and the name is released for anyone to take. This cannot be undone."
        },
    )
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPMuted("Your feed channels are not touched.")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPTextField(
        value = state.input,
        onValueChange = vm::setDeleteNodeInput,
        label = "Type @$username to confirm",
        placeholder = "@$username",
        kind = HPFieldKind.Mono,
        enabled = !state.running,
        contentDescription = "Type @$username to confirm",
    )
    HPButton(
        label = if (state.running) "Deleting…" else "Delete My Node",
        onClick = vm::deleteMyNode,
        style = HPButtonStyle.DANGER,
        enabled = !state.running && vm.deleteNodeConfirmed(state.input),
    )
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPButton("Cancel", vm::closeSheet, style = HPButtonStyle.GHOST, enabled = !state.running)
}
