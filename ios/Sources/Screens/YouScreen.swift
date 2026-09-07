// Screens — You (PRODUCT.md §2.8): my node, my feeds, compose, listing, view as others, Settings.
// Sign Out moved to Settings (§2.20) so the two destructive actions live together; this screen
// pushes Settings and carries the contact lines (§2.19) above the version line.

import SwiftUI

struct YouScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Screen(refresh: { await model.refreshYou() }) {
            if let node = model.myNode, model.myCardState == .newerVersion {
                // PROTOCOL §8: a v2 card is mine, but this client cannot read or write it.
                header(node)
                HPCard { HPMuted(AppModel.newerCardText) }
                HPButton("View as others see it", style: .ghost) { model.path.append(.profile(username: node.username)) }
                HPButton("Settings", style: .ghost) { model.path.append(.settings) }
                    .padding(.top, HPTokens.Space.rowGap)
            } else if let node = model.myNode {
                header(node)
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    HPSectionMark("Your feeds")
                    HPButton("Manage", style: .neutral, size: .small) { model.path.append(.manageFeeds) }
                        .padding(.bottom, HPTokens.Space.rowPad)
                }
                let feeds = model.myCard?.feeds ?? []
                if feeds.isEmpty {
                    HPCard { HPMuted("No feeds yet. Manage picks the channels that post as you.") }
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
                HPButton("Settings", style: .ghost) { model.path.append(.settings) }
                    .padding(.top, HPTokens.Space.rowGap)
            } else {
                // No node: the §2.3 empty state, linking to Setup (PRODUCT §2.2).
                EmptyCard("Nothing here yet.", message: "Follow a node and their feeds show up here, newest first.",
                          action: ("Set Up", { model.openSetup() }))
                HPButton("Settings", style: .ghost) { model.path.append(.settings) }
            }
            // §2.19: the address is reachable from inside the app, and the commitment under it
            // says what a client with no server can actually do about a report.
            VStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                Button { model.contactByMail() } label: {
                    HPMuted("Questions or reports: \(Moderation.contactAddress)")
                        .frame(minHeight: HPTokens.Space.touchMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Write to \(Moderation.contactAddress)")
                HPSmall("Reports are read by a person within 24 hours.", color: HPTokens.Colors.faint)
                HPMonoSmall(footer, color: HPTokens.Colors.faint)
            }
            .padding(.top, HPTokens.Space.cardPad)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
    }

    private var footer: String {
        var parts = [model.versionLine]
        if !model.tdlibVersion.isEmpty { parts.append("TDLib \(model.tdlibVersion)") }
        if let n = model.myNode { parts.append("node @\(n.username)") }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private func header(_ node: MyNode) -> some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowPad) {
            NodeAvatar(photo: model.myPhoto, size: HPTokens.Space.avatarProfile,
                       initial: String((model.myCard?.name ?? model.myTitle).prefix(1)))
            VStack(alignment: .leading, spacing: 0) {
                HPH2((model.myCard?.name?.isEmpty == false ? model.myCard?.name : nil) ?? model.myTitle)
                HPMono("@" + node.username)
            }
            Spacer(minLength: HPTokens.Space.rowGap)
            if model.myCardState == .ok {
                HPButton("Edit Card", style: .neutral, size: .small) { model.modal = .editCard }
            }
        }
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
        HPSectionMark("Work").padding(.top, HPTokens.Space.rowPad)
        // §10.8: nothing here is checkable, and the modal says so rather than letting the fields
        // imply otherwise. `Verified` is reserved for the feed backlink and appears nowhere here.
        HPMuted("Optional. All of this is your own claim, the same as your bio. Nobody checks it and nothing here is verified.")
            .padding(.bottom, HPTokens.Space.cardPad)

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
                HPSmall("Ends \(ends). After that it stops showing.", color: HPTokens.Colors.faint)
                    .padding(.bottom, HPTokens.Space.rowGap)
            }
        }

        HPSectionMark("Work feeds").padding(.top, HPTokens.Space.rowPad)
        HPMuted("Which of your feeds is work. The rest stay where they are.")
            .padding(.bottom, HPTokens.Space.rowGap)
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

struct SignOutModal: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPH2("Sign out of tgsocial?")
            HPMuted("Your node stays on Telegram.")
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Sign Out", style: .danger) { Task { await model.signOut() } }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}
