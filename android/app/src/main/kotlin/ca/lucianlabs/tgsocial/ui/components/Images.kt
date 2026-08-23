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
    val app = LocalContext.current.applicationContext as TgApp
    val px = with(LocalDensity.current) { width.roundToPx() }
    var image by remember(ref?.uniqueId) { mutableStateOf(ref?.let { app.media.cached(it, px) }) }
    LaunchedEffect(ref?.uniqueId, px) {
        if (ref == null || image != null) return@LaunchedEffect
        image = runCatching { app.media.image(ref, px, priority) }.getOrNull()
    }
    return image
}
