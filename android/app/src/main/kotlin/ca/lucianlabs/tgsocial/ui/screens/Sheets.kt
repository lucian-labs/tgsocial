package ca.lucianlabs.tgsocial.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonRow
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPFieldKind
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPListItem
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPTabs
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTextField
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.Comment
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.Availability

/**
 * Sheet bodies. The modal itself (scrim, card, fade) is one `HPModal` host in the shell; these are its contents.
 * PRODUCT §2.9 — Compose. Photo attach via the system Photo Picker (no storage permission).
 */
@Composable
fun ColumnScope.ComposeSheet(vm: AppViewModel) {
    val c by vm.compose.collectAsStateWithLifecycle()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> vm.composePhoto(uri) }
    HPSectionMark("Post to")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    if (c.feeds.isEmpty()) {
        HPMuted("Pick a feed on the You screen first.")
    } else {
        HPTabs(items = c.feeds.map { it.title }, selected = c.selected.coerceIn(0, c.feeds.lastIndex), onSelect = vm::composeSelect)
    }
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPTextField(c.text, vm::composeText, placeholder = "Say it.", kind = HPFieldKind.Multiline(6), enabled = !c.posting, contentDescription = "Post text")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = HPTokens.Space.rowGap)) {
        HPButton(if (c.photo == null) "Add Photo" else "Change Photo", { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, enabled = !c.posting)
        if (c.photo != null) {
            Spacer(Modifier.width(HPTokens.Space.rowGap))
            HPMonoSmall("1 photo", maxLines = 1)
            Spacer(Modifier.width(HPTokens.Space.rowGap))
            HPButton("Remove", { vm.composePhoto(null) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, enabled = !c.posting)
        }
    }
    HPButtonRow(
        first = { m -> HPButton("Post", vm::post, modifier = m, style = HPButtonStyle.PRIMARY, enabled = !c.posting && c.feeds.isNotEmpty() && (c.text.isNotBlank() || c.photo != null)) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST, enabled = !c.posting) },
    )
}

/** PRODUCT §2.8 — Edit Card modal: NAME, BIO, LINK, Save. */
@Composable
fun ColumnScope.EditCardSheet(vm: AppViewModel) {
    val e by vm.editCard.collectAsStateWithLifecycle()
    HPH2("Edit card")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPTextField(e.name, { vm.setEditCard(name = it) }, label = "Name", kind = HPFieldKind.Text)
    HPTextField(e.bio, { vm.setEditCard(bio = it) }, label = "Bio", kind = HPFieldKind.Text)
    HPTextField(e.link, { vm.setEditCard(link = it) }, label = "Link", kind = HPFieldKind.Url, placeholder = "https://")
    HPButtonRow(
        first = { m -> HPButton("Save", vm::saveEditCard, modifier = m, style = HPButtonStyle.PRIMARY, enabled = !e.saving) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST) },
    )
}

/** PRODUCT §4 — Sign out asks once. */
@Composable
fun ColumnScope.SignOutSheet(vm: AppViewModel) {
    HPH2("Sign out of tgsocial?")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPMuted("Your node stays on Telegram.")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButtonRow(
        first = { m -> HPButton("Sign Out", vm::signOut, modifier = m, style = HPButtonStyle.DANGER) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST) },
    )
}

@Composable
private fun StatusRow(label: String, value: String, isLast: Boolean = false) {
    HPListItem(isLast = isLast) {
        HPBody(label, maxLines = 1)
        Spacer(Modifier.weight(1f))
        HPText(value, HPTokens.Type.mono, HPTokens.Colors.muted, modifier = Modifier.weight(2f), maxLines = 6, textAlign = TextAlign.End)
    }
}

/**
 * PRODUCT §2.10 — the Status sheet: live rows over the connection state, the activity registry, and the feed.
 * It updates while open; `Refresh Now` re-runs the feed refresh and re-reads my card.
 */
@Composable
fun ColumnScope.StatusSheet(vm: AppViewModel) {
    val conn by vm.connection.collectAsStateWithLifecycle()
    val pending by vm.pending.collectAsStateWithLifecycle()
    val lastError by vm.lastError.collectAsStateWithLifecycle()
    val phone by vm.phone.collectAsStateWithLifecycle()
    val me by vm.me.collectAsStateWithLifecycle()
    val node by vm.myNode.collectAsStateWithLifecycle()
    val feed by vm.feed.collectAsStateWithLifecycle()
    // Relative times (`card 2 min ago`) re-derive while the sheet is open.
    var tick by remember { mutableStateOf(0) }
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(10_000); tick++ } }
    tick // read so recomposition follows the ticker

    HPSectionMark("Status")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    StatusRow("Connection", vm.connectionLabel(conn))
    StatusRow("Telegram", if (phone.isBlank()) "Signed in" else "Signed in · ${Format.maskPhone(phone)}")
    val nodeValue = when {
        node == null -> "None"
        me?.fetchedAt?.takeIf { it > 0 } != null -> "@${node?.username} · card ${Format.ago(me!!.fetchedAt)}"
        else -> "@${node?.username}"
    }
    StatusRow("Node", nodeValue)
    val sources = if (feed.sourceCount == 1) "1 source" else "${feed.sourceCount} sources"
    val posts = if (feed.posts.size == 1) "1 post" else "${feed.posts.size} posts"
    val refreshed = feed.refreshedAt.takeIf { it > 0 }?.let { " · refreshed ${Format.time(it / 1000)}" }.orEmpty()
    StatusRow("Feed", "$sources · $posts$refreshed")
    // What is in flight right now, or `Nothing` (§2.10).
    StatusRow("Pending", if (pending.isEmpty()) "Nothing" else pending.joinToString("\n") { it.label })
    StatusRow("Last error", lastError?.let { "${it.message} at ${Format.time(it.at / 1000)}" } ?: "None")
    StatusRow("TDLib", vm.tdlibVersion, isLast = true)
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButton("Refresh Now", { vm.refreshFeed(resetCursors = true) }, style = HPButtonStyle.ACCENT)
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPButton("Close", vm::closeSheet, style = HPButtonStyle.GHOST)
}

/**
 * PRODUCT §2.12 — the comment composer. First comment ever: one extra card makes the comments channel
 * (PROTOCOL §6.4); on success the composer proceeds.
 */
@Composable
fun ColumnScope.CommentComposerSheet(vm: AppViewModel) {
    val c by vm.commentComposer.collectAsStateWithLifecycle()
    if (c.needsChannel) {
        HPSectionMark("Your comments channel")
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPMuted("Your comments live in a public channel you own. Anyone can read it on Telegram; you can edit or delete anything there.")
        Spacer(Modifier.height(HPTokens.Space.cardGap))
        HPTextField(c.channelName, vm::setReplyChannelName, kind = HPFieldKind.Username, gapBelow = false, enabled = !c.creatingChannel, contentDescription = "Comments channel name")
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        Row(verticalAlignment = Alignment.CenterVertically) {
            when (c.channelAvailability) {
                Availability.AVAILABLE -> HPPill("Available", HPPillTone.GOLD)
                Availability.TAKEN -> HPPill(if (c.channelNote.isNotBlank() && c.channelNote != "Taken") c.channelNote else "Taken", HPPillTone.BAD)
                Availability.CHECKING -> HPPill("Checking")
                Availability.UNKNOWN -> Unit
            }
        }
        Spacer(Modifier.height(HPTokens.Space.cardGap))
        HPButton("Make Channel", vm::makeRepliesChannel, style = HPButtonStyle.PRIMARY, enabled = !c.creatingChannel && c.channelAvailability != Availability.TAKEN)
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPButton("Cancel", vm::closeSheet, style = HPButtonStyle.GHOST, enabled = !c.creatingChannel)
        return
    }
    val target = c.target
    if (target != null) {
        val excerpt = target.excerpt.replace('\n', ' ').trim()
        val quote = if (excerpt.isEmpty()) "re: ${target.title}" else "re: ${target.title} — '${excerpt.take(60)}${if (excerpt.length > 60) "…" else ""}'"
        HPMuted(quote, maxLines = 2)
        Spacer(Modifier.height(HPTokens.Space.rowGap))
    }
    HPTextField(c.text, vm::setCommentText, placeholder = "Say it.", kind = HPFieldKind.Multiline(6), enabled = !c.posting, contentDescription = "Comment text")
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> vm.setCommentPhoto(uri) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = HPTokens.Space.rowGap)) {
        HPButton(if (c.photo == null) "Add Photo" else "Change Photo", { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, enabled = !c.posting)
        if (c.photo != null) {
            Spacer(Modifier.width(HPTokens.Space.rowGap))
            HPMonoSmall("1 photo", maxLines = 1)
            Spacer(Modifier.width(HPTokens.Space.rowGap))
            HPButton("Remove", { vm.setCommentPhoto(null) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, enabled = !c.posting)
        }
    }
    HPButtonRow(
        first = { m -> HPButton("Post", vm::postComment, modifier = m, style = HPButtonStyle.PRIMARY, enabled = !c.posting && (c.text.isNotBlank() || c.photo != null)) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST, enabled = !c.posting) },
    )
}

/** PRODUCT §2.12 — deleting your comment asks once. */
@Composable
fun ColumnScope.DeleteCommentSheet(vm: AppViewModel, comment: Comment) {
    HPH2("Delete this comment?")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButtonRow(
        first = { m -> HPButton("Delete", { vm.deleteComment(comment) }, modifier = m, style = HPButtonStyle.DANGER) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST) },
    )
}
