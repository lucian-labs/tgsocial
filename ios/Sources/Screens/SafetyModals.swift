// Screens — the safety modals (PRODUCT.md §2.15, §2.16) and the comment sheet (§2.12).
//
// The SAFETY block is shared by the post sheet and the comment sheet, because the two carry the
// same rows in the same words — the only differences are the ones the spec names: a comment reads
// `Report Comment`, never carries `Mute` (mute is about a channel's posts and a comment is not
// one), and on your own comment the report row becomes `Delete`.

import SwiftUI

/// The `SAFETY` block (PRODUCT §2.15). `mute` is nil on a comment sheet; `block` is nil when there
/// is no attributed node to block, and when the node is mine.
struct SafetyBlock: View {
    /// `Report Post` / `Report Comment` — or `Delete` on my own comment.
    let primary: (label: String, danger: Bool, run: () -> Void)
    let block: (label: String, run: () -> Void)?
    let mute: (label: String, run: () -> Void)?

    var body: some View {
        HPSectionMark("Safety")
            .padding(.top, HPTokens.Space.cardPad)
        VStack(alignment: .leading, spacing: HPTokens.Space.rowGap) {
            HPButton(primary.label, style: primary.danger ? .danger : .neutral, size: .small, action: primary.run)
            if let block {
                HPButton(block.label, style: .ghost, size: .small, action: block.run)
            }
            if let mute {
                HPButton(mute.label, style: .ghost, size: .small, action: mute.run)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The comment sheet (PRODUCT §2.12): long-press a comment anywhere it renders. Same modal as the
/// post sheet with the comment's own rows.
struct CommentSheetModal: View {
    @Environment(AppModel.self) private var model
    let comment: Comment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Comment")
            row("Posted", PostTime.exact(unix: comment.date))
            row("From", "@" + comment.ownerUsername)
            row("Channel", "@" + comment.channelUsername, isLast: true)
            HPButton("Open in Telegram", style: .neutral) {
                model.modal = nil
                model.openInTelegram(comment.link)
            }
            .padding(.top, HPTokens.Space.rowPad)
            SafetyBlock(primary: primary, block: blockRow, mute: nil)
            HPButton("Close", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// §2.15: "On your own comment the sheet reads `Delete` in place of `Report Comment`."
    private var primary: (label: String, danger: Bool, run: () -> Void) {
        if comment.isMine {
            return ("Delete", true, { model.modal = .deleteComment(comment) })
        }
        let subject = ReportSubject(comment: comment)
        return (subject.buttonLabel, true, { model.modal = .report(subject) })
    }

    private var blockRow: (label: String, run: () -> Void)? {
        guard !model.isMe(comment.ownerUsername) else { return nil }
        let username = comment.ownerUsername
        return ("Block @\(username)", { model.modal = .block(username: username) })
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

/// The report confirm (PRODUCT §2.15): what the email says, the seven reasons, and the send that
/// hides the content whether or not the mail ever leaves.
struct ReportModal: View {
    @Environment(AppModel.self) private var model
    let subject: ReportSubject

    var body: some View {
        ReportConfirm(subject: subject,
                      onSend: { reason in model.sendReport(subject, reason: reason) },
                      onCancel: { model.modal = nil },
                      onOpenBluesky: subject.isBluesky ? { model.open(subject.link) } : nil)
    }
}

/// The confirm's own layout, taking values and closures rather than the app model — the same shape
/// `PostHeader` takes, and for the same reason: this is the tallest thing the app puts in an
/// `HPModal` (taller than an iPhone SE at default Dynamic Type), so whether `Send Report` and
/// `Cancel` are reachable is a question about *this view's* height, and it is answered by measuring
/// it. A view that can only be built around a live TDLib session cannot be measured.
struct ReportConfirm: View {
    let subject: ReportSubject
    let onSend: (String) -> Void
    let onCancel: () -> Void
    /// Set for a Bluesky post: opens it on Bluesky (§2.40 `Report on Bluesky`).
    var onOpenBluesky: (() -> Void)? = nil
    @State private var reason: String?

    /// PRODUCT §2.15: the consequence, one sentence, the same on every subject. A private post's
    /// "the maintainer can't open it" (§2.32) and a Bluesky post's "nobody here can remove it"
    /// (§2.40) are reasons, not consequences, so they live in the spec (§3); on a Bluesky post the
    /// `Report on Bluesky` button is the whole of the difference on screen.
    static let paragraph = "It's hidden here and emailed to \(Moderation.contactAddress)."

    static func paragraph(for subject: ReportSubject) -> String { paragraph }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Report")
            HPH2(subject.title)
            HPMuted(Self.paragraph(for: subject))
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPSectionMark("Why")
            HPListCard {
                ForEach(Array(Moderation.reasons.enumerated()), id: \.element) { i, option in
                    reasonRow(option, isLast: i == Moderation.reasons.count - 1)
                }
            }
            if subject.isBluesky, let open = onOpenBluesky {
                // §2.40: Bluesky's own report lives on the post, one tap away.
                HPButton("Report on Bluesky", style: .ghost, size: .small, action: open)
                    .padding(.top, HPTokens.Space.rowGap)
            }
            HPButton("Send Report", style: .danger, enabled: reason != nil) {
                guard let reason else { return }
                onSend(reason)
            }
            .padding(.top, HPTokens.Space.rowPad)
            HPButton("Cancel", style: .ghost, action: onCancel)
                .padding(.top, HPTokens.Space.rowGap)
        }
    }

    /// Single-select, 40pt, the picked row carrying a gold check. The hit target is the row, so the
    /// tap area is the card's full width rather than the label's.
    private func reasonRow(_ option: String, isLast: Bool) -> some View {
        Button { reason = option } label: {
            HPListItem(isLast: isLast) {
                HPBody(option)
            } trailing: {
                if reason == option {
                    Text("\u{2713}").hpStyle(HPType.h2, color: HPTokens.Colors.accent)
                }
            }
            .frame(minHeight: HPTokens.Space.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(HPPressStyle())
        .accessibilityLabel(option)
        .accessibilityAddTraits(reason == option ? [.isButton, .isSelected] : .isButton)
    }
}

/// The block confirm (PRODUCT §2.16): its consequence in one sentence (§3).
struct BlockModal: View {
    @Environment(AppModel.self) private var model
    let username: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Block")
            HPH2("Block @\(username)?")
            HPMuted("Their posts and comments disappear here, and they aren't told.")
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Block", style: .danger) { model.block(username) }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}
