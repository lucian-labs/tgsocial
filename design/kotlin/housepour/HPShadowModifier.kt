package ca.lucianlabs.housepour

import android.graphics.BlurMaskFilter
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp

/**
 * CSS-style box-shadow (offset, blur, spread) drawn behind a rounded rect. The only shadows in the look are the
 * token ones: `Shadow.contact + Shadow.cast` on cards, one on each gradient button, one on the toast.
 */
fun Modifier.hpShadow(cornerRadius: Dp, vararg shadows: HPShadow, alphaScale: Float = 1f): Modifier =
    drawBehind {
        for (shadow in shadows) drawBoxShadow(shadow, cornerRadius, alphaScale)
    }

private fun DrawScope.drawBoxShadow(shadow: HPShadow, cornerRadius: Dp, alphaScale: Float) {
    val spread = shadow.spread.toPx()
    val blur = shadow.blur.toPx()
    val left = shadow.x.toPx() - spread
    val top = shadow.y.toPx() - spread
    val right = size.width + shadow.x.toPx() + spread
    val bottom = size.height + shadow.y.toPx() + spread
    if (right <= left || bottom <= top) return
    val radius = (cornerRadius.toPx() + spread).coerceAtLeast(0f)
    val color = shadow.color.copy(alpha = (shadow.color.alpha * alphaScale).coerceIn(0f, 1f)).toArgb()
    drawIntoCanvas { canvas ->
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        if (blur > 0f && supportsBlurMask) {
            // CSS blur radius ≈ 2σ; Skia's BlurMaskFilter radius ≈ σ / 0.577, so radius ≈ 0.866 × blur.
            paint.maskFilter = BlurMaskFilter((blur * 0.866f).coerceAtLeast(0.5f), BlurMaskFilter.Blur.NORMAL)
            canvas.nativeCanvas.drawRoundRect(RectF(left, top, right, bottom), radius, radius, paint)
        } else if (blur > 0f) {
            // API 26/27: hardware canvases ignore mask filters — approximate the soft edge with stacked translucent rings.
            val rings = 6
            val base = paint.alpha
            for (i in rings downTo 1) {
                val grow = blur * 0.5f * i / rings
                paint.alpha = (base / rings.toFloat()).toInt().coerceAtLeast(1)
                canvas.nativeCanvas.drawRoundRect(RectF(left - grow, top - grow, right + grow, bottom + grow), radius + grow, radius + grow, paint)
            }
        } else {
            canvas.nativeCanvas.drawRoundRect(RectF(left, top, right, bottom), radius, radius, paint)
        }
    }
}

private inline fun DrawScope.drawIntoCanvas(block: (androidx.compose.ui.graphics.Canvas) -> Unit) {
    drawContext.canvas.let(block)
}
