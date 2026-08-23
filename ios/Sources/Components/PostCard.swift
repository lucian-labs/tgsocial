// Components — PostCard (PRODUCT.md §2.3, COMPONENTS.md "Composite"). The header is the NODE the
// post reaches you through (the person leads, the channel follows); time is relative; Share sits
// right of the time; the footer is counts + Comment. Long-press opens the post sheet — the only
// place Open in Telegram appears on a post.

import SwiftUI

struct PostCard: View {
    @Environment(AppModel.self) private var model
    let post: Post
    /// Set on the Thread screen's own post so text taps do not push the thread again.
    var inThread: Bool = false
    let onOpenFeed: (String) -> Void

    var body: some View {
        HPCard {
            header

            // Body text (tap → Thread screen, long-press → post sheet, PRODUCT §2.3). Plain
            // gestures, not a Button: a child Button would claim the touch and the card's
            // long-press could never fire over the dominant press surface. Mirrors Android's
            // combinedClickable on the text (PostCard.kt).
            if !post.text.isEmpty || post.forwardedFrom?.isEmpty == false {
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
                .onTapGesture { openThread() }
                .onLongPressGesture { model.modal = .postSheet(post) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(inThread ? "Post text" : "Open thread")
                .accessibilityAction { openThread() }
                .accessibilityAction(named: "Post details") { model.modal = .postSheet(post) }
            }

            // Media (PRODUCT §2.11): everything opens or plays inside the app.
            PostMediaList(ownerId: post.id, media: post.media, caption: post.text.plain,
                          onOpenExternal: { model.open(post.deepLink) })

            footer
        }
        .opacity(post.isPending ? HPAlpha.disabled : 1)
        // §2.3: long-press opens the post sheet. This container gesture covers the padding and
        // gaps; the body text and comments count carry their own long-press above, and the
        // inline players, scrubbers, and buttons keep receiving their own gestures first.
        .onLongPressGesture { model.modal = .postSheet(post) }
    }

    // MARK: Header — attribution (PRODUCT §2.3): the person leads, the channel follows.

    /// Attributed → the node's name; else the channel title, no subheading.
    private var headerName: String { post.authorName ?? post.sourceTitle }
    private var headerPhoto: PhotoRef? { post.authorUsername == nil ? post.sourcePhoto : post.authorPhoto }
    private var headerInitial: String {
        let trimmed = headerName.hasPrefix("@") ? String(headerName.dropFirst()) : headerName
        return String(trimmed.prefix(1))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                // Avatar + name are one 40pt-minimum target (COMPONENTS.md rule 6): the node's
                // profile when attributed, the feed channel otherwise.
                Button { openHeader() } label: {
                    HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                        NodeAvatar(photo: headerPhoto, size: HPTokens.Space.avatarRow, initial: headerInitial)
                        HPBody(headerName, strong: true)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(minHeight: HPTokens.Space.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(headerName)")
                Spacer(minLength: HPTokens.Space.rowGap)
                // Relative time, mono faint, refreshed each minute while visible.
                TimelineView(.everyMinute) { context in
                    HPMonoSmall(PostTime.relative(unix: post.date, now: context.date), color: HPTokens.Colors.faint)
                }
                shareButton
            }
            // Subheading: the channel, mono small muted, tap → feed channel screen (§2.6).
            if post.authorUsername != nil {
                Button { onOpenFeed(post.sourceUsername) } label: {
                    HPMonoSmall(post.sourceTitle)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        // COMPONENTS.md rule 6: 40pt minimum hit target. The header stays
                        // compact, so grow the tappable area with a clear overlay instead
                        // of inflating the layout.
                        .overlay {
                            Color.clear
                                .frame(height: HPTokens.Space.touchMin)
                                .contentShape(Rectangle())
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(post.sourceTitle)")
                .padding(.leading, HPTokens.Space.avatarRow + HPTokens.Space.rowGap)
            }
        }
    }

    private func openHeader() {
        if let author = post.authorUsername {
            model.path.append(.profile(username: author))
        } else {
            onOpenFeed(post.sourceUsername)
        }
    }

    /// Share — ghost small button right of the time (§2.3): the system share sheet with the
    /// post's t.me link.
    @ViewBuilder private var shareButton: some View {
        if let url = DeepLink.url(post.deepLink) {
            ShareLink(item: url) {
                Text("Share")
                    .hpStyle(HPType.buttonSm, color: HPTokens.Colors.muted)
                    .lineLimit(1)
                    .padding(.vertical, HPTokens.Space.buttonSmY)
                    .padding(.horizontal, HPTokens.Space.buttonSmX)
                    .frame(minHeight: HPTokens.Space.touchMin)
                    .contentShape(Capsule())
            }
            .buttonStyle(HPPressStyle())
            .accessibilityLabel("Share")
        }
    }

    // MARK: Footer — `N reactions · N comments` left, ( Comment ) ghost sm right (§2.3).
    // Views and Open in Telegram live in the long-press sheet now, not on the card face.

    private var footer: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.tabsPad) {
            if !leadingCountsText.isEmpty {
                HPMonoSmall(leadingCountsText, color: HPTokens.Colors.faint)
                    .lineLimit(1)
                HPMonoSmall("\u{00B7}", color: HPTokens.Colors.faint)
            }
            // Same dual wiring as the body text: tap → thread, long-press → post sheet,
            // so a long-press over the counts still reaches the sheet (§2.3).
            HPMonoSmall(commentsText, color: HPTokens.Colors.faint)
                .lineLimit(1)
                .frame(minHeight: HPTokens.Space.touchMin)
                .contentShape(Rectangle())
                .onTapGesture { openThread() }
                .onLongPressGesture { model.modal = .postSheet(post) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open thread, \(commentsText)")
                .accessibilityAction { openThread() }
                .accessibilityAction(named: "Post details") { model.modal = .postSheet(post) }
            Spacer(minLength: HPTokens.Space.rowGap)
            if !inThread {
                HPButton("Comment", style: .ghost, size: .small) { model.startComment(on: post) }
            }
        }
        .padding(.top, HPTokens.Space.rowGap)
    }

    private func openThread() {
        guard !inThread else { return }
        model.path.append(.thread(post: post))
    }

    private var commentCount: Int { model.commentCount(for: post) }

    private var commentsText: String {
        "\(commentCount) comment\(commentCount == 1 ? "" : "s")"
    }

    /// Pending tag + reactions: the reaction emoji + count when few, the summed count otherwise.
    private var leadingCountsText: String {
        var parts: [String] = []
        if post.isPending { parts.append("Sending") }
        let reacted = post.reactions.filter { $0.count > 0 }
        if !reacted.isEmpty {
            if reacted.count <= Self.fewReactions {
                parts.append(reacted.map { "\($0.emoji) \(CompactCount.format($0.count))" }.joined(separator: " "))
            } else {
                let total = reacted.reduce(0) { $0 + $1.count }
                parts.append("\(CompactCount.format(total)) reaction\(total == 1 ? "" : "s")")
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Up to this many distinct reactions render as emoji + count; more collapse to the sum.
    static let fewReactions = 3
}

/// The long-press post sheet (PRODUCT §2.3): a House Pour modal with the exact timestamp, views,
/// and the feed — and the card's one hand-off, Open in Telegram.
struct PostSheetModal: View {
    @Environment(AppModel.self) private var model
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Post")
            row("Posted", PostTime.exact(unix: post.date))
            row("Views", CompactCount.format(post.views))
            row("Feed", "\(post.sourceTitle) \u{00B7} @\(post.sourceUsername)", isLast: true)
            HPButton("Open in Telegram", style: .neutral) {
                model.modal = nil
                model.open(post.deepLink)
            }
            .padding(.top, HPTokens.Space.rowPad)
            HPButton("Close", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    private func row(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        HPListItem(isLast: isLast) {
            HPBody(label)
        } trailing: {
            HPMono(value, small: true)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("\(label): \(value)")
        }
    }
}
