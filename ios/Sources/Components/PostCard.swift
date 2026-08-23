// Components — PostCard (PRODUCT.md §2.3, COMPONENTS.md "Composite").

import SwiftUI

struct PostCard: View {
    @Environment(AppModel.self) private var model
    let post: Post
    let onOpenFeed: (String) -> Void

    var body: some View {
        HPCard {
            // Header: avatar, title (→ feed channel), time; username below.
            HStack(alignment: .top, spacing: HPTokens.Space.rowGap) {
                NodeAvatar(photo: post.sourcePhoto, size: HPTokens.Space.avatarRow, initial: String(post.sourceTitle.prefix(1)))
                // Title + username are one 40pt-minimum target (COMPONENTS.md rule 6) that opens the feed channel.
                Button { onOpenFeed(post.sourceUsername) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        HPBody(post.sourceTitle, strong: true)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HPMonoSmall("@" + post.sourceUsername)
                    }
                    .frame(minHeight: HPTokens.Space.touchMin, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(post.sourceTitle)")
                Spacer(minLength: HPTokens.Space.rowGap)
                HPMonoSmall(PostTime.format(unix: post.date), color: HPTokens.Colors.faint)
                    .padding(.top, HPTokens.Space.pillY)
            }

            // Body (tap → post on Telegram)
            Button { model.open(post.deepLink) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    if let from = post.forwardedFrom, !from.isEmpty {
                        HPMuted("Forwarded from \(from)")
                            .padding(.top, HPTokens.Space.rowPad)
                    }
                    if !post.text.isEmpty {
                        RichTextView(text: post.text)
                            .padding(.top, HPTokens.Space.rowPad)
                    }
                    if let media = post.media {
                        PostMediaView(media: media)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open post on Telegram")

            // Footer: counts left, Open in Telegram right.
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                HPMonoSmall(footerText, color: HPTokens.Colors.faint)
                    .lineLimit(1)
                Spacer(minLength: HPTokens.Space.rowGap)
                HPButton("Open in Telegram", style: .ghost, size: .small) { model.open(post.deepLink) }
            }
            .padding(.top, HPTokens.Space.rowGap)
        }
        .opacity(post.isPending ? HPAlpha.disabled : 1)
    }

    private var footerText: String {
        var parts: [String] = []
        if post.isPending { parts.append("Sending") }
        if post.views > 0 { parts.append(CompactCount.format(post.views) + " views") }
        let reacted = post.reactions.filter { $0.count > 0 }
        if !reacted.isEmpty {
            parts.append(reacted.map { "\($0.emoji) \(CompactCount.format($0.count))" }.joined(separator: " "))
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}
