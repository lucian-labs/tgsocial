// Components — PostCard (PRODUCT.md §2.3, COMPONENTS.md "Composite"). Tapping the text or the
// comments count opens the Thread screen; tapping media opens it in the app; `Open in Telegram`
// remains the one hand-off.

import SwiftUI

struct PostCard: View {
    @Environment(AppModel.self) private var model
    let post: Post
    /// Set on the Thread screen's own post so text taps do not push the thread again.
    var inThread: Bool = false
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

            // Body text (tap → Thread screen, PRODUCT §2.3).
            if !post.text.isEmpty || post.forwardedFrom?.isEmpty == false {
                Button { openThread() } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        if let from = post.forwardedFrom, !from.isEmpty {
                            HPMuted("Forwarded from \(from)")
                                .padding(.top, HPTokens.Space.rowPad)
                        }
                        if !post.text.isEmpty {
                            RichTextView(text: post.text)
                                .padding(.top, HPTokens.Space.rowPad)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(inThread)
                .accessibilityLabel(inThread ? "Post text" : "Open thread")
            }

            // Media (PRODUCT §2.11): everything opens or plays inside the app.
            PostMediaList(ownerId: post.id, media: post.media, caption: post.text.plain,
                          onOpenExternal: { model.open(post.deepLink) })

            // Footer counts: mono faint; the comments count is tappable (→ Thread). One joined
            // line "1.2k views · 14 reactions · 3 comments" (§2.3) — the interpunct renders
            // between the counts and the comments segment so the join survives the tap target.
            HStack(alignment: .center, spacing: HPTokens.Space.tabsPad) {
                if !countsText.isEmpty {
                    HPMonoSmall(countsText, color: HPTokens.Colors.faint)
                        .lineLimit(1)
                }
                if !countsText.isEmpty, commentCount > 0 {
                    HPMonoSmall("\u{00B7}", color: HPTokens.Colors.faint)
                }
                if commentCount > 0 {
                    Button { openThread() } label: {
                        HPMonoSmall(commentsText, color: HPTokens.Colors.faint)
                            .lineLimit(1)
                            .frame(minHeight: HPTokens.Space.touchMin)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(inThread)
                    .accessibilityLabel("Open thread, \(commentsText)")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, HPTokens.Space.rowGap)

            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                if !inThread {
                    HPButton("Comment", style: .ghost, size: .small) { model.startComment(on: post) }
                }
                Spacer(minLength: HPTokens.Space.rowGap)
                HPButton("Open in Telegram", style: .ghost, size: .small) { model.open(post.deepLink) }
            }
        }
        .opacity(post.isPending ? HPAlpha.disabled : 1)
    }

    private func openThread() {
        guard !inThread else { return }
        model.path.append(.thread(post: post))
    }

    private var commentCount: Int { model.commentCount(for: post) }

    private var commentsText: String {
        "\(commentCount) comment\(commentCount == 1 ? "" : "s")"
    }

    private var countsText: String {
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
