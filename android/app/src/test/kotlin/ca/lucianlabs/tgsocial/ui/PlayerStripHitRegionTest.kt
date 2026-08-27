package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.click
import androidx.compose.ui.test.down
import androidx.compose.ui.test.moveTo
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.up
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPPlayerRow
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
 * COMPONENTS rule 6 for the spectrogram strip (PRODUCT §2.11.1: "The strip keeps the 40pt hit region of any
 * control, taller than its painted height if need be"), measured the way rule 6 requires — by injecting real
 * taps at 1dp steps over the **assembled** player row, with a neighbour placed after it, rather than by
 * asking one composable how big it thinks it is.
 *
 * The strip is the case where the drawn shape *is* the region: it paints `stripHeight` (44dp), which already
 * clears `touchMin`, so there is no overlay to reach past its own bounds and nothing to tile against. What
 * still has to be proved is that it holds all 44 under a finger with a clickable sibling below it — Compose
 * hit-tests children in reverse placement order, so a later sibling wins every point the two share.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class PlayerStripHitRegionTest {

    @get:Rule
    val rule = createComposeRule()

    private var fired: String? = null
    private var seekedTo: Float? = null

    private val touchMin: Dp = HPTokens.Space.touchMin

    private fun show(strip: HPStrip?) {
        rule.setContent {
            HousePourTheme(resolver = HPFontResolver { null }) {
                Box(Modifier.width(HPTokens.Space.columnMax)) {
                    Column {
                        HPPlayerRow(
                            title = TITLE,
                            subtitle = "Ana Iliovic",
                            playing = false,
                            progress = 0.4f,
                            elapsed = "0:12",
                            total = "0:30",
                            onToggle = { fired = TOGGLE },
                            onSeek = { fired = SEEK; seekedTo = it },
                            strip = strip,
                        )
                        // The card does not end at the row: something tappable always follows it.
                        HPButton(
                            "Comment",
                            { fired = COMMENT },
                            style = HPButtonStyle.GHOST,
                            size = HPButtonSize.SMALL,
                        )
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

    /** The longest unbroken run of taps that reach [who], sweeping down the column at [x]. */
    private fun liveSpan(x: Int, who: String, to: Int): IntRange? {
        var best: IntRange? = null
        var start = -1
        for (y in 0..to) {
            if (probe(x, y) == who) {
                if (start < 0) start = y
                if (best == null || y - start > best.last - best.first) best = start..y
            } else {
                start = -1
            }
        }
        return best
    }

    @Test
    fun `the strip keeps a live 40dp seek region on the assembled row`() {
        show(HPStrip(null, FloatArray(64) { 0.5f }))
        val bounds = rule.onNodeWithContentDescription(SEEK_LABEL, useUnmergedTree = true).getUnclippedBoundsInRoot()
        val x = ((bounds.left + bounds.right) / 2).value.toInt()
        val span = liveSpan(x, SEEK, SWEEP_TO) ?: throw AssertionError("the strip never answered a tap")
        val live = (span.last - span.first + 1).dp
        println("[live] the strip = $live (y ${span.first}..${span.last}) at x=$x; painted ${bounds.top}..${bounds.bottom}")
        assertTrue("the strip is $live tall under a finger, under $touchMin — rule 6", live.value + EPSILON >= touchMin.value)
        // And it is the painted shape that carries it, not an overlay reaching past the row.
        assertEquals("the strip paints its own region", HPTokens.Space.stripHeight.value, (bounds.bottom - bounds.top).value, EPSILON)
        assertTrue("stripHeight must clear touchMin", HPTokens.Space.stripHeight.value >= touchMin.value)
    }

    @Test
    fun `nothing else answers inside the strip's band`() {
        show(HPStrip(null, FloatArray(64) { 0.5f }))
        val bounds = rule.onNodeWithContentDescription(SEEK_LABEL, useUnmergedTree = true).getUnclippedBoundsInRoot()
        val x = ((bounds.left + bounds.right) / 2).value.toInt()
        for (y in bounds.top.value.toInt() + 1 until bounds.bottom.value.toInt()) {
            assertEquals("something else answers inside the strip at y=$y", SEEK, probe(x, y))
        }
    }

    @Test
    fun `a tap anywhere along the strip seeks to that point`() {
        show(HPStrip(null, FloatArray(64) { 0.5f }))
        val bounds = rule.onNodeWithContentDescription(SEEK_LABEL, useUnmergedTree = true).getUnclippedBoundsInRoot()
        val y = ((bounds.top + bounds.bottom) / 2).value.toInt()
        val left = bounds.left.value
        val width = (bounds.right - bounds.left).value
        for (fraction in listOf(0.1f, 0.5f, 0.85f)) {
            seekedTo = null
            assertEquals(SEEK, probe((left + width * fraction).toInt(), y))
            assertEquals("tapped at $fraction along the strip", fraction, seekedTo ?: -1f, 0.03f)
        }
    }

    /**
     * §2.11.1's fallback: with nothing analysed the strip is a hairline, and the row is usable the moment it
     * appears. The region is the same 44dp either way — degrading the picture must not degrade the control.
     */
    @Test
    fun `the region survives with nothing analysed at all`() {
        show(null)
        val bounds = rule.onNodeWithContentDescription(SEEK_LABEL, useUnmergedTree = true).getUnclippedBoundsInRoot()
        val x = ((bounds.left + bounds.right) / 2).value.toInt()
        val span = liveSpan(x, SEEK, SWEEP_TO) ?: throw AssertionError("the fallback strip never answered a tap")
        val live = (span.last - span.first + 1).dp
        println("[live] the fallback strip = $live (y ${span.first}..${span.last})")
        assertTrue("the fallback strip is $live tall, under $touchMin — rule 6", live.value + EPSILON >= touchMin.value)
    }

    /** The same row, with a caller-driven width, for the tests that resize it under a finger. */
    private fun showResizable(width: () -> Dp) {
        rule.setContent {
            HousePourTheme(resolver = HPFontResolver { null }) {
                Box(Modifier.width(width())) {
                    HPPlayerRow(
                        title = TITLE,
                        subtitle = "Ana Iliovic",
                        playing = false,
                        progress = 0.4f,
                        elapsed = "0:12",
                        total = "0:30",
                        onToggle = { fired = TOGGLE },
                        onSeek = { fired = SEEK; seekedTo = it },
                        strip = HPStrip(null, FloatArray(64) { 0.5f }),
                    )
                }
            }
        }
    }

    /**
     * §2.11.1: "Tap or drag anywhere on the strip to seek." The tap half is covered above; this is the drag,
     * which commits on release and must commit the fraction the finger ended on.
     */
    @Test
    fun `a drag across the strip commits the fraction it ends on`() {
        show(HPStrip(null, FloatArray(64) { 0.5f }))
        seekedTo = null
        rule.onNodeWithContentDescription(SEEK_LABEL, useUnmergedTree = true).performTouchInput {
            swipe(
                start = Offset(width * 0.1f, height / 2f),
                end = Offset(width * 0.8f, height / 2f),
                durationMillis = 200,
            )
        }
        rule.waitForIdle()
        assertEquals("the drag committed where it ended", 0.8f, seekedTo ?: -1f, 0.03f)
    }

    /**
     * The strip's width can change *between* the touch that starts a drag and the drag itself: the manifest
     * keeps `orientation|screenSize` out of the recreate list, so a rotation resizes the row without
     * restarting the composition or the `pointerInput` block. A drag that divided by a width captured at
     * first touch would then send the far end of the strip past 1.0 (everything seeks to the end) or cap it
     * short of it (the far end becomes unreachable).
     */
    @Test
    fun `a drag still seeks where the finger is after the strip changes width`() {
        var width by mutableStateOf(HPTokens.Space.columnMax / 2)
        showResizable { width }
        val strip = rule.onNodeWithContentDescription(SEEK_LABEL, useUnmergedTree = true)

        strip.performTouchInput { down(Offset(this.width * 0.25f, this.height / 2f)) }
        width = HPTokens.Space.columnMax
        rule.waitForIdle()

        seekedTo = null
        strip.performTouchInput {
            moveTo(Offset(this.width * 0.75f, this.height / 2f))
            up()
        }
        rule.waitForIdle()
        assertEquals("the drag used the strip's width at the time of the drag", 0.75f, seekedTo ?: -1f, 0.03f)
    }

    private companion object {
        const val TITLE = "Devlog 14"
        const val SEEK_LABEL = "Seek"
        const val SEEK = "seek"
        const val TOGGLE = "toggle"
        const val COMMENT = "comment"
        const val EPSILON = 0.5f
        /** Past the bottom of the row and its neighbour. */
        const val SWEEP_TO = 220
    }
}
