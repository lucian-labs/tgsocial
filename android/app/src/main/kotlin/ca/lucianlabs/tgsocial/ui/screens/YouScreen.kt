package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPListItem
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPToggle
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.BuildConfig
import ca.lucianlabs.tgsocial.model.FeedSource
import ca.lucianlabs.tgsocial.model.MyNode
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FeedRow
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage

/** PRODUCT §2.8 — You. Compose is the one gold action on this screen. */
fun LazyListScope.YouItems(vm: AppViewModel, me: NodeSnapshot?, node: MyNode?) {
    if (me == null || node == null) {
        item(key = "you-empty") {
            Box(Modifier.columnItem()) {
                EmptyCard("No node yet.", "Make your node to pick feeds, follow people, and post.", "Make your node") { vm.push(Screen.Setup) }
            }
        }
        item(key = "you-signout-only") {
            Box(Modifier.columnItem()) { HPButton("Sign Out", { vm.openSheet(Sheet.SignOut) }, style = HPButtonStyle.DANGER) }
        }
        item(key = "you-footer-only") { Footer(null) }
        return
    }
    if (me.newerVersion) {
        // PROTOCOL §8 — a v2+ card is mine but unreadable here; no writes, no second node.
        item(key = "you-newer") {
            Box(Modifier.columnItem()) {
                EmptyCard("Newer card. Update the app.", "@${me.username} was written by a newer tgsocial. This version can read it once updated.")
            }
        }
        item(key = "you-signout-newer") {
            Box(Modifier.columnItem().padding(top = HPTokens.Space.rowGap)) { HPButton("Sign Out", { vm.openSheet(Sheet.SignOut) }, style = HPButtonStyle.DANGER) }
        }
        item(key = "you-footer-newer") { Footer(node) }
        return
    }
    val card = me.card
    item(key = "you-head") {
        val image = rememberTdImage(me.photo, HPTokens.Space.avatarProfile)
        Row(Modifier.columnItem().padding(bottom = HPTokens.Space.cardGap), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
            HPAvatar(image, HPTokens.Space.avatarProfile, me.initial, contentDescription = me.displayName)
            Column(Modifier.weight(1f)) {
                HPH2(me.displayName, maxLines = 2)
                HPMonoSmall("@${me.username}")
            }
            HPButton("Edit Card", { vm.openSheet(Sheet.EditCard) }, style = HPButtonStyle.NEUTRAL, size = HPButtonSize.SMALL)
        }
    }
    item(key = "you-feeds-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) {
            HPSectionMark("Your feeds", trailing = { HPButton("Manage", { vm.push(Screen.ManageFeeds) }, style = HPButtonStyle.NEUTRAL, size = HPButtonSize.SMALL) })
        }
    }
    item(key = "you-feeds") {
        val feeds = card?.feeds.orEmpty()
        val cards by vm.cards.collectAsStateWithLifecycle()
        var sources by remember(feeds, cards) { mutableStateOf(feeds.mapNotNull { vm.cachedFeedSource(it) }) }
        LaunchedEffect(feeds) { sources = vm.resolveFeedSources(feeds) }
        Box(Modifier.columnItem()) {
            HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
                if (feeds.isEmpty()) {
                    Spacer(Modifier.height(HPTokens.Space.rowPad)); HPMuted("No feeds yet. Manage picks the channels that post as you."); Spacer(Modifier.height(HPTokens.Space.rowPad))
                } else if (sources.isEmpty()) {
                    feeds.forEachIndexed { i, f ->
                        HPListItem(isLast = i == feeds.lastIndex) { Column(Modifier.weight(1f)) { HPBody("@$f", maxLines = 1) } }
                    }
                } else {
                    sources.forEachIndexed { i, f: FeedSource ->
                        FeedRow(f, isLast = i == sources.lastIndex, verified = f.verifiedFor.any { it.equals(me.username, ignoreCase = true) }, onOpen = { vm.openSheet(Sheet.Compose(f.username)) })
                    }
                }
            }
        }
    }
    item(key = "you-compose") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.cardGap)) {
            HPButton("Compose", { vm.openSheet(Sheet.Compose(null)) }, style = HPButtonStyle.PRIMARY, enabled = !card?.feeds.isNullOrEmpty())
        }
    }
    item(key = "you-listing-mark") { Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Listing") } }
    item(key = "you-listing") {
        val public = card?.public ?: true
        Box(Modifier.columnItem()) {
            HPCard {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
                    HPBody("Public listing", Modifier.weight(1f))
                    HPPill(if (public) "Listed" else "Unlisted", if (public) HPPillTone.GOLD else HPPillTone.NEUTRAL)
                    HPToggle(public, { vm.setPublic(it) }, label = "Public listing")
                }
                Spacer(Modifier.height(HPTokens.Space.cardGap))
                HPButton("Announce in Directory", vm::announce, style = HPButtonStyle.NEUTRAL, size = HPButtonSize.SMALL, enabled = public, fullWidth = true)
            }
        }
    }
    item(key = "you-view") {
        Box(Modifier.columnItem()) { HPButton("View as others see it", { vm.push(Screen.Profile(me.username)) }, style = HPButtonStyle.GHOST) }
    }
    item(key = "you-signout") {
        Box(Modifier.columnItem().padding(top = HPTokens.Space.rowGap)) { HPButton("Sign Out", { vm.openSheet(Sheet.SignOut) }, style = HPButtonStyle.DANGER) }
    }
    item(key = "you-footer") { Footer(node) }
}

@androidx.compose.runtime.Composable
private fun Footer(node: MyNode?) {
    Box(Modifier.columnItem().padding(top = HPTokens.Space.cardGap), contentAlignment = Alignment.Center) {
        val parts = listOf("tgsocial ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})", "TDLib ${BuildConfig.TDLIB_VERSION}") + listOfNotNull(node?.let { "node @${it.username}" })
        HPMonoSmall(parts.joinToString(" · "), color = HPTokens.Colors.faint)
    }
}
