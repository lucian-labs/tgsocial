package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPMono
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.ChannelUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FooterNote
import ca.lucianlabs.tgsocial.ui.components.PostCard
import ca.lucianlabs.tgsocial.ui.components.openLink
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage

/** PRODUCT §2.6 — channel header, then its posts chronologically. */
fun LazyListScope.FeedChannelItems(vm: AppViewModel, c: ChannelUi) {
    val src = c.source
    item(key = "channel-head") {
        val context = LocalContext.current
        Column(Modifier.columnItem()) {
            if (src == null) {
                if (c.loading) FooterNote("Loading…") else EmptyCard("Not a channel.", "@${c.username} could not be opened.")
            } else {
                val image = rememberTdImage(src.photo, HPTokens.Space.avatarProfile)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
                    HPAvatar(image, HPTokens.Space.avatarProfile, src.initial, contentDescription = src.title)
                    Column(Modifier.weight(1f)) {
                        HPH2(src.title)
                        HPMono("@${src.username}")
                    }
                }
                if (src.description.isNotBlank()) {
                    Spacer(Modifier.height(HPTokens.Space.rowGap))
                    HPMuted(src.description)
                }
                Spacer(Modifier.height(HPTokens.Space.rowGap))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    HPButton("Open in Telegram", { openLink(context, DeepLink.channel(src.username)) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
                    if (c.verified) { Spacer(Modifier.width(HPTokens.Space.rowGap)); HPPill("Verified", HPPillTone.GOLD) }
                }
                Spacer(Modifier.height(HPTokens.Space.cardGap))
            }
        }
    }
    items(c.posts, key = { it.key }) { post ->
        val index by vm.commentIndex.collectAsStateWithLifecycle()
        Box(Modifier.columnItem()) {
            PostCard(
                post = post,
                commentCount = vm.commentCount(post, index),
                onOpenChannel = { if (it != c.username) vm.push(Screen.FeedChannel(it)) },
                onOpenThread = { vm.openThread(post) },
                onComment = { vm.openSheet(Sheet.CommentComposer(vm.targetForPost(post))) },
                onOpenViewer = { vm.openViewer(post, it) },
            )
        }
    }
    item(key = "channel-footer") {
        Box(Modifier.columnItem()) {
            when {
                c.loading -> FooterNote("Loading…")
                c.exhausted && c.posts.isEmpty() && src != null -> FooterNote("No posts yet.")
                c.exhausted -> FooterNote("That's everything.")
            }
        }
    }
}
