package ca.lucianlabs.housepour

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Which way a hit target grows when its content is smaller than `touchMin`. */
enum class HPHitGrow {
    /** Centred on the content — the default, for anything with room on both sides. */
    BOTH,

    /** Keeps the content's bottom edge and grows upward — the upper row of a tight two-line stack. */
    UP,

    /** Keeps the content's top edge and grows downward — the lower row of a tight two-line stack. */
    DOWN,
}

/**
 * COMPONENTS rule 6 — the `touchMin` hit target as an **overlay, not a box**.
 *
 * [content] is measured and placed at its natural size and *this node reports that size*, so a 24pt line of
 * text still occupies 24pt of the column it sits in. A transparent `touchMin` square is then placed over the
 * content and carries the click, the role and the accessibility label; it is allowed to spill past this node's
 * bounds, which Compose still hit-tests because nothing here clips. Growing the line box instead — padding a
 * 13pt subheading out to 40pt and pulling it back with a negative margin — satisfies the rule and wrecks the
 * rhythm (PRODUCT §2.3).
 *
 * Two hit targets stacked in a stack shorter than 2 × `touchMin` must overlap somewhere; [grow] decides where.
 * `UP` on the upper row and `DOWN` on the lower row splits them exactly at the boundary between the two line
 * boxes, so each element's own painted text always taps through to itself.
 */
@Composable
fun HPHitTarget(
    onClick: () -> Unit,
    contentDescription: String,
    modifier: Modifier = Modifier,
    grow: HPHitGrow = HPHitGrow.BOTH,
    min: Dp = HPTokens.Space.touchMin,
    content: @Composable () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    Layout(
        modifier = modifier,
        content = {
            Box { content() }
            Box(
                Modifier
                    .clickable(interactionSource = interaction, indication = null, role = Role.Button, onClick = onClick)
                    .semantics { this.contentDescription = contentDescription },
            )
        },
    ) { measurables, constraints ->
        val body = measurables[0].measure(constraints)
        val minPx = min.roundToPx()
        val w = maxOf(body.width, minPx)
        val h = maxOf(body.height, minPx)
        val overlay = measurables[1].measure(Constraints.fixed(w, h))
        layout(body.width, body.height) {
            body.place(0, 0)
            val y = when (grow) {
                HPHitGrow.BOTH -> (body.height - h) / 2
                HPHitGrow.UP -> body.height - h
                HPHitGrow.DOWN -> 0
            }
            overlay.place((body.width - w) / 2, y)
        }
    }
}

/**
 * The line box one line of this style paints into, at font scale 1. The ramp sets `lineHeight` explicitly with
 * `Trim.None` (see `toTextStyle`), so this is the height the text actually measures, not an estimate.
 */
val HPTextStyle.hpLineBox: Dp get() = (size * lineHeight).dp

/**
 * COMPONENTS rule 6, the **tiling** half — the band a [HPHitGrow.DOWN] target needs to itself *below* the line
 * box it covers, which is everything of [min] the line box does not already provide.
 *
 * An overlay is only as big as what will actually hit it. Compose hit-tests a parent's children in reverse
 * placement order, so a *later* sibling that starts inside this band wins every point they share and the
 * control ships smaller than [min] however big [HPHitTarget] measured it — the target reads 40dp in a layout
 * assertion and lives at 30dp under a finger, with the missing 10dp firing the sibling's action instead. Hold
 * this band clear of anything clickable and the boundary between the two is a line, not an overlap.
 */
fun hpHitBandBelow(contentHeight: Dp, min: Dp = HPTokens.Space.touchMin): Dp =
    (min - contentHeight).coerceAtLeast(0.dp)
