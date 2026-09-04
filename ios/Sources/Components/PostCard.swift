// Components — PostCard (PRODUCT.md §2.3, COMPONENTS.md "Composite"). The name is the NODE the post
// reaches you through (the person leads, the channel follows) and the avatar is the SOURCE CHANNEL
// the post came from; time is relative; Share sits right of the time; the footer is counts +
// Comment. Long-press opens the post sheet — the only place Open in Telegram appears on a post.

import SwiftUI

struct PostCard: View {
    @Environment(AppModel.self) private var model
    let post: Post
    /// Set on the Thread screen's own post so text taps do not push the thread again.
    var inThread: Bool = false
    let onOpenFeed: (String) -> Void

    var body: some View {
        HPCard {
            // Rule 6's tiling half: the header does not own all of its own hit targets, so the card
            // holds `PostHeaderBottomGap` clear of tap surfaces under it. See the modifier.
            header.postHeaderBottomBand()

            if !post.text.isEmpty || post.forwardedFrom?.isEmpty == false {
                PostTextBlock(text: post.text,
                              forwardedFrom: post.forwardedFrom,
                              label: inThread ? "Post text" : "Open thread",
                              onOpen: { openThread() },
                              onDetails: { model.modal = .postSheet(post) })
            }

            // Media (PRODUCT §2.11): everything opens or plays inside the app.
            PostMediaList(ownerId: post.id, media: post.media, caption: post.text.plain,
                          post: post,
                          onOpenExternal: { model.openInTelegram(post.deepLink) })

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

    /// PRODUCT §2.3: the avatar is the **source channel** — its photo first, the node's photo
    /// second, the initial last. See `Attribution.avatarPhoto` for why a channel with no photo
    /// arrives as nil rather than as Telegram's generated letter.
    private var headerPhoto: PhotoRef? {
        Attribution.avatarPhoto(sourcePhoto: post.sourcePhoto, nodePhoto: post.authorPhoto)
    }

    private var headerInitial: String {
        let trimmed = headerName.hasPrefix("@") ? String(headerName.dropFirst()) : headerName
        return String(trimmed.prefix(1))
    }

    private var header: some View {
        PostHeader(name: headerName,
                   // Unattributed posts fall back to the channel itself: channel photo + title,
                   // no subheading (PRODUCT §2.3 "Attribution").
                   channel: post.authorUsername == nil ? nil : post.sourceTitle,
                   date: post.date,
                   shareURL: DeepLink.url(post.deepLink),
                   onShareRefused: model.isDemo ? { model.refuseShareInDemo() } : nil,
                   onOpenName: { openHeader() },
                   onOpenChannel: { onOpenFeed(post.sourceUsername) }) {
            NodeAvatar(photo: headerPhoto, size: HPTokens.Space.avatarRow, initial: headerInitial)
        }
    }

    private func openHeader() {
        if let author = post.authorUsername {
            model.path.append(.profile(username: author))
        } else {
            onOpenFeed(post.sourceUsername)
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

/// The post's own text (PRODUCT §2.3): tap → Thread screen, long-press → post sheet. Plain
/// gestures, not a Button: a child Button would claim the touch and the card's long-press could
/// never fire over the dominant press surface. Mirrors Android's combinedClickable on the text
/// (PostCard.kt).
///
/// **Its tap surface stops at its glyphs.** The `rowPad` gap above the text is applied outside the
/// content shape, so the band between the header and the text belongs to the header's hit regions
/// (COMPONENTS.md rule 6: regions tile, they never overlap). With the padding inside the shape this
/// block claimed the band, and — being laid out after the header — took every touch in it: the
/// channel subheading's region, the bottom of the avatar's and the bottom of Share's. A control's
/// region is only worth the space its neighbours leave clear.
///
/// Split out of `PostCard` so `PostHeaderHitRegionTests` can host the real block against the real
/// header without an `AppModel`; a hand-copied stand-in would only prove the copy.
struct PostTextBlock: View {
    let text: RichText
    let forwardedFrom: String?
    /// `Post text` on the Thread screen's own post, `Open thread` everywhere else.
    let label: String
    let onOpen: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HPTokens.Space.rowPad) {
            if let forwardedFrom, !forwardedFrom.isEmpty {
                HPMuted("Forwarded from \(forwardedFrom)")
            }
            if !text.isEmpty {
                RichTextView(text: text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hpTouchRegion(PostCardRegion.text)
        .onTapGesture { onOpen() }
        .onLongPressGesture { onDetails() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(label)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: "Post details") { onDetails() }
        // Outside the shape above, on purpose. See the note in this type's documentation.
        .padding(.top, HPTokens.Space.rowPad)
    }
}

/// The long-press post sheet (PRODUCT §2.3): a House Pour modal with the exact timestamp, views,
/// and the feed — the card's one hand-off, Open in Telegram — and the SAFETY block (§2.15).
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
                model.openInTelegram(post.deepLink)
            }
            .padding(.top, HPTokens.Space.rowPad)
            SafetyBlock(primary: (subject.buttonLabel, true, { model.modal = .report(subject) }),
                        block: blockRow, mute: muteRow)
            HPButton("Close", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    private var subject: ReportSubject { ReportSubject(post: post) }

    /// §2.15: absent when the post is unattributed — there is no node to block — and on my own.
    private var blockRow: (label: String, run: () -> Void)? {
        guard let username = post.authorUsername, !model.isMe(username) else { return nil }
        return ("Block @\(username)", { model.modal = .block(username: username) })
    }

    /// The source channel, named by its title (§2.17). Reads `Unmute` once it is muted, so the row
    /// is the same one tap back.
    private var muteRow: (label: String, run: () -> Void)? {
        let username = post.sourceUsername
        let title = post.sourceTitle
        if model.isMuted(feed: username) {
            return ("Unmute \(title)", { model.modal = nil; model.unmute(feed: username, title: title) })
        }
        return ("Mute \(title)", { model.modal = nil; model.mute(feed: username, title: title) })
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
