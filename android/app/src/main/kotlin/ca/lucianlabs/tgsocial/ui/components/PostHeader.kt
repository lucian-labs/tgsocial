package ca.lucianlabs.tgsocial.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.unit.Dp
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPHitGrow
import ca.lucianlabs.housepour.HPHitTarget
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.hpHitBandBelow
import ca.lucianlabs.housepour.hpLineBox

/**
 * The gap a post card holds between [PostHeader] and the first **clickable** thing under it.
 *
 * `rowGap` is the rhythm; rule 6 is the floor. The channel subheading is one mono-small line box (19.2dp) and
 * takes the rest of its `touchMin` as an overlay hanging below itself — so the 20.8dp under the header belongs
 * to the channel, not to the card. Compose hit-tests later-placed siblings first, so a clickable sibling that
 * starts inside that band swallows it: with `rowGap` alone the channel measured 40dp and lived at 30dp, and the
 * bottom 10dp of it opened the thread. Holding the band makes the boundary between the channel and the body a
 * line, exactly the way the name and the channel already tile with each other.
 */
val PostHeaderBottomGap: Dp = maxOf(HPTokens.Space.rowGap, hpHitBandBelow(HPTokens.Type.monoSmall.hpLineBox))

/**
 * PRODUCT §2.3 — the post header: the source-channel avatar, the name/channel stack, then the time and Share.
 *
 * The metrics are the spec's: the stack is **tight** (the name at the body line height, the channel directly
 * under it at the mono-small line height, no extra leading), the avatar is **centred against that stack**
 * rather than pinned to the top of it, and the whole row measures about one avatar tall.
 *
 * Every control keeps its `touchMin` hit target as an **overlay** ([HPHitTarget]) — nothing here is padded out
 * to 40dp and pulled back with a negative margin, which is what leaves a 47pt box around 19pt of text. The two
 * stack rows grow away from each other so the split between their targets lands exactly on the boundary
 * between their line boxes.
 *
 * The channel's half of that split hangs below the header, so the header does not own all of its own hit
 * targets: the card has to keep [PostHeaderBottomGap] clear underneath. See that value for why.
 *
 * Split out of [PostCard] so these metrics can be measured directly (see `PostHeaderTest` for what they
 * measure and `PostCardHitRegionTest` for what they do once the card puts something under them).
 */
@Composable
fun PostHeader(
    avatar: ImageBitmap?,
    name: String,
    initial: String,
    channelTitle: String?,
    time: String,
    onOpenName: () -> Unit,
    onOpenChannel: () -> Unit,
    onShare: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap),
    ) {
        // The avatar is the source channel (§2.3); tapping it goes where the name goes.
        HPHitTarget(onClick = onOpenName, contentDescription = name) {
            HPAvatar(avatar, HPTokens.Space.avatarRow, initial)
        }
        Column(modifier = Modifier.weight(1f)) {
            // The name is the node (tap → node profile); on the channel fallback it is the channel title.
            HPHitTarget(onClick = onOpenName, contentDescription = "Open $name", grow = HPHitGrow.UP) {
                HPBody(name, strong = true, maxLines = 1)
            }
            if (channelTitle != null) {
                // Subheading = the channel title, mono small muted, tap → feed channel screen (§2.6).
                HPHitTarget(onClick = onOpenChannel, contentDescription = "Open $channelTitle", grow = HPHitGrow.DOWN) {
                    HPMonoSmall(channelTitle, maxLines = 1)
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
            HPMonoSmall(time, color = HPTokens.Colors.faint, maxLines = 1)
            HPButton("Share", onShare, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Share")
        }
    }
}
