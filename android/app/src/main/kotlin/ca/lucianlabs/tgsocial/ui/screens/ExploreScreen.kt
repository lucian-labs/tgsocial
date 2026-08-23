package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.PaddingValues
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPFieldKind
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPTextField
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.ExploreUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.NodeRow

/** PRODUCT §2.4 — Find a node, Nearby (+1 ranked by mutual count), Directory. */
fun LazyListScope.ExploreItems(vm: AppViewModel, explore: ExploreUi, me: NodeSnapshot?) {
    item(key = "explore-search") {
        Box(Modifier.columnItem()) {
            HPTextField(
                value = explore.query,
                onValueChange = vm::setQuery,
                placeholder = "Find a node",
                kind = HPFieldKind.Username,
                imeAction = ImeAction.Search,
                onSubmit = vm::submitQuery,
                contentDescription = "Find a node",
            )
        }
    }
    nodeSection(vm, "Nearby", explore.nearby, me, emptyText = if (explore.loading && !explore.loaded) "Loading…" else "Follow someone and their people appear here.", showMutual = true, keyPrefix = "nearby")
    nodeSection(vm, "Directory", explore.directory, me, emptyText = if (explore.loading && !explore.loaded) "Loading…" else "No nodes found. Be the first: make yours public.", showMutual = false, keyPrefix = "directory")
}

fun LazyListScope.nodeSection(
    vm: AppViewModel,
    title: String,
    entries: List<NodeEntry>,
    me: NodeSnapshot?,
    emptyText: String,
    showMutual: Boolean,
    keyPrefix: String,
    count: Int? = null,
) {
    item(key = "$keyPrefix-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap, top = HPTokens.Space.rowGap)) { HPSectionMark(title, count) }
    }
    item(key = "$keyPrefix-card") {
        Box(Modifier.columnItem()) {
            HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
                if (entries.isEmpty()) {
                    Spacer(Modifier.height(HPTokens.Space.rowPad))
                    HPMuted(emptyText)
                    Spacer(Modifier.height(HPTokens.Space.rowPad))
                } else {
                    Column {
                        entries.forEachIndexed { i, e ->
                            NodeRow(
                                entry = e,
                                isLast = i == entries.lastIndex,
                                following = me?.card?.follows(e.username) == true,
                                isMe = vm.isMe(e.username),
                                onOpen = { vm.push(Screen.Profile(e.username)) },
                                onFollow = { vm.follow(e.username) },
                                onUnfollow = { vm.unfollow(e.username) },
                                showMutual = showMutual,
                            )
                        }
                    }
                }
            }
        }
    }
}
