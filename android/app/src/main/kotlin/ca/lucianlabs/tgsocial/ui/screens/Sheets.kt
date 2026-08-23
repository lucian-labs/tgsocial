package ca.lucianlabs.tgsocial.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonRow
import ca.lucianlabs.housepour.HPButtonSize
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPFieldKind
import ca.lucianlabs.housepour.HPH2
import ca.lucianlabs.housepour.HPMonoSmall
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPSectionMark
import ca.lucianlabs.housepour.HPTabs
import ca.lucianlabs.housepour.HPTextField
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.tgsocial.ui.AppViewModel

/**
 * Sheet bodies. The modal itself (scrim, card, fade) is one `HPModal` host in the shell; these are its contents.
 * PRODUCT §2.9 — Compose. Photo attach via the system Photo Picker (no storage permission).
 */
@Composable
fun ColumnScope.ComposeSheet(vm: AppViewModel) {
    val c by vm.compose.collectAsStateWithLifecycle()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> vm.composePhoto(uri) }
    HPSectionMark("Post to")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    if (c.feeds.isEmpty()) {
        HPMuted("Pick a feed on the You screen first.")
    } else {
        HPTabs(items = c.feeds.map { it.title }, selected = c.selected.coerceIn(0, c.feeds.lastIndex), onSelect = vm::composeSelect)
    }
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPTextField(c.text, vm::composeText, placeholder = "Say it.", kind = HPFieldKind.Multiline(6), enabled = !c.posting, contentDescription = "Post text")
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = HPTokens.Space.rowGap)) {
        HPButton(if (c.photo == null) "Add Photo" else "Change Photo", { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, enabled = !c.posting)
        if (c.photo != null) {
            Spacer(Modifier.width(HPTokens.Space.rowGap))
            HPMonoSmall("1 photo", maxLines = 1)
            Spacer(Modifier.width(HPTokens.Space.rowGap))
            HPButton("Remove", { vm.composePhoto(null) }, style = HPButtonStyle.GHOST, size = HPButtonSize.SMALL, enabled = !c.posting)
        }
    }
    HPButtonRow(
        first = { m -> HPButton("Post", vm::post, modifier = m, style = HPButtonStyle.PRIMARY, enabled = !c.posting && c.feeds.isNotEmpty() && (c.text.isNotBlank() || c.photo != null)) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST, enabled = !c.posting) },
    )
}

/** PRODUCT §2.8 — Edit Card modal: NAME, BIO, LINK, Save. */
@Composable
fun ColumnScope.EditCardSheet(vm: AppViewModel) {
    val e by vm.editCard.collectAsStateWithLifecycle()
    HPH2("Edit card")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPTextField(e.name, { vm.setEditCard(name = it) }, label = "Name", kind = HPFieldKind.Text)
    HPTextField(e.bio, { vm.setEditCard(bio = it) }, label = "Bio", kind = HPFieldKind.Text)
    HPTextField(e.link, { vm.setEditCard(link = it) }, label = "Link", kind = HPFieldKind.Url, placeholder = "https://")
    HPButtonRow(
        first = { m -> HPButton("Save", vm::saveEditCard, modifier = m, style = HPButtonStyle.PRIMARY, enabled = !e.saving) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST) },
    )
}

/** PRODUCT §4 — Sign out asks once. */
@Composable
fun ColumnScope.SignOutSheet(vm: AppViewModel) {
    HPH2("Sign out of tgsocial?")
    Spacer(Modifier.height(HPTokens.Space.rowGap))
    HPMuted("Your node stays on Telegram.")
    Spacer(Modifier.height(HPTokens.Space.cardGap))
    HPButtonRow(
        first = { m -> HPButton("Sign Out", vm::signOut, modifier = m, style = HPButtonStyle.DANGER) },
        second = { m -> HPButton("Cancel", vm::closeSheet, modifier = m, style = HPButtonStyle.GHOST) },
    )
}
