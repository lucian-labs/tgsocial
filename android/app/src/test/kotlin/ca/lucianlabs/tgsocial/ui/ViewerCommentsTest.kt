package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HPViewer
import ca.lucianlabs.housepour.HPViewerButton
import ca.lucianlabs.housepour.HousePourTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * PRODUCT §2.12 — **comments inside the carousel**, measured on the assembled viewer.
 *
 * "Opening it does not leave the media: the media shrinks to a mini view pinned at the top — the current item,
 * still tappable to restore it full-screen — and the thread takes the rest of the sheet."
 *
 * So three things: the media is still on screen and no longer full screen; a tap on it restores, even though
 * the page under the finger consumes taps of its own (zoom, play); and the new `Comments` control keeps the
 * `touchMin` region every control owes (COMPONENTS rule 6) next to the ones that were already there.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class ViewerCommentsTest {

    @get:Rule
    val rule = createComposeRule()

    private var fired: String? = null

    /** One composition per test — `setContent` may only be called once — so the state is what changes. */
    private var open by mutableStateOf(false)

    private val touchMin: Dp = HPTokens.Space.touchMin

    /** A page that consumes its own taps, as every real viewer page does (HPZoomable, the video surface). */
    @Composable
    private fun Page(page: Int) {
        Box(
            Modifier
                .fillMaxSize()
                .background(HPTokens.Colors.bg2)
                .pointerInput(page) { detectTapGestures { fired = "page:$page" } }
                .semantics { contentDescription = "Page $page" },
        )
    }

    private fun show(commentsOpen: Boolean) {
        open = commentsOpen
        rule.setContent {
            HousePourTheme(resolver = HPFontResolver { null }) {
                HPViewer(
                    pageCount = 3,
                    initialPage = 0,
                    onDismiss = { fired = "close" },
                    caption = CAPTION,
                    actions = {
                        HPViewerButton("Comments", { fired = "comments" })
                        HPViewerButton("Save", { fired = "save" })
                    },
                    sheet = if (open) ({ HPMuted(THREAD) }) else null,
                    onRestore = { fired = "restore" },
                ) { page, _ -> Page(page) }
            }
        }
    }

    private fun bounds(description: String): DpRect =
        rule.onNodeWithContentDescription(description, useUnmergedTree = true).getUnclippedBoundsInRoot()

    private fun probe(x: Int, y: Int): String {
        fired = null
        rule.onRoot().performTouchInput { click(Offset(x.toFloat(), y.toFloat())) }
        rule.waitForIdle()
        return fired ?: "-"
    }

    private fun liveSpan(fixed: Int, who: String, from: Int, to: Int, vertical: Boolean): IntRange? {
        var best: IntRange? = null
        var start = -1
        for (v in from..to) {
            val hit = if (vertical) probe(fixed, v) else probe(v, fixed)
            if (hit == who) {
                if (start < 0) start = v
                if (best == null || v - start > best.last - best.first) best = start..v
            } else {
                start = -1
            }
        }
        return best
    }

    @Test
    fun `the Comments control keeps a 40dp region beside the ones already there`() {
        show(commentsOpen = false)
        val comments = bounds("Comments")
        val cx = ((comments.left + comments.right) / 2).value.toInt()
        val cy = ((comments.top + comments.bottom) / 2).value.toInt()
        val down = liveSpan(cx, "comments", 0, (comments.bottom + touchMin).value.toInt(), vertical = true)
            ?: throw AssertionError("the Comments control never answered a tap")
        val live = (down.last - down.first + 1).dp
        println("[live] Comments = $live (y ${down.first}..${down.last})")
        assertTrue("Comments is $live tall under a finger, under $touchMin — rule 6", live.value + EPSILON >= touchMin.value)
        // And it does not stand on its neighbours: Close and Save keep their own taps in the same row.
        assertEquals("close", probe(((bounds("Close").left + bounds("Close").right) / 2).value.toInt(), cy))
        assertEquals("save", probe(((bounds("Save").left + bounds("Save").right) / 2).value.toInt(), cy))
        assertEquals("comments", probe(cx, cy))
    }

    @Test
    fun `opening comments shrinks the media instead of leaving it`() {
        show(commentsOpen = false)
        val full = bounds("Page 0")
        open = true
        rule.waitForIdle()
        val mini = bounds("Page 0")
        assertEquals("the mini view is the token height", HPTokens.Space.viewerMiniHeight.value, (mini.bottom - mini.top).value, EPSILON)
        assertTrue("which is smaller than full screen", (mini.bottom - mini.top) < (full.bottom - full.top))
        assertTrue("and it is pinned at the top, under the chrome", mini.top >= bounds("Close").top)
        // The thread takes the rest of the sheet, and the caption steps aside for it.
        rule.onNodeWithText(THREAD, useUnmergedTree = true).getUnclippedBoundsInRoot().let { sheet ->
            assertTrue("the thread starts under the mini view", sheet.top >= mini.bottom)
        }
        // The caption is the media's; with the thread open it is gone rather than sitting behind the sheet.
        assertEquals("the caption stepped aside", 0, rule.onAllNodesWithText(CAPTION, useUnmergedTree = true).fetchSemanticsNodes().size)
    }

    /** "still tappable to restore it full-screen" — over a page that consumes its own taps. */
    @Test
    fun `tapping the mini view restores the media`() {
        show(commentsOpen = true)
        val mini = bounds("Page 0")
        val hit = probe(((mini.left + mini.right) / 2).value.toInt(), ((mini.top + mini.bottom) / 2).value.toInt())
        assertEquals("restore", hit)
    }

    /** Full screen, the same tap belongs to the page — the restore only exists while comments are up. */
    @Test
    fun `full screen the page keeps its own taps`() {
        show(commentsOpen = false)
        val page = bounds("Page 0")
        assertEquals("page:0", probe(((page.left + page.right) / 2).value.toInt(), ((page.top + page.bottom) / 2).value.toInt()))
    }

    private companion object {
        const val CAPTION = "Four takes from the same afternoon."
        const val THREAD = "No comments from your network yet."
        const val EPSILON = 0.5f
    }
}
