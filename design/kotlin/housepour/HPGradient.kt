package ca.lucianlabs.housepour

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.Shader
import androidx.compose.ui.graphics.ShaderBrush
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** A CSS-style `linear-gradient(<degrees>, …)` that resolves against the painted size. 0° = up, 90° = right. */
class HPAngledGradient(private val colors: List<Color>, private val degrees: Double) : ShaderBrush() {
    override fun createShader(size: Size): Shader {
        val a = Math.toRadians(degrees)
        val cx = size.width / 2
        val cy = size.height / 2
        val half = (abs(size.width * sin(a)) + abs(size.height * cos(a))).toFloat() / 2
        val dx = (sin(a) * half).toFloat()
        val dy = (-cos(a) * half).toFloat()
        return LinearGradientShader(Offset(cx - dx, cy - dy), Offset(cx + dx, cy + dy), colors)
    }
}
