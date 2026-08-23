// Components — NodeRow, FeedRow, EmptyCard (COMPONENTS.md "Composite").

import SwiftUI

struct NodeRow: View {
    @Environment(AppModel.self) private var model
    let node: NodeInfo
    let followedBy: Int?
    let isLast: Bool
    let showFollow: Bool
    let onOpen: () -> Void

    init(node: NodeInfo, followedBy: Int? = nil, isLast: Bool, showFollow: Bool = true, onOpen: @escaping () -> Void) {
        self.node = node; self.followedBy = followedBy; self.isLast = isLast; self.showFollow = showFollow; self.onOpen = onOpen
    }

    var body: some View {
        HPListItem(isLast: isLast) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    NodeAvatar(photo: node.photo, size: HPTokens.Space.avatarRow, initial: node.initial)
                    VStack(alignment: .leading, spacing: 0) {
                        HPBody(node.displayName, strong: true).lineLimit(1)
                        HPMonoSmall("@\(node.username) \u{00B7} \(node.feedCount) feed\(node.feedCount == 1 ? "" : "s")").lineLimit(1)
                        if let n = followedBy, n > 0 {
                            HPSmall("Followed by \(n) of yours")
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(node.displayName)")
        } trailing: {
            if showFollow, !model.isMe(node.username) {
                FollowButton(username: node.username)
            } else {
                Text("\u{203A}").hpStyle(HPType.h2, color: HPTokens.Colors.faint)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct FollowButton: View {
    @Environment(AppModel.self) private var model
    let username: String
    let size: HPButtonSize
    @State private var busy = false

    init(username: String, size: HPButtonSize = .small) { self.username = username; self.size = size }

    var body: some View {
        let following = model.isFollowing(username)
        HPButton(following ? (size == .small ? "Following" : "Unfollow") : "Follow",
                 style: following ? .ghost : (size == .small ? .neutral : .primary),
                 size: size, enabled: !busy) {
            guard !busy else { return }
            busy = true
            Task {
                if following { await model.unfollow(username) } else { await model.follow(username) }
                busy = false
            }
        }
        .animation(HPMotion.color, value: following)
    }
}

struct FeedRow: View {
    let feed: FeedInfo?
    let username: String
    let verified: Bool
    let isLast: Bool
    let onOpen: () -> Void

    var body: some View {
        HPListItem(isLast: isLast) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    VStack(alignment: .leading, spacing: 0) {
                        HPBody(feed?.title ?? username).lineLimit(1)
                        HPMonoSmall("@" + username).lineLimit(1)
                    }
                    if verified { HPPill("Verified", tone: .gold) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open feed \(feed?.title ?? username)")
        } trailing: {
            Text("\u{203A}").hpStyle(HPType.h2, color: HPTokens.Colors.faint)
                .accessibilityHidden(true)
        }
    }
}

struct EmptyCard: View {
    let title: String
    let message: String
    let action: (label: String, run: () -> Void)?

    init(_ title: String, message: String, action: (label: String, run: () -> Void)? = nil) {
        self.title = title; self.message = message; self.action = action
    }

    var body: some View {
        HPCard {
            HPH2(title)
            HPMuted(message).padding(.top, HPTokens.Space.rowGap)
            if let action {
                HPButton(action.label, style: .accent, action: action.run)
                    .padding(.top, HPTokens.Space.cardPad)
            }
        }
    }
}
