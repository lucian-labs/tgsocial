package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
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
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPH1
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPKebabButton
import ca.lucianlabs.housepour.HPMenu
import ca.lucianlabs.housepour.HPMenuItem
import ca.lucianlabs.housepour.HPMono
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPToastTone
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.PublicLink
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.ProfileUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FeedRow
import ca.lucianlabs.tgsocial.ui.components.FooterNote
import ca.lucianlabs.tgsocial.ui.components.copyToClipboard
import ca.lucianlabs.tgsocial.ui.components.openInTelegram
import ca.lucianlabs.tgsocial.ui.components.openLink
import ca.lucianlabs.tgsocial.ui.components.publicOrigin
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage

/** PRODUCT §2.5 — node profile. My own profile is the same screen without the Follow button. */
fun LazyListScope.ProfileItems(vm: AppViewModel, p: ProfileUi, me: NodeSnapshot?) {
    val snap = p.snapshot
    if (p.blocked) {
        // PRODUCT §2.16 — the one exception to "a blocked node renders as nothing at all". This screen is
        // reached deliberately (a t.me link, a public URL, an exact-username search), where an empty screen
        // would read as a broken app. Their photo is not loaded: the initial is enough to say who this is.
        item(key = "profile-blocked") {
            Column(Modifier.columnItem()) {
                HPAvatar(null, HPTokens.Space.avatarProfile, snap?.initial ?: "·", contentDescription = null)
                Spacer(Modifier.height(HPTokens.Space.rowGap))
                HPMono("@${p.username}")
                Spacer(Modifier.height(HPTokens.Space.labelBottom))
                HPH2("You blocked this node.")
                Spacer(Modifier.height(HPTokens.Space.rowGap))
                HPMuted("Nothing they post reaches you.")
                Spacer(Modifier.height(HPTokens.Space.cardGap))
                HPButton("Unblock", { vm.unblock(p.username) }, style = HPButtonStyle.GHOST)
            }
        }
        return
    }
    if (snap == null) {
        item(key = "profile-loading") {
            Box(Modifier.columnItem()) {
                if (p.loading) FooterNote("Loading…")
                else EmptyCard("Not a tgsocial node.", "@${p.username} has no card on Telegram.")
            }
        }
        return
    }
    item(key = "profile-head") {
        val image = rememberTdImage(snap.photo, HPTokens.Space.avatarProfile)
        val context = LocalContext.current
        Column(Modifier.columnItem()) {
            // PRODUCT §2.5 / §2.16 — the avatar sits left, the kebab top-right: the same component the feed
            // channel header carries (§2.6), with `Block` added.
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                HPAvatar(image, HPTokens.Space.avatarProfile, snap.initial, contentDescription = snap.displayName)
                Spacer(Modifier.weight(1f))
                var menuOpen by remember { mutableStateOf(false) }
                Box {
                    HPKebabButton({ menuOpen = true }, contentDescription = "More")
                    HPMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        val blockable = !vm.isMe(snap.username)
                        HPMenuItem("Open in Telegram", {
                            menuOpen = false
                            openInTelegram(context, DeepLink.channel(snap.username))
                        })
                        HPMenuItem("Copy Link", {
                            menuOpen = false
                            // PRODUCT §2.22.3 — the demo refuses with its own line; only a real copy is confirmed.
                            if (copyToClipboard(context, PublicLink.node(snap.username, publicOrigin))) {
                                vm.toast.show("Link copied.", HPToastTone.GOOD)
                            }
                        }, isLast = !blockable)
                        if (blockable) {
                            HPMenuItem("Block @${snap.username}", {
                                menuOpen = false
                                vm.openSheet(Sheet.Block(snap.username))
                            }, isLast = true)
                        }
                    }
                }
            }
            Spacer(Modifier.height(HPTokens.Space.rowGap))
            HPH1(snap.displayName)
            HPMono("@${snap.username}")
            val card = snap.card
            if (card?.bio != null) { Spacer(Modifier.height(HPTokens.Space.labelBottom)); HPMuted(card.bio) }
            if (card?.link != null) {
                // Link entity treatment (accent, underlined) on a 40pt target with a label (COMPONENTS rule 6).
                val display = card.link.removePrefix("https://").removePrefix("http://").trimEnd('/')
                val underlined = remember(display) { buildAnnotatedString { withStyle(SpanStyle(textDecoration = TextDecoration.Underline)) { append(display) } } }
                Box(
                    modifier = Modifier
                        .defaultMinSize(minHeight = HPTokens.Space.touchMin)
                        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) { openLink(context, card.link) }
                        .semantics { contentDescription = "Open $display" },
                    contentAlignment = Alignment.CenterStart,
                ) {
                    HPText(underlined, HPTokens.Type.body, HPTokens.Colors.accent, maxLines = 1)
                }
            }
            Spacer(Modifier.height(HPTokens.Space.cardGap))
            when {
                p.newerVersion -> HPMuted("Newer card. Update the app.")
                card == null -> HPMuted("Not a tgsocial node.")
                vm.isMe(snap.username) -> Unit
                me?.card?.follows(snap.username) == true -> HPButton("Unfollow", { vm.unfollow(snap.username) }, style = HPButtonStyle.GHOST)
                else -> HPButton("Follow", { vm.follow(snap.username) }, style = HPButtonStyle.PRIMARY)
            }
            Spacer(Modifier.height(HPTokens.Space.cardGap))
        }
    }
    val card = snap.card ?: return
    item(key = "profile-feeds-mark") { Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Feeds") } }
    item(key = "profile-feeds") {
        Box(Modifier.columnItem()) {
            HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
                if (card.feeds.isEmpty()) {
                    Spacer(Modifier.height(HPTokens.Space.rowPad)); HPMuted("No feeds yet."); Spacer(Modifier.height(HPTokens.Space.rowPad))
                } else if (p.feeds.isEmpty()) {
                    Spacer(Modifier.height(HPTokens.Space.rowPad)); HPMuted("Loading…"); Spacer(Modifier.height(HPTokens.Space.rowPad))
                } else {
                    val safety by vm.safety.collectAsStateWithLifecycle()
                    p.feeds.forEachIndexed { i, f ->
                        FeedRow(
                            feed = f,
                            isLast = i == p.feeds.lastIndex,
                            verified = f.verifiedFor.any { it.equals(snap.username, ignoreCase = true) },
                            onOpen = { vm.push(Screen.FeedChannel(f.username)) },
                            // PRODUCT §2.17 — a muted feed stays listed here, with a faint pill after the title.
                            trailing = { if (safety.isMuted(f.username)) HPPill("Muted") },
                        )
                    }
                }
            }
        }
    }
    nodeSection(vm, "Follows", p.follows, me, emptyText = if (card.follows.isEmpty()) "Follows no one yet." else "Loading…", showMutual = false, keyPrefix = "profile-follows", count = card.follows.size)
}
