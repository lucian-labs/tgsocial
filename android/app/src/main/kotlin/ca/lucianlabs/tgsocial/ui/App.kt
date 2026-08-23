package ca.lucianlabs.tgsocial.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import ca.lucianlabs.housepour.HPBackdrop
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPModal
import ca.lucianlabs.housepour.HPTabs
import ca.lucianlabs.housepour.HPToastHost
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HPTopbar
import ca.lucianlabs.housepour.HPWordmark
import ca.lucianlabs.housepour.HousePourTheme
import ca.lucianlabs.housepour.hpColumnContentPadding
import ca.lucianlabs.housepour.hpColumnWidth
import ca.lucianlabs.tgsocial.ui.components.PullToRefresh
import ca.lucianlabs.tgsocial.ui.components.StatusPill
import ca.lucianlabs.tgsocial.ui.screens.ComposeSheet
import ca.lucianlabs.tgsocial.ui.screens.EditCardSheet
import ca.lucianlabs.tgsocial.ui.screens.ExploreItems
import ca.lucianlabs.tgsocial.ui.screens.FeedChannelItems
import ca.lucianlabs.tgsocial.ui.screens.FeedItems
import ca.lucianlabs.tgsocial.ui.screens.GraphItems
import ca.lucianlabs.tgsocial.ui.screens.ProfileItems
import ca.lucianlabs.tgsocial.ui.screens.SetupItems
import ca.lucianlabs.tgsocial.ui.screens.SignInScreen
import ca.lucianlabs.tgsocial.ui.screens.SignOutSheet
import ca.lucianlabs.tgsocial.ui.screens.YouItems
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter

@Composable
fun TgSocialApp(vm: AppViewModel = viewModel()) {
    HousePourTheme {
        HPBackdrop {
            val auth by vm.auth.collectAsStateWithLifecycle()
            if (auth.step != AuthStep.READY) {
                SignInScreen(vm)
            } else {
                Shell(vm)
            }
            HPToastHost(vm.toast)
        }
    }
}

@Composable
private fun Shell(vm: AppViewModel) {
    val stack by vm.stack.collectAsStateWithLifecycle()
    val sheet by vm.sheet.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val tab by vm.tab.collectAsStateWithLifecycle()
    val setupNeeded by vm.setupNeeded.collectAsStateWithLifecycle()
    val screen = stack.last()
    val pushed = stack.size > 1

    BackHandler(enabled = pushed || sheet != null) { vm.back() }

    // The topbar overlays the scroll container so cards pass under the translucent bar; the lists pad their top
    // by the measured bar height (LocalTopInset).
    val density = LocalDensity.current
    var topbarHeight by remember { mutableStateOf(0.dp) }
    Box(modifier = Modifier.fillMaxSize()) {
        CompositionLocalProvider(LocalTopInset provides topbarHeight) {
            Box(modifier = Modifier.fillMaxSize().imePadding()) {
                when (screen) {
                    Screen.Home -> if (setupNeeded) SetupHost(vm, feedsOnly = false) else Home(vm, tab)
                    Screen.Setup -> SetupHost(vm, feedsOnly = false)
                    Screen.ManageFeeds -> SetupHost(vm, feedsOnly = true)
                    is Screen.Profile -> {
                        val profile by vm.profile.collectAsStateWithLifecycle()
                        val me by vm.me.collectAsStateWithLifecycle()
                        ColumnList(key = screen, state = remember(screen) { LazyListState() }) { ProfileItems(vm, profile, me) }
                    }
                    is Screen.FeedChannel -> {
                        val channel by vm.channel.collectAsStateWithLifecycle()
                        val state = remember(screen) { LazyListState() }
                        LoadMoreWhenNear(state) { vm.loadMoreChannel() }
                        ColumnList(key = screen, state = state) { FeedChannelItems(vm, channel) }
                    }
                }
            }
        }
        HPTopbar(
            modifier = Modifier.align(Alignment.TopCenter).onSizeChanged { topbarHeight = with(density) { it.height.toDp() } },
            leading = {
                if (pushed) HPButton("‹ Back", { vm.back() }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Back")
                else HPWordmark(modifier = Modifier.semantics { contentDescription = "tgsocial" })
            },
            trailing = { StatusPill(status) },
        )
    }

    // One modal host that stays composed: it fades in when a sheet opens and keeps the last sheet's content
    // while it fades out (COMPONENTS HPModal: fades `Motion.toast`).
    var lastSheet by remember { mutableStateOf<Sheet?>(null) }
    if (sheet != null) lastSheet = sheet
    HPModal(isPresented = sheet != null, onDismiss = vm::closeSheet) {
        when (sheet ?: lastSheet) {
            is Sheet.Compose -> ComposeSheet(vm)
            Sheet.EditCard -> EditCardSheet(vm)
            Sheet.SignOut -> SignOutSheet(vm)
            null -> Unit
        }
    }
}

/** Height of the overlaid topbar; lists pad their top by it so the first card starts below the bar. */
val LocalTopInset = compositionLocalOf { 0.dp }

@Composable
private fun SetupHost(vm: AppViewModel, feedsOnly: Boolean) {
    val setup by vm.setup.collectAsStateWithLifecycle()
    val me by vm.me.collectAsStateWithLifecycle()
    val setupNeeded by vm.setupNeeded.collectAsStateWithLifecycle()
    ColumnList(key = "setup-$feedsOnly") { SetupItems(vm, setup, me, feedsOnly, canSkip = setupNeeded) }
}

@Composable
private fun Home(vm: AppViewModel, tab: Tab) {
    val feed by vm.feed.collectAsStateWithLifecycle()
    val explore by vm.explore.collectAsStateWithLifecycle()
    val graph by vm.graph.collectAsStateWithLifecycle()
    val me by vm.me.collectAsStateWithLifecycle()
    val myNode by vm.myNode.collectAsStateWithLifecycle()
    val cards by vm.cards.collectAsStateWithLifecycle()
    val refreshing = when (tab) {
        Tab.FEED -> feed.refreshing
        Tab.EXPLORE -> explore.loading
        Tab.GRAPH -> graph.loading
        Tab.YOU -> false
    }
    val state = remember(tab) { LazyListState() }
    if (tab == Tab.FEED) LoadMoreWhenNear(state) { vm.loadMoreFeed() }
    PullToRefresh(
        refreshing = refreshing,
        topInset = LocalTopInset.current,
        onRefresh = {
            when (tab) {
                Tab.FEED -> vm.refreshFeed(resetCursors = true)
                Tab.EXPLORE -> vm.loadExplore()
                Tab.GRAPH -> vm.loadGraph()
                Tab.YOU -> vm.refreshFeed(resetCursors = true)
            }
        },
    ) {
        ColumnList(key = tab, state = state) {
            item(key = "tabs") {
                HPTabs(
                    items = Tab.entries.map { it.label },
                    selected = tab.ordinal,
                    onSelect = { vm.selectTab(Tab.entries[it]) },
                    modifier = Modifier.hpColumnWidth().padding(bottom = HPTokens.Space.tabsBottom),
                )
            }
            when (tab) {
                Tab.FEED -> FeedItems(vm, feed, me)
                Tab.EXPLORE -> ExploreItems(vm, explore, me)
                Tab.GRAPH -> GraphItems(vm, graph, me, cards)
                Tab.YOU -> YouItems(vm, me, myNode)
            }
        }
    }
}

/** The HPColumn as a LazyColumn: column width, side padding, bottom safe area. */
@Composable
fun ColumnList(key: Any?, state: LazyListState = rememberLazyListState(), content: LazyListScope.() -> Unit) {
    val padding: PaddingValues = hpColumnContentPadding(top = LocalTopInset.current + HPTokens.Space.topbarBottom)
    LazyColumn(
        state = state,
        modifier = Modifier.fillMaxSize(),
        contentPadding = padding,
        horizontalAlignment = Alignment.CenterHorizontally,
        content = content,
    )
}

/** Infinite scroll: fire when the last item is within ~two screens of the bottom. */
@Composable
fun LoadMoreWhenNear(state: LazyListState, onLoadMore: () -> Unit) {
    LaunchedEffect(state) {
        snapshotFlow {
            val info = state.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            val visible = info.visibleItemsInfo.size
            last >= info.totalItemsCount - 1 - visible * 2 && info.totalItemsCount > 0
        }.distinctUntilChanged().filter { it }.collect { onLoadMore() }
    }
}

/** Keep item widths inside the column. */
fun Modifier.columnItem(): Modifier = this.hpColumnWidth().fillMaxWidth()
