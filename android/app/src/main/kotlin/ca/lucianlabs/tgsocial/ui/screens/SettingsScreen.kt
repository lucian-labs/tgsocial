package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
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
import ca.lucianlabs.housepour.HPListItem
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPSmall
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.demo.DemoCopy
import ca.lucianlabs.tgsocial.model.MyNode
import ca.lucianlabs.tgsocial.protocol.HiddenItem
import ca.lucianlabs.tgsocial.protocol.ReportEmail
import ca.lucianlabs.tgsocial.protocol.SafetyLists
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.openMail
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage

/**
 * PRODUCT §2.20 — Settings: the safety lists, the contact card, and the two destructive actions in that
 * order. Sign Out moved here from You (§2.8) so `Delete My Node` could sit under it rather than a mis-tap
 * away from `View as others see it` — the reversible destructive action first, the irreversible one second.
 */
fun LazyListScope.SettingsItems(vm: AppViewModel, safety: SafetyLists, node: MyNode?, inDemo: Boolean = false) {
    item(key = "settings-safety-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Safety") }
    }
    item(key = "settings-safety-note") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.cardGap)) {
            HPMuted("Blocked and reported content is hidden everywhere in the app. The filter is always on; there is no switch. These lists live on this device only and nobody else can read them.")
        }
    }

    item(key = "settings-blocked-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Blocked", safety.blocked.size) }
    }
    item(key = "settings-blocked") {
        ListCard(safety.blocked.isEmpty(), "You haven't blocked anyone.") {
            val cards by vm.cards.collectAsStateWithLifecycle()
            safety.blocked.forEachIndexed { i, username ->
                val snapshot = cards[Username.key(username)]
                val image = rememberTdImage(snapshot?.photo, HPTokens.Space.avatarRow)
                HPListItem(
                    modifier = Modifier.rowTap("Open @$username") { vm.push(Screen.Profile(username)) },
                    isLast = i == safety.blocked.lastIndex,
                    trailing = { HPButton("Unblock", { vm.unblock(username) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Unblock @$username") },
                ) {
                    HPAvatar(image, HPTokens.Space.avatarRow, snapshot?.initial ?: "·", contentDescription = null)
                    Column(Modifier.weight(1f)) {
                        HPBody(snapshot?.displayName ?: "@$username", strong = true, maxLines = 1)
                        HPMonoSmall("@$username", maxLines = 1)
                    }
                }
            }
        }
    }

    item(key = "settings-muted-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Muted", safety.mutedFeeds.size) }
    }
    item(key = "settings-muted") {
        ListCard(safety.mutedFeeds.isEmpty(), "No muted feeds.") {
            safety.mutedFeeds.forEachIndexed { i, username ->
                val title = vm.cachedFeedSource(username)?.title ?: "@$username"
                HPListItem(
                    modifier = Modifier.rowTap("Open @$username") { vm.push(Screen.FeedChannel(username)) },
                    isLast = i == safety.mutedFeeds.lastIndex,
                    trailing = { HPButton("Unmute", { vm.unmuteFeed(username, title) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Unmute $title") },
                ) {
                    Column(Modifier.weight(1f)) {
                        HPBody(title, maxLines = 1)
                        HPMonoSmall("@$username", maxLines = 1)
                    }
                }
            }
        }
    }

    item(key = "settings-hidden-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Hidden", safety.hidden.size) }
    }
    item(key = "settings-hidden") {
        ListCard(safety.hidden.isEmpty(), "Nothing hidden.") {
            safety.hidden.forEachIndexed { i, item -> HiddenRow(vm, item, isLast = i == safety.hidden.lastIndex) }
        }
    }

    item(key = "settings-contact-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Contact") }
    }
    item(key = "settings-contact") {
        val context = LocalContext.current
        Box(Modifier.columnItem()) {
            HPCard {
                Box(
                    modifier = Modifier
                        .defaultMinSize(minHeight = HPTokens.Space.touchMin)
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                            openMail(context, ReportEmail.ADDRESS)
                        }
                        .semantics { contentDescription = "Write to ${ReportEmail.ADDRESS}" },
                    contentAlignment = Alignment.CenterStart,
                ) {
                    HPText(ReportEmail.ADDRESS, HPTokens.Type.body, HPTokens.Colors.accent, maxLines = 1)
                }
                Spacer(Modifier.height(HPTokens.Space.rowGap))
                // The honest part: a client with no server cannot delete someone else's channel, so this says
                // what it can do instead of implying a takedown it cannot perform (§2.19).
                HPMuted("Reports are read by a person within 24 hours. Content that breaks the rules is reported to Telegram, the only party that can remove it from the network. Your copy is hidden on your device the moment you report it, whether or not anyone else acts.")
            }
        }
    }

    // PRODUCT §2.22.3 — `Sign Out` is not in the demo at all: `( Leave Demo )` (neutral) sits where it sits in
    // a real session, above `( Delete My Node )` (danger). Leaving is not destructive, so it is not danger.
    item(key = "settings-signout") {
        Box(Modifier.columnItem()) {
            if (inDemo) HPButton(DemoCopy.LEAVE, { vm.leaveDemo() }, style = HPButtonStyle.NEUTRAL)
            else HPButton("Sign Out", { vm.openSheet(Sheet.SignOut) }, style = HPButtonStyle.DANGER)
        }
    }
    if (node != null) {
        item(key = "settings-delete-node") {
            Box(Modifier.columnItem().padding(top = HPTokens.Space.rowGap)) {
                HPButton("Delete My Node", { vm.openSheet(Sheet.DeleteNode) }, style = HPButtonStyle.DANGER)
            }
        }
    }
}

/**
 * A hidden row names its channel and message id and **never** the content: showing a preview of the thing
 * someone reported would undo the report (§2.20). The reason is the one they picked, kept verbatim.
 */
@Composable
private fun HiddenRow(vm: AppViewModel, item: HiddenItem, isLast: Boolean) {
    val channel = item.key.substringBefore('/')
    val messageId = item.key.substringAfter('/')
    val title = vm.cachedFeedSource(channel)?.title ?: "@$channel"
    HPListItem(
        isLast = isLast,
        trailing = { HPButton("Unhide", { vm.unhide(item.key) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Unhide $title $messageId") },
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                HPBody(title, Modifier.weight(1f, fill = false), maxLines = 1)
                HPMonoSmall(" · $messageId", maxLines = 1)
            }
            // `at` is ISO 8601 UTC (PROTOCOL §7.1); the row shows the day, which is what "reported when" means.
            HPSmall("${item.reason} · reported ${item.at.take(10)}", maxLines = 1)
        }
    }
}

/** A list card, or its empty line — the shape every section in §2.20 shares. */
@Composable
private fun ListCard(empty: Boolean, emptyText: String, rows: @Composable () -> Unit) {
    Box(Modifier.columnItem()) {
        HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
            if (empty) {
                Spacer(Modifier.height(HPTokens.Space.rowPad))
                HPMuted(emptyText)
                Spacer(Modifier.height(HPTokens.Space.rowPad))
            } else {
                rows()
            }
        }
    }
}

@Composable
private fun Modifier.rowTap(label: String, onClick: () -> Unit): Modifier =
    this
        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button, onClick = onClick)
        .semantics { contentDescription = label }
