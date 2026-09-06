package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonRow
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPFieldKind
import ca.lucianlabs.housepour.HPFieldLabel
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPPill
import ca.lucianlabs.housepour.HPPillTone
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPText
import ca.lucianlabs.housepour.HPTextField
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.model.Vouch
import ca.lucianlabs.tgsocial.protocol.DeepLink
import ca.lucianlabs.tgsocial.protocol.Format
import ca.lucianlabs.tgsocial.protocol.ReportSubject
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.Availability
import ca.lucianlabs.tgsocial.ui.Sheet
import ca.lucianlabs.tgsocial.ui.VouchCopy
import ca.lucianlabs.tgsocial.ui.components.openInTelegram

/**
 * PRODUCT §2.25 — the vouch modal. One person saying one thing another person can do: one capability, one
 * message, in the voucher's own comments channel, where the subject cannot edit it or take it down.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ColumnScope.VouchSheetBody(vm: AppViewModel) {
    val v by vm.vouch.collectAsStateWithLifecycle()

    // PROTOCOL §10.4 — it is the same channel §6.1 already made, so it is the same card §2.12 already
    // specifies, verbatim and unchanged, rather than a second one saying nearly the same thing.
    if (v.needsChannel) {
        HPSectionMark("Your comments channel")
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPMuted("Your comments live in a public channel you own. Anyone can read it on Telegram; you can edit or delete anything there.")
        Spacer(Modifier.height(HPTokens.Space.cardGap))
        HPTextField(v.channelName, vm::setVouchChannelName, kind = HPFieldKind.Username, gapBelow = false, enabled = !v.creatingChannel, contentDescription = "Comments channel name")
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        Row(verticalAlignment = Alignment.CenterVertically) {
            when (v.channelAvailability) {
                Availability.AVAILABLE -> HPPill("Available", HPPillTone.GOLD)
                Availability.TAKEN -> HPPill(if (v.channelNote.isNotBlank() && v.channelNote != "Taken") v.channelNote else "Taken", HPPillTone.BAD)
                Availability.CHECKING -> HPPill("Checking")
                Availability.UNKNOWN -> Unit
            }
        }
        Spacer(Modifier.height(HPTokens.Space.cardGap))
        HPButton("Make Channel", vm::makeVouchChannel, style = HPButtonStyle.PRIMARY, enabled = !v.creatingChannel && v.channelAvailability != Availability.TAKEN)
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPButton("Cancel", vm::closeSheet, style = HPButtonStyle.GHOST, enabled = !v.creatingChannel)
        return
    }

    // The subject's first name, or the wording for a card that carries no `name` at all — a username is not
    // a name and would put `@tgs_bob` in the middle of a sentence about a person (§2.25).
    val name = v.subjectName
    HPSectionMark("Vouch")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPH2(VouchCopy.ask(name))
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPMuted(VouchCopy.ownership(name))
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    // The label names the subject rather than a pronoun the app does not know; a card with no `name` falls
    // back to the generic form (§2.25).
    HPFieldLabel(v.fieldLabel)
    FlowRow(
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(HPTokens.Space.rowGap),
        verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(HPTokens.Space.labelBottom),
    ) {
        for (tag in v.chips) {
            val vouched = tag in v.alreadyVouched
            // §2.25 — an already-vouched chip is not selectable: a second identical vouch is noise, and the
            // count it would inflate is not a count anyone should trust anyway (PROTOCOL §10.5).
            Chip(
                label = if (vouched) "Vouched" else tag,
                selected = !v.custom && v.selected == tag,
                enabled = !vouched && !v.posting,
                onClick = { vm.pickVouchTag(tag) },
            )
        }
        Chip(
            label = "Something else",
            selected = v.custom,
            enabled = !v.posting,
            onClick = { vm.pickVouchTag(null) },
        )
    }
    if (v.custom) {
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPTextField(v.customText, vm::setVouchCustom, kind = HPFieldKind.Text, gapBelow = false, enabled = !v.posting, contentDescription = "What they do")
        if (v.customRefused) {
            HPText("Letters, numbers, spaces, and + # . - only.", HPTokens.Type.small, HPTokens.Colors.faint)
        }
    }
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPTextField(v.body, vm::setVouchBody, placeholder = "Why.", kind = HPFieldKind.Multiline(4), enabled = !v.posting, contentDescription = "Why")
    HPButtonRow(
        first = { m -> HPButton("Post Vouch", vm::postVouch, modifier = m, style = HPButtonStyle.PRIMARY, enabled = v.canPost) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST, enabled = !v.posting) },
    )
    // §2.25 — the inert `Vouched` chip says what happened; this line says which thing it was. It stands on
    // its own, because "pick one thing" is still the instruction underneath it.
    val spent = v.tag?.takeIf { it in v.alreadyVouched } ?: v.chips.firstOrNull { it in v.alreadyVouched }
    if (spent != null) HPText(VouchCopy.already(name, spent), HPTokens.Type.small, HPTokens.Colors.faint)
    if (v.canPost) {
        HPText("People who follow you will see it, and the people who follow them.", HPTokens.Type.small, HPTokens.Colors.faint)
    } else if (!v.customRefused) {
        HPText("Pick one thing.", HPTokens.Type.small, HPTokens.Colors.faint)
    }
}

/** A single-select pill on a 40pt target built as an overlay, not an inflated box (COMPONENTS rule 6). */
@Composable
private fun Chip(label: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .defaultMinSize(minHeight = HPTokens.Space.touchMin)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                enabled = enabled,
                role = Role.RadioButton,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        HPPill(label, if (selected) HPPillTone.GOLD else HPPillTone.NEUTRAL)
    }
}

/**
 * PRODUCT §2.25 — the vouch sheet: §2.12's comment sheet with two strings changed. `Feed` names the
 * voucher's comments channel, `SAFETY` reads `Report Vouch` and `Block @…`, and there is no `Mute`.
 *
 * On my own work card it also carries the line that is the honest cost of the guarantee: a vouch someone
 * wrote about me is in **their** channel, and I cannot reach it (PROTOCOL §10.4).
 */
@Composable
fun ColumnScope.VouchOptionsSheet(vm: AppViewModel, vouch: Vouch) {
    val context = LocalContext.current
    HPSectionMark("Vouch")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    StatusRow("Posted", Format.exact(vouch.date.toLong()))
    StatusRow("From", "@${vouch.voucherUsername}")
    StatusRow("Channel", "@${vouch.channelUsername}", isLast = true)
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButton("Open in Telegram", { openInTelegram(context, DeepLink.post(vouch.channelUsername, vouch.messageId)) }, style = HPButtonStyle.NEUTRAL)
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    if (vm.isMe(vouch.subjectUsername) && !vouch.own) {
        HPMuted("You can't remove a vouch someone wrote. Report it or block them.")
        Spacer(Modifier.height(HPTokens.Space.rowGap))
    }
    HPSectionMark("Safety")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    if (vouch.own) {
        HPButton("Delete", { vm.openSheet(Sheet.DeleteVouch(vouch)) }, style = HPButtonStyle.DANGER, size = HPButtonSize.SMALL)
    } else {
        HPButton("Report Vouch", { vm.openReport(ReportSubject.forVouch(vouch)) }, style = HPButtonStyle.DANGER, size = HPButtonSize.SMALL)
        Spacer(Modifier.height(HPTokens.Space.rowGap))
        HPButton("Block @${vouch.voucherUsername}", { vm.openSheet(Sheet.Block(vouch.voucherUsername)) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL)
    }
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButton("Close", vm::closeSheet, style = HPButtonStyle.GHOST)
}

/** PRODUCT §2.25 — deleting my own vouch asks once, the same way deleting my own comment does. */
@Composable
fun ColumnScope.DeleteVouchSheet(vm: AppViewModel, vouch: Vouch) {
    HPH2("Delete this vouch?")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButtonRow(
        first = { m -> HPButton("Delete", { vm.deleteVouch(vouch) }, modifier = m, style = HPButtonStyle.DANGER) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST) },
    )
}
