package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import ca.lucianlabs.housepour.HPBody
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPFieldKind
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPListItem
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPSmall
import ca.lucianlabs.housepour.HPTextField
import ca.lucianlabs.housepour.HPToggle
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.NodeSnapshot
import ca.lucianlabs.tgsocial.protocol.Username
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.Availability
import ca.lucianlabs.tgsocial.ui.SetupUi
import ca.lucianlabs.tgsocial.ui.columnItem

/** PRODUCT §2.2 — Your node, then Your feeds once the node exists. `feedsOnly` is You → Manage. */
fun LazyListScope.SetupItems(vm: AppViewModel, s: SetupUi, me: NodeSnapshot?, feedsOnly: Boolean, canSkip: Boolean) {
    if (!feedsOnly) {
        item(key = "setup-node-mark") { Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Your node") } }
        item(key = "setup-node") {
            Box(Modifier.columnItem()) {
                HPCard {
                    if (me != null) {
                        HPH2(me.displayName)
                        HPMonoSmall("@${me.username}")
                        Spacer(Modifier.height(HPTokens.Space.rowGap))
                        HPMuted("Your node lives on Telegram, and anyone can read it there.")
                    } else {
                        HPH2("Make your node.")
                        Spacer(Modifier.height(HPTokens.Space.rowGap))
                        HPMuted("A public channel that holds your feeds and who you follow. It lives on Telegram, and anyone can read it there.")
                        Spacer(Modifier.height(HPTokens.Space.cardGap))
                        HPTextField(s.nodeName, vm::setNodeName, label = "Node name", placeholder = "tgs_yourname", kind = HPFieldKind.Username, gapBelow = false, enabled = !s.creating)
                        Spacer(Modifier.height(HPTokens.Space.rowGap))
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.rowGap)) {
                            when (s.availability) {
                                Availability.AVAILABLE -> HPPill("Available", HPPillTone.GOLD)
                                Availability.TAKEN -> HPPill(if (s.availabilityNote.isNotBlank() && s.availabilityNote != "Taken") s.availabilityNote else "Taken", HPPillTone.BAD)
                                Availability.CHECKING -> HPPill("Checking")
                                Availability.UNKNOWN -> Unit
                            }
                        }
                        Spacer(Modifier.height(HPTokens.Space.cardGap))
                        HPButton("Create Node", vm::createNode, style = HPButtonStyle.PRIMARY, enabled = !s.creating && s.availability != Availability.TAKEN && Username.normalise(s.nodeName) == s.nodeName)
                        Spacer(Modifier.height(HPTokens.Space.rowGap))
                        HPButton("I already have one", vm::findExistingNode, style = HPButtonStyle.GHOST, enabled = !s.creating)
                    }
                }
            }
        }
    }
    if (me != null) {
        item(key = "setup-feeds-mark") { Box(Modifier.columnItem().padding(bottom = HPTokens.Space.rowGap)) { HPSectionMark("Your feeds") } }
        item(key = "setup-feeds") {
            Box(Modifier.columnItem()) {
                HPCard {
                    HPMuted("Pick the channels that post as you.")
                    Spacer(Modifier.height(HPTokens.Space.rowGap))
                    if (s.candidatesLoading && s.candidates.isEmpty()) HPMuted("Loading…")
                    else if (s.candidates.isEmpty()) HPMuted("No channels you can post to. Make one in Telegram first.")
                    Column(Modifier.padding(bottom = HPTokens.Space.rowGap)) {
                        s.candidates.forEachIndexed { i, c ->
                            val username = c.username
                            val key = username?.let { Username.key(it) }
                            val on = key != null && key in s.selected
                            HPListItem(
                                isLast = i == s.candidates.lastIndex && s.verifyPrompt == null,
                                modifier = Modifier.alpha(if (c.isPublic) 1f else 0.5f),
                                trailing = {
                                    if (username != null) HPToggle(on, { vm.toggleFeed(username, it) }, label = "Use ${c.title} as a feed")
                                },
                            ) {
                                Column(Modifier.weight(1f)) {
                                    HPBody(c.title, maxLines = 1)
                                    if (username != null) HPMonoSmall("@$username", maxLines = 1) else HPMonoSmall("Needs a public link.", maxLines = 1)
                                }
                            }
                            if (username != null && s.verifyPrompt?.let { Username.same(it, username) } == true) {
                                Column(Modifier.fillMaxWidth().padding(vertical = HPTokens.Space.rowGap)) {
                                    HPSmall("Add a line to this channel's description so readers can verify it's yours?")
                                    Spacer(Modifier.height(HPTokens.Space.rowGap))
                                    Row(horizontalArrangement = Arrangement.spacedBy(HPTokens.Space.btnRowGap)) {
                                        HPButton("Verify", { vm.answerVerify(true) }, style = HPButtonStyle.NEUTRAL, size = HPButtonSize.SMALL)
                                        HPButton("Skip", { vm.answerVerify(false) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
                                    }
                                }
                            }
                        }
                    }
                    HPButton("Save Feeds", vm::saveFeeds, style = HPButtonStyle.PRIMARY, enabled = !s.saving && s.candidates.isNotEmpty())
                }
            }
        }
    }
    if (canSkip && !feedsOnly) {
        item(key = "setup-skip") {
            Box(Modifier.columnItem()) { HPButton("Skip for now", vm::skipSetup, style = HPButtonStyle.GHOST) }
        }
    }
}
