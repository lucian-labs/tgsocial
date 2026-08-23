package ca.lucianlabs.housepour

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Circle, `bg2` fill, 1pt `line` ring; the fallback initial is set in the display serif (h2 at 36, h1 at 72), muted. */
@Composable
fun HPAvatar(
    image: ImageBitmap?,
    size: Dp,
    fallbackInitial: String,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
) {
    Box(
        modifier = modifier
            .size(size)
            .clip(CircleShape)
            .background(HPTokens.Colors.bg2, CircleShape)
            .border(HPTokens.BORDER_WIDTH.dp, HPTokens.Colors.line, CircleShape)
            .semantics { if (contentDescription != null) this.contentDescription = contentDescription },
        contentAlignment = Alignment.Center,
    ) {
        if (image != null) {
            Image(bitmap = image, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        } else {
            val style = if (size >= HPTokens.Space.avatarProfile) HPTokens.Type.h1 else HPTokens.Type.h2
            HPText(fallbackInitial.take(1).uppercase(), style, HPTokens.Colors.muted, maxLines = 1)
        }
    }
}

/** Full width, media radius, `bg2` placeholder while loading; no border, no shadow. */
@Composable
fun HPMedia(
    image: ImageBitmap?,
    aspect: Float,
    modifier: Modifier = Modifier,
    contentDescription: String? = null,
    overlay: (@Composable () -> Unit)? = null,
) {
    val shape = RoundedCornerShape(HPTokens.Radius.media)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(aspect.coerceIn(0.5f, 2.5f))
            .clip(shape)
            .background(HPTokens.Colors.bg2, shape)
            .semantics { if (contentDescription != null) this.contentDescription = contentDescription },
        contentAlignment = Alignment.BottomEnd,
    ) {
        if (image != null) {
            Image(bitmap = image, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        }
        if (overlay != null) overlay()
    }
}
