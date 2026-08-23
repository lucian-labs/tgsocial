package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPTokens
import kotlinx.coroutines.launch

/**
 * Pull-to-refresh without Material: a nested-scroll pull that reveals a muted `Pull to refresh` / `Refreshing…`
 * row above the list. House Pour motion: settles on `Motion.color` tweens, no springs, no spinner.
 *
 * [topInset] is the height of whatever overlays the top of the content (the translucent topbar) so the indicator
 * row appears below it rather than beneath it.
 */
@Composable
fun PullToRefresh(
    refreshing: Boolean,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier,
    topInset: Dp = 0.dp,
    content: @Composable () -> Unit,
) {
    val density = LocalDensity.current
    // Release past two avatar rows; the revealed row is one touch target tall.
    val threshold = with(density) { (HPTokens.Space.avatarRow * 2).toPx() }
    val indicator = with(density) { HPTokens.Space.touchMin.toPx() }
    val pull = remember { Animatable(0f) }
    val scope = rememberCoroutineScope()
    val settle = tween<Float>(HPTokens.Motion.COLOR_MS)

    // The connection is remembered once; read the latest values through state so a tab switch (same call site,
    // different onRefresh) never fires a stale lambda or reads a stale `refreshing`.
    val isRefreshing by rememberUpdatedState(refreshing)
    val refresh by rememberUpdatedState(onRefresh)

    LaunchedEffect(refreshing) {
        if (refreshing) pull.animateTo(indicator, settle) else pull.animateTo(0f, settle)
    }

    val connection = remember {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (isRefreshing) return Offset.Zero
                if (available.y < 0 && pull.value > 0f) {
                    val consumed = maxOf(available.y, -pull.value)
                    scope.launch { pull.snapTo(pull.value + consumed) }
                    return Offset(0f, consumed)
                }
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (isRefreshing || source != NestedScrollSource.UserInput) return Offset.Zero
                if (available.y > 0) {
                    val next = (pull.value + available.y * 0.5f).coerceAtMost(threshold * 1.6f)
                    scope.launch { pull.snapTo(next) }
                    return Offset(0f, available.y)
                }
                return Offset.Zero
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                if (!isRefreshing && pull.value >= threshold) {
                    refresh()
                    pull.animateTo(indicator, settle)
                } else if (!isRefreshing) {
                    pull.animateTo(0f, settle)
                }
                return Velocity.Zero
            }
        }
    }

    Box(modifier = modifier.nestedScroll(connection)) {
        val offsetPx = pull.value.toInt()
        Box(
            modifier = Modifier.fillMaxWidth().padding(top = topInset).height(with(density) { offsetPx.toDp() }),
            contentAlignment = Alignment.Center,
        ) {
            if (offsetPx > 0) {
                HPMuted(if (refreshing) "Refreshing…" else if (pull.value >= threshold) "Release to refresh" else "Pull to refresh", maxLines = 1)
            }
        }
        Column(modifier = Modifier.offset { IntOffset(0, offsetPx) }) { content() }
    }
}
