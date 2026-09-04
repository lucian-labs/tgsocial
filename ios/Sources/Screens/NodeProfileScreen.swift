// Screens — Node profile (PRODUCT.md §2.5). My own profile is the same screen with no Follow button.

import SwiftUI

struct NodeProfileScreen: View {
    @Environment(AppModel.self) private var model
    let username: String
    @State private var node: NodeInfo?
    @State private var feeds: [FeedInfo] = []
    @State private var follows: [NodeInfo] = []
    @State private var failed = false

    var body: some View {
        Screen(back: true, refresh: { await load(force: true) }) {
            // §2.16: a blocked node renders as nothing at all everywhere else, but this profile is
            // reached deliberately — a t.me link, a public URL, an exact-username search — and an
            // empty screen there reads as a broken app. So it says so, and offers the undo.
            if model.isBlocked(username) {
                blockedState
            } else if let node {
                header(node)
                if node.state == .newerVersion {
                    HPCard { HPMuted("Newer card. Update the app.") }
                } else if node.state == .notANode {
                    HPCard { HPMuted("Not a tgsocial node.") }
                } else if let card = node.card {
                    if !model.isMe(node.username) {
                        FollowButton(username: node.username, size: .regular)
                            .padding(.bottom, HPTokens.Space.cardGap)
                    }
                    HPSectionMark("Feeds")
                    if card.feeds.isEmpty {
                        HPCard { HPMuted("No feeds listed.") }
                    } else {
                        HPListCard {
                            ForEach(Array(card.feeds.enumerated()), id: \.element) { i, feedName in
                                let info = feeds.first { $0.key == Username.key(feedName) }
                                // §2.17: a muted feed stays listed here, wearing the pill.
                                FeedRow(feed: info, username: feedName,
                                        verified: info?.isVerified(for: node.username) ?? false,
                                        muted: model.isMuted(feed: feedName),
                                        isLast: i == card.feeds.count - 1) {
                                    model.path.append(.feedChannel(username: feedName))
                                }
                            }
                        }
                    }
                    HPSectionMark("Follows", count: card.follows.count)
                    if card.follows.isEmpty {
                        HPCard { HPMuted("Follows no one yet.") }
                    } else {
                        HPListCard {
                            ForEach(Array(card.follows.enumerated()), id: \.element) { i, name in
                                let info = follows.first { $0.key == Username.key(name) }
                                    ?? NodeInfo(username: name, chatId: 0, title: name, card: nil, state: .ok, photo: nil, fetchedAt: .distantPast)
                                NodeRow(node: info, isLast: i == card.follows.count - 1, showFollow: false) {
                                    model.path.append(.profile(username: name))
                                }
                            }
                        }
                    }
                }
            } else if failed {
                HPCard { HPMuted("Not a tgsocial node.") }
            } else {
                FeedFooter(text: "Loading\u{2026}")
            }
        }
        // PROTOCOL §4.5: refresh when opening a profile; the cached card is the instant placeholder.
        .task(id: username) { await load(force: true) }
    }

    /// PRODUCT §2.16. Their photo is not loaded: the initial stands in, because a blocked node
    /// should not be handed a face on the one screen that still mentions them.
    @ViewBuilder private var blockedState: some View {
        VStack(alignment: .leading, spacing: 0) {
            NodeAvatar(photo: nil, size: HPTokens.Space.avatarProfile, initial: String(username.prefix(1)))
            HPMono("@" + username).padding(.top, HPTokens.Space.rowPad)
            HPH2("You blocked this node.").padding(.top, HPTokens.Space.rowGap)
            HPMuted("Nothing they post reaches you.").padding(.top, HPTokens.Space.rowGap)
            HPButton("Unblock", style: .ghost) { model.unblock(username) }
                .padding(.top, HPTokens.Space.cardPad)
        }
    }

    @ViewBuilder private func header(_ node: NodeInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: HPTokens.Space.rowGap) {
                NodeAvatar(photo: node.photo, size: HPTokens.Space.avatarProfile, initial: node.initial)
                Spacer(minLength: HPTokens.Space.rowGap)
                // §2.5: the same kebab the feed channel carries (§2.6), now carrying Block (§2.16).
                HPMenu(items: kebabItems(node))
            }
            HPH1(node.displayName).padding(.top, HPTokens.Space.rowPad)
            HPMono("@" + node.username)
            if let bio = node.card?.bio, !bio.isEmpty { HPMuted(bio).padding(.top, HPTokens.Space.rowGap) }
            if let link = node.card?.link, !link.isEmpty {
                Button { model.open(link) } label: {
                    Text(link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                        .hpStyle(HPType.body, color: HPTokens.Colors.accent)
                        .underline()
                        .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open link \(link)")
            }
        }
        .padding(.bottom, HPTokens.Space.cardGap)
    }

    private func kebabItems(_ node: NodeInfo) -> [HPMenuItem] {
        var items = [
            HPMenuItem("Open in Telegram") { model.openInTelegram(DeepLink.chat(username: node.username)) },
            HPMenuItem("Copy Link") { model.copyLink(PublicLink.node(username: node.username)) },
        ]
        if !model.isMe(node.username) {
            items.append(HPMenuItem("Block @\(node.username)") { model.modal = .block(username: node.username) })
        }
        return items
    }

    /// Through the model, not the repository: the demo substitutes the whole source (PRODUCT
    /// §2.22.4) and this screen asks the same question either way.
    private func load(force: Bool) async {
        node = model.node(username)
        guard let loaded = await model.loadProfile(username: username, force: force) else {
            if node == nil { failed = true }
            return
        }
        node = loaded.node
        feeds = loaded.feeds
        follows = loaded.follows
    }
}
