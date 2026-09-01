package ca.lucianlabs.housepour

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * PRODUCT §2.11.3 — **the photo mosaic's layout rule**, as arithmetic: no Compose, no Android, so the
 * rectangles a screen will paint can be asserted directly.
 *
 * "A post with more than one photo is a mosaic, not a stack — an album is one thing, and reading it as
 * one block is the point."
 *
 * The three arrangements are the table in §2.11.3, and they are all **two columns wide**:
 *
 * ```
 *   2   a b       two tiles side by side, equal width
 *   3   a b       one TALL leading tile with two stacked beside it
 *       a c
 *   4   a b       two by two
 *       c d
 * ```
 *
 * Five or more paints the same four tiles with `+N` over the fourth. The same table drives the web build
 * (`web/js/mosaic.js` `MOSAIC_AREAS`) and the CSS grid it hands to `grid-template-areas`, so the three
 * platforms cannot disagree about which tile is where.
 */
object HPMosaic {

    /** §2.11.3: five photos and fifty both draw four tiles; the rest become `+N`. */
    const val MAX_TILES = 4

    /** Every layout above is two columns wide — the property the ratio derivation below leans on. */
    const val COLUMNS = 2

    /** Rows of tile indices, one entry per grid cell; a tile repeated down a column spans those rows. */
    private val AREAS: Map<Int, List<List<Int>>> = mapOf(
        2 to listOf(listOf(0, 1)),
        3 to listOf(listOf(0, 1), listOf(0, 2)),
        4 to listOf(listOf(0, 1), listOf(2, 3)),
    )

    /** One tile's rectangle in the block's own pixel space. */
    data class Cell(val index: Int, val left: Float, val top: Float, val width: Float, val height: Float)

    /**
     * A mosaic ready to place: the block's [height] for the width it was planned at, its [cells] in album
     * order, and the [overflow] count the last tile carries as `+N` (0 when the album fits).
     * [reflowed] records that the block fell back to a single column because the grid could not give
     * every tile a `touchMin` edge — §2.11.3's "reflows at the narrow end rather than overflowing".
     */
    data class Plan(
        val width: Float,
        val height: Float,
        val cells: List<Cell>,
        val overflow: Int,
        val reflowed: Boolean,
    )

    /** How many tiles an album of [count] photos paints. Under two is not a mosaic at all. */
    fun tiles(count: Int): Int = count.coerceAtLeast(0).coerceAtMost(MAX_TILES)

    /** How many photos hide behind the `+N` on the last tile. */
    fun overflow(count: Int): Int = (count - MAX_TILES).coerceAtLeast(0)

    /** The middle value — one panorama in an album of squares must not set the shape. */
    private fun median(values: List<Float>): Float? {
        val xs = values.filter { it.isFinite() && it > 0f }.sorted()
        if (xs.isEmpty()) return null
        val mid = xs.size / 2
        return if (xs.size % 2 == 1) xs[mid] else (xs[mid - 1] + xs[mid]) / 2
    }

    /**
     * §2.11.3's "aspect-aware, and the block keeps a sane overall ratio instead of letting one tall photo
     * set the height."
     *
     * Every layout is two columns, so a cell's ratio follows the block's: at three and four tiles a cell
     * is half the width and half the height — the block's ratio again — and at two it is half the width
     * at full height, half the block's. Solve "the cells look like the photos" for the block and it wants
     * `COLUMNS × r` at two tiles and `r` at three or four, where `r` is the median photo ratio. Then
     * clamp, which is what stops a column of portraits painting a block taller than the card and why a
     * tall photo **covers** its cell instead of setting the height.
     *
     * No usable shape at all (photos with no declared size) falls back to the middle of the sane range —
     * the geometric mean, so the fallback is centred in ratio rather than in arithmetic — instead of to a
     * guess about the picture.
     */
    fun ratio(
        aspects: List<Float>,
        shown: Int,
        min: Float = HPTokens.Ratio.mosaicMin,
        max: Float = HPTokens.Ratio.mosaicMax,
    ): Float {
        val r = median(aspects)
        val wanted = when {
            r == null -> sqrt(min * max)
            shown <= COLUMNS -> COLUMNS * r
            else -> r
        }
        return wanted.coerceIn(min, max)
    }

    /**
     * The block's rectangles at [width] pixels wide, with [gutter] hairlines between tiles.
     *
     * [minTile] is the floor every tile keeps in both axes (COMPONENTS rule 6 — a tile is a tap target,
     * and one narrower than `touchMin` is not one). Below it the grid cannot be drawn honestly, so the
     * block reflows to a single column rather than overflowing its card.
     */
    fun plan(
        count: Int,
        aspects: List<Float>,
        width: Float,
        gutter: Float,
        minTile: Float,
        min: Float = HPTokens.Ratio.mosaicMin,
        max: Float = HPTokens.Ratio.mosaicMax,
    ): Plan {
        val shown = tiles(count)
        val extra = overflow(count)
        if (shown < 2 || width <= 0f) return Plan(width, 0f, emptyList(), extra, reflowed = false)

        val rows = AREAS.getValue(shown)
        val columnWidth = (width - gutter * (COLUMNS - 1)) / COLUMNS
        val blockHeight = width / ratio(aspects, shown, min, max)
        val rowHeight = (blockHeight - gutter * (rows.size - 1)) / rows.size

        if (columnWidth < minTile || rowHeight < minTile) return column(shown, aspects, width, gutter, extra, min, max)

        // A tile's rectangle is the union of the grid cells carrying its index — which is what makes the
        // 3-up leading tile tall without a second code path.
        val cells = (0 until shown).map { index ->
            var top = Int.MAX_VALUE
            var bottom = Int.MIN_VALUE
            var left = Int.MAX_VALUE
            var right = Int.MIN_VALUE
            rows.forEachIndexed { r, row ->
                row.forEachIndexed { c, tile ->
                    if (tile == index) {
                        top = minOf(top, r); bottom = maxOf(bottom, r)
                        left = minOf(left, c); right = maxOf(right, c)
                    }
                }
            }
            Cell(
                index = index,
                left = left * (columnWidth + gutter),
                top = top * (rowHeight + gutter),
                width = (right - left + 1) * columnWidth + (right - left) * gutter,
                height = (bottom - top + 1) * rowHeight + (bottom - top) * gutter,
            )
        }
        return Plan(width, blockHeight, cells, extra, reflowed = false)
    }

    /** The narrow end: one full-width tile per row, each at its own clamped shape. Never overflows. */
    private fun column(
        shown: Int,
        aspects: List<Float>,
        width: Float,
        gutter: Float,
        extra: Int,
        min: Float,
        max: Float,
    ): Plan {
        var y = 0f
        val cells = (0 until shown).map { i ->
            val aspect = aspects.getOrNull(i)?.takeIf { it.isFinite() && it > 0f } ?: sqrt(min * max)
            val height = width / aspect.coerceIn(min, max)
            Cell(i, 0f, y, width, height).also { y += height + gutter }
        }
        return Plan(width, (y - gutter).coerceAtLeast(0f), cells, extra, reflowed = true)
    }
}

/**
 * PRODUCT §2.11.3 — **the photo mosaic**: an album drawn as one object.
 *
 * `radius-media` on the OUTER corners only (the block is clipped once, the tiles are not) with hairline
 * `line` gutters showing through between them, so it reads as one thing rather than four cards. Tiles
 * `cover` their cell — that is the caller's [tile], which is handed the cell's pixel size precisely so it
 * can request a thumbnail at TILE size rather than at card size.
 *
 * Tapping a tile calls [onTap] with that tile's index, which §2.11.3 requires to open the carousel at
 * that tile. Each tile's painted shape is its own hit region: [HPMosaic.plan] refuses to lay out a grid
 * whose cells fall under `touchMin` (COMPONENTS rule 6), so no overlay is needed and nothing is owed by
 * the container.
 */
@Composable
fun HPMosaic(
    count: Int,
    aspects: List<Float>,
    onTap: (Int) -> Unit,
    modifier: Modifier = Modifier,
    label: (Int) -> String = { "Photo ${it + 1}" },
    tile: @Composable (index: Int, widthPx: Int, heightPx: Int) -> Unit,
) {
    if (count < 2) return
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    BoxWithConstraints(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            // The gutters are this ground showing through the 1dp gaps between tiles — one hairline
            // surface under the block, never a border per tile.
            .background(HPTokens.Colors.line, shape),
    ) {
        val density = LocalDensity.current
        val widthPx = with(density) { maxWidth.toPx() }
        val gutterPx = with(density) { HPTokens.BORDER_WIDTH.dp.toPx() }
        val minTilePx = with(density) { HPTokens.Space.touchMin.toPx() }
        val plan = remember(count, aspects, widthPx, gutterPx, minTilePx) {
            HPMosaic.plan(count, aspects, widthPx, gutterPx, minTilePx)
        }
        Box(Modifier.fillMaxWidth().height(with(density) { plan.height.toDp() })) {
            for (cell in plan.cells) {
                val w = cell.width.roundToInt()
                val h = cell.height.roundToInt()
                Box(
                    modifier = Modifier
                        .offset { IntOffset(cell.left.roundToInt(), cell.top.roundToInt()) }
                        .size(with(density) { w.toDp() }, with(density) { h.toDp() })
                        .background(HPTokens.Colors.bg2)
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                            role = Role.Button,
                        ) { onTap(cell.index) }
                        .semantics { contentDescription = label(cell.index) },
                ) {
                    tile(cell.index, w, h)
                    // §2.11.3 — the `+N` in the pill style over a scrim, on the last tile only.
                    if (plan.overflow > 0 && cell.index == plan.cells.lastIndex) {
                        Box(
                            modifier = Modifier.fillMaxSize().background(HPTokens.Colors.scrim),
                            contentAlignment = Alignment.Center,
                        ) {
                            HPPill("+${plan.overflow}", HPPillTone.NEUTRAL)
                        }
                    }
                }
            }
        }
    }
}
