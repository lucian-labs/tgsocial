package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.click
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpRect
import androidx.compose.ui.unit.dp
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HousePourTheme
import ca.lucianlabs.tgsocial.ui.components.PostHeader
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.abs

private val DpRect.wide: Dp get() = right - left
private val DpRect.tall: Dp get() = bottom - top

/**
 * PRODUCT §2.3 header metrics and COMPONENTS rule 6 hit targets, taken off a real Compose measure pass
 * rather than read off a screenshot. Every expected value is derived from HPTokens — no hand-typed pixels.
 *
 * The painted line boxes are found by their text, the hit targets by their accessibility label, so the two
 * can be measured against each other: the overlay must be bigger than the box it covers.
 *
 * These are the header's *nominal* metrics, measured on the header alone. How big each target behaves once the
 * card places siblings under it is a different question and a different test — `PostCardHitRegionTest`, which
 * injects taps. The header alone always passes; the channel is the one that can ship smaller than it measures.
 */
@RunWith(RobolectricTestRunner::class)
// Native graphics: the line boxes have to be measured by the real text shaper, not by a stub Paint.
@GraphicsMode(GraphicsMode.Mode.NATIVE)
// The stock Application: TgApp boots TDLib, which has no business in a layout measurement.
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class PostHeaderTest {

    @get:Rule
    val rule = createComposeRule()

    private var openedName = 0
    private var openedChannel = 0

    /** Token-derived expectations: one body line over one mono-small line, and the avatar beside them. */
    private val avatar: Dp = HPTokens.Space.avatarRow
    private val nameLine: Dp = (HPTokens.Type.bodyStrong.size * HPTokens.Type.bodyStrong.lineHeight).dp
    private val channelLine: Dp = (HPTokens.Type.monoSmall.size * HPTokens.Type.monoSmall.lineHeight).dp
    private val stack: Dp = nameLine + channelLine
    private val touchMin: Dp = HPTokens.Space.touchMin

    private fun show(channelTitle: String? = CHANNEL) {
        rule.setContent {
            // A null font resolver keeps the kit's fallback families; the ramp's line heights are explicit
            // token values, so the measured stack does not depend on which face is installed.
            HousePourTheme(resolver = HPFontResolver { null }) {
                Box(Modifier.width(HPTokens.Space.columnMax - HPTokens.Space.cardPad * 2)) {
                    PostHeader(
                        avatar = null,
                        name = NAME,
                        initial = NAME.take(1),
                        channelTitle = channelTitle,
                        time = TIME,
                        onOpenName = { openedName++ },
                        onOpenChannel = { openedChannel++ },
                        onShare = {},
                        modifier = Modifier.testTag(HEADER),
                    )
                }
            }
        }
    }

    /** A hit target, found by the accessibility label it carries. */
    private fun target(description: String): SemanticsNodeInteraction =
        rule.onNodeWithContentDescription(description, useUnmergedTree = true)

    /** A painted line box, found by the text inside it. */
    private fun painted(text: String): DpRect =
        rule.onNodeWithText(text, useUnmergedTree = true).getUnclippedBoundsInRoot()

    private fun header(): DpRect = rule.onNodeWithTag(HEADER, useUnmergedTree = true).getUnclippedBoundsInRoot()

    private fun assertClose(expected: Dp, actual: Dp, what: String) {
        assertTrue(
            "$what: expected ~$expected, measured $actual (off by ${abs(expected.value - actual.value)}dp)",
            abs(expected.value - actual.value) <= TOLERANCE.value,
        )
    }

    @Test
    fun `the header is about one avatar tall`() {
        show()
        val h = header().tall
        println("[metrics] header=$h avatar=$avatar nameLine=$nameLine channelLine=$channelLine stack=$stack")
        // The row is the taller of the avatar and the two-line stack, and nothing in it is inflated past that.
        assertClose(maxOf(avatar, stack), h, "header height")
        assertTrue("header $h is more than a quarter taller than its own avatar ($avatar)", h.value <= avatar.value * 1.25f)
    }

    @Test
    fun `the name over channel stack is tight`() {
        show()
        val name = painted(NAME)
        val channel = painted(CHANNEL)
        println("[metrics] namePainted=${name.top}..${name.bottom} (${name.tall}) channelPainted=${channel.top}..${channel.bottom} (${channel.tall})")
        assertClose(nameLine, name.tall, "the name's line box")
        assertClose(channelLine, channel.tall, "the channel's line box")
        // No extra leading: the channel's line box starts where the name's ends.
        assertClose(name.bottom, channel.top, "leading between the name and the channel")
    }

    @Test
    fun `the avatar is centred against the stack`() {
        show()
        val h = header()
        // The avatar's hit target is centred on the avatar, so it shares the avatar's centre line.
        val a = target(NAME).getUnclippedBoundsInRoot()
        val above = a.top - h.top
        val below = h.bottom - a.bottom
        println("[metrics] avatarTarget=${a.top}..${a.bottom} above=$above below=$below")
        assertClose(above, below, "the avatar is not centred in the header")
    }

    @Test
    fun `every header control keeps a 40dp hit target`() {
        show()
        for (description in listOf(NAME, "Open $NAME", "Open $CHANNEL", "Share")) {
            val b = target(description).getUnclippedBoundsInRoot()
            println("[hit] $description = ${b.wide} x ${b.tall}")
            assertTrue("$description hit target is ${b.wide} wide, under $touchMin", b.wide.value + EPSILON >= touchMin.value)
            assertTrue("$description hit target is ${b.tall} tall, under $touchMin", b.tall.value + EPSILON >= touchMin.value)
        }
    }

    @Test
    fun `the hit target is an overlay, not a bigger line box`() {
        show()
        val nameBox = painted(NAME)
        val channelBox = painted(CHANNEL)
        val nameTarget = target("Open $NAME").getUnclippedBoundsInRoot()
        val channelTarget = target("Open $CHANNEL").getUnclippedBoundsInRoot()
        println("[hit] name target ${nameTarget.tall} over a ${nameBox.tall} line box; channel target ${channelTarget.tall} over a ${channelBox.tall} line box")
        assertTrue("the name target ${nameTarget.tall} does not reach past its ${nameBox.tall} line box", nameTarget.tall > nameBox.tall)
        assertTrue("the channel target ${channelTarget.tall} does not reach past its ${channelBox.tall} line box", channelTarget.tall > channelBox.tall)
        // Each target still covers all of its own text, so a tap on the painted glyphs never opens the other one.
        assertTrue("the name target does not cover its own line box", nameTarget.top <= nameBox.top && nameTarget.bottom >= nameBox.bottom)
        assertTrue("the channel target does not cover its own line box", channelTarget.top <= channelBox.top && channelTarget.bottom >= channelBox.bottom)
    }

    @Test
    fun `a tap on the grown part of a target still fires`() {
        show()
        val channel = target("Open $CHANNEL")
        val box = painted(CHANNEL)
        val grown = channel.getUnclippedBoundsInRoot()
        assertTrue("nothing to tap: the target ${grown.tall} does not extend past the ${box.tall} line box", grown.bottom > box.bottom)
        channel.performTouchInput { click(bottomCenter) }
        rule.waitForIdle()
        println("[hit] tapped ${grown.bottom - box.bottom} below the channel's painted box; taps=$openedChannel")
        assertTrue("a tap on the grown part of the channel target did not open the channel", openedChannel == 1)
    }

    @Test
    fun `the trailing group does not force the row taller than the stack needs`() {
        show()
        val h = header()
        val share = target("Share").getUnclippedBoundsInRoot()
        val time = painted(TIME)
        println("[metrics] share=${share.tall} time=${time.tall} header=${h.tall}")
        assertTrue("Share (${share.tall}) is taller than the header (${h.tall})", share.tall <= h.tall)
        assertTrue("the time (${time.tall}) is taller than the header (${h.tall})", time.tall <= h.tall)
    }

    @Test
    fun `the channel-attributed header drops the subheading and stays one line`() {
        show(channelTitle = null)
        val h = header().tall
        println("[metrics] single-line header=$h")
        // One line of name, so the row is only as tall as its tallest control — the Share button at `touchMin`.
        assertClose(maxOf(avatar, nameLine, touchMin), h, "single-line header height")
        assertTrue("single-line header $h is more than a quarter taller than its own avatar ($avatar)", h.value <= avatar.value * 1.25f)
    }

    private companion object {
        const val HEADER = "post-header"
        const val NAME = "Ana Iliovic"
        const val CHANNEL = "WaveLoop devlog"
        const val TIME = "2h ago"
        const val EPSILON = 0.5f
        val TOLERANCE = 2.dp
    }
}
