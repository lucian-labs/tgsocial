package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPMosaic
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HousePourTheme
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.model.Post
import ca.lucianlabs.tgsocial.model.PostMedia
import ca.lucianlabs.tgsocial.model.PostText
import ca.lucianlabs.tgsocial.ui.components.PostCard
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * PRODUCT §2.11.3 on the **assembled card** — `HPMosaicTest` proves the arithmetic, this proves the screen.
 *
 * Two claims live here, and neither survives being asked of a component in isolation (COMPONENTS rule 6):
 * every tile answers a finger over at least `touchMin` in both directions, and the tile that answers is the
 * one that was touched — "tapping any tile opens the carousel at that tile", where *that tile* means its page
 * in the post's own media, not its place in the mosaic.
 *
 * The card is the shipping [PostCard]; nothing here is a mock-up of it.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
// The stock Application: TgApp boots TDLib, which has no business in a measure pass. No repo means no pixels,
// which is the same state as a photo that has not downloaded yet — the tile still lays out and still taps.
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class PhotoMosaicHitRegionTest {

    @get:Rule
    val rule = createComposeRule()

    private var fired: String? = null

    private val touchMin: Dp = HPTokens.Space.touchMin

    private fun photos(n: Int, aspect: Float = 1f) = List(n) {
        PostMedia.Photo(FileRef(id = it, uniqueId = "photo-$it"), width = (1000 * aspect).toInt(), height = 1000)
    }

    private fun show(media: List<PostMedia>, text: String? = "Four takes from the same afternoon.") {
        rule.setContent {
            HousePourTheme(resolver = HPFontResolver { null }) {
                Box(Modifier.width(HPTokens.Space.columnMax)) {
                    PostCard(
                        post = Post(
                            chatId = 1,
                            messageId = 2,
                            date = 1_700_000_000,
                            sourceUsername = "waveloop",
                            sourceTitle = "WaveLoop devlog",
                            nodeUsername = "ana",
                            nodeName = "Ana Iliovic",
                            text = text?.let { PostText(it) },
                            media = media,
                        ),
                        commentCount = 3,
                        onOpenChannel = { fired = "channel" },
                        onOpenProfile = { fired = "profile" },
                        onOpenThread = { fired = "thread" },
                        onComment = { fired = "comment" },
                        onOpenViewer = { fired = "viewer:$it" },
                        onLongPress = { fired = "sheet" },
                    )
                }
            }
        }
    }

    private fun tile(n: Int): DpRect =
        rule.onNodeWithContentDescription("Photo $n", useUnmergedTree = true).getUnclippedBoundsInRoot()

    private fun tileCount(): Int {
        var n = 0
        while (n < 12 && rule.onAllNodesWithContentDescription("Photo ${n + 1}", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()) n++
        return n
    }

    private fun probe(x: Int, y: Int): String {
        fired = null
        rule.onRoot().performTouchInput { click(Offset(x.toFloat(), y.toFloat())) }
        rule.waitForIdle()
        return fired ?: "-"
    }

    private fun probeCentre(rect: DpRect): String =
        probe(((rect.left + rect.right) / 2).value.toInt(), ((rect.top + rect.bottom) / 2).value.toInt())

    private val DpRect.wide: Dp get() = right - left
    private val DpRect.tall: Dp get() = bottom - top

    @Test
    fun `two photos draw two tiles side by side and each opens its own page`() {
        show(photos(2))
        assertEquals("two tiles", 2, tileCount())
        val a = tile(1)
        val b = tile(2)
        assertEquals("equal width", a.wide.value, b.wide.value, EPSILON)
        assertEquals("full height, both", a.tall.value, b.tall.value, EPSILON)
        assertTrue("side by side", b.left >= a.right)
        assertEquals("viewer:0", probeCentre(a))
        assertEquals("viewer:1", probeCentre(b))
    }

    @Test
    fun `three photos draw one tall leading tile with two stacked beside it`() {
        show(photos(3))
        assertEquals(3, tileCount())
        val lead = tile(1)
        val top = tile(2)
        val bottom = tile(3)
        assertTrue("the leading tile is the tall one", lead.tall > top.tall)
        assertTrue("the stack is beside it", top.left >= lead.right && bottom.left >= lead.right)
        assertTrue("and stacked", bottom.top >= top.bottom)
        assertEquals("the leading tile is as tall as the block", lead.tall.value, (bottom.bottom - top.top).value, EPSILON)
        assertEquals("viewer:0", probeCentre(lead))
        assertEquals("viewer:1", probeCentre(top))
        assertEquals("viewer:2", probeCentre(bottom))
    }

    @Test
    fun `four photos draw two by two`() {
        show(photos(4))
        assertEquals(4, tileCount())
        val a = tile(1)
        val b = tile(2)
        val c = tile(3)
        val d = tile(4)
        assertEquals("a and b share a row", a.top.value, b.top.value, EPSILON)
        assertEquals("c and d share a row", c.top.value, d.top.value, EPSILON)
        assertEquals("a and c share a column", a.left.value, c.left.value, EPSILON)
        assertTrue("the second row is under the first", c.top >= a.bottom)
        for ((i, rect) in listOf(a, b, c, d).withIndex()) assertEquals("viewer:$i", probeCentre(rect))
    }

    /** §2.11.3: five or more paint the first four, and the fourth carries the `+N` — and still opens page 3. */
    @Test
    fun `seven photos draw four tiles with a plus count, and the last still opens its own page`() {
        show(photos(7))
        assertEquals("never more than four tiles", HPMosaic.MAX_TILES, tileCount())
        rule.onNodeWithText("+3", useUnmergedTree = true).assertExists()
        assertEquals("viewer:3", probeCentre(tile(4)))
    }

    /**
     * The region, on the assembled card: a `touchMin` window centred on each tile answers that tile at every
     * point of both axes, and so do the tile's own inner corners — a neighbour that had taken a strip of it
     * would show up in one or the other. The mosaic never needs an overlay to reach that, because
     * [HPMosaic.plan] refuses to lay out a cell under `touchMin` in the first place.
     */
    @Test
    fun `every tile answers a finger over at least a hit target in both directions`() {
        show(photos(4))
        for (n in 1..4) {
            val rect = tile(n)
            val who = "viewer:${n - 1}"
            assertTrue("tile $n paints ${rect.wide} wide", rect.wide.value + EPSILON >= touchMin.value)
            assertTrue("tile $n paints ${rect.tall} tall", rect.tall.value + EPSILON >= touchMin.value)
            val cx = ((rect.left + rect.right) / 2).value.toInt()
            val cy = ((rect.top + rect.bottom) / 2).value.toInt()
            val half = touchMin.value.toInt() / 2
            for (step in -half..half) {
                assertEquals("tile $n loses a point $step dp down its centre", who, probe(cx, cy + step))
                assertEquals("tile $n loses a point $step dp across its centre", who, probe(cx + step, cy))
            }
            // The corners are inset by `radius-media`: the block is clipped to that radius on its outer
            // corners (§2.11.3 — it reads as ONE object), and a clipped layer does not answer touches
            // outside its own shape, so the outermost corner point belongs to nobody by design. Inside the
            // radius the tile owns every edge — which is the assertion a neighbour stealing a strip fails.
            val inset = HPTokens.Radius.media.value.toInt() + 1
            for (x in listOf(rect.left.value.toInt() + inset, rect.right.value.toInt() - inset)) {
                for (y in listOf(rect.top.value.toInt() + inset, rect.bottom.value.toInt() - inset)) {
                    assertEquals("tile $n loses its corner at ($x, $y)", who, probe(x, y))
                }
            }
            // And the straight edges are the tile's from 1dp in — nothing above or beside it reaches in.
            assertEquals("tile $n loses its top edge", who, probe(cx, rect.top.value.toInt() + 1))
            assertEquals("tile $n loses its bottom edge", who, probe(cx, rect.bottom.value.toInt() - 1))
            assertEquals("tile $n loses its left edge", who, probe(rect.left.value.toInt() + 1, cy))
            assertEquals("tile $n loses its right edge", who, probe(rect.right.value.toInt() - 1, cy))
            println("[live] tile $n = ${rect.wide} x ${rect.tall}, whole and its own")
        }
    }

    /** A single photo is not a mosaic: §2.11.3 starts at two, and one photo keeps §2.11's full-width media. */
    @Test
    fun `one photo is still one photo`() {
        show(photos(1))
        assertEquals("no tiles", 0, tileCount())
        assertEquals("viewer:0", probeCentre(rule.onNodeWithContentDescription("Photo", useUnmergedTree = true).getUnclippedBoundsInRoot()))
    }

    /** The block keeps a sane ratio: four portraits must not paint a block taller than the clamp allows. */
    @Test
    fun `a tall album does not set the block's height`() {
        show(photos(4, aspect = 0.4f))
        val block = tile(4).bottom - tile(1).top
        val width = tile(2).right - tile(1).left
        assertTrue("the block is $block for a width of $width", block <= width / HPTokens.Ratio.mosaicMin + 1.dp)
    }

    private companion object {
        const val EPSILON = 0.5f
    }
}
