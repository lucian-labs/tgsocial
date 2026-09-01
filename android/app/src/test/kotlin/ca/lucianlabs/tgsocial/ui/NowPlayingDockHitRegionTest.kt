package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPFloatingTabs
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPNowPlaying
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
 * COMPONENTS rule 6 for the now-playing dock (PRODUCT §2.11.2: the mini waveform "keeps a 40pt hit region
 * though it paints thinner"), measured the way rule 6 requires — real taps at 1dp steps over the **assembled**
 * dock, with the floating tab bar placed after it exactly as the shell does, rather than by asking one
 * composable how big it thinks it is.
 *
 * Three things have to hold at once in a row this tight, and none of them is visible from a component on its
 * own: the waveform holds `touchMin` under a finger; it does not take those 40 out of the play circle beside
 * it (they are side by side, not stacked, which is the whole reason the row can afford both); and the row's
 * own tap — "tapping the row anywhere but its controls opens the post the audio came from" — reaches every
 * point the two controls do not.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class NowPlayingDockHitRegionTest {

    @get:Rule
    val rule = createComposeRule()

    private var fired: String? = null
    private var seekedTo: Float? = null

    private val touchMin: Dp = HPTokens.Space.touchMin

    /** The dock as the shell assembles it: the pill, then the floating tab bar under it (`App.kt`). */
    private fun show(peaks: FloatArray?, progress: Float = 0.4f, openable: Boolean = true) {
        rule.setContent {
            HousePourTheme(resolver = HPFontResolver { null }) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(HPTokens.Space.columnMax)) {
                    Box(Modifier.padding(horizontal = HPTokens.Space.columnSide, vertical = HPTokens.Space.rowGap)) {
                        HPNowPlaying(
                            title = TITLE,
                            playing = true,
                            elapsed = "0:12",
                            onToggle = { fired = TOGGLE },
                            onStop = { fired = STOP },
                            peaks = peaks,
                            progress = progress,
                            onSeek = { fired = SEEK; seekedTo = it },
                            onOpen = if (openable) ({ fired = OPEN }) else null,
                        )
                    }
                    HPFloatingTabs(items = listOf("Feed", "Explore"), selected = 0, onSelect = { fired = TABS })
                }
            }
        }
    }

    private fun bounds(description: String): DpRect =
        rule.onNodeWithContentDescription(description, useUnmergedTree = true).getUnclippedBoundsInRoot()

    /** For the things labelled by their own text rather than by a description: the title, the `Stop` button. */
    private fun textBounds(text: String): DpRect =
        rule.onNodeWithText(text, ignoreCase = true, useUnmergedTree = true).getUnclippedBoundsInRoot()

    private fun probe(x: Int, y: Int): String {
        fired = null
        rule.onRoot().performTouchInput { click(Offset(x.toFloat(), y.toFloat())) }
        rule.waitForIdle()
        return fired ?: "-"
    }

    /** The longest unbroken run of taps that reach [who] sweeping down the column at [x]. */
    private fun liveSpan(x: Int, who: String, from: Int, to: Int): IntRange? {
        var best: IntRange? = null
        var start = -1
        for (y in from..to) {
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
    fun `the mini waveform keeps a live 40dp seek region on the assembled dock`() {
        show(FloatArray(64) { 0.6f })
        val wave = bounds(WAVE)
        val x = ((wave.left + wave.right) / 2).value.toInt()
        val span = liveSpan(x, SEEK, 0, (wave.bottom + touchMin).value.toInt())
            ?: throw AssertionError("the waveform never answered a tap")
        val live = (span.last - span.first + 1).dp
        println("[live] mini waveform = $live (y ${span.first}..${span.last}) at x=$x; painted ${wave.top}..${wave.bottom}")
        assertTrue("the waveform is $live tall under a finger, under $touchMin — rule 6", live.value + EPSILON >= touchMin.value)
        // It paints `miniWaveHeight` and is touched over `touchMin`: the control's own box carries the
        // region, so nothing is owed by the row and nothing is stolen from it.
        assertEquals("the control's box is the region", touchMin.value, (wave.bottom - wave.top).value, EPSILON)
        assertTrue("and it paints thinner than that", HPTokens.Space.miniWaveHeight < touchMin)
    }

    @Test
    fun `the play circle keeps its own 40dp beside the waveform`() {
        show(FloatArray(64) { 0.6f })
        val circle = bounds("Pause")
        val x = ((circle.left + circle.right) / 2).value.toInt()
        val span = liveSpan(x, TOGGLE, 0, (circle.bottom + touchMin).value.toInt())
            ?: throw AssertionError("the play circle never answered a tap")
        val live = (span.last - span.first + 1).dp
        println("[live] play circle = $live (y ${span.first}..${span.last}) at x=$x")
        assertTrue("the circle is $live tall under a finger — rule 6", live.value + EPSILON >= touchMin.value)
        // The two controls are side by side, so neither region reaches into the other's column at all.
        assertTrue("the waveform starts after the circle ends", bounds(WAVE).left >= circle.right)
    }

    @Test
    fun `nothing else answers inside the waveform's band`() {
        show(FloatArray(64) { 0.6f })
        val wave = bounds(WAVE)
        val x = ((wave.left + wave.right) / 2).value.toInt()
        for (y in wave.top.value.toInt() + 1 until wave.bottom.value.toInt()) {
            assertEquals("something else answers inside the waveform at y=$y", SEEK, probe(x, y))
        }
    }

    @Test
    fun `a tap along the waveform seeks to that point, and a drag commits where it ends`() {
        show(FloatArray(64) { 0.6f })
        val wave = bounds(WAVE)
        val y = ((wave.top + wave.bottom) / 2).value.toInt()
        val left = wave.left.value
        val width = (wave.right - wave.left).value
        for (fraction in listOf(0.15f, 0.5f, 0.85f)) {
            seekedTo = null
            assertEquals(SEEK, probe((left + width * fraction).toInt(), y))
            assertEquals("tapped at $fraction along the waveform", fraction, seekedTo ?: -1f, 0.05f)
        }
        seekedTo = null
        rule.onNodeWithContentDescription(WAVE, useUnmergedTree = true).performTouchInput {
            swipe(start = Offset(this.width * 0.1f, this.height / 2f), end = Offset(this.width * 0.7f, this.height / 2f), durationMillis = 200)
        }
        rule.waitForIdle()
        assertEquals("the drag committed where it ended", 0.7f, seekedTo ?: -1f, 0.05f)
    }

    /** §2.11.2's fallback: a clip whose strip degraded to the hairline draws a flat line — and still seeks. */
    @Test
    fun `the region survives with no envelope at all`() {
        show(null)
        val wave = bounds(WAVE)
        val x = ((wave.left + wave.right) / 2).value.toInt()
        val span = liveSpan(x, SEEK, 0, (wave.bottom + touchMin).value.toInt())
            ?: throw AssertionError("the flat waveform never answered a tap")
        val live = (span.last - span.first + 1).dp
        println("[live] flat waveform = $live (y ${span.first}..${span.last})")
        assertTrue("the flat waveform is $live tall, under $touchMin — rule 6", live.value + EPSILON >= touchMin.value)
    }

    /** PRODUCT §2.11: "tapping the row anywhere but its controls opens the post the audio came from." */
    @Test
    fun `the row opens the post everywhere its controls do not`() {
        show(FloatArray(64) { 0.6f })
        val row = bounds("Now playing")
        val title = textBounds(TITLE)
        val y = ((row.top + row.bottom) / 2).value.toInt()
        assertEquals("the title is the row's, not a control's", OPEN, probe(((title.left + title.right) / 2).value.toInt(), y))
        // …and never at the cost of a control: each of the three keeps its own tap.
        assertEquals(TOGGLE, probe(((bounds("Pause").left + bounds("Pause").right) / 2).value.toInt(), y))
        assertEquals(SEEK, probe(((bounds(WAVE).left + bounds(WAVE).right) / 2).value.toInt(), y))
        val stop = textBounds("Stop")
        assertEquals(STOP, probe(((stop.left + stop.right) / 2).value.toInt(), y))
    }

    private companion object {
        const val TITLE = "Devlog 14"
        const val WAVE = "Progress"
        const val SEEK = "seek"
        const val TOGGLE = "toggle"
        const val STOP = "stop"
        const val OPEN = "open"
        const val TABS = "tabs"
        const val EPSILON = 0.5f
    }
}
