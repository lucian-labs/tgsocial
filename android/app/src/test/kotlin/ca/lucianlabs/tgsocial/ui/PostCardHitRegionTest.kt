package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HousePourTheme
import ca.lucianlabs.tgsocial.model.Post
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
 * COMPONENTS rule 6 measured **live**, on the assembled card rather than on the header alone.
 *
 * [PostHeaderTest] asks the layout how big each hit target is. That is not the same question as how big it
 * *behaves*: an overlay is only as large as what will actually reach it, and Compose hit-tests a parent's
 * children in reverse placement order, so a clickable sibling placed below the header wins every point the two
 * share. The channel subheading used to measure 40dp and live at 30dp, with its bottom 10dp opening the thread.
 *
 * So this test injects real taps at absolute root coordinates in 1dp steps (density 1 — `mdpi`) and reads back
 * which handler fired, which is the only way that class of defect shows up. Nothing here is a mock-up of the
 * card: it renders the shipping [PostCard].
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
// The stock Application: TgApp boots TDLib, which has no business in a layout measurement. The card's avatar
// falls back to the initial, which is what an unphotographed channel renders anyway (PRODUCT §2.3).
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class PostCardHitRegionTest {

    @get:Rule
    val rule = createComposeRule()

    /** Which handler the last injected tap reached. */
    private var fired: String? = null

    private val touchMin: Dp = HPTokens.Space.touchMin

    private fun post(text: String?) = Post(
        chatId = 1,
        messageId = 2,
        date = 1_700_000_000,
        sourceUsername = "waveloop",
        sourceTitle = CHANNEL,
        nodeUsername = "ana",
        nodeName = NAME,
        text = text?.let { PostText(it) },
    )

    private fun show(text: String?) {
        rule.setContent {
            // A null font resolver keeps the kit's fallback families; the ramp's line heights are explicit
            // token values, so the measured stack does not depend on which face is installed.
            HousePourTheme(resolver = HPFontResolver { null }) {
                Box(Modifier.width(HPTokens.Space.columnMax)) {
                    PostCard(
                        post = post(text),
                        commentCount = 3,
                        onOpenChannel = { fired = CHANNEL_HIT },
                        onOpenProfile = { fired = NAME_HIT },
                        onOpenThread = { fired = THREAD_HIT },
                        onComment = { fired = "comment" },
                        onOpenViewer = { fired = "viewer" },
                        onLongPress = { fired = "sheet" },
                    )
                }
            }
        }
    }

    private fun bounds(description: String): DpRect =
        rule.onNodeWithContentDescription(description, useUnmergedTree = true).getUnclippedBoundsInRoot()

    /** Which handler a tap at absolute root (x, y) actually reaches — `-` for nothing. */
    private fun probe(x: Int, y: Int): String {
        fired = null
        rule.onRoot().performTouchInput { click(Offset(x.toFloat(), y.toFloat())) }
        rule.waitForIdle()
        return fired ?: "-"
    }

    /**
     * The longest unbroken run of taps that reach [who], sweeping straight down the column at [x]. This is the
     * control's real height under a finger; the layout's idea of it is [PostHeaderTest]'s business.
     */
    private fun liveSpan(x: Int, who: String): IntRange? {
        var best: IntRange? = null
        var start = -1
        for (y in 0..SWEEP_TO) {
            if (probe(x, y) == who) {
                if (start < 0) start = y
                if (best == null || y - start > best.last - best.first) best = start..y
            } else {
                start = -1
            }
        }
        return best
    }

    private fun assertLive(x: Int, who: String, label: String): IntRange {
        val span = liveSpan(x, who) ?: throw AssertionError("$label never fired anywhere down x=$x")
        // A run of N consecutive 1dp samples is N dp of live region: y and y+1 are 1dp apart, and the sample at
        // each end is inside the region.
        val live = (span.last - span.first + 1).dp
        println("[live] $label = $live (y ${span.first}..${span.last}) at x=$x")
        assertTrue("$label is $live tall under a finger, under $touchMin — rule 6", live.value + EPSILON >= touchMin.value)
        return span
    }

    private fun centreX(description: String): Int =
        bounds(description).let { ((it.left + it.right) / 2).value.toInt() }

    @Test
    fun `the name, the channel and the avatar keep live 40dp regions on the assembled card`() {
        show(TEXT)
        assertLive(centreX(NAME), NAME_HIT, "the avatar")
        val stackX = centreX("Open $CHANNEL")
        val name = assertLive(stackX, NAME_HIT, "the name")
        val channel = assertLive(stackX, CHANNEL_HIT, "the channel")
        // Rule 6's tiling clause: the boundary between two stacked controls is a line, not a gap and not an
        // overlap. Nothing sits between the name's last row and the channel's first…
        assertEquals("the name and the channel do not tile", name.last + 1, channel.first)
        // …and the body picks up on the row after the channel's last, rather than eating into it.
        assertEquals("the channel does not tile with the body text", THREAD_HIT, probe(stackX, channel.last + 1))
    }

    /**
     * The same sweep on a post with no text. The channel is the control the card squeezes — its target is the
     * one that hangs *downward*, into whatever comes next — and with no body that next thing is the footer's
     * `Comments` box, which carries its own `touchMin`. Asserted rather than assumed.
     */
    @Test
    fun `the channel keeps its region on a post with no text`() {
        show(null)
        assertLive(centreX("Open $CHANNEL"), CHANNEL_HIT, "the channel, no text")
    }

    /**
     * Share sits at the other end of the same row, and nothing in the card may reach into its band either.
     * Its own handler goes to the system share sheet rather than to a callback, so this reads the region the
     * only way it can from here: no *foreign* control answers inside it.
     */
    @Test
    fun `nothing intrudes on Share's band`() {
        show(TEXT)
        val share = bounds("Share")
        val x = ((share.left + share.right) / 2).value.toInt()
        for (y in share.top.value.toInt()..share.bottom.value.toInt()) {
            assertEquals("something else answers inside Share's band at y=$y", "-", probe(x, y))
        }
        println("[live] Share's band ${share.top}..${share.bottom} answers to nothing else")
    }

    private companion object {
        const val NAME = "Ana Iliovic"
        const val CHANNEL = "WaveLoop devlog"
        const val TEXT = "Some post text long enough to wrap onto a second line inside the card."
        const val NAME_HIT = "name"
        const val CHANNEL_HIT = "channel"
        const val THREAD_HIT = "thread"
        const val EPSILON = 0.5f
        /** Past the footer of the tallest card here; the sweep only needs to clear the header's neighbours. */
        const val SWEEP_TO = 200
    }
}
