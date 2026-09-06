package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPTabs
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.FeedMode
import ca.lucianlabs.tgsocial.ui.FeedUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.Tab
import ca.lucianlabs.tgsocial.ui.WorkUi
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FooterNote
import ca.lucianlabs.tgsocial.ui.components.PostCard

/**
 * PRODUCT §2.3 — the main feed. Strictly chronological (PROTOCOL §4.8).
 *
 * §2.24 — and, when the reader's network carries work, two ways to read it. A **mode**, not a fifth tab: a
 * tab would say there are two networks and there is one. The same nodes, the same follows, the same cards,
 * read two ways, which is the whole claim PROTOCOL §10 is built to prove.
 */
@OptIn(ExperimentalFoundationApi::class)
fun LazyListScope.FeedItems(vm: AppViewModel, feed: FeedUi, me: NodeSnapshot?, mode: FeedMode, work: WorkUi) {
    // The control appears only when at least one node in my follows, or I, carry a `work.feeds` entry: a
    // reader whose network has no work in it sees Feed exactly as it is today. It stays visible in **both**
    // modes, so the mode is never a state someone is stuck in.
    if (work.available) {
        stickyHeader(key = "feed-mode") {
            Box(
                Modifier
                    .fillMaxWidth()
                    // Sticky under the topbar, and painted the way the topbar is. `HPBackdrop` is a gradient
                    // plus a gold wash centred above the top-left corner and a violet one at the top-right,
                    // and this strip sits exactly where both are strongest — so a flat `backdropTop` rect
                    // cannot match the ground beneath it, and reads as a lighter band with the wash still
                    // running at full strength either side of it. The kit's own answer for a bar over this
                    // backdrop is HPTopbar's translucent `topbarBg` carried edge to edge (Android takes the
                    // fill without the blur, COMPONENTS), so this is that fill, bled back out over the
                    // column's side padding to the screen edges. No shadow: the floating tab bar (PRODUCT §1)
                    // is the one raised pill on this screen.
                    .bleedX(HPTokens.Space.columnSide)
                    .background(HPTokens.Colors.topbarBg)
                    .padding(bottom = HPTokens.Space.rowGap),
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.padding(horizontal = HPTokens.Space.columnSide).columnItem()) {
                    HPTabs(
                        items = FeedMode.entries.map { it.label },
                        selected = mode.ordinal,
                        onSelect = { vm.setFeedMode(FeedMode.entries[it]) },
                    )
                }
            }
        }
    }
    if (mode == FeedMode.WORK && work.available) {
        WorkFeedItems(vm, work)
        return
    }
    // PRODUCT §2.18 — `chaining` is a page the filter took whole with more still to fetch (FeedUi). That is
    // not an empty feed and must not be dressed as one: the next page is on its way in.
    if (feed.ready && feed.posts.isEmpty() && !feed.loading && !feed.chaining) {
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
    // PRODUCT §2.3 — the window is anchored at the pagination cursor, so once it is full a live post newer than
    // the head cannot be inserted without punching a hole in the feed (FeedOrder.window). Deep in a paginated
    // session this is the way back to the top: refresh rebuilds from the newest post down.
    if (feed.newerAvailable) {
        item(key = "feed-newer") {
            Box(Modifier.columnItem()) {
                HPButton("Newer posts", { vm.refreshFeed() }, style = HPButtonStyle.ACCENT, contentDescription = "Jump to newest posts")
            }
        }
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
                onComment = { vm.openCommentComposer(post) },
                onOpenViewer = { vm.openViewer(post, it) },
                onLongPress = { vm.openSheet(Sheet.PostSheet(post)) },
            )
        }
    }
    item(key = "feed-footer") {
        Box(Modifier.columnItem()) {
            when {
                feed.loading || !feed.ready || feed.chaining -> FooterNote("Loading…")
                feed.exhausted && feed.posts.isNotEmpty() -> FooterNote("That's everything.")
            }
        }
    }
}

/**
 * Paint past the column's side padding, out to the screen edges: the content is measured [inset] wider on
 * each side and placed back over the margins, while the item still reports the column's own width so nothing
 * around it moves. What a sticky bar needs and a `background` on a padded item cannot do: the list itself is
 * full width and only its content is inset, so the overflow lands inside the list's own bounds and is drawn.
 */
private fun Modifier.bleedX(inset: Dp): Modifier = layout { measurable, constraints ->
    val extra = inset.roundToPx() * 2
    val wide = constraints.copy(
        minWidth = constraints.minWidth + extra,
        maxWidth = if (constraints.hasBoundedWidth) constraints.maxWidth + extra else constraints.maxWidth,
    )
    val placeable = measurable.measure(wide)
    layout((placeable.width - extra).coerceAtLeast(0), placeable.height) {
        placeable.place(-inset.roundToPx(), 0)
    }
}
