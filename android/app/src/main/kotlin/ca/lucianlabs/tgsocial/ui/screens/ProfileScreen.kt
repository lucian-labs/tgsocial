package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.remember
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
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPH1
import ca.lucianlabs.housepour.HPMono
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.ProfileUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FeedRow
import ca.lucianlabs.tgsocial.ui.components.FooterNote
import ca.lucianlabs.tgsocial.ui.components.openLink
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage

/** PRODUCT §2.5 — node profile. My own profile is the same screen without the Follow button. */
fun LazyListScope.ProfileItems(vm: AppViewModel, p: ProfileUi, me: NodeSnapshot?) {
    val snap = p.snapshot
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
            HPAvatar(image, HPTokens.Space.avatarProfile, snap.initial, contentDescription = snap.displayName)
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
                    p.feeds.forEachIndexed { i, f ->
                        FeedRow(f, isLast = i == p.feeds.lastIndex, verified = f.verifiedFor.any { it.equals(snap.username, ignoreCase = true) }, onOpen = { vm.push(Screen.FeedChannel(f.username)) })
                    }
                }
            }
        }
    }
    nodeSection(vm, "Follows", p.follows, me, emptyText = if (card.follows.isEmpty()) "Follows no one yet." else "Loading…", showMutual = false, keyPrefix = "profile-follows", count = card.follows.size)
}
