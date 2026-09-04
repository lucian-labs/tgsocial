package ca.lucianlabs.tgsocial.ui.media

import android.app.Application
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPStrip
import ca.lucianlabs.housepour.HPTokens
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
 * PRODUCT §2.11.1, last paragraph: "Voice notes and video notes use the same strip — a video note keeps its
 * circular player and gets the strip as the transport underneath it." That sentence is shared copy and
 * shared behaviour (§3), and Android was the build that did not meet it: the circle played, and there was
 * nothing under it to see the clip in, pause it from, or drag.
 *
 * So what these render is [PlayingVideoNote] — the note's own playing state, circle and transport together,
 * with only the ExoPlayer surface swapped for a stand-in that installs the same tap the real one does. That
 * is the placement the divergence was about: driving `VideoNoteTransport` on its own would measure a
 * component nothing is obliged to call. Delete the `VideoNoteTransport(...)` call from [PlayingVideoNote]
 * and all six of these fail (measured, not asserted); drop the circle instead and the first is what
 * catches it.
 *
 * Every check drives real touches at real coordinates over the assembled note, with the picture above the
 * strip and a tappable neighbour below it — COMPONENTS rule 6's own test — because a control that reports a
 * 40dp box and loses every point of it to a sibling is not a control.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class VideoNoteTransportTest {

    @get:Rule
    val rule = createComposeRule()

    private var fired: String? = null
    private var seekedTo: Float? = null

    /** 0:37 into a 2:05 note — real numbers, so the serif times below are a real reading of them. */
    private fun show(strip: HPStrip? = HPStrip(null, FloatArray(64) { 0.5f })) {
        rule.setContent {
            HousePourTheme(resolver = HPFontResolver { null }) {
                Box(Modifier.width(HPTokens.Space.columnMax)) {
                    Column {
                        PlayingVideoNote(
                            playing = true,
                            positionMs = 37_000,
                            durationMs = 125_000,
                            strip = strip,
                            onToggle = { fired = TOGGLE },
                            onSeek = { fired = SEEK; seekedTo = it },
                        ) {
                            // Stands in for the video output, and claims the circle the same way
                            // `InlinePlayerPicture` does: fillMaxSize, clickable, no indication. A picture
                            // that took no touches would make the sweep below easier than the real card.
                            Box(
                                Modifier
                                    .fillMaxSize()
                                    .clickable(
                                        interactionSource = remember { MutableInteractionSource() },
                                        indication = null,
                                    ) { fired = PICTURE }
                                    .semantics { contentDescription = PICTURE_LABEL },
                            )
                        }
                        // The card does not end at the transport: the post text follows it.
                        HPButton("Comment", { fired = COMMENT }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
                    }
                }
            }
        }
    }

    private fun probe(x: Int, y: Int): String {
        fired = null
        rule.onRoot().performTouchInput { click(Offset(x.toFloat(), y.toFloat())) }
        rule.waitForIdle()
        return fired ?: "-"
    }

    private fun bounds(label: String) =
        rule.onNodeWithContentDescription(label, useUnmergedTree = true).getUnclippedBoundsInRoot()

    /**
     * The sentence's two halves in the order it gives them: the circular player is still there and still
     * round, and the strip is UNDERNEATH it — not inside it, where a clipped shape would make the row a
     * chord instead of a control.
     */
    @Test
    fun `the note keeps its circle and puts the strip underneath it`() {
        show()
        val circle = bounds(PICTURE_LABEL)
        val w = (circle.right - circle.left).value
        val h = (circle.bottom - circle.top).value
        assertEquals("the player is round, not ${w}x${h}dp", w, h, 1f)
        val strip = bounds(SEEK_LABEL)
        assertTrue("the strip starts at ${strip.top}, above the circle's bottom ${circle.bottom}",
            strip.top.value + EPSILON >= circle.bottom.value)
    }

    /**
     * The strip IS the video note's scrubber (§2.11.1) — not the hairline, which the sentence after that one
     * reserves for a video MESSAGE. Tapping a third of the way along seeks a third of the way in, which is
     * the whole claim: "you can see where the loud part is before you drag to it".
     */
    @Test
    fun `the strip under the circle seeks the note`() {
        show()
        val strip = bounds(SEEK_LABEL)
        val y = ((strip.top + strip.bottom) / 2).value.toInt()
        val left = strip.left.value
        val width = (strip.right - strip.left).value
        for (fraction in listOf(0.15f, 0.5f, 0.8f)) {
            seekedTo = null
            assertEquals("the strip answered the tap", SEEK, probe((left + width * fraction).toInt(), y))
            assertEquals("tapped $fraction along the strip", fraction, seekedTo ?: -1f, 0.03f)
        }
    }

    /** And it keeps rule 6's 40dp under a finger, with a tappable sibling on EITHER side of it in the card. */
    @Test
    fun `the strip keeps a live 40dp region between its neighbours`() {
        show()
        val strip = bounds(SEEK_LABEL)
        val x = ((strip.left + strip.right) / 2).value.toInt()
        // Sweep from inside the picture above to past the button below, so both siblings get their chance
        // to steal points. The longest UNBROKEN run, not a count: 40dp scattered around a sibling is not 40dp.
        val from = maxOf(0, strip.top.value.toInt() - MARGIN)
        val to = strip.bottom.value.toInt() + MARGIN
        var live = 0
        var run = 0
        for (yy in from..to) {
            run = if (probe(x, yy) == SEEK) run + 1 else 0
            if (run > live) live = run
        }
        println("[live] the video note's strip answers ${live}dp of unbroken taps at x=$x")
        assertTrue("the strip is ${live.dp} tall under a finger, under ${HPTokens.Space.touchMin}",
            live + EPSILON >= HPTokens.Space.touchMin.value)
    }

    /**
     * A transport with no pause is a picture. The glyph is the same 40dp target the video message's
     * transport uses, and it toggles this note rather than the shared audio player.
     */
    @Test
    fun `the play glyph pauses the note and keeps its own 40dp target`() {
        show()
        val glyph = bounds("Pause")
        val w = (glyph.right - glyph.left).value
        val h = (glyph.bottom - glyph.top).value
        assertTrue("the glyph target is ${w}dp wide", w + EPSILON >= HPTokens.Space.touchMin.value)
        assertTrue("the glyph target is ${h}dp tall", h + EPSILON >= HPTokens.Space.touchMin.value)
        val x = ((glyph.left + glyph.right) / 2).value.toInt()
        val y = ((glyph.top + glyph.bottom) / 2).value.toInt()
        assertEquals("the glyph answered its own centre", TOGGLE, probe(x, y))
    }

    /**
     * The serif elapsed / total either side of it, read off the position rather than the label — the same
     * `Format.duration` every other transport in the app renders (PRODUCT §3: one wording, three builds).
     */
    @Test
    fun `elapsed and total are the clip's own times`() {
        show()
        rule.onNodeWithText("0:37", useUnmergedTree = true).assertExists()
        rule.onNodeWithText("2:05", useUnmergedTree = true).assertExists()
    }

    /**
     * §2.11.1: "The row is usable the moment it appears; the spectrum fills in." A note whose analysis has
     * not landed (or failed) still gets a transport that seeks — the picture degrades, the control does not.
     */
    @Test
    fun `an unanalysed note still has a transport that seeks`() {
        show(strip = null)
        val strip = bounds(SEEK_LABEL)
        val y = ((strip.top + strip.bottom) / 2).value.toInt()
        val x = (strip.left.value + (strip.right - strip.left).value * 0.6f).toInt()
        seekedTo = null
        assertEquals(SEEK, probe(x, y))
        assertEquals(0.6f, seekedTo ?: -1f, 0.03f)
    }

    private companion object {
        const val SEEK_LABEL = "Seek video note"
        const val PICTURE_LABEL = "Video note picture"
        const val SEEK = "seek"
        const val TOGGLE = "toggle"
        const val PICTURE = "picture"
        const val COMMENT = "comment"
        const val EPSILON = 0.5f
        /** How far past the strip on each side to sweep: into the picture above, past the button below. */
        const val MARGIN = 60
    }
}
