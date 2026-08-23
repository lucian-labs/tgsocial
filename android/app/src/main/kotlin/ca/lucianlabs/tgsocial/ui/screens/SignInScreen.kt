package ca.lucianlabs.tgsocial.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import ca.lucianlabs.housepour.HPButton
import ca.lucianlabs.housepour.HPButtonStyle
import ca.lucianlabs.housepour.HPCard
import ca.lucianlabs.housepour.HPColumn
import ca.lucianlabs.housepour.HPFieldKind
import ca.lucianlabs.housepour.HPH1
import ca.lucianlabs.housepour.HPMono
import ca.lucianlabs.housepour.HPMuted
import ca.lucianlabs.housepour.HPTextField
import ca.lucianlabs.housepour.HPTokens
import ca.lucianlabs.housepour.HPWordmark
import ca.lucianlabs.tgsocial.ui.AppViewModel
import ca.lucianlabs.tgsocial.ui.AuthStep

/** PRODUCT §2.1 — shown whenever TDLib is not authorizationStateReady. */
@Composable
fun SignInScreen(vm: AppViewModel) {
    val auth by vm.auth.collectAsStateWithLifecycle()
    var phone by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf("") }
    var password by rememberSaveable { mutableStateOf("") }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .systemBarsPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(top = HPTokens.Space.bottomSafe / 2, bottom = HPTokens.Space.bottomSafe),
    ) {
        HPColumn {
            HPWordmark(large = true)
            Spacer(Modifier.height(HPTokens.Space.cardGap))
            HPH1("Your Telegram, as a feed.")
            Spacer(Modifier.height(HPTokens.Space.rowGap))
            HPMuted("Sign in with the Telegram account you already have. Nothing is stored anywhere but Telegram and this device.")
            Spacer(Modifier.height(HPTokens.Space.cardGap + HPTokens.Space.rowGap))
            HPCard {
                when (auth.step) {
                    AuthStep.LOADING -> HPMuted("Connecting to Telegram…")
                    AuthStep.PHONE -> {
                        HPTextField(phone, { phone = it }, label = "Phone number", placeholder = "+1 604 555 0199", kind = HPFieldKind.Phone, imeAction = ImeAction.Go, onSubmit = { vm.sendPhone(phone) })
                        HPButton("Send Code", { vm.sendPhone(phone) }, style = HPButtonStyle.PRIMARY, enabled = !auth.busy && phone.isNotBlank())
                    }
                    AuthStep.CODE -> {
                        HPTextField(code, { if (it.length <= 8) code = it.filter { c -> c.isDigit() } }, label = "Code", placeholder = "12345", kind = HPFieldKind.Number, imeAction = ImeAction.Go, onSubmit = { vm.sendCode(code) })
                        HPButton("Sign In", { vm.sendCode(code) }, style = HPButtonStyle.PRIMARY, enabled = !auth.busy && code.length >= 4)
                        Spacer(Modifier.height(HPTokens.Space.rowGap))
                        HPButton("Use another number", { code = ""; vm.useAnotherNumber() }, style = HPButtonStyle.GHOST, enabled = !auth.busy)
                    }
                    AuthStep.PASSWORD -> {
                        HPTextField(password, { password = it }, label = "Password", kind = HPFieldKind.Secure, imeAction = ImeAction.Go, onSubmit = { vm.sendPassword(password) }, gapBelow = auth.passwordHint.isBlank())
                        if (auth.passwordHint.isNotBlank()) {
                            HPMuted(auth.passwordHint)
                            Spacer(Modifier.height(HPTokens.Space.inputBottom))
                        }
                        HPButton("Unlock", { vm.sendPassword(password) }, style = HPButtonStyle.PRIMARY, enabled = !auth.busy && password.isNotEmpty())
                    }
                    AuthStep.OTHER_DEVICE -> {
                        HPMuted("Open this link on a device where you are already signed in to Telegram.")
                        Spacer(Modifier.height(HPTokens.Space.rowGap))
                        HPMono(auth.qrLink.orEmpty())
                        Spacer(Modifier.height(HPTokens.Space.cardGap))
                        HPButton("Use a phone number", { vm.useAnotherNumber() }, style = HPButtonStyle.GHOST)
                    }
                    AuthStep.REGISTRATION -> {
                        HPMuted("Sign up in Telegram first.")
                        Spacer(Modifier.height(HPTokens.Space.cardGap))
                        HPButton("Use another number", { vm.useAnotherNumber() }, style = HPButtonStyle.GHOST)
                    }
                    AuthStep.READY -> Unit
                }
            }
        }
    }
}
