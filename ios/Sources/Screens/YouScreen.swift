// Screens — You (PRODUCT.md §2.8): my node, my feeds, compose, listing, view as others. The avatar
// tab opens it (§1). `Settings` is top right in every state (Elijah, 2026-09-25: "put "settings" on
// top right of that") — the one door to Settings, where both sign-outs and Delete My Node live
// together (§2.20). The contact lines (§2.19) sit above the version line.

import SwiftUI

struct YouScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Screen(refresh: { await model.refreshYou() }) {
            YouSettingsButton()
            if model.session.kind == .blueskyOnly {
                // §2.8, Bluesky only: no node, so no node sections — the account, Compose, and the
                // Telegram section standing where they would be.
                blueskyOnlyBody
            } else if let node = model.myNode, model.myCardState == .newerVersion {
                // PROTOCOL §8: a v2 card is mine, but this client cannot read or write it.
                header(node)
                HPCard { HPMuted(AppModel.newerCardText) }
                HPButton("View as others see it", style: .ghost) { model.path.append(.profile(username: node.username)) }
            } else if let node = model.myNode {
                header(node)
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    HPSectionMark("Your feeds")
                    HPButton("Manage", style: .neutral, size: .small) { model.path.append(.manageFeeds) }
                        .padding(.bottom, HPTokens.Space.rowPad)
                }
                let feeds = model.myCard?.feeds ?? []
                if feeds.isEmpty {
                    HPCard { HPMuted("No feeds yet.") }
                } else {
                    HPListCard {
                        ForEach(Array(feeds.enumerated()), id: \.element) { i, f in
                            let info = model.feedInfo(f)
                            FeedRow(feed: info, username: f, verified: info?.isVerified(for: node.username) ?? false, isLast: i == feeds.count - 1) {
                                model.modal = .compose(feed: f)
                            }
                        }
                    }
                }
                HPButton("Compose", style: .primary, enabled: !feeds.isEmpty) { model.modal = .compose(feed: feeds.first) }
                    .padding(.bottom, HPTokens.Space.cardGap)

                // PRODUCT §2.23: the only nag in this section. `work.open` expires on its own, so
                // a person who forgets is invisible without being told. One row, no badge, no red,
                // dismissible by acting or by ignoring it; it never appears on anyone else's
                // screen and there is no notification.
                if let notice = model.openExpiryNotice {
                    HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                        HPMuted(notice)
                        Spacer(minLength: HPTokens.Space.rowGap)
                        HPButton("Edit Card", style: .ghost, size: .small) { model.modal = .editCard }
                    }
                    .padding(.bottom, HPTokens.Space.cardGap)
                }

                HPSectionMark("Listing")
                HPCard {
                    let isPublic = model.myCard?.isPublic ?? true
                    HPListItem {
                        HPBody("Public listing")
                    } trailing: {
                        Button { Task { await model.setPublic(!isPublic) } } label: {
                            HPPill(isPublic ? "Listed" : "Unlisted", tone: isPublic ? .gold : .neutral)
                                .hpTouchTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isPublic ? "Public listing on. Tap to unlist." : "Public listing off. Tap to list.")
                    }
                    HPListItem(isLast: true) {
                        HPButton("Announce in Directory", style: .neutral, size: .small, enabled: isPublic) { Task { await model.announce() } }
                    }
                }
                // PRODUCT §2.27: between LISTING and `View as others see it`. Not in the demo
                // (§2.34): a demo that painted an invite link would be handing the reviewer a fake
                // bearer token to reason about.
                if !model.isDemo {
                    PrivateSection().padding(.top, HPTokens.Space.cardGap)
                }
                HPButton("View as others see it", style: .ghost) { model.path.append(.profile(username: node.username)) }
            } else {
                // No node: the §2.3 empty state, linking to Setup (PRODUCT §2.2).
                EmptyCard("Nothing here yet.", action: ("Set Up", { model.openSetup() }))
                    .hpTouchRegion(YouScreen.headerRegion)
            }
            // §2.19: the address is reachable from inside the app. The 24-hour commitment is on
            // Settings' CONTACT card, the one place it is said (§3: one helper line, not two).
            VStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                Button { model.contactByMail() } label: {
                    HPMuted(Moderation.contactAddress)
                        .frame(minHeight: HPTokens.Space.touchMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Write to \(Moderation.contactAddress)")
                HPMonoSmall(footer, color: HPTokens.Colors.faint)
            }
            .padding(.top, HPTokens.Space.cardPad)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
    }

    /// Bluesky only (§2.8): the account. The header taps through to the profile on Bluesky; Compose
    /// posts there (§2.9) and is absent while Bluesky has ended the session, until `Sign In Again`.
    @ViewBuilder private var blueskyOnlyBody: some View {
        let bsky = model.bluesky!
        let handle = bsky.account?.handleLabel ?? bsky.endedHandle.map { "@" + $0 } ?? ""
        let name = bsky.account?.displayName?.isEmpty == false ? bsky.account!.displayName! : handle
        Button {
            if let did = bsky.heldDid { model.open(Atproto.bskyProfileUrl(did)) }
        } label: {
            HStack(alignment: .center, spacing: HPTokens.Space.rowPad) {
                MyAvatarImage(avatar: model.tabAvatar, size: HPTokens.Space.avatarProfile)
                VStack(alignment: .leading, spacing: 0) {
                    HPH2(name).lineLimit(1)
                    HPMono(handle).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(handle) on Bluesky")
        .hpTouchRegion(YouScreen.headerRegion)
        .padding(.bottom, HPTokens.Space.cardGap)
        if bsky.isSignedIn {
            HPButton("Compose", style: .primary) { model.modal = .compose(feed: nil) }
                .padding(.bottom, HPTokens.Space.cardGap)
        }
        HPSectionMark(SessionCopy.telegramMark)
        HPButton(SessionCopy.signInWithTelegram, style: .neutral, size: .small) { model.openTelegramSignIn() }
            .hpTouchRegion(SessionCopy.signInWithTelegram)
    }

    /// The first thing under `Settings` in every state — the header, or the no-node card — measured
    /// so a test can read that `Settings` sits above it, at its right edge.
    static let headerRegion = "You.header"

    private var footer: String {
        var parts = [model.versionLine]
        // A Bluesky-only reader runs no TDLib (PROTOCOL §12.11), so the line names none.
        if model.telegramReady, !model.tdlibVersion.isEmpty { parts.append("TDLib \(model.tdlibVersion)") }
        if let n = model.myNode { parts.append("node @\(n.username)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private func header(_ node: MyNode) -> some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowPad) {
            // §1's chain, the tab's own: the node photo, else the Bluesky avatar (both signed in,
            // a node with no photo), else the initial.
            MyAvatarImage(avatar: model.tabAvatar, size: HPTokens.Space.avatarProfile)
            VStack(alignment: .leading, spacing: 0) {
                HPH2((model.myCard?.name?.isEmpty == false ? model.myCard?.name : nil) ?? model.myTitle)
                HPMono("@" + node.username)
            }
            Spacer(minLength: HPTokens.Space.rowGap)
            if model.myCardState == .ok {
                HPButton("Edit Card", style: .neutral, size: .small) { model.modal = .editCard }
            }
        }
        .hpTouchRegion(Self.headerRegion)
        .padding(.bottom, HPTokens.Space.cardGap)
    }
}

/// You → Manage: the Setup feeds card as a pushed screen.
struct ManageFeedsScreen: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Screen(back: true) {
            FeedsCard(primaryLabel: "Save Feeds") { dismiss() }
        }
    }
}

/// PRODUCT §2.8's Edit Card, grown a `WORK` section (§2.23). The NAME / BIO / LINK fields are
/// unchanged; everything below them is optional and absent from the card until it is filled in.
struct EditCardModal: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var bio = ""
    @State private var link = ""
    @State private var saving = false

    // Work (§2.23). `intent == nil` is the `Nothing` tab, which writes no `work.open` at all.
    @State private var role = ""
    @State private var does = ""
    @State private var intent: WorkIntent?
    @State private var horizon = WorkCodec.openHorizons[0]
    @State private var workFeeds: Set<String> = []
    @State private var roleTrimmed = false
    @State private var notes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Edit card")
            HPTextField("Name", text: $name, placeholder: "", kind: .text)
            HPTextField("Bio", text: $bio, placeholder: "", kind: .text)
            HPTextField("Link", text: $link, placeholder: "https://", kind: .url)
            workSection
            HPButtonRow {
                HPButton("Save", style: .primary, enabled: !saving) { save() }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
                    ForEach(notes, id: \.self) { HPSmall($0, color: HPTokens.Colors.faint) }
                }
                .padding(.top, HPTokens.Space.rowGap)
            }
        }
        .onAppear { load() }
    }

    @ViewBuilder private var workSection: some View {
        // §10.8: nothing here is checkable. The fields do not imply otherwise because `Verified`
        // is reserved for the feed backlink and appears nowhere here; the reason lives in PRODUCT
        // §2.23, not on screen (§3).
        HPSectionMark("Work").padding(.top, HPTokens.Space.rowPad)

        HPTextField("Role", text: $role, placeholder: "", kind: .text)
            .onChange(of: role) { _, new in
                // §2.23 makes this a PASTE-time behaviour: "the field takes the first 80, faint
                // under it reads `Trimmed to 80.`" Trimming at Save instead would put the note on
                // screen for the tick before the modal closes, so the writer sees `Card saved.`
                // and never learns what went. The field is the cap.
                if new.count > WorkCodec.roleMax {
                    role = String(new.prefix(WorkCodec.roleMax))
                    roleTrimmed = true
                } else if new.count < WorkCodec.roleMax {
                    roleTrimmed = false
                }
            }
        if role.count >= 60 {
            HPSmall("\(role.count) / \(WorkCodec.roleMax)", color: HPTokens.Colors.faint)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if roleTrimmed { HPSmall("Trimmed to 80.", color: HPTokens.Colors.faint) }

        HPTextField("What you do", text: $does, placeholder: "", kind: .text)
        HPSmall("Up to twelve, separated by commas.", color: HPTokens.Colors.faint)
            .padding(.bottom, HPTokens.Space.rowGap)

        HPFieldLabel("Open to")
        HPTabs(items: intentTabs, selected: intentSelection, bottomPadded: false) { $0?.editLabel ?? "Nothing" }
            .padding(.bottom, HPTokens.Space.rowGap)
        if intent != nil {
            HPFieldLabel("For")
            HPTabs(items: WorkCodec.openHorizons, selected: $horizon, bottomPadded: false) { "\($0) days" }
                .padding(.bottom, HPTokens.Space.rowGap)
            // The date is derived, never typed — §10.3's expiry is arithmetic on the card text and
            // the writer should be able to see exactly what it will say.
            if let ends = WorkCodec.day(after: horizon).flatMap(WorkDate.full) {
                HPSmall("Ends \(ends).", color: HPTokens.Colors.faint)
                    .padding(.bottom, HPTokens.Space.rowGap)
            }
        }

        HPSectionMark("Work feeds").padding(.top, HPTokens.Space.rowPad)
        let feeds = model.myCard?.feeds ?? []
        if feeds.isEmpty {
            HPCard { HPMuted("You have no feeds yet.") }
        } else {
            HPListCard {
                ForEach(Array(feeds.enumerated()), id: \.element) { i, feed in
                    HPListItem(isLast: i == feeds.count - 1) {
                        VStack(alignment: .leading, spacing: 0) {
                            HPBody(model.feedInfo(feed)?.title ?? feed).lineLimit(1)
                            HPMonoSmall("@" + feed).lineLimit(1)
                        }
                    } trailing: {
                        HPToggle(isOn: toggle(for: feed), label: "Mark @\(feed) as work")
                    }
                }
            }
        }
    }

    /// `Nothing` first, then the four §10.3 intents. Optionals as tab items so `Nothing` is the
    /// absence of an intent rather than a fifth one the card would have to spell.
    private var intentTabs: [WorkIntent?] { [nil] + WorkIntent.allCases.map { Optional($0) } }
    private var intentSelection: Binding<WorkIntent?> { Binding(get: { intent }, set: { intent = $0 }) }

    private func toggle(for feed: String) -> Binding<Bool> {
        Binding(get: { workFeeds.contains(Username.key(feed)) },
                set: { on in
                    if on { workFeeds.insert(Username.key(feed)) } else { workFeeds.remove(Username.key(feed)) }
                })
    }

    private func load() {
        name = model.myCard?.name ?? model.myTitle
        bio = model.myCard?.bio ?? ""
        link = model.myCard?.link ?? ""
        let work = model.myWork
        role = work?.role ?? ""
        does = (work?.does ?? []).joined(separator: ", ")
        intent = work?.open?.intent
        // The horizon is not on the card — the end date is (§10.3) — so it comes back from what is
        // left of it. Without this the control reads `30 days` over a 90-day intent, and any Save,
        // even one that only touched the bio, would rewrite the end date to today+30.
        horizon = model.editCardHorizon
        workFeeds = Set((work?.feeds ?? []).map(Username.key))
    }

    private func save() {
        saving = true
        notes = []
        let feeds = (model.myCard?.feeds ?? []).filter { workFeeds.contains(Username.key($0)) }
        Task {
            // One write for both halves (§10.6): they are the same pinned message, and two writes
            // would be two chances to fail and a state where the bio landed and the work card
            // did not.
            switch await model.saveCard(name: name, bio: bio, link: link,
                                        role: role, doesText: does, intent: intent,
                                        horizonDays: horizon, feeds: feeds) {
            case .saved:
                model.showToast("Card saved.", tone: .good)
                model.modal = nil
            case .savedWithNotes(let list):
                notes = list
                model.showToast("Card saved.", tone: .good)
            case .refused(let text):
                if !text.isEmpty { model.showToast(text, tone: .bad) }
            }
            saving = false
        }
    }
}

/// PRODUCT §2.8: `( Settings )`, ghost sm, in the header's top-right corner — where §2.6 puts a
/// channel's kebab — in every state, the demo included. The topbar's right is the status pill's.
struct YouSettingsButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HPButton(SessionCopy.settings, style: .ghost, size: .small) { model.path.append(.settings) }
                .hpTouchRegion(SessionCopy.settings)
        }
    }
}

/// PRODUCT §4: `Sign out of Telegram?` — the consequence, one sentence (§3). Signing out of
/// Telegram no longer signs out of Bluesky (§2.35: "Sign-outs are independent"), so the line that
/// used to say so is gone, and being the last one out changes nothing it says.
struct SignOutModal: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPH2(SessionCopy.signOutTelegramTitle)
            HPMuted(SessionCopy.signOutTelegramBody)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Sign Out", style: .danger) { Task { await model.signOutTelegram() } }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}
