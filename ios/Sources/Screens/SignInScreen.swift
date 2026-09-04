// Screens — Sign in (PRODUCT.md §2.1). Shown whenever TDLib is not authorizationStateReady.

import SwiftUI

struct SignInScreen: View {
    @Environment(AppModel.self) private var model
    @State private var phone = ""
    @State private var code = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HPColumn {
                VStack(alignment: .leading, spacing: 0) {
                    HPWordmark("tgsocial")
                        .padding(.top, HPTokens.Space.bottomSafe / 2)
                    HPH1("Your Telegram, as a feed.")
                        .padding(.top, HPTokens.Space.cardGap)
                    HPMuted("Sign in with the Telegram account you already have. Nothing is stored anywhere but Telegram and this device.")
                        .padding(.top, HPTokens.Space.rowGap)
                        .padding(.bottom, HPTokens.Space.cardPad)
                    HPCard { step }
                    // §2.22's entry point: ghost, OUTSIDE the card, below the gold `Send Code`, so
                    // the card still runs from `PHONE NUMBER` to the one filled button and the
                    // primary action keeps the only fill on the screen.
                    //
                    // Step 1 only. Once a number is in flight the screen has one job, and nobody
                    // mid-sign-in can fall into the demo by reaching for the wrong control.
                    if case .phone = model.auth {
                        HPButton(DemoCopy.enterButton, style: .ghost) { model.enterDemo() }
                            .padding(.top, HPTokens.Space.cardGap)
                        HPMuted(DemoCopy.enterMuted)
                            .padding(.top, HPTokens.Space.rowGap)
                    }
                    // §2.19: the only screen a signed-out reader sees, so the address is on it.
                    Button { model.contactByMail() } label: {
                        HPMuted(Moderation.contactAddress)
                            .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Write to \(Moderation.contactAddress)")
                    .padding(.top, HPTokens.Space.rowGap)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var step: some View {
        switch model.auth {
        case .loading:
            HPMuted("Connecting to Telegram.")
        case .phone:
            HPTextField("Phone number", text: $phone, placeholder: "+1 604 555 0199", kind: .phone) { submitPhone() }
            HPButton("Send Code", style: .primary, enabled: !busy && !phone.trimmingCharacters(in: .whitespaces).isEmpty) { submitPhone() }
        case .code(let number):
            HPMonoSmall(number).padding(.bottom, HPTokens.Space.rowGap)
            HPTextField("Code", text: $code, placeholder: "12345", kind: .number) { submitCode() }
            HPButton("Sign In", style: .primary, enabled: !busy && code.count >= HPMetric.codeLength) { submitCode() }
            HPButton("Use another number", style: .ghost) { code = ""; model.useAnotherNumber() }
                .padding(.top, HPTokens.Space.rowGap)
        case .password(let hint):
            HPTextField("Password", text: $password, placeholder: "", kind: .secure) { submitPassword() }
            if !hint.isEmpty { HPMuted(hint).padding(.bottom, HPTokens.Space.rowGap) }
            HPButton("Unlock", style: .primary, enabled: !busy && !password.isEmpty) { submitPassword() }
        case .otherDevice(let link):
            HPMuted("Confirm this sign-in from another device. The link, as plain text:")
            HPMono(link).padding(.top, HPTokens.Space.rowGap).textSelection(.enabled)
            HPButton("Use a phone number instead", style: .ghost) { model.useAnotherNumber() }
                .padding(.top, HPTokens.Space.rowGap)
        case .registration:
            HPMuted("Sign up in Telegram first.")
            HPButton("Use another number", style: .ghost) { model.useAnotherNumber() }
                .padding(.top, HPTokens.Space.rowGap)
        case .unsupported(let state):
            HPMuted("Telegram wants a step this app doesn't have yet. Sign in with the Telegram app first, then come back.")
            HPMonoSmall(state, color: HPTokens.Colors.faint).padding(.top, HPTokens.Space.rowGap)
            HPButton("Use another number", style: .ghost) { model.useAnotherNumber() }
                .padding(.top, HPTokens.Space.rowGap)
        case .ready:
            HPMuted("Signed in.")
        case .loggingOut:
            HPMuted("Signing out.")
        }
    }

    private func submitPhone() {
        guard !busy else { return }
        busy = true
        Task { await model.submitPhone(phone); busy = false }
    }

    private func submitCode() {
        guard !busy, code.count >= HPMetric.codeLength else { return }
        busy = true
        Task { await model.submitCode(code); busy = false }
    }

    private func submitPassword() {
        guard !busy, !password.isEmpty else { return }
        busy = true
        Task { await model.submitPassword(password); busy = false }
    }
}

/// Shown when Secrets.xcconfig was not filled in (never ships; a developer-facing state).
struct SecretsMissingScreen: View {
    var body: some View {
        ScrollView {
            HPColumn {
                VStack(alignment: .leading, spacing: 0) {
                    HPWordmark("tgsocial").padding(.top, HPTokens.Space.bottomSafe / 2)
                    HPCard {
                        HPH2("No Telegram credentials.")
                        HPMuted("Copy ios/Secrets.xcconfig.example to ios/Secrets.xcconfig and fill in TG_API_ID and TG_API_HASH from my.telegram.org, then rebuild.")
                            .padding(.top, HPTokens.Space.rowGap)
                    }
                    .padding(.top, HPTokens.Space.cardGap)
                }
            }
        }
    }
}
