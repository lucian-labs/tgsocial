// Screens — Sign in (PRODUCT.md §2.1). Shown whenever the reader is signed in to neither network
// (§1), as §2.1's offer of the second network once the first is in, and — Telegram's card alone —
// pushed from inside the app for a reader signed in to Bluesky alone (`TelegramSignInScreen`).
//
// Two peer cards, and neither button is gold: gold marks the one next action (§1), and a gold
// `Send Code` would say Telegram is the sign-in and Bluesky the extra. Once a sign-in is in flight
// the screen has one job, and that job's card stands alone with its button gold.

import SwiftUI

enum SignInMode: Equatable {
    /// Signed in to neither: both cards, `Look Around First`.
    case both
    /// §2.1's offer: the other network's card alone, gold, and `Not Now`.
    case offer(OtherNetwork)
}

struct SignInScreen: View {
    @Environment(AppModel.self) private var model
    let mode: SignInMode
    @State private var telegram = TelegramEntry()
    @State private var handle = ""
    @State private var blueskyRunning = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HPColumn {
                VStack(alignment: .leading, spacing: 0) {
                    HPWordmark("tgsocial")
                        .padding(.top, HPTokens.Space.bottomSafe / 2)
                    HPH1(headline)
                        .padding(.top, HPTokens.Space.cardGap)
                    cards
                        .padding(.top, HPTokens.Space.cardPad)
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

    private var headline: String {
        switch mode {
        case .both: return SessionCopy.headline
        case .offer(let network): return SessionCopy.offerTitle(network)
        }
    }

    /// Whether Telegram's card is shown here at all: not in the Bluesky offer, where Telegram is
    /// already in and `auth` reads `.ready`.
    private var hasTelegramCard: Bool { mode != .offer(.bluesky) }
    private var hasBlueskyCard: Bool { mode != .offer(.telegram) }

    @ViewBuilder private var cards: some View {
        if hasTelegramCard, !model.auth.isPhoneStep {
            // A number is in flight: Telegram's card alone, its button gold (§2.1 "Telegram's steps").
            HPCard { TelegramSteps(entry: $telegram, primary: true) }
        } else if hasBlueskyCard, let waiting = model.bluesky.waitingHandle {
            // Bluesky's page is open in the browser: the waiting state in place of both cards.
            HPCard { BlueskyWaiting(handle: waiting) }
        } else {
            switch mode {
            case .both:
                VStack(alignment: .leading, spacing: HPTokens.Space.cardGap) {
                    HPCard { TelegramSteps(entry: $telegram, primary: false) }
                    HPCard { blueskyCard(primary: false) }
                }
                // §2.22's entry point: ghost, outside both cards, so the two sign-ins stay the
                // screen's two filled buttons and the demo reads as the third, lesser way in.
                // Step 1 only — absent once either sign-in is in flight.
                if !blueskyRunning {
                    HPButton(DemoCopy.enterButton, style: .ghost) { model.enterDemo() }
                        .padding(.top, HPTokens.Space.cardGap)
                }
            case .offer(let network):
                HPCard {
                    if network == .bluesky { blueskyCard(primary: true) } else { TelegramSteps(entry: $telegram, primary: true) }
                }
                HPButton(SessionCopy.notNow, style: .ghost) { model.declineOffer() }
                    .padding(.top, HPTokens.Space.cardGap)
            }
        }
    }

    @ViewBuilder private func blueskyCard(primary: Bool) -> some View {
        HPSectionMark(SessionCopy.blueskyMark)
        HPTextField(SessionCopy.handleLabel, text: $handle, placeholder: "elijah.bsky.social", kind: .mono) { submitBluesky() }
        HPButton(BlueskyCopy.signIn, style: primary ? .primary : .neutral,
                 enabled: !blueskyRunning && AtprotoIdentity.handleInput(handle) != nil) { submitBluesky() }
        if blueskyRunning {
            // Before the browser opens (finding the server): Cancel stops the attempt there.
            HPButton("Cancel", style: .ghost) { model.bluesky.cancelSignIn() }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// §2.35's sign-in, run from this card. A cancel, a refusal, a failure and the timeout come
    /// back here with the handle still typed; success routes itself (the offer, or the app).
    private func submitBluesky() {
        guard !blueskyRunning, AtprotoIdentity.handleInput(handle) != nil else { return }
        blueskyRunning = true
        Task {
            _ = await model.signInBluesky(handle)
            blueskyRunning = false
        }
    }
}

/// §2.35's waiting state, in a card: the resolved handle, the screen's one helper line, Cancel.
struct BlueskyWaiting: View {
    @Environment(AppModel.self) private var model
    let handle: String

    var body: some View {
        HPSectionMark(SessionCopy.blueskyMark)
        HPH2(BlueskyCopy.waiting)
        HPMonoSmall(handle).lineLimit(1)
            .padding(.top, HPTokens.Space.rowGap)
        HPMuted(BlueskyCopy.finishInBrowser)
            .padding(.top, HPTokens.Space.rowGap)
            .padding(.bottom, HPTokens.Space.cardPad)
        HPButton("Cancel", style: .ghost) { model.bluesky.cancelSignIn() }
    }
}

/// What the reader has typed into Telegram's steps. Held by the screen, not the card, so a card
/// that moves between "both" and "alone" keeps the number.
struct TelegramEntry: Equatable {
    var phone = ""
    var code = ""
    var password = ""
    var busy = false
}

extension AuthPhase {
    /// §2.1 step 1 — or TDLib not up yet, or off on purpose (§12.11): the phone field, and `Send
    /// Code` starts TDLib if it has to. Everything else is a sign-in in flight.
    var isPhoneStep: Bool {
        switch self {
        case .loading, .phone, .off: return true
        default: return false
        }
    }
}

/// Telegram's steps (PROTOCOL §4.1), in whichever card holds them. `primary` is whether this card
/// is the one next action: false beside Bluesky's card, true alone — and every step after the
/// number is alone.
struct TelegramSteps: View {
    @Environment(AppModel.self) private var model
    @Binding var entry: TelegramEntry
    let primary: Bool

    var body: some View {
        HPSectionMark(SessionCopy.telegramMark)
        switch model.auth {
        case .loading, .off, .phone:
            HPTextField(SessionCopy.phoneLabel, text: $entry.phone, placeholder: "+1 604 555 0199", kind: .phone) { submitPhone() }
            HPButton(SessionCopy.sendCode, style: primary ? .primary : .neutral,
                     enabled: !entry.busy && !entry.phone.trimmingCharacters(in: .whitespaces).isEmpty) { submitPhone() }
        case .code(let number):
            HPMonoSmall(number).padding(.bottom, HPTokens.Space.rowGap)
            HPTextField("Code", text: $entry.code, placeholder: "12345", kind: .number) { submitCode() }
            HPButton("Sign In", style: .primary, enabled: !entry.busy && entry.code.count >= HPMetric.codeLength) { submitCode() }
            HPButton("Use another number", style: .ghost) { entry.code = ""; model.useAnotherNumber() }
                .padding(.top, HPTokens.Space.rowGap)
        case .password(let hint):
            HPTextField("Password", text: $entry.password, placeholder: "", kind: .secure) { submitPassword() }
            if !hint.isEmpty { HPMuted(hint).padding(.bottom, HPTokens.Space.rowGap) }
            HPButton("Unlock", style: .primary, enabled: !entry.busy && !entry.password.isEmpty) { submitPassword() }
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
            HPMuted("Sign in with the Telegram app first.")
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
        guard !entry.busy, !entry.phone.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        entry.busy = true
        Task { await model.submitPhone(entry.phone); entry.busy = false }
    }

    private func submitCode() {
        guard !entry.busy, entry.code.count >= HPMetric.codeLength else { return }
        entry.busy = true
        Task { await model.submitCode(entry.code); entry.busy = false }
    }

    private func submitPassword() {
        guard !entry.busy, !entry.password.isEmpty else { return }
        entry.busy = true
        Task { await model.submitPassword(entry.password); entry.busy = false }
    }
}

/// PRODUCT §2.1 "From inside the app": a Bluesky-only reader's `Sign In with Telegram`. Telegram's
/// card alone, its button gold, `‹ Back` top left, no `Look Around First`, no offer. It lands where
/// Telegram's sign-in would — Setup with no node, else back where it was opened (`onReady` pops it).
struct TelegramSignInScreen: View {
    @State private var entry = TelegramEntry()

    var body: some View {
        Screen(back: true) {
            HPCard { TelegramSteps(entry: $entry, primary: true) }
        }
    }
}

/// PRODUCT §2.41's Telegram card: a screen whose content needs Telegram, reached signed in to
/// Bluesky alone, keeps its topbar and tab bar and shows this in place of its body — the screen's
/// one helper line (§3) and its one action.
struct NeedsTelegramCard: View {
    @Environment(AppModel.self) private var model
    /// The screen's own verb: `find nodes`, `see @tgs_ana`, `use the Connector`.
    let verb: String

    var body: some View {
        HPCard {
            HPMuted(SessionCopy.needsTelegram(verb))
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButton(SessionCopy.signInWithTelegram, style: .primary) { model.openTelegramSignIn() }
                .hpTouchRegion(SessionCopy.signInWithTelegram)
        }
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
