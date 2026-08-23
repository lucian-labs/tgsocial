package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPListItem
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPSmall
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.SyncStatus

/** StatusPill — `Synced` gold; everything else neutral. A button: tapping opens the Status sheet (PRODUCT §2.10). */
@Composable
fun StatusPill(status: SyncStatus, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .defaultMinSize(minHeight = HPTokens.Space.touchMin, minWidth = HPTokens.Space.touchMin)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Status" },
        contentAlignment = Alignment.Center,
    ) {
        HPPill(status.label, if (status == SyncStatus.SYNCED) HPPillTone.GOLD else HPPillTone.NEUTRAL)
    }
}

/** EmptyCard — h2, muted body, at most one accent action. */
@Composable
fun EmptyCard(title: String, body: String, action: String? = null, onAction: (() -> Unit)? = null) {
    HPCard {
        HPH2(title)
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPMuted(body)
        if (action != null && onAction != null) {
            Spacer(Modifier.height(HPTokens.Space.cardGap))
            HPButton(action, onAction, style = HPButtonStyle.ACCENT)
        }
    }
}

@Composable
private fun Modifier.rowClick(label: String, onClick: () -> Unit): Modifier =
    this
        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onClick)
        .semantics { contentDescription = label }

/** NodeRow — avatar, name over `@username · n feeds`, optional "Followed by n of yours", trailing Follow / Following. */
@Composable
fun NodeRow(
    entry: NodeEntry,
    isLast: Boolean,
    following: Boolean,
    isMe: Boolean,
    onOpen: () -> Unit,
    onFollow: () -> Unit,
    onUnfollow: () -> Unit,
    showMutual: Boolean = true,
    showFollow: Boolean = true,
) {
    val image = rememberTdImage(entry.photo, HPTokens.Space.avatarRow)
    HPListItem(
        modifier = Modifier.rowClick("Open @${entry.username}", onOpen),
        isLast = isLast,
        trailing = {
            if (showFollow && !isMe) {
                if (following) HPButton("Following", onUnfollow, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Unfollow @${entry.username}")
                else HPButton("Follow", onFollow, style = HPButtonStyle.NEUTRAL, size = HPButtonSize.SMALL, contentDescription = "Follow @${entry.username}")
            }
        },
    ) {
        HPAvatar(image, HPTokens.Space.avatarRow, entry.initial, contentDescription = entry.name)
        Column(modifier = Modifier.weight(1f)) {
            HPBody(entry.name, strong = true, maxLines = 1)
            val feeds = if (entry.feedCount == 1) "1 feed" else "${entry.feedCount} feeds"
            HPMonoSmall("@${entry.username} · $feeds", maxLines = 1)
            if (showMutual && entry.mutualCount > 0) {
                HPSmall("Followed by ${entry.mutualCount} of yours", maxLines = 1)
            }
        }
    }
}

/** FeedRow — title, mono username, optional Verified pill, trailing chevron in `faint`. */
@Composable
fun FeedRow(feed: FeedSource, isLast: Boolean, verified: Boolean, onOpen: () -> Unit, trailing: (@Composable RowScope.() -> Unit)? = null) {
    HPListItem(
        modifier = Modifier.rowClick("Open @${feed.username}", onOpen),
        isLast = isLast,
        trailing = {
            if (trailing != null) trailing()
            if (verified) HPPill("Verified", HPPillTone.GOLD)
            HPText("›", HPTokens.Type.body, HPTokens.Colors.faint, maxLines = 1)
        },
    ) {
        Column(modifier = Modifier.weight(1f)) {
            HPBody(feed.title, maxLines = 1)
            HPMonoSmall("@${feed.username}", maxLines = 1)
        }
    }
}

/** Muted centred row used for `Loading…` / `That's everything.` */
@Composable
fun FooterNote(text: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = HPTokens.Space.rowPad), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        HPMuted(text, maxLines = 1)
    }
}
