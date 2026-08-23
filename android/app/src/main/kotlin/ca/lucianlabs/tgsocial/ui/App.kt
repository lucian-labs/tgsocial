package ca.lucianlabs.tgsocial.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
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
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.util.UnstableApi
import ca.lucianlabs.housepour.HPBackdrop
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPFloatingTabs
import ca.lucianlabs.housepour.HPModal
import ca.lucianlabs.housepour.HPNowPlaying
import ca.lucianlabs.housepour.HPToastHost
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HPTopbar
import ca.lucianlabs.housepour.HPWordmark
import ca.lucianlabs.housepour.HousePourTheme
import ca.lucianlabs.housepour.hpColumnWidth
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.ui.components.PullToRefresh
import ca.lucianlabs.tgsocial.ui.components.StatusPill
import ca.lucianlabs.tgsocial.ui.media.PlaybackHub
import ca.lucianlabs.tgsocial.ui.media.PostViewer
import ca.lucianlabs.tgsocial.ui.media.rememberTgApp
import ca.lucianlabs.tgsocial.ui.screens.CommentComposerSheet
import ca.lucianlabs.tgsocial.ui.screens.ComposeSheet
import ca.lucianlabs.tgsocial.ui.screens.DeleteCommentSheet
import ca.lucianlabs.tgsocial.ui.screens.EditCardSheet
import ca.lucianlabs.tgsocial.ui.screens.ExploreItems
import ca.lucianlabs.tgsocial.ui.screens.FeedChannelItems
import ca.lucianlabs.tgsocial.ui.screens.FeedItems
import ca.lucianlabs.tgsocial.ui.screens.GraphItems
import ca.lucianlabs.tgsocial.ui.screens.PostSheet
import ca.lucianlabs.tgsocial.ui.screens.ProfileItems
import ca.lucianlabs.tgsocial.ui.screens.SetupItems
import ca.lucianlabs.tgsocial.ui.screens.SignInScreen
import ca.lucianlabs.tgsocial.ui.screens.SignOutSheet
import ca.lucianlabs.tgsocial.ui.screens.StatusSheet
import ca.lucianlabs.tgsocial.ui.screens.ThreadItems
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

@OptIn(UnstableApi::class)
@Composable
private fun Shell(vm: AppViewModel) {
    val stack by vm.stack.collectAsStateWithLifecycle()
    val sheet by vm.sheet.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val tab by vm.tab.collectAsStateWithLifecycle()
    val setupNeeded by vm.setupNeeded.collectAsStateWithLifecycle()
    val viewer by vm.viewer.collectAsStateWithLifecycle()
    val screen = stack.last()
    val pushed = stack.size > 1

    BackHandler(enabled = pushed || sheet != null || viewer != null) { vm.back() }

    // PRODUCT §1 — the floating tab bar is hidden on Sign in (outside the shell), Setup, and inside
    // full-screen viewers; it stays on pushed screens.
    val onSetup = (screen is Screen.Home && setupNeeded) || screen is Screen.Setup
    val tabsVisible = !onSetup && viewer == null

    // PRODUCT §2.11 — the now-playing row docks at the bottom while audio plays, even where the tab bar is
    // hidden (Setup, a thread reached from a viewer); only a full-screen viewer covers it.
    val app = rememberTgApp()
    val now by app.playback.now.collectAsStateWithLifecycle()
    val dockVisible = now != null && viewer == null

    // The topbar overlays the scroll container so cards pass under the translucent bar; the lists pad their top
    // by the measured bar height (LocalTopInset). The bottom overlay does the same with LocalBottomInset: the
    // measured tab-bar height when the bar is up, plus the measured now-playing dock height while audio plays —
    // each tracked as its own State, so the inset grows when playback starts and falls back when it stops.
    val density = LocalDensity.current
    var topbarHeight by remember { mutableStateOf(0.dp) }
    var tabsHeight by remember { mutableStateOf(0.dp) }
    var dockHeight by remember { mutableStateOf(0.dp) }
    val bottomInset = (if (tabsVisible) tabsHeight else 0.dp) + (if (dockVisible) dockHeight else 0.dp)
    Box(modifier = Modifier.fillMaxSize()) {
        CompositionLocalProvider(
            LocalTopInset provides topbarHeight,
            LocalBottomInset provides bottomInset,
        ) {
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
                    is Screen.Thread -> {
                        // PRODUCT §2.12 — the thread refreshes its comment index when opened; pull-to-refresh re-scans.
                        val refreshing by vm.commentsRefreshing.collectAsStateWithLifecycle()
                        val state = remember(screen) { LazyListState() }
                        PullToRefresh(refreshing = refreshing, topInset = LocalTopInset.current, onRefresh = { vm.refreshComments(force = true) }) {
                            ColumnList(key = screen, state = state) { ThreadItems(vm, screen.post) }
                        }
                    }
                }
            }
        }
        if (viewer == null) {
            HPTopbar(
                modifier = Modifier.align(Alignment.TopCenter).onSizeChanged { topbarHeight = with(density) { it.height.toDp() } },
                leading = {
                    if (pushed) HPButton("‹ Back", { vm.back() }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Back")
                    else HPWordmark(modifier = Modifier.semantics { contentDescription = "tgsocial" })
                },
                trailing = { StatusPill(status) { vm.openSheet(Sheet.Status) } },
            )
        }
        if (tabsVisible || dockVisible) {
            BottomOverlay(
                vm = vm,
                tab = tab,
                now = now.takeIf { dockVisible },
                tabsVisible = tabsVisible,
                onTabsHeight = { tabsHeight = it },
                onDockHeight = { dockHeight = it },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
        // PRODUCT §2.11 — the full-screen viewer covers the shell: topbar and floating tab bar are gone while it is up.
        viewer?.let { PostViewer(vm, it) }
    }

    // One modal host that stays composed: it fades in when a sheet opens and keeps the last sheet's content
    // while it fades out (COMPONENTS HPModal: fades `Motion.toast`).
    var lastSheet by remember { mutableStateOf<Sheet?>(null) }
    if (sheet != null) lastSheet = sheet
    HPModal(isPresented = sheet != null, onDismiss = vm::closeSheet) {
        when (val s = sheet ?: lastSheet) {
            is Sheet.Compose -> ComposeSheet(vm)
            Sheet.EditCard -> EditCardSheet(vm)
            Sheet.SignOut -> SignOutSheet(vm)
            Sheet.Status -> StatusSheet(vm)
            is Sheet.CommentComposer -> CommentComposerSheet(vm)
            is Sheet.DeleteComment -> DeleteCommentSheet(vm, s.comment)
            is Sheet.PostSheet -> PostSheet(vm, s.post)
            null -> Unit
        }
    }
}

/**
 * PRODUCT §1 / §2.11 — the floating bottom pill, with the now-playing row docked above it while audio plays.
 * Either half can stand alone: the dock keeps floating where the tab bar is hidden (Setup, a thread reached
 * from a viewer). Content scrolls under this overlay; lists pad their bottom by the measured heights + `cardGap`
 * (LocalBottomInset), reported piecewise through [onTabsHeight] / [onDockHeight].
 */
@OptIn(UnstableApi::class)
@Composable
private fun BottomOverlay(
    vm: AppViewModel,
    tab: Tab,
    now: PlaybackHub.NowPlaying?,
    tabsVisible: Boolean,
    onTabsHeight: (Dp) -> Unit,
    onDockHeight: (Dp) -> Unit,
    modifier: Modifier = Modifier,
) {
    val app = rememberTgApp()
    val density = LocalDensity.current
    val nav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    Column(modifier = modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        now?.let { playing ->
            // `rowGap` keeps the docked row's cast shadow off the tab pill — two raised surfaces never touch.
            // Alone (tab bar hidden), the dock takes the bar's own safe-area clearance instead.
            Box(
                Modifier
                    .onSizeChanged { onDockHeight(with(density) { it.height.toDp() }) }
                    .hpColumnWidth()
                    .padding(horizontal = HPTokens.Space.columnSide)
                    .padding(bottom = if (tabsVisible) HPTokens.Space.rowGap else nav + HPTokens.Space.cardGap),
            ) {
                HPNowPlaying(
                    title = playing.title,
                    playing = playing.playing,
                    elapsed = Format.duration((playing.positionMs / 1000).toInt()),
                    onToggle = { app.playback.toggleCurrent() },
                    onStop = { app.playback.stopAudio() },
                )
            }
        }
        if (tabsVisible) {
            HPFloatingTabs(
                items = Tab.entries.map { it.label },
                selected = tab.ordinal,
                onSelect = { vm.selectTab(Tab.entries[it]) },
                modifier = Modifier.onSizeChanged { onTabsHeight(with(density) { it.height.toDp() }) },
            )
        }
    }
}

/** Height of the overlaid topbar; lists pad their top by it so the first card starts below the bar. */
val LocalTopInset = compositionLocalOf { 0.dp }

/** Height of the floating tab bar overlay (bar + now-playing + safe area); lists pad their bottom by it + cardGap. */
val LocalBottomInset = compositionLocalOf { 0.dp }

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
            when (tab) {
                Tab.FEED -> FeedItems(vm, feed, me)
                Tab.EXPLORE -> ExploreItems(vm, explore, me)
                Tab.GRAPH -> GraphItems(vm, graph, me, cards)
                Tab.YOU -> YouItems(vm, me, myNode)
            }
        }
    }
}

/**
 * The HPColumn as a LazyColumn: column width, side padding, and — when the floating tab bar is up — a bottom
 * pad of the overlay height + `cardGap` so the last card clears the pill (PRODUCT §1).
 */
@Composable
fun ColumnList(key: Any?, state: LazyListState = rememberLazyListState(), content: LazyListScope.() -> Unit) {
    val nav = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val bottomInset = LocalBottomInset.current
    val bottom = if (bottomInset > 0.dp) bottomInset + HPTokens.Space.cardGap else HPTokens.Space.bottomSafe + nav
    val padding = PaddingValues(
        start = HPTokens.Space.columnSide,
        end = HPTokens.Space.columnSide,
        top = LocalTopInset.current + HPTokens.Space.topbarBottom,
        bottom = bottom,
    )
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
