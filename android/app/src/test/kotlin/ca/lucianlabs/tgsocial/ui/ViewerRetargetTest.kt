package ca.lucianlabs.tgsocial.ui

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import ca.lucianlabs.housepour.HPFontResolver
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HPViewer
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
 * PRODUCT §2.11.3 — "tapping tile N opens the carousel at index N" — held across a viewer that opens *from* a
 * viewer, which §2.12 makes a real path: a comment inside the comments sheet renders its own mosaic, and tapping
 * one of its tiles calls `openViewer(commentPost, n)` while a viewer is already up.
 *
 * `_viewer` is a conflated StateFlow, so that arrives as a non-null → non-null change with no null frame between,
 * and the host's composition slot would survive it. The pager's `initialPage` is remembered per slot
 * (`rememberSaveable` with an empty inputs array), so a surviving slot means the second viewer opens on the first
 * one's page — silently, with no crash for a test to trip over. App.kt keys the host on `post.key` for exactly
 * this; these tests are the measurement of that, so removing the key fails here rather than in someone's hands.
 *
 * The key covers every reachable case because the only viewer-from-viewer path is ThreadScreen.kt:198 — a
 * *comment's* post, always a different chat, so always a different key. Reopening the **same** post at another
 * index while its viewer is up would not move, and is deliberately not asserted here: the comments sheet renders
 * `ThreadItems(..., includePost = false)`, so the open post is never one of the tiles you can tap. Within one
 * album, re-targeting is the pager's own job — you swipe. If a path to `openViewer(samePost, n)` ever appears,
 * the key stops being sufficient and this is the file that should grow the case.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-mdpi", application = Application::class)
class ViewerRetargetTest {

    @get:Rule
    val rule = createComposeRule()

    private data class Open(val postKey: String, val pageCount: Int, val page: Int)

    /** What the pager last reported through `onPage` — the same signal AppViewModel stores back as `viewer.page`. */
    private var reported: Int? = null
    private var open by mutableStateOf(Open("100:1", 4, 2))

    @Composable
    private fun Page(postKey: String, page: Int) {
        Box(
            Modifier
                .fillMaxSize()
                .background(HPTokens.Colors.bg2)
                .semantics { contentDescription = "$postKey#$page" },
        )
    }

    /** The host as App.kt writes it: `viewer?.let { key(it.post.key) { PostViewer(vm, it) } }`. */
    private fun host() {
        rule.setContent {
            HousePourTheme(resolver = HPFontResolver { null }) {
                val o = open
                key(o.postKey) {
                    HPViewer(
                        pageCount = o.pageCount,
                        initialPage = o.page,
                        onDismiss = {},
                        onPage = { reported = it },
                    ) { page, _ -> Page(o.postKey, page) }
                }
            }
        }
    }

    private fun onScreen(postKey: String, page: Int): Boolean =
        rule.onAllNodesWithContentDescription("$postKey#$page", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()

    /**
     * Open a 4-photo album at tile 3, then a comment's own 4-photo mosaic at tile 1, with no close between.
     * Both albums are the same length on purpose: a shorter second album would be coerced into range by the
     * surviving pager and could land on the right index by accident, which is not a test of anything.
     */
    @Test
    fun `a viewer opened from a viewer lands on the index that was tapped`() {
        host()
        rule.waitForIdle()
        assertEquals("the first viewer opens where it was asked to", 2, reported)

        open = Open("200:7", 4, 0)
        rule.waitForIdle()

        assertEquals("the second viewer opens on its own index, not the first one's page", 0, reported)
        assertTrue("and it is that item on screen", onScreen("200:7", 0))
        assertTrue("the first viewer's pages are gone", !onScreen("100:1", 2))
    }

    /**
     * The page the second viewer wants may not exist in the first one — 4 pages down to 2 — so a slot that
     * survived would be coerced to the last page and show the wrong photo rather than an out-of-range crash.
     * Asking for page 0 of a shorter album is the sharpest version: it can only be right if the pager was rebuilt.
     */
    @Test
    fun `a shorter album after a longer one is not left on the old page`() {
        host()
        rule.waitForIdle()
        assertEquals(2, reported)

        open = Open("200:9", 2, 0)
        rule.waitForIdle()

        assertEquals("page 0 of the new album, not page 1 coerced from page 2", 0, reported)
        assertTrue(onScreen("200:9", 0))
    }

}
