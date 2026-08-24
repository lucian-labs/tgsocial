package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPKebabButton
import ca.lucianlabs.housepour.HPMenu
import ca.lucianlabs.housepour.HPMenuItem
import ca.lucianlabs.housepour.HPMono
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPToastTone
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.PublicLink
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.ChannelUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FooterNote
import ca.lucianlabs.tgsocial.ui.components.PostCard
import ca.lucianlabs.tgsocial.ui.components.copyToClipboard
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
                // The avatar sits left; the top-right corner carries the `Verified` pill (backlinked feeds only,
                // PROTOCOL §3) and the kebab menu. Title, username, and description run full width beneath.
                var menuOpen by remember { mutableStateOf(false) }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
                    HPAvatar(image, HPTokens.Space.avatarProfile, src.initial, contentDescription = src.title)
                    Spacer(Modifier.weight(1f))
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
                    ) {
                        if (c.verified) HPPill("Verified", HPPillTone.GOLD)
                        Box {
                            HPKebabButton({ menuOpen = true }, contentDescription = "More")
                            HPMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                                HPMenuItem("Open in Telegram", {
                                    menuOpen = false
                                    openLink(context, DeepLink.channel(src.username))
                                })
                                HPMenuItem("Copy Link", {
                                    menuOpen = false
                                    copyToClipboard(context, PublicLink.feed(src.username))
                                    vm.toast.show("Link copied.", HPToastTone.GOOD)
                                }, isLast = true)
                            }
                        }
                    }
                }
                Spacer(Modifier.height(HPTokens.Space.rowGap))
                HPH2(src.title)
                HPMono("@${src.username}")
                if (src.description.isNotBlank()) {
                    Spacer(Modifier.height(HPTokens.Space.rowGap))
                    HPMuted(src.description)
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
                onOpenProfile = { vm.push(Screen.Profile(it)) },
                onOpenThread = { vm.openThread(post) },
                onComment = { vm.openSheet(Sheet.CommentComposer(vm.targetForPost(post))) },
                onOpenViewer = { vm.openViewer(post, it) },
                onLongPress = { vm.openSheet(Sheet.PostSheet(post)) },
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
