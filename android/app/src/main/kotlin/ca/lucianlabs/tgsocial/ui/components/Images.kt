package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import ca.lucianlabs.tgsocial.TgApp
import ca.lucianlabs.tgsocial.model.FileRef
import ca.lucianlabs.tgsocial.repo.MediaRepo

/** Loads a TDLib file as an ImageBitmap at roughly [width], via the MediaRepo cache. */
@Composable
fun rememberTdImage(ref: FileRef?, width: Dp, priority: Int = MediaRepo.PRIORITY_VISIBLE): ImageBitmap? {
    val px = with(LocalDensity.current) { width.roundToPx() }
    return rememberTdImagePx(ref, px, priority)
}

/**
 * The pixel-exact form, for callers that already know the decode size they want — the viewer asks for
 * `media.zoomWidthPx` rather than doubling a Dp, which on a 3x display used to work out to six times the
 * screen width and put a sensor-resolution decode in the cache.
 *
 * The decoded bitmap is held in composition state, so a memory-pressure eviction of the shared cache never
 * blanks what is on screen — the next composition of a card that scrolled away decodes again from disk.
 */
@Composable
fun rememberTdImagePx(ref: FileRef?, px: Int, priority: Int = MediaRepo.PRIORITY_VISIBLE): ImageBitmap? {
    // `as?`, not `as`: the layout tests boot the stock Application rather than TgApp (TDLib has no business in
    // a measure pass), and no repo simply means no bitmap — the same state as a file that has not arrived yet.
    val app = LocalContext.current.applicationContext as? TgApp
    var image by remember(ref?.uniqueId, px) { mutableStateOf(ref?.let { app?.media?.cached(it, px) }) }
    LaunchedEffect(ref?.uniqueId, px) {
        if (app == null || ref == null || image != null) return@LaunchedEffect
        // Cancellation (the row scrolled away) drops the decode with the composition; MediaRepo releases the
        // per-key load lock in a finally, so a cancelled load leaves nothing behind.
        image = runCatching { app.media.image(ref, px, priority) }.getOrNull()
    }
    return image
}
