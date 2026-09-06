package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPAvatar
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPH1
import ca.lucianlabs.housepour.HPListItem
import ca.lucianlabs.housepour.HPMono
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPSmall
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.model.Vouch
import ca.lucianlabs.tgsocial.protocol.WorkCard
import ca.lucianlabs.tgsocial.protocol.WorkFormat
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.ExploreUi
import ca.lucianlabs.tgsocial.ui.OpenIntent
import ca.lucianlabs.tgsocial.ui.Screen
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.VouchCopy
import ca.lucianlabs.tgsocial.ui.WorkSection
import ca.lucianlabs.tgsocial.ui.WorkUi
import ca.lucianlabs.tgsocial.ui.columnItem
import ca.lucianlabs.tgsocial.ui.components.EmptyCard
import ca.lucianlabs.tgsocial.ui.components.FooterNote
import ca.lucianlabs.tgsocial.ui.components.PostCard
import ca.lucianlabs.tgsocial.ui.components.rememberTdImage

/**
 * PRODUCT §2.23–§2.25 — the work surfaces. All of them are additive in the same way the protocol is: a node
 * with no work keys renders exactly as it did before this file existed, with no empty section and no
 * "not set up yet".
 *
 * The one word this app uses is **work**. Never "professional", never "career", never "job" as a noun for
 * the surface, and `Verified` (PROTOCOL §3) appears nowhere here — that pill means one checkable thing and
 * lending it to an unverifiable one empties it (§10.8).
 */

// ---------------------------------------------------------------- the work card on a profile (§2.23)

/**
 * The `WORK` section of a node profile, between the bio/link block and `FEEDS`.
 *
 * **Absent entirely** when there is nothing to say — no section mark, no "not set up yet" — but that is two
 * conditions and not one: a vouch is written in somebody else's channel about a node that need never have
 * claimed anything (PROTOCOL §10.4), so [work] alone cannot gate the section. Gate on it and a vouch about a
 * node with no `work.` keys is indexed, counted, and rendered nowhere — invisible to the reader and, worse,
 * invisible to the subject on their own profile, which is the exact case `VOUCHED, NOT CLAIMED` exists for.
 * Hence [work] is nullable here and the caller passes [vouches] alongside it.
 */
fun LazyListScope.WorkCardItems(
    vm: AppViewModel,
    snap: NodeSnapshot,
    work: WorkCard?,
    vouches: List<Vouch>,
    isMe: Boolean,
) {
    val claimed = work?.does.orEmpty()
    val unclaimed = WorkSection.unclaimed(work, vouches)
    val open = work?.open?.takeIf { WorkFormat.openIsCurrent(it) }
    item(key = "work-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap, top = HPTokens.Space.rowGap)) { HPSectionMark("Work") }
    }
    // Only when the node claimed something itself: a node that has only been vouched for has no role line
    // and no intent pill, and an empty block would leave a gap where a self-claim would have been.
    if (work?.role != null || open != null) {
        item(key = "work-head") {
            Column(Modifier.columnItem()) {
                // The role line is body text, undecorated. It is a self-claim exactly like the bio above it,
                // and it must not borrow the visual language of the Verified pill (PROTOCOL §10.8).
                work?.role?.let { HPBody(it) }
                // PROTOCOL §10.3 — expired, or further out than the horizon, is simply not drawn. Not greyed,
                // not "was open until": there is no rendering of an intent that has stopped being one.
                val label = open?.let { WorkFormat.intentLabel(it.intent) }
                if (open != null && label != null) {
                    if (work?.role != null) Spacer(Modifier.height(HPTokens.Space.rowGap))
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
                        HPPill(label, HPPillTone.GOLD)
                        WorkFormat.untilLabel(open.until)?.let { HPMonoSmall(it, color = HPTokens.Colors.faint, maxLines = 1) }
                    }
                }
                Spacer(Modifier.height(HPTokens.Space.cardGap))
            }
        }
    }
    if (claimed.isNotEmpty()) {
        item(key = "work-tags") {
            Box(Modifier.columnItem()) {
                HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
                    claimed.forEachIndexed { i, tag ->
                        TagRow(vm, snap, tag, vouches.count { it.tag.equals(tag, ignoreCase = true) }, isLast = i == claimed.lastIndex)
                    }
                }
            }
        }
    }
    if (unclaimed.isNotEmpty()) {
        item(key = "work-unclaimed") {
            // PROTOCOL §10.4 — the tag need not appear in the subject's own `work.does`, because a vouch is
            // the voucher's sentence and the subject must not be able to edit it by editing their card. This
            // heading is how a person finds out what they are known for.
            Column(Modifier.columnItem().padding(top = HPTokens.Space.cardGap)) {
                HPSectionMark("Vouched, not claimed")
                Spacer(Modifier.height(HPTokens.Space.rowGap))
                HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
                    unclaimed.forEachIndexed { i, tag ->
                        TagRow(vm, snap, tag, vouches.count { it.tag.equals(tag, ignoreCase = true) }, isLast = i == unclaimed.lastIndex)
                    }
                }
            }
        }
    }
    if (claimed.isNotEmpty() && vouches.isEmpty()) {
        item(key = "work-empty") {
            Column(Modifier.columnItem().padding(top = HPTokens.Space.rowGap)) {
                if (isMe) {
                    HPMuted("No vouches from your network yet.")
                    // Uncomfortable and true (PROTOCOL §10.5). A client that omits this line implies a
                    // completeness it does not have: there is no reverse index, so you can be vouched and
                    // never know it.
                    HPText("Someone may have vouched for you outside it. You'd only see it if you can reach them.", HPTokens.Type.small, HPTokens.Colors.faint)
                } else {
                    HPMuted("No vouches from your network.")
                }
            }
        }
    }
    item(key = "work-vouch-btn") {
        val safety by vm.safety.collectAsStateWithLifecycle()
        if (isMe || safety.isBlocked(snap.username)) return@item
        Box(Modifier.columnItem().padding(top = HPTokens.Space.cardGap)) {
            // §2.25's copy names the person, not their channel: `Vouch for Ana`. A card with no `name` has
            // nothing to put there but the username, and says so plainly.
            HPButton(VouchCopy.button(snap.firstName, snap.username), { vm.openVouch(snap.username) }, style = HPButtonStyle.NEUTRAL, size = HPButtonSize.SMALL)
        }
    }
}

/**
 * One tag row. A row with vouches taps through to the Vouches screen; a row with none **is not a control** —
 * no chevron, no hit target, no press state (§2.23).
 *
 * The trailing figure is allowed only because the reader can resolve it into names in one step and it is
 * labelled with its scope: `Vouched by 2` describes what this reader can see, where `2 endorsements` would be
 * a claim about a world that does not exist here (PROTOCOL §10.5).
 */
@Composable
private fun TagRow(vm: AppViewModel, snap: NodeSnapshot, tag: String, count: Int, isLast: Boolean) {
    if (count == 0) {
        HPListItem(isLast = isLast) { HPBody(tag, Modifier.weight(1f), maxLines = 1) }
        return
    }
    HPListItem(
        modifier = Modifier
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                vm.push(Screen.Vouches(snap.username, tag))
            }
            .semantics { contentDescription = "Vouches for $tag" },
        isLast = isLast,
        trailing = {
            HPSmall("Vouched by $count", maxLines = 1)
            HPText("›", HPTokens.Type.body, HPTokens.Colors.faint, maxLines = 1)
        },
    ) {
        HPBody(tag, Modifier.weight(1f), maxLines = 1)
    }
}

// ---------------------------------------------------------------- Work mode on Feed (§2.24)

/**
 * PRODUCT §2.24 — Work mode. Two things, in this order, and the first is the reason the mode exists: the
 * work feed's distinguishing feature is not the filter, it is expiring intent.
 */
fun LazyListScope.WorkFeedItems(vm: AppViewModel, work: WorkUi) {
    item(key = "work-open-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) {
            HPSectionMark("Open now", work.openNow.size.takeIf { it > 0 })
        }
    }
    item(key = "work-open") {
        Box(Modifier.columnItem()) {
            if (work.openNow.isEmpty()) {
                Column {
                    HPMuted("Nobody in your network is open right now.")
                    // §2.24 — under five follows, the honest reason the list is short.
                    if (work.followCount < 5) {
                        HPText("Your network is small. This reads the people you follow, and theirs.", HPTokens.Type.small, HPTokens.Colors.faint)
                    }
                }
            } else {
                HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
                    work.openNow.forEachIndexed { i, row -> OpenRow(vm, row, isLast = i == work.openNow.lastIndex) }
                }
            }
        }
    }
    if (work.posts.isEmpty()) {
        item(key = "work-posts-empty") {
            // Never over a feed that is still arriving, and never over a page the work filter took whole with
            // more still to fetch (`chaining`, PRODUCT §2.18): an empty state there is a screen telling the
            // reader to go and fix something that is not wrong (PRODUCT §4).
            if (work.loading || work.chaining) {
                Box(Modifier.columnItem()) { FooterNote("Loading…") }
                return@item
            }
            Box(Modifier.columnItem().padding(top = HPTokens.Space.cardGap)) {
                EmptyCard(
                    "No work posts yet.",
                    "Mark one of your feeds as work, or follow someone who has.",
                    "Edit Card",
                ) { vm.openSheet(Sheet.EditCard) }
            }
        }
        return
    }
    items(work.posts, key = { "work-${it.key}" }) { post ->
        val index by vm.commentIndex.collectAsStateWithLifecycle()
        Box(Modifier.columnItem().padding(top = HPTokens.Space.rowGap)) {
            // §2.3's post card, unchanged — same card, same attribution, same long-press sheet. Suppressing
            // the unmarked feeds is the entire filter: no scoring, no promotion, no "relevant to you".
            PostCard(
                post = post,
                commentCount = vm.commentCount(post, index),
                onOpenChannel = { vm.push(Screen.FeedChannel(it)) },
                onOpenProfile = { vm.push(Screen.Profile(it)) },
                onOpenThread = { vm.openThread(post) },
                onComment = { vm.openCommentComposer(post) },
                onOpenViewer = { vm.openViewer(post, it) },
                onLongPress = { vm.openSheet(Sheet.PostSheet(post)) },
            )
        }
    }
    item(key = "work-posts-footer") {
        Box(Modifier.columnItem()) {
            when {
                work.loading -> FooterNote("Loading…")
                work.exhausted -> FooterNote("That's everything.")
            }
        }
    }
}

@Composable
private fun OpenRow(vm: AppViewModel, row: OpenIntent, isLast: Boolean) {
    val image = rememberTdImage(row.photo, HPTokens.Space.avatarRow)
    val label = WorkFormat.intentLabel(row.intent) ?: return
    HPListItem(
        modifier = Modifier
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                vm.push(Screen.Profile(row.username))
            }
            .semantics { contentDescription = "Open @${row.username}" },
        isLast = isLast,
        trailing = {
            HPPill(label, HPPillTone.GOLD)
            if (row.plusOne) HPPill("+1", HPPillTone.NEUTRAL)
            HPText("›", HPTokens.Type.body, HPTokens.Colors.faint, maxLines = 1)
        },
    ) {
        HPAvatar(image, HPTokens.Space.avatarRow, row.initial, contentDescription = row.name)
        Column(Modifier.weight(1f)) {
            HPBody(row.name, strong = true, maxLines = 1)
            val until = WorkFormat.untilLabel(row.until)
            val tags = row.tags.joinToString(", ")
            val line = listOf(until.orEmpty(), tags).filter { it.isNotBlank() }.joinToString(" · ")
            if (line.isNotBlank()) HPMonoSmall(line, color = HPTokens.Colors.faint, maxLines = 1)
        }
    }
}

// ---------------------------------------------------------------- the Vouches screen (§2.25)

/** PRODUCT §2.25 — the vouches for one capability of one node, newest first. */
fun LazyListScope.VouchesItems(vm: AppViewModel, username: String, tag: String) {
    item(key = "vouches-head") {
        val cards by vm.cards.collectAsStateWithLifecycle()
        val name = cards[ca.lucianlabs.tgsocial.protocol.Username.key(username)]?.displayName ?: "@$username"
        Column(Modifier.columnItem().padding(bottom = HPTokens.Space.cardGap)) {
            // The h1 is the tag as written; the subject is the line under it.
            HPH1(tag)
            HPMono(name)
        }
    }
    item(key = "vouches-list") {
        val index by vm.vouchIndex.collectAsStateWithLifecycle()
        val list = vm.vouchesFor(username, tag, index)
        Column(Modifier.columnItem()) {
            HPSectionMark("Vouches", list.size.takeIf { it > 0 })
            Spacer(Modifier.height(HPTokens.Space.rowGap))
            if (list.isEmpty()) {
                // Reachable only when the last vouch was deleted between renders.
                HPMuted("No vouches from your network.")
                Spacer(Modifier.height(HPTokens.Space.rowGap))
                HPMuted("You see vouches written by people you can reach — you, who you follow, and theirs.")
                return@item
            }
            HPCard {
                list.forEachIndexed { i, v -> VouchRow(vm, v, isLast = i == list.lastIndex) }
            }
            Spacer(Modifier.height(HPTokens.Space.rowGap))
            // PROTOCOL §10.5 — permanent, not an empty state. The scope is the honest description of what
            // this list is, and it belongs on the screen rather than in a footnote.
            HPText("Vouches from your network — you, who you follow, and theirs.", HPTokens.Type.small, HPTokens.Colors.faint)
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun VouchRow(vm: AppViewModel, vouch: Vouch, isLast: Boolean) {
    val image = rememberTdImage(vouch.voucherPhoto, HPTokens.Space.avatarRow)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClickLabel = "Open @${vouch.voucherUsername}",
                onClick = { vm.push(Screen.Profile(vouch.voucherUsername)) },
                onLongClick = { vm.openSheet(Sheet.VouchSheet(vouch)) },
            )
            .padding(vertical = HPTokens.Space.rowGap)
            .semantics { contentDescription = "Vouch by ${vouch.voucherName}" },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
            HPAvatar(image, HPTokens.Space.avatarRow, vouch.voucherName.firstOrNull { it.isLetterOrDigit() }?.toString() ?: "·", contentDescription = vouch.voucherName)
            HPBody(vouch.voucherName, Modifier.weight(1f), strong = true, maxLines = 1)
            if (vouch.plusOne) HPPill("+1", HPPillTone.NEUTRAL)
            // §2.25 — a month and a year, not a relative time. `2y ago` buries exactly the thing a reader is
            // weighing, which is whether this was last year or half a career ago.
            HPMonoSmall(WorkFormat.monthYear(vouch.date.toLong()), color = HPTokens.Colors.faint, maxLines = 1)
        }
        if (vouch.body.isNotBlank()) {
            Spacer(Modifier.height(HPTokens.Space.labelBottom))
            HPBody(vouch.body)
        }
        if (!isLast) Spacer(Modifier.height(HPTokens.Space.labelBottom))
    }
}

// ---------------------------------------------------------------- capability search (§2.24)

/**
 * PRODUCT §2.24 — `WHAT THEY DO` on Explore. The faint line under it is permanent rather than an empty
 * state: a search box that stays quiet about its reach is a search box that lies about it (PROTOCOL §10.7).
 */
fun LazyListScope.CapabilityItems(vm: AppViewModel, explore: ExploreUi, me: NodeSnapshot?) {
    if (explore.query.isBlank()) return
    item(key = "capability-mark") {
        Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap, top = HPTokens.Space.rowGap)) { HPSectionMark("What they do") }
    }
    item(key = "capability-card") {
        Column(Modifier.columnItem()) {
            HPCard(padding = PaddingValues(horizontal = HPTokens.Space.cardPad, vertical = 0.dp)) {
                if (explore.capability.isEmpty()) {
                    Spacer(Modifier.height(HPTokens.Space.rowPad))
                    HPMuted("Nobody you can reach lists that.")
                    Spacer(Modifier.height(HPTokens.Space.rowPad))
                } else {
                    explore.capability.forEachIndexed { i, hit ->
                        val entry = hit.entry
                        val image = rememberTdImage(entry.photo, HPTokens.Space.avatarRow)
                        val following = me?.card?.follows(entry.username) == true
                        HPListItem(
                            modifier = Modifier
                                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button) {
                                    vm.push(Screen.Profile(entry.username))
                                }
                                .semantics { contentDescription = "Open @${entry.username}" },
                            isLast = i == explore.capability.lastIndex,
                            trailing = {
                                if (!vm.isMe(entry.username)) {
                                    if (following) HPButton("Following", { vm.unfollow(entry.username) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, contentDescription = "Unfollow @${entry.username}")
                                    else HPButton("Follow", { vm.follow(entry.username) }, style = HPButtonStyle.NEUTRAL, size = HPButtonSize.SMALL, contentDescription = "Follow @${entry.username}")
                                }
                            },
                        ) {
                            HPAvatar(image, HPTokens.Space.avatarRow, entry.initial, contentDescription = entry.name)
                            Column(Modifier.weight(1f)) {
                                HPBody(entry.name, strong = true, maxLines = 1)
                                val mutual = if (entry.mutualCount > 0) "Followed by ${entry.mutualCount} of yours" else null
                                val line = listOfNotNull("@${entry.username}", hit.tags.joinToString(", "), mutual).joinToString(" · ")
                                HPMonoSmall(line, maxLines = 1)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(HPTokens.Space.rowGap))
            HPText(
                "Searches the cards you can reach — your network and the directory. There is no global search.",
                HPTokens.Type.small,
                HPTokens.Colors.faint,
            )
        }
    }
}
