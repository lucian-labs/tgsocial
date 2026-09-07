// Screens — Settings (PRODUCT.md §2.20) and Delete my node (§2.21).
//
// Everything the safety lists (PROTOCOL §7.1) hold, each row with its own undo, plus the contact
// card (§2.19) and the two destructive actions. Sign Out lives here rather than on You so the
// irreversible action can sit directly below the reversible one instead of a mis-tap away from
// `View as others see it`.

import SwiftUI

struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Screen(back: true) {
            HPSectionMark("Safety")
            HPMuted("Blocked and reported content is hidden everywhere in the app. The filter is always on; there is no switch. These lists live on this device only and nobody else can read them.")
                .padding(.bottom, HPTokens.Space.cardGap)

            blocked
            muted
            hidden
            // PRODUCT §2.33: between HIDDEN and CONTACT, present only when there is a private layer.
            if !model.isDemo { PrivateSettingsSection() }
            contact

            // §2.22.3: `Sign Out` is not in the demo at all — there is no session to leave.
            // `( Leave Demo )` is neutral and sits exactly where it sat, above the danger button.
            if model.isDemo {
                HPButton(DemoCopy.leaveButton, style: .neutral) { model.leaveDemo() }
                    .padding(.top, HPTokens.Space.rowGap)
            } else {
                HPButton("Sign Out", style: .danger) { model.modal = .signOut }
                    .padding(.top, HPTokens.Space.rowGap)
            }
            if model.myNode != nil {
                HPButton("Delete My Node", style: .danger) { model.modal = .deleteNode }
                    .padding(.top, HPTokens.Space.rowGap)
            }
        }
    }

    // MARK: Blocked

    @ViewBuilder private var blocked: some View {
        let list = model.moderation.lists.blocked
        HPSectionMark("Blocked", count: list.count)
        if list.isEmpty {
            HPCard { HPMuted("You haven't blocked anyone.") }
        } else {
            HPListCard {
                ForEach(Array(list.enumerated()), id: \.element) { i, username in
                    let node = model.node(username)
                    HPListItem(isLast: i == list.count - 1) {
                        Button { model.path.append(.profile(username: username)) } label: {
                            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                                NodeAvatar(photo: node?.photo, size: HPTokens.Space.avatarRow,
                                           initial: String((node?.displayName ?? username).prefix(1)))
                                VStack(alignment: .leading, spacing: 0) {
                                    HPBody(node?.displayName ?? "@" + username, strong: true).lineLimit(1)
                                    HPMonoSmall("@" + username).lineLimit(1)
                                }
                            }
                            .frame(minHeight: HPTokens.Space.touchMin)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(node?.displayName ?? username)")
                    } trailing: {
                        HPButton("Unblock", style: .ghost, size: .small) { model.unblock(username) }
                    }
                }
            }
        }
    }

    // MARK: Muted

    @ViewBuilder private var muted: some View {
        let list = model.moderation.lists.mutedFeeds
        HPSectionMark("Muted", count: list.count)
        if list.isEmpty {
            HPCard { HPMuted("No muted feeds.") }
        } else {
            HPListCard {
                ForEach(Array(list.enumerated()), id: \.element) { i, key in
                    // PRODUCT §2.32: a private channel shows its title with a `Private` pill in
                    // place of a username; its key is `c/<id>` (PROTOCOL §7.2).
                    let privateId = PrivateLink.supergroupId(fromSourceKey: key)
                    let privateInfo = privateId.flatMap { model.privateChatId(supergroupId: $0) }.flatMap { model.privateChannel(chatId: $0) }
                    let feed = privateId == nil ? model.feedInfo(key) : privateInfo
                    let title = feed?.title ?? (privateId == nil ? "@" + key : "Private channel")
                    HPListItem(isLast: i == list.count - 1) {
                        Button { model.openFeed(sourceKey: key) } label: {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: HPTokens.Space.rowGap) {
                                    HPBody(title).lineLimit(1)
                                    if privateId != nil { HPPill("Private", tone: .neutral) }
                                }
                                if privateId == nil { HPMonoSmall("@" + key).lineLimit(1) }
                            }
                            .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open feed \(title)")
                    } trailing: {
                        HPButton("Unmute", style: .ghost, size: .small) { model.unmute(sourceKey: key, title: title) }
                    }
                }
            }
        }
    }

    // MARK: Hidden

    @ViewBuilder private var hidden: some View {
        let list = model.moderation.lists.hidden
        HPSectionMark("Hidden", count: list.count)
        if list.isEmpty {
            HPCard { HPMuted("Nothing hidden.") }
        } else {
            HPListCard {
                ForEach(Array(list.enumerated()), id: \.element.key) { i, item in
                    HPListItem(isLast: i == list.count - 1) {
                        VStack(alignment: .leading, spacing: 0) {
                            // §2.20: the row names its channel and message id, never the content —
                            // showing a preview of the thing someone reported would undo the report.
                            HPBody(Self.hiddenTitle(item, model: model)).lineLimit(1)
                            HPMonoSmall("\(item.reason) \u{00B7} reported \(Moderation.reportedDate(item.at))")
                                .lineLimit(1)
                        }
                        .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                    } trailing: {
                        HPButton("Unhide", style: .ghost, size: .small) { model.unhide(item) }
                    }
                }
            }
        }
    }

    /// `WaveLoop devlog · 144` — the channel's title where it is known, its username where it is not.
    /// A private post's key is `c/<id>/<n>` (PROTOCOL §7.2); its row reads the channel title with
    /// the key column `c/<id> · <n>` (PRODUCT §2.32), never a username it does not have.
    static func hiddenTitle(_ item: HiddenItem, model: AppModel) -> String {
        if let (sourceKey, n) = Self.privateParts(item.key) {
            let title = PrivateLink.supergroupId(fromSourceKey: sourceKey)
                .flatMap { model.privateChatId(supergroupId: $0) }
                .flatMap { model.privateChannel(chatId: $0)?.title } ?? "Private channel"
            return "\(title) \u{00B7} \(sourceKey) \u{00B7} \(n)"
        }
        let parts = item.key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let channel = String(parts.first ?? "")
        let id = parts.count > 1 ? String(parts[1]) : ""
        let title = model.feedInfo(channel)?.title ?? "@" + channel
        return id.isEmpty ? title : "\(title) \u{00B7} \(id)"
    }

    /// `c/<id>/<n>` → (`c/<id>`, `<n>`); nil for a username key.
    static func privateParts(_ key: String) -> (String, String)? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "c", PrivateLink.supergroupId(fromSourceKey: "c/" + parts[1]) != nil else { return nil }
        return ("c/" + parts[1], String(parts[2]))
    }

    // MARK: Contact (§2.19)

    @ViewBuilder private var contact: some View {
        HPSectionMark("Contact")
        HPCard {
            Button { model.contactByMail() } label: {
                Text(Moderation.contactAddress)
                    .hpStyle(HPType.body, color: HPTokens.Colors.accent)
                    .underline()
                    .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Write to \(Moderation.contactAddress)")
            HPMuted("Reports are read by a person within 24 hours. Content that breaks the rules is reported to Telegram, the only party that can remove it from the network. Your copy is hidden on your device the moment you report it, whether or not anyone else acts.")
                .padding(.top, HPTokens.Space.rowGap)
        }
    }
}

/// Delete my node (PRODUCT §2.21): the type-the-username confirm, the run, and the four ways it can
/// end short of success. A tap-to-confirm would not be proportional — this destroys two public
/// channels and releases their names.
struct DeleteNodeModal: View {
    @Environment(AppModel.self) private var model
    @State private var typed = ""
    @State private var running = false
    @State private var failure: DeleteNodeResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure {
                failureView(failure)
            } else {
                confirm
            }
        }
    }

    private var username: String { model.myNode?.username ?? "" }
    private var repliesUsername: String { model.myCard?.replies ?? model.suggestedRepliesUsername }

    // MARK: The confirm

    /// PRODUCT §2.21's paragraph, grown per §2.33 when a private node exists: the private clause
    /// is derived, and the sentence about members is present only then.
    private var paragraph: String {
        if let clause = model.deleteNodePrivateClause {
            return "This deletes the channel @\(username), your comments channel @\(repliesUsername), \(clause) from Telegram. The public card other people read disappears, every post and comment in those channels goes with it, every member of your private channels loses them at once, and the public names are released for anyone to take. This cannot be undone."
        }
        return "This deletes the channel @\(username) and your comments channel @\(repliesUsername) from Telegram. The public card other people read disappears, every post and comment in those two channels goes with it, and the names are released for anyone to take. This cannot be undone."
    }

    @ViewBuilder private var confirm: some View {
        HPSectionMark("Delete my node")
        HPH2("Delete my node.")
        HPMuted(paragraph)
            .padding(.top, HPTokens.Space.rowGap)
        HPMuted("Your feed channels are not touched.")
            .padding(.top, HPTokens.Space.rowGap)
            .padding(.bottom, HPTokens.Space.cardPad)
        HPTextField("Type @\(username) to confirm", text: $typed, placeholder: "@\(username)", kind: .mono)
        HPButtonRow {
            HPButton(running ? "Deleting\u{2026}" : "Delete My Node", style: .danger,
                     enabled: !running && Moderation.confirmsDelete(typed, username: username)) { run() }
        } b: {
            HPButton("Cancel", style: .ghost, enabled: !running) { model.modal = nil }
        }
    }

    private func run() {
        guard !running else { return }
        running = true
        // §2.21: while the delete runs the modal cannot be dismissed — a scrim tap mid-delete would
        // leave the run with nowhere to report the outcome.
        model.modalLocked = true
        Task {
            let result = await model.deleteMyNode()
            model.modalLocked = false
            running = false
            switch result {
            // Both handled by the model: it wipes local state and toasts, or says `You're offline.`
            case .deleted, .offline: break
            default: failure = result
            }
        }
    }

    // MARK: The ways it ends short

    @ViewBuilder private func failureView(_ result: DeleteNodeResult) -> some View {
        HPSectionMark("Delete my node")
        switch result {
        case .notOwner(let name):
            HPMuted(Self.message(for: result) ?? "")
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButton("Open in Telegram", style: .neutral) {
                model.modal = nil
                model.openInTelegram(DeepLink.chat(username: name))
            }
            HPButton("Close", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        case .commentsFailed, .nodeFailed, .privateFailed, .commentsFailedAfterPrivate, .nodeFailedAfterPrivate:
            retry(Self.message(for: result) ?? "")
        case .deleted, .offline:
            EmptyView()
        }
    }

    /// The sentence each short ending shows (PRODUCT §2.21, §2.33), verbatim. Every one names
    /// what is still there, and only the two that stop before anything went say
    /// `Nothing was deleted.` — once the private channels have gone (PROTOCOL §11.4.12 puts them
    /// first, and `deleteChat` is for every member at once) no later refusal may say it.
    static func message(for result: DeleteNodeResult) -> String? {
        switch result {
        case .notOwner(let name):
            return "Telegram won't let you delete @\(name) \u{2014} only the channel's owner can. Open it in Telegram to see who owns it."
        case .commentsFailed(let name, let error):
            return "Couldn't delete @\(name) \u{2014} Telegram said: \(error). Nothing was deleted."
        case .nodeFailed(let name, let error):
            return "Your comments channel is gone. @\(name) is still there \u{2014} Telegram said: \(error)."
        // PRODUCT §2.33: the four private outcomes, one per point the run can stop at.
        case .privateFailed(let title, let error):
            return "Couldn't delete \(title) \u{2014} Telegram said: \(error). Nothing was deleted."
        case .commentsFailedAfterPrivate(let name, let replies, let error):
            return "Your private channels are gone. @\(replies) and @\(name) are still there \u{2014} Telegram said: \(error)."
        case .nodeFailedAfterPrivate(let name, let commentsWent, let error):
            let gone = commentsWent ? "Your private channels and your comments channel are gone." : "Your private channels are gone."
            return "\(gone) @\(name) is still there \u{2014} Telegram said: \(error)."
        case .deleted, .offline:
            return nil
        }
    }

    @ViewBuilder private func retry(_ message: String) -> some View {
        HPMuted(message)
            .padding(.bottom, HPTokens.Space.cardPad)
        HPButtonRow {
            HPButton(running ? "Deleting\u{2026}" : "Try Again", style: .danger, enabled: !running) {
                failure = nil
                run()
            }
        } b: {
            HPButton("Close", style: .ghost, enabled: !running) { model.modal = nil }
        }
    }
}
