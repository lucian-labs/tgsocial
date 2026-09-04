package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpRect
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HousePourTheme
import ca.lucianlabs.tgsocial.protocol.ReportEmail
import ca.lucianlabs.tgsocial.ui.screens.ReportSheetBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

private val DpRect.tall: Dp get() = bottom - top

/**
 * PRODUCT §2.15 — the report confirm, measured on the shipping composable.
 *
 * Two things are worth asserting here and neither is visible from the view model. **A reason is single-select**
 * — the second tap moves the choice rather than adding to it, which is what makes the subject line one reason
 * — and **`Send Report` is not an action until one is picked**, because a report whose subject is
 * `tgsocial report — ` is a report the address cannot sort. The rows also owe the 40dp of COMPONENTS rule 6,
 * so this reads their real measured height rather than the padding that was typed.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
// A tall window so the whole sheet measures and taps land on rows that are actually laid out; the stock
// Application, because TgApp boots TDLib and this is a layout question.
@Config(sdk = [34], qualifiers = "w411dp-h1200dp-mdpi", application = Application::class)
class ReportSheetTest {

    @get:Rule
    val rule = createComposeRule()

    private var picked: String? = null
    private var sends = 0

    /** Buttons paint in `Type.button`, which uppercases; the semantics text is what is painted. */
    private val sendLabel = "Send Report".uppercase()

    private fun show(isComment: Boolean = false) {
        rule.setContent {
            // A null font resolver keeps the kit's fallback families; the ramp's line heights are explicit
            // token values, so the measured stack does not depend on which face is installed.
            HousePourTheme(resolver = HPFontResolver { null }) {
                var selected by remember { mutableStateOf<String?>(null) }
                Column(Modifier.width(HPTokens.Space.columnMax)) {
                    ReportSheetBody(
                        isComment = isComment,
                        selected = selected,
                        canSend = selected != null,
                        onPick = { picked = it; selected = it },
                        onSend = { sends++ },
                        onCancel = {},
                    )
                }
            }
        }
    }

    @Test
    fun `every reason is offered, and every row is a 40dp target`() {
        show()
        for (reason in ReportEmail.REASONS) {
            val height = rule.onNodeWithContentDescription(reason).getUnclippedBoundsInRoot().tall
            assertTrue("$reason is ${height} — under the 40dp minimum", height >= HPTokens.Space.touchMin)
        }
    }

    @Test
    fun `picking a reason moves the choice rather than adding to it`() {
        show()
        rule.onNodeWithContentDescription("Violence or threats").performClick()
        assertEquals("Violence or threats", picked)
        rule.onNodeWithContentDescription("Violence or threats").assertIsSelected()

        rule.onNodeWithContentDescription("Spam").performClick()
        assertEquals("Spam", picked)
        rule.onNodeWithContentDescription("Spam").assertIsSelected()
        rule.onNodeWithContentDescription("Violence or threats").assertIsNotSelected()
    }

    @Test
    fun `Send Report is not an action until a reason is picked`() {
        show()
        rule.onNodeWithText(sendLabel).assertIsNotEnabled()
        assertEquals("nothing was sent", 0, sends)

        rule.onNodeWithContentDescription("Child safety").performClick()
        rule.onNodeWithText(sendLabel).assertIsEnabled()
        rule.onNodeWithText(sendLabel).performClick()
        assertEquals(1, sends)
    }

    @Test
    fun `the same sheet reports a comment, and says so`() {
        show(isComment = true)
        rule.onNodeWithText("Report this comment.").assertExists()
        rule.onNodeWithText("Report this post.").assertDoesNotExist()
    }
}
