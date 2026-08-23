package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.FeedUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.Tab
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FooterNote
import ca.lucianlabs.tgsocial.ui.components.PostCard

/** PRODUCT §2.3 — the main feed. Strictly chronological (PROTOCOL §4.8). */
fun LazyListScope.FeedItems(vm: AppViewModel, feed: FeedUi, me: NodeSnapshot?) {
    if (feed.ready && feed.posts.isEmpty() && !feed.loading) {
        item(key = "feed-empty") {
            Box(Modifier.columnItem()) {
                if (me == null) {
                    EmptyCard("Nothing here yet.", "Make your node to pick feeds and follow people.", "Make your node") { vm.push(Screen.Setup) }
                } else {
                    EmptyCard("Nothing here yet.", "Follow a node and their feeds show up here, newest first.", "Explore") { vm.selectTab(Tab.EXPLORE) }
                }
            }
        }
        return
    }
    items(feed.posts, key = { it.key }) { post ->
        val index by vm.commentIndex.collectAsStateWithLifecycle()
        Box(Modifier.columnItem()) {
            PostCard(
                post = post,
                commentCount = vm.commentCount(post, index),
                onOpenChannel = { vm.push(Screen.FeedChannel(it)) },
                onOpenProfile = { vm.push(Screen.Profile(it)) },
                onOpenThread = { vm.openThread(post) },
                onComment = { vm.openSheet(Sheet.CommentComposer(vm.targetForPost(post))) },
                onOpenViewer = { vm.openViewer(post, it) },
                onLongPress = { vm.openSheet(Sheet.PostSheet(post)) },
            )
        }
    }
    item(key = "feed-footer") {
        Box(Modifier.columnItem()) {
            when {
                feed.loading || !feed.ready -> FooterNote("Loading…")
                feed.exhausted && feed.posts.isNotEmpty() -> FooterNote("That's everything.")
            }
        }
    }
}
