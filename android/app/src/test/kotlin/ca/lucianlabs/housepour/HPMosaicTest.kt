package ca.lucianlabs.housepour

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PRODUCT §2.11.3 — the mosaic's layout rule, asserted as the rectangles it actually produces.
 *
 * The arrangement per count is the section's own table, and the block's shape is the album's, clamped. Both
 * are pure arithmetic in [HPMosaic], which is the point: the geometry a reader sees can be checked without a
 * screen, and `PhotoMosaicHitRegionTest` then only has to prove that the screen places what this planned.
 */
class HPMosaicTest {

    private val gutter = 1f
    private val minTile = 40f
    private val width = 360f
    private val square = listOf(1f, 1f, 1f, 1f, 1f)

    private fun plan(count: Int, aspects: List<Float> = square, width: Float = this.width) =
        HPMosaic.plan(count, aspects.take(HPMosaic.MAX_TILES), width, gutter, minTile)

    @Test
    fun `two photos are side by side at equal width and full height`() {
        val p = plan(2)
        assertEquals("two tiles", 2, p.cells.size)
        val (a, b) = p.cells
        assertEquals("equal width", a.width, b.width, EPS)
        assertEquals("full height, both", p.height, a.height, EPS)
        assertEquals("full height, both", p.height, b.height, EPS)
        assertEquals("the leading tile starts at the left edge", 0f, a.left, EPS)
        assertEquals("one hairline between them", a.width + gutter, b.left, EPS)
        assertEquals("and the pair fills the block", width, b.left + b.width, EPS)
    }

    @Test
    fun `three photos are one tall leading tile with two stacked beside it`() {
        val p = plan(3)
        val lead = p.cells[0]
        val top = p.cells[1]
        val bottom = p.cells[2]
        assertEquals("the leading tile is full height", p.height, lead.height, EPS)
        assertEquals("the leading tile is a column wide", (width - gutter) / 2, lead.width, EPS)
        assertEquals("the stack sits beside it", lead.width + gutter, top.left, EPS)
        assertEquals("both stacked tiles share the second column", top.left, bottom.left, EPS)
        assertEquals("each is half the block, less the gutter", (p.height - gutter) / 2, top.height, EPS)
        assertEquals("each is half the block, less the gutter", (p.height - gutter) / 2, bottom.height, EPS)
        assertEquals("the second is under the first", top.top + top.height + gutter, bottom.top, EPS)
        assertEquals("and the stack ends where the block does", p.height, bottom.top + bottom.height, EPS)
    }

    @Test
    fun `four photos are two by two`() {
        val p = plan(4)
        assertEquals(4, p.cells.size)
        val (a, b, c, d) = p.cells
        assertEquals("a and b share a row", a.top, b.top, EPS)
        assertEquals("c and d share a row", c.top, d.top, EPS)
        assertEquals("a and c share a column", a.left, c.left, EPS)
        assertEquals("b and d share a column", b.left, d.left, EPS)
        for (cell in p.cells) {
            assertEquals("every tile is a quarter", (width - gutter) / 2, cell.width, EPS)
            assertEquals("every tile is a quarter", (p.height - gutter) / 2, cell.height, EPS)
        }
        assertEquals("nothing hides behind a +N", 0, p.overflow)
    }

    @Test
    fun `five or more paint four tiles and count the rest`() {
        for (count in 5..12) {
            val p = plan(count)
            assertEquals("still four tiles at $count photos", HPMosaic.MAX_TILES, p.cells.size)
            assertEquals("the rest are the +N", count - HPMosaic.MAX_TILES, p.overflow)
        }
        // The `+N` rides the LAST tile, which is the one whose index the carousel opens at (§2.11.3).
        assertEquals(HPMosaic.MAX_TILES - 1, plan(9).cells.last().index)
    }

    /** §2.11.3: "the block keeps a sane overall ratio rather than letting one tall photo set the height". */
    @Test
    fun `one tall photo does not set the block's height`() {
        val portraits = List(4) { 0.5f }
        val tall = plan(4, portraits)
        assertEquals("clamped at the tall end", width / HPTokens.Ratio.mosaicMin, tall.height, EPS)
        assertTrue("and so never taller than the clamp allows", tall.height <= width / HPTokens.Ratio.mosaicMin + EPS)

        // One panorama among squares is the median's job, not the mean's: it must not flatten the block.
        val squareBlock = plan(4, listOf(1f, 1f, 1f, 1f)).height
        val withPanorama = plan(4, listOf(1f, 1f, 1f, 6f)).height
        assertEquals("the odd one out does not move the block", squareBlock, withPanorama, EPS)

        // And a pair of panoramas is clamped at the wide end rather than drawing a letterbox slot.
        assertEquals(width / HPTokens.Ratio.mosaicMax, plan(2, listOf(6f, 6f)).height, EPS)
    }

    @Test
    fun `two tiles shape the block for a HALF width cell, three and four for a quarter`() {
        // A cell at two tiles is half the width at full height, so the block wants twice the photo's ratio;
        // at three and four a cell is half of both, so it wants the photo's ratio as it stands.
        val pair = 0.9f // twice this is still inside the clamp, so the derivation is what shows
        assertEquals(HPMosaic.COLUMNS * pair, HPMosaic.ratio(listOf(pair, pair), shown = 2), EPS)
        val r = 1.2f
        assertEquals(r, HPMosaic.ratio(listOf(r, r, r), shown = 3), EPS)
        assertEquals(r, HPMosaic.ratio(listOf(r, r, r, r), shown = 4), EPS)
        // …and the clamp still binds it: two square photos would want 2.0, which is past the wide end.
        assertEquals(HPTokens.Ratio.mosaicMax, HPMosaic.ratio(listOf(1f, 1f), shown = 2), EPS)
        // Photos with no declared size fall back to the middle of the sane range, not to a guess.
        val middle = HPMosaic.ratio(listOf(0f, 0f), shown = 4)
        assertTrue("between the clamps", middle > HPTokens.Ratio.mosaicMin && middle < HPTokens.Ratio.mosaicMax)
    }

    /** §2.11.3: "it reflows at the narrow end rather than overflowing." */
    @Test
    fun `a column too narrow for a tap target reflows instead of overflowing`() {
        val narrow = 60f // two columns of 29.5 — under `touchMin`, so not a tile anyone can hit
        val p = HPMosaic.plan(4, square.take(4), narrow, gutter, minTile)
        assertTrue("it reflowed", p.reflowed)
        assertEquals("one tile per row", 4, p.cells.size)
        for (cell in p.cells) {
            assertEquals("full width", narrow, cell.width, EPS)
            assertEquals("flush left", 0f, cell.left, EPS)
            assertTrue("and never wider than the block", cell.left + cell.width <= narrow + EPS)
        }
        assertEquals("stacked, one hairline apart", p.cells[0].height + gutter, p.cells[1].top, EPS)
        assertEquals("the block is as tall as its stack", p.cells.last().top + p.cells.last().height, p.height, EPS)
    }

    @Test
    fun `every tile in an ordinary mosaic clears the hit target floor`() {
        for (count in 2..8) {
            val p = plan(count)
            assertFalse("a phone-width mosaic never needs the reflow at $count", p.reflowed)
            for (cell in p.cells) {
                assertTrue("tile ${cell.index} of $count is ${cell.width} wide", cell.width >= minTile)
                assertTrue("tile ${cell.index} of $count is ${cell.height} tall", cell.height >= minTile)
            }
        }
    }

    @Test
    fun `nothing overlaps and nothing leaves the block`() {
        for (count in 2..7) {
            val p = plan(count)
            for (cell in p.cells) {
                assertTrue("inside the width", cell.left + cell.width <= p.width + EPS)
                assertTrue("inside the height", cell.top + cell.height <= p.height + EPS)
            }
            for (a in p.cells) {
                for (b in p.cells) {
                    if (a.index >= b.index) continue
                    val apart = a.left + a.width <= b.left + EPS || b.left + b.width <= a.left + EPS ||
                        a.top + a.height <= b.top + EPS || b.top + b.height <= a.top + EPS
                    assertTrue("tiles ${a.index} and ${b.index} of $count overlap", apart)
                }
            }
        }
    }

    private companion object {
        const val EPS = 0.01f
    }
}
