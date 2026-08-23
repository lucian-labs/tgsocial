package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.NodeEntry
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.GraphUi
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.columnItem
import androidx.compose.ui.graphics.drawscope.translate
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

/** PRODUCT §2.7 — radial canvas (you gold 10pt centre, follows 8pt ring 1, +1 6pt faint ring 2), then the two lists. */
fun LazyListScope.GraphItems(vm: AppViewModel, graph: GraphUi, me: NodeSnapshot?, cards: Map<String, NodeSnapshot>) {
    item(key = "graph-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Your network") }
    }
    item(key = "graph-canvas") {
        Box(Modifier.columnItem()) {
            HPCard(padding = androidx.compose.foundation.layout.PaddingValues(HPTokens.Space.rowGap)) {
                NetworkCanvas(graph.direct, graph.plusOne, cards, onTap = { vm.push(Screen.Profile(it)) })
            }
        }
    }
    nodeSection(vm, "Direct", graph.direct, me, emptyText = if (graph.loading && !graph.loaded) "Loading…" else "Follow someone and they appear here.", showMutual = false, keyPrefix = "direct", count = graph.direct.size)
    nodeSection(vm, "+1", graph.plusOne, me, emptyText = if (graph.loading && !graph.loaded) "Loading…" else "Follow someone and their people appear here.", showMutual = true, keyPrefix = "plusone", count = graph.plusOne.size)
}

private data class Dot(val username: String, val x: Float, val y: Float, val radius: Float, val ring: Int)

@androidx.compose.runtime.Composable
private fun NetworkCanvas(direct: List<NodeEntry>, plusOne: List<NodeEntry>, cards: Map<String, NodeSnapshot>, onTap: (String) -> Unit) {
    var pan by remember { mutableStateOf(Offset.Zero) }
    var canvasSize by remember { mutableStateOf(IntSize.Zero) }
    val density = LocalDensity.current
    val r10 = with(density) { 5.dp.toPx() }
    val r8 = with(density) { 4.dp.toPx() }
    val r6 = with(density) { 3.dp.toPx() }
    val hit = with(density) { 20.dp.toPx() }
    val line = with(density) { HPTokens.BORDER_WIDTH.dp.toPx() }

    // Fixed radial layout, angles evenly spaced; no physics.
    val dots: List<Dot> = remember(direct, plusOne, canvasSize, r10, r8, r6) {
        if (canvasSize == IntSize.Zero) return@remember emptyList()
        val cx = canvasSize.width / 2f
        val cy = canvasSize.height / 2f
        val min = minOf(canvasSize.width, canvasSize.height).toFloat()
        val ring1 = min * 0.22f
        val ring2 = min * 0.42f
        val out = ArrayList<Dot>()
        out += Dot("", cx, cy, r10, 0)
        direct.forEachIndexed { i, e ->
            val a = -Math.PI / 2 + 2 * Math.PI * i / direct.size.coerceAtLeast(1)
            out += Dot(e.username, cx + (ring1 * cos(a)).toFloat(), cy + (ring1 * sin(a)).toFloat(), r8, 1)
        }
        plusOne.forEachIndexed { i, e ->
            val a = -Math.PI / 2 + 2 * Math.PI * (i + 0.5) / plusOne.size.coerceAtLeast(1)
            out += Dot(e.username, cx + (ring2 * cos(a)).toFloat(), cy + (ring2 * sin(a)).toFloat(), r6, 2)
        }
        out
    }
    val edges: List<Pair<Dot, Dot>> = remember(dots, cards) {
        val byKey = dots.associateBy { Username.key(it.username) }
        val centre = dots.firstOrNull { it.ring == 0 } ?: return@remember emptyList()
        val out = ArrayList<Pair<Dot, Dot>>()
        for (d in dots.filter { it.ring == 1 }) {
            out += centre to d
            for (f in cards[Username.key(d.username)]?.card?.follows.orEmpty()) {
                val t = byKey[Username.key(f)] ?: continue
                out += d to t
            }
        }
        out
    }

    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1f)
            .onSizeChanged { canvasSize = it }
            .semantics { contentDescription = "Your network: ${direct.size} direct, ${plusOne.size} at distance two. Tap a dot to open a node." }
            .pointerInput(Unit) {
                detectDragGestures { change, drag -> change.consume(); pan += drag }
            }
            .pointerInput(dots) {
                detectTapGestures { p ->
                    val local = p - pan
                    dots.filter { it.ring > 0 }.minByOrNull { hypot(it.x - local.x, it.y - local.y) }
                        ?.takeIf { hypot(it.x - local.x, it.y - local.y) <= hit }
                        ?.let { onTap(it.username) }
                }
            },
    ) {
        translate(pan.x, pan.y) {
            for ((a, b) in edges) drawLine(HPTokens.Colors.line, Offset(a.x, a.y), Offset(b.x, b.y), line)
            for (d in dots) {
                val color = when (d.ring) { 0 -> HPTokens.Colors.accent; 1 -> HPTokens.Colors.ink; else -> HPTokens.Colors.faint }
                drawCircle(color, d.radius, Offset(d.x, d.y))
            }
        }
    }
}
