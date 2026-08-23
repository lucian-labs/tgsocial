// Screens — You (PRODUCT.md §2.8): my node, my feeds, compose, listing, view as others, sign out.

import SwiftUI

struct YouScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Screen(refresh: { await model.refreshYou() }) {
            HPTabs(items: Tab.allCases, selected: $model.tab) { $0.label }
            if let node = model.myNode, model.myCardState == .newerVersion {
                // PROTOCOL §8: a v2 card is mine, but this client cannot read or write it.
                header(node)
                HPCard { HPMuted(AppModel.newerCardText) }
                HPButton("View as others see it", style: .ghost) { model.path.append(.profile(username: node.username)) }
                HPButton("Sign Out", style: .danger) { model.modal = .signOut }
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
                            let info = model.nodes.cachedFeed(f)
                            FeedRow(feed: info, username: f, verified: info?.isVerified(for: node.username) ?? false, isLast: i == feeds.count - 1) {
                                model.modal = .compose(feed: f)
                            }
                        }
                    }
                }
                HPButton("Compose", style: .primary, enabled: !feeds.isEmpty) { model.modal = .compose(feed: feeds.first) }
                    .padding(.bottom, HPTokens.Space.cardGap)

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
                HPButton("View as others see it", style: .ghost) { model.path.append(.profile(username: node.username)) }
                HPButton("Sign Out", style: .danger) { model.modal = .signOut }
                    .padding(.top, HPTokens.Space.rowGap)
            } else {
                // No node: the §2.3 empty state, linking to Setup (PRODUCT §2.2).
                EmptyCard("Nothing here yet.", message: "Follow a node and their feeds show up here, newest first.",
                          action: ("Set Up", { model.openSetup() }))
                HPButton("Sign Out", style: .danger) { model.modal = .signOut }
            }
            HPMonoSmall(footer, color: HPTokens.Colors.faint)
                .padding(.top, HPTokens.Space.cardPad)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private var footer: String {
        var parts = ["tgsocial \(model.appVersion) (\(model.buildNumber))"]
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

struct EditCardModal: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var bio = ""
    @State private var link = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Edit card")
            HPTextField("Name", text: $name, placeholder: "", kind: .text)
            HPTextField("Bio", text: $bio, placeholder: "", kind: .text)
            HPTextField("Link", text: $link, placeholder: "https://", kind: .url)
            HPButtonRow {
                HPButton("Save", style: .primary, enabled: !saving) {
                    saving = true
                    Task {
                        if await model.editCard(name: name, bio: bio, link: link) { model.modal = nil }
                        saving = false
                    }
                }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
        .onAppear {
            name = model.myCard?.name ?? model.myTitle
            bio = model.myCard?.bio ?? ""
            link = model.myCard?.link ?? ""
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
