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
            if let node {
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
                                FeedRow(feed: info, username: feedName,
                                        verified: info?.isVerified(for: node.username) ?? false,
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

    @ViewBuilder private func header(_ node: NodeInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NodeAvatar(photo: node.photo, size: HPTokens.Space.avatarProfile, initial: node.initial)
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

    private func load(force: Bool) async {
        node = model.nodes.cachedNode(username)
        do {
            let info = try await model.perform { try await model.nodes.readNode(username: username, force: force) }
            node = info
            if let card = info.card {
                async let f = model.nodes.readFeeds(card.feeds)
                async let n = model.nodes.readNodes(card.follows)
                feeds = (try? await f) ?? []
                follows = (try? await n) ?? []
            }
        } catch {
            if node == nil { failed = true }
        }
    }
}
