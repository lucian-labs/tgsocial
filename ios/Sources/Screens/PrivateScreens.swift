// Screens — the private layer (PRODUCT.md §2.27–§2.34, PROTOCOL.md §11).
//
// One section on You, two pushed screens, one channel screen, and the modals. Every string here
// is PRODUCT §2.27–§2.34 verbatim; the two paragraphs that matter most — WHAT PRIVATE MEANS HERE
// and the invite sheet's bearer-token warning — appear every time, with no "got it", because a
// client that trims them has promised something Telegram membership does not do.

import CoreImage.CIFilterBuiltins
import SwiftUI
import TDLibKit

/// Sizes the kit has no token for yet, derived from the ones it has: the invite preview's avatar
/// (§2.31: "avatar 48pt") sits between the row and profile sizes, and a QR square fills half the
/// column so a phone across a table can read it.
enum PrivateMetric {
    static let previewAvatar: CGFloat = (HPTokens.Space.avatarRow + HPTokens.Space.avatarProfile) / 2 - 6
    static let qrSide: CGFloat = HPTokens.Space.columnMax / 2
}

// MARK: - You → PRIVATE (§2.27, §2.28)

/// The section You carries between `LISTING` and `View as others see it`. Absent in the demo
/// (§2.34) and when there is no public node (§2.27) — the caller decides both.
struct PrivateSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HPSectionMark("Private")
        if let node = model.privateRecord.privateNode {
            HPCard {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    HPBody(model.privateNodeTitle).lineLimit(1)
                    Spacer(minLength: HPTokens.Space.rowGap)
                    HPMonoSmall(Self.members(model.privateMemberCounts[node.chatId] ?? 0))
                }
                let requests = model.totalPendingRequests
                if requests > 0 {
                    Button { model.path.append(.privateRequests) } label: {
                        HPMono(Self.requests(requests), color: HPTokens.Colors.accent)
                            .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open requests, \(Self.requests(requests))")
                }
                HPButton("Open", style: .neutral, size: .small) { model.path.append(.privateNode) }
                    .padding(.top, HPTokens.Space.rowGap)
            }
        } else {
            HPCard {
                HPMuted("Nothing private yet.")
                HPButton("Make a Private Node", style: .neutral, size: .small) { model.modal = .makePrivateNode }
                    .padding(.top, HPTokens.Space.rowGap)
            }
        }
    }

    static func members(_ n: Int) -> String { "\(n) member\(n == 1 ? "" : "s")" }
    static func requests(_ n: Int) -> String { "\(n) request\(n == 1 ? "" : "s")" }
}

/// §2.27: the confirm, which is the only place the promise is spelled out in full — and it is
/// spelled out every time. Not skippable; no "don't show again".
struct MakePrivateNodeModal: View {
    @Environment(AppModel.self) private var model
    @State private var making = false

    static let promise = "A second channel of yours with no public name. Nobody can find it. People get in only when you approve them, one at a time, and only they can read it."
    static let meaning = "Telegram checks who is a member, and that is the whole of it. Telegram can read what you post. Anyone you let in can screenshot or forward it. A new member sees everything you ever posted there."
    static let cost = "Your public card will note that a private node exists \u{2014} not how to reach it. Turn that off in Settings."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Private node")
            HPH2("Make your private node.")
            HPMuted(Self.promise)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            // The honest part, and it stays: trimmed to the first paragraph this modal promises
            // end-to-end encryption by omission (§2.27).
            HPSectionMark("What private means here")
            HPMuted(Self.meaning)
                .padding(.bottom, HPTokens.Space.cardPad)
            // PROTOCOL §11.3's cost, stated before it is paid.
            HPSmall(Self.cost, color: HPTokens.Colors.faint)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton(making ? "Making your private node" : "Make It", style: .primary, enabled: !making) {
                    guard !making else { return }
                    making = true
                    Task {
                        _ = await model.makePrivateNode()
                        making = false
                    }
                }
            } b: {
                HPButton("Cancel", style: .ghost, enabled: !making) { model.modal = nil }
            }
        }
    }
}

// MARK: - The Private screen (§2.28)

struct PrivateScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Screen(back: true, refresh: { await model.refreshPrivate(); await reloadMembers() }) {
            if let node = model.privateRecord.privateNode, let me = model.myNode {
                header(node, me: me)
                HPButton("Share Invite", style: .primary) { model.modal = .privateInvite(chatId: node.chatId, title: model.privateNodeTitle) }
                HPButton(requestsLabel, style: .neutral) { model.path.append(.privateRequests) }
                    .padding(.top, HPTokens.Space.rowGap)
                    .padding(.bottom, HPTokens.Space.cardGap)

                feeds(node)
                members(node)
            } else {
                HPCard { HPMuted("Nothing private yet.") }
            }
        }
        .task { await reloadMembers() }
    }

    private var requestsLabel: String {
        let n = model.totalPendingRequests
        return n > 0 ? "Requests \u{00B7} \(n)" : "Requests"
    }

    private func reloadMembers() async {
        for chat in model.ownedPrivateChats { await model.loadMembers(chatId: chat.chatId) }
    }

    @ViewBuilder private func header(_ node: PrivateNodeRef, me: MyNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: HPTokens.Space.rowGap) {
                NodeAvatar(photo: model.privateChannel(chatId: node.chatId)?.photo ?? model.myPhoto,
                           size: HPTokens.Space.avatarProfile, initial: String(model.privateNodeTitle.prefix(1)))
                Spacer(minLength: HPTokens.Space.rowGap)
                // §2.28: no `Copy Link` — the only link this channel has is the invite, and the
                // invite has its own button with its own warning.
                HPMenu(items: [
                    HPMenuItem("Open in Telegram") { model.openInTelegram(PrivateLink.chat(supergroupId: node.supergroupId)) },
                    HPMenuItem("Revoke Invite") { model.modal = .revokeInvite(chatId: node.chatId, title: model.privateNodeTitle) },
                ])
            }
            HPH2(model.privateNodeTitle).padding(.top, HPTokens.Space.rowPad)
            HPMono("private node of @" + me.username)
            let members = PrivateSection.members(model.privateMemberCounts[node.chatId] ?? 0)
            let requests = model.totalPendingRequests
            HStack(spacing: 0) {
                HPMonoSmall(members, color: HPTokens.Colors.faint)
                if requests > 0 {
                    HPMonoSmall(" \u{00B7} ", color: HPTokens.Colors.faint)
                    HPMonoSmall(PrivateSection.requests(requests), color: HPTokens.Colors.accent)
                }
            }
        }
        .padding(.bottom, HPTokens.Space.cardGap)
    }

    @ViewBuilder private func feeds(_ node: PrivateNodeRef) -> some View {
        HPSectionMark("Private feeds")
        let extra = model.privateRecord.privateFeeds
        HPListCard {
            // The node itself, always first, not removable (§2.28).
            privateFeedRow(chatId: node.chatId, title: model.privateNodeTitle, isLast: extra.isEmpty)
            ForEach(Array(extra.enumerated()), id: \.element.id) { i, feed in
                privateFeedRow(chatId: feed.chatId, title: model.privateChannelInfo[feed.chatId]?.title ?? feed.title,
                               isLast: i == extra.count - 1)
            }
        }
        HPButton("Add a Private Feed", style: .ghost, size: .small) { model.modal = .addPrivateFeed }
            .padding(.bottom, HPTokens.Space.cardGap)
    }

    private func privateFeedRow(chatId: Int64, title: String, isLast: Bool) -> some View {
        HPListItem(isLast: isLast) {
            Button { model.path.append(.privateChannel(chatId: chatId)) } label: {
                HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                    HPBody(title).lineLimit(1)
                    Spacer(minLength: HPTokens.Space.rowGap)
                    HPMonoSmall(PrivateSection.members(model.privateMemberCounts[chatId] ?? 0))
                }
                .frame(minHeight: HPTokens.Space.touchMin)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(title)")
        } trailing: {
            Text("\u{203A}").hpStyle(HPType.h2, color: HPTokens.Colors.faint).accessibilityHidden(true)
        }
    }

    @ViewBuilder private func members(_ node: PrivateNodeRef) -> some View {
        let list = model.privateMembers[node.chatId] ?? []
        HPSectionMark("Members", count: list.count)
        if list.isEmpty {
            HPMuted("Nobody yet. Share the invite.")
        } else {
            HPListCard {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, member in
                    HPListItem(isLast: i == list.count - 1) {
                        MemberRow(name: member.name, username: member.username, photo: member.photo,
                                  subline: "since " + String(PostTime.exact(unix: member.joinedDate).prefix(10)))
                    } trailing: {
                        HPButton("Remove", style: .ghost, size: .small) { model.modal = .removeMember(member, chatId: node.chatId) }
                    }
                }
            }
        }
    }
}

/// A Telegram account as a row (§2.28, §2.30): name, `@handle`, and a mono subline. The app
/// does not guess a node here — that is what Telegram knows.
struct MemberRow: View {
    let name: String
    let username: String?
    let photo: PhotoRef?
    let subline: String

    var body: some View {
        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
            NodeAvatar(photo: photo, size: HPTokens.Space.avatarRow, initial: String(name.prefix(1)))
            VStack(alignment: .leading, spacing: 0) {
                HPBody(name).lineLimit(1)
                HPMonoSmall((username.map { "@" + $0 + " \u{00B7} " } ?? "") + subline).lineLimit(1)
            }
        }
        .frame(minHeight: HPTokens.Space.touchMin)
    }
}

/// §2.28: `Remove Ana Iliovic?` — what removal does, and what it does not undo.
struct RemoveMemberModal: View {
    @Environment(AppModel.self) private var model
    let member: PrivateMember
    let chatId: Int64
    @State private var alsoFeeds = false

    static let body = "They lose access to this channel now. They keep any screenshots or forwards they made, and Telegram keeps its own copies. They can't ask to join again unless you let them back in from Telegram."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Remove")
            HPH2("Remove \(member.name)?")
            HPMuted(Self.body)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            if !model.privateFeedsContaining(userId: member.userId).isEmpty, model.privateRecord.privateNode?.chatId == chatId {
                CheckboxRow(label: "Also remove from your private feeds", isOn: $alsoFeeds)
                    .padding(.bottom, HPTokens.Space.cardPad)
            }
            HPButtonRow {
                HPButton("Remove", style: .danger) { Task { await model.removeMember(member, chatId: chatId, alsoFeeds: alsoFeeds) } }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}

/// A 40pt checkbox row (COMPONENTS rule 6): the label is the target.
struct CheckboxRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                Text(isOn ? "\u{2611}" : "\u{2610}")
                    .hpStyle(HPType.h2, color: isOn ? HPTokens.Colors.accent : HPTokens.Colors.faint)
                HPBody(label)
                Spacer(minLength: 0)
            }
            .frame(minHeight: HPTokens.Space.touchMin)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// §2.28: `Add a private feed.`
struct AddPrivateFeedModal: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var adding = false

    static let body = "A separate private channel with its own members. Being in your private node doesn't get anyone in here \u{2014} you approve each person again."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Private feed")
            HPH2("Add a private feed.")
            HPMuted(Self.body)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPTextField("Feed name", text: $title, placeholder: "", kind: .text)
            HPButtonRow {
                HPButton("Add It", style: .primary, enabled: !adding && !title.trimmingCharacters(in: .whitespaces).isEmpty) {
                    guard !adding else { return }
                    adding = true
                    Task {
                        _ = await model.addPrivateFeed(title: title)
                        adding = false
                    }
                }
            } b: {
                HPButton("Cancel", style: .ghost, enabled: !adding) { model.modal = nil }
            }
        }
    }
}

// MARK: - The invite sheet (§2.29, PROTOCOL §11.7)

struct PrivateInviteModal: View {
    @Environment(AppModel.self) private var model
    let chatId: Int64
    let title: String
    @State private var link: String?
    @State private var showQR = false

    /// PROTOCOL §11.7, every time the sheet opens. The last sentence is §11.4.1's primary-link
    /// hole: the link Telegram's own channel screen offers first joins without approval.
    static let warning = "Anyone with this link can ask to join. Anyone they pass it to can ask too. Nobody gets in until you approve them, so a link that travels costs you a request, not a member. Share it only from here."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Invite")
            HPH2("Invite someone to \(title).")
            if let link {
                if showQR, let image = Self.qr(link) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: PrivateMetric.qrSide, maxHeight: PrivateMetric.qrSide)
                        .padding(.vertical, HPTokens.Space.rowPad)
                        .accessibilityLabel("QR code of the invite link")
                } else {
                    HPMono(link, small: true, color: HPTokens.Colors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.vertical, HPTokens.Space.rowPad)
                }
            } else {
                HPMuted("Loading\u{2026}").padding(.vertical, HPTokens.Space.rowPad)
            }
            HPMuted(Self.warning)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButton("Copy Invite", style: .primary, enabled: link != nil) {
                if let link { model.copyInvite(link) }
            }
            if let link, let url = URL(string: link) {
                // Native share sheet, opened only by this tap — never by the app on its own (§11.7).
                ShareLink(item: url) {
                    Text("Share\u{2026}")
                        .hpStyle(HPType.button, color: HPTokens.Colors.ink)
                        .padding(.vertical, HPTokens.Space.buttonY)
                        .padding(.horizontal, HPTokens.Space.buttonX)
                        .frame(maxWidth: .infinity)
                        .overlay(Capsule(style: .continuous).strokeBorder(HPTokens.Colors.line2, lineWidth: HPTokens.borderWidth))
                        .frame(minHeight: HPTokens.Space.touchMin)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HPPressStyle())
                .accessibilityLabel("Share")
                .padding(.top, HPTokens.Space.rowGap)
            }
            HPButton(showQR ? "Show as Link" : "Show as QR", style: .ghost, size: .small, enabled: link != nil) { showQR.toggle() }
                .padding(.top, HPTokens.Space.rowGap)
            HPButton("Close", style: .ghost) { model.modal = nil }
                .padding(.top, HPTokens.Space.rowGap)
        }
        .task(id: chatId) { link = await model.inviteLink(forChat: chatId) }
    }

    static func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// §2.29: `Revoke this invite?`
struct RevokeInviteModal: View {
    @Environment(AppModel.self) private var model
    let chatId: Int64
    let title: String
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Revoke")
            HPH2("Revoke this invite?")
            HPMuted("The old link stops working and you get a new one. Everyone already in stays in.")
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Revoke", style: .danger, enabled: !running) {
                    running = true
                    Task { await model.revokeInvite(chatId: chatId, title: title); running = false }
                }
            } b: {
                HPButton("Cancel", style: .ghost, enabled: !running) { model.modal = nil }
            }
        }
    }
}

// MARK: - Requests (§2.30)

struct RequestsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Screen(back: true, refresh: { await model.loadRequests() }) {
            let list = model.joinRequests
            HPSectionMark("Requests", count: list.count)
            if list.isEmpty {
                HPMuted(model.requestsLoading ? "Loading\u{2026}" : "No requests.")
            } else {
                HPListCard {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, request in
                        row(request, isLast: i == list.count - 1)
                    }
                }
            }
        }
        // §2.30: the list refreshes live from `updateChatPendingJoinRequests` while it is open.
        .onAppear { model.requestsSurfaceAppeared() }
        .onDisappear { model.requestsSurfaceDisappeared() }
    }

    private func row(_ r: JoinRequest, isLast: Bool) -> some View {
        HPListItem(isLast: isLast) {
            VStack(alignment: .leading, spacing: 0) {
                MemberRow(name: r.name, username: r.username, photo: r.photo,
                          subline: PostTime.relative(unix: r.date, now: Date()))
                if !r.bio.isEmpty { HPMuted(r.bio).lineLimit(2) }
                // §11.4.5: labelled a guess, and the only tgsocial fact on the row. Nothing else
                // is inferred from it — no "follows you", no mutual count.
                if let guess = r.guessedNode {
                    Button { model.path.append(.profile(username: guess)) } label: {
                        HPMonoSmall("Maybe @\(guess) \u{203A}", color: HPTokens.Colors.faint)
                            .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Maybe @\(guess). Opens the profile.")
                }
                if model.ownedPrivateChats.count > 1 {
                    HPMonoSmall(r.chatTitle, color: HPTokens.Colors.faint).lineLimit(1)
                }
                HStack(spacing: HPTokens.Space.btnRowGap) {
                    HPButton("Approve", style: .primary, size: .small) { Task { await model.decideRequest(r, approve: true) } }
                    HPButton("Decline", style: .ghost, size: .small) { Task { await model.decideRequest(r, approve: false) } }
                }
                .padding(.top, HPTokens.Space.rowGap)
            }
        }
    }
}

// MARK: - Asking to join (§2.31)

/// The preview — `checkChatInviteLink`'s title, photo and member count, and nothing more,
/// because that is all Telegram shows a non-member.
struct InvitePreviewModal: View {
    @Environment(AppModel.self) private var model
    let preview: InvitePreview
    @State private var asking = false

    static let body = "Ask to join this private channel. The owner approves each person, and you'll see it here if they do."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Invite")
            HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                NodeAvatar(photo: preview.photo, size: PrivateMetric.previewAvatar, initial: String(preview.title.prefix(1)))
                VStack(alignment: .leading, spacing: 0) {
                    HPBody(preview.title, strong: true).lineLimit(1)
                    HPMonoSmall(PrivateSection.members(preview.memberCount))
                }
            }
            HPMuted(Self.body)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            HPButtonRow {
                HPButton("Ask to Join", style: .primary, enabled: !asking) {
                    asking = true
                    Task { await model.askToJoin(preview); asking = false }
                }
            } b: {
                HPButton("Cancel", style: .ghost, enabled: !asking) { model.modal = nil }
            }
        }
    }
}

/// Explore's `WAITING` section (§2.31): the requests I have out, and the line that says what
/// Telegram does not tell a declined requester. Absent when the list is empty.
struct WaitingSection: View {
    @Environment(AppModel.self) private var model

    static let line = "If they decline, nothing arrives. Ask again if you think they missed it."

    var body: some View {
        let pending = model.privateRecord.pending
        if !pending.isEmpty {
            HPSectionMark("Waiting")
            HPListCard {
                ForEach(Array(pending.enumerated()), id: \.element.id) { i, entry in
                    HPListItem(isLast: i == pending.count - 1) {
                        HStack(alignment: .center, spacing: HPTokens.Space.rowGap) {
                            NodeAvatar(photo: entry.photo, size: HPTokens.Space.avatarRow, initial: String(entry.title.prefix(1)))
                            VStack(alignment: .leading, spacing: 0) {
                                HPBody(entry.title).lineLimit(1)
                                HPMonoSmall("asked " + Self.asked(entry.askedAt)).lineLimit(1)
                            }
                        }
                        .frame(minHeight: HPTokens.Space.touchMin)
                    } trailing: {
                        HStack(spacing: HPTokens.Space.btnRowGap) {
                            HPButton("Ask Again", style: .ghost, size: .small) { Task { await model.askAgain(entry) } }
                            // §2.31: forgets it locally and nothing else — there is no call to withdraw.
                            HPButton("Forget", style: .ghost, size: .small) { model.forgetPending(entry) }
                        }
                    }
                }
            }
            HPMuted(Self.line)
                .padding(.bottom, HPTokens.Space.cardGap)
        }
    }

    static func asked(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: iso) else { return iso }
        return RelativeTime.format(date)
    }
}

// MARK: - The private channel screen (§2.28 feed variant, §2.31 "Their card")

struct PrivateChannelScreen: View {
    @Environment(AppModel.self) private var model
    let chatId: Int64
    @State private var feed: FeedInfo?
    @State private var posts: [Post] = []
    @State private var cursor: Int64 = 0
    @State private var exhausted = false
    @State private var loading = false
    @State private var failed = false
    @State private var observerId = UUID()

    static let unverifiedLine = "Nothing confirms that. Posts here are shown as this channel, not as that person."

    private var isMine: Bool { model.ownsPrivateChat(chatId) }
    private var follow: PrivateFollow? { model.privateOwner(chatId: chatId) }
    private var isNode: Bool { follow?.chatId == chatId || model.privateRecord.privateNode?.chatId == chatId }

    var body: some View {
        Screen(back: true, refresh: { await load(reset: true) }) {
            if let feed {
                header(feed)
                // §2.18: blocked and reported posts drop out here too; mute does not apply.
                let visible = model.visible(posts: posts)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { post in
                        PostCard(post: post) { _ in }
                            .onAppear {
                                if let i = visible.firstIndex(where: { $0.id == post.id }), i >= visible.count - FeedScreen.prefetchDistance {
                                    Task { await load(reset: false) }
                                }
                            }
                    }
                    if exhausted {
                        FeedFooter(text: visible.isEmpty ? "No posts yet." : "That's everything.")
                    } else {
                        FeedFooter(text: "Loading\u{2026}").onAppear { Task { await load(reset: false) } }
                    }
                }
            } else if failed {
                HPCard { HPMuted("Channel not found.") }
            } else {
                FeedFooter(text: "Loading\u{2026}")
            }
        }
        .task(id: chatId) {
            feed = model.privateChannel(chatId: chatId)
            model.observeMessages(observerId) { apply(live: $0) }
            await load(reset: true)
        }
        .onDisappear { model.stopObservingMessages(observerId) }
    }

    @ViewBuilder private func header(_ feed: FeedInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: HPTokens.Space.rowGap) {
                NodeAvatar(photo: feed.photo, size: HPTokens.Space.avatarProfile, initial: String(feed.title.prefix(1)))
                Spacer(minLength: HPTokens.Space.rowGap)
                HStack(spacing: HPTokens.Space.rowGap) {
                    // §2.31: `Verified` here means exactly PROTOCOL §11.3's check; `Unconfirmed`
                    // is its absence, said aloud. A feed of a follow carries neither of its own —
                    // the card is verified as a whole (§11.5).
                    if let follow, follow.chatId == chatId {
                        HPPill(follow.verified ? "Verified" : "Unconfirmed", tone: follow.verified ? .gold : .neutral)
                    } else {
                        HPPill("Private", tone: .neutral)
                    }
                    HPMenu(items: kebab(feed))
                }
            }
            HPH2(feed.title).padding(.top, HPTokens.Space.rowPad)
            if isMine, let me = model.myNode {
                HPMono(isNode ? "private node of @\(me.username)" : "private \u{00B7} " + PrivateSection.members(model.privateMemberCounts[chatId] ?? 0))
            } else if let follow, follow.chatId == chatId {
                // Taps to the public profile: what the card claims, which is what it is when
                // verified and only what it says when not.
                Button { model.path.append(.profile(username: follow.card.node)) } label: {
                    HPMono((follow.verified ? "private node of @" : "says it belongs to @") + follow.card.node)
                        .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open @\(follow.card.node)")
                if !follow.verified {
                    HPMuted(Self.unverifiedLine).padding(.top, HPTokens.Space.rowGap)
                }
            } else {
                HPMono("private")
            }
        }
        .padding(.bottom, HPTokens.Space.cardGap)
    }

    /// §2.28: `Open in Telegram` and, for a channel I own, `Share Invite` / `Revoke Invite`; for
    /// one I am a member of, `Leave`. Never `Copy Link`.
    private func kebab(_ feed: FeedInfo) -> [HPMenuItem] {
        var items = [HPMenuItem("Open in Telegram") { model.openInTelegram(PrivateLink.chat(supergroupId: feed.privateSupergroupId ?? 0)) }]
        if isMine {
            items.append(HPMenuItem("Share Invite") { model.modal = .privateInvite(chatId: chatId, title: feed.title) })
            items.append(HPMenuItem("Revoke Invite") { model.modal = .revokeInvite(chatId: chatId, title: feed.title) })
        } else if let follow {
            items.append(HPMenuItem("Leave") { model.modal = .leavePrivate(follow) })
        }
        let key = feed.key
        items.append(model.isMuted(sourceKey: key)
            ? HPMenuItem("Unmute Feed") { model.unmute(sourceKey: key, title: feed.title) }
            : HPMenuItem("Mute Feed") { model.mute(sourceKey: key, title: feed.title) })
        return items
    }

    /// Mirrors `FeedChannelScreen.apply(live:)`: album parts fold into the post already on screen.
    private func apply(live m: Message) {
        guard let feed, m.chatId == feed.chatId, let post = Mapping.post(m, source: feed) else { return }
        let stamped = model.feed.stamped(post)
        if stamped.albumId != 0, let i = posts.firstIndex(where: { $0.chatId == stamped.chatId && $0.albumId == stamped.albumId }) {
            guard !posts[i].albumMessageIds.contains(stamped.messageId) else { return }
            posts[i] = Mapping.merged(posts[i], stamped)
        } else {
            guard !posts.contains(where: { $0.id == stamped.id }) else { return }
            posts.insert(stamped, at: 0)
        }
        FeedOrder.sortNewestFirst(&posts)
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        if !reset, exhausted { return }
        loading = true; defer { loading = false }
        guard let page = await model.loadPrivateChannel(chatId: chatId, cursor: cursor, reset: reset) else {
            if feed == nil { failed = true }
            return
        }
        feed = page.feed
        if reset { posts = page.posts } else {
            let known = Set(posts.map(\.id))
            posts += page.posts.filter { !known.contains($0.id) }
        }
        exhausted = page.exhausted
        cursor = page.cursor
    }
}

/// §2.33: `Leave Ana · private?`
struct LeavePrivateModal: View {
    @Environment(AppModel.self) private var model
    let follow: PrivateFollow
    @State private var alsoFeeds = true

    static let body = "Their private posts leave your feed. To get back in you'd ask again, and they'd approve you again."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HPSectionMark("Leave")
            HPH2("Leave \(follow.title)?")
            HPMuted(Self.body)
                .padding(.top, HPTokens.Space.rowGap)
                .padding(.bottom, HPTokens.Space.cardPad)
            if !follow.feeds.isEmpty {
                CheckboxRow(label: "Also leave their private feeds", isOn: $alsoFeeds)
                    .padding(.bottom, HPTokens.Space.cardPad)
            }
            HPButtonRow {
                HPButton("Leave", style: .danger) { Task { await model.leavePrivate(follow, alsoFeeds: alsoFeeds && !follow.feeds.isEmpty) } }
            } b: {
                HPButton("Cancel", style: .ghost) { model.modal = nil }
            }
        }
    }
}

// MARK: - Settings (§2.33)

/// The `PRIVATE` card and `PRIVATE FOLLOWS` list, between `HIDDEN` and `CONTACT`; present only
/// when the reader has a private node or is a member of any.
struct PrivateSettingsSection: View {
    @Environment(AppModel.self) private var model

    static let confirmBody = "Your public card notes that a private node exists \u{2014} not how to reach it. Off, and members' apps can't confirm your private node is yours; they see it as unconfirmed."

    var body: some View {
        if model.hasPrivateLayer {
            HPSectionMark("Private")
            if let node = model.privateRecord.privateNode {
                HPCard {
                    HPListItem {
                        HPBody("Confirm on public card")
                    } trailing: {
                        HStack(spacing: HPTokens.Space.rowGap) {
                            HPMonoSmall(model.confirmPrivateOnCard ? "On" : "Off")
                            HPToggle(isOn: Binding(get: { model.confirmPrivateOnCard },
                                                   set: { on in Task { await model.setConfirmPrivateOnCard(on) } }),
                                     label: "Confirm on public card")
                        }
                    }
                    HPMuted(Self.confirmBody)
                        .padding(.vertical, HPTokens.Space.rowGap)
                    HPListItem(isLast: true) {
                        HPBody("Revoke invite")
                    } trailing: {
                        HPButton("Revoke", style: .ghost, size: .small) { model.modal = .revokeInvite(chatId: node.chatId, title: model.privateNodeTitle) }
                    }
                }
            }
            let follows = model.privateFollows
            HPSectionMark("Private follows", count: follows.count)
            if follows.isEmpty {
                HPCard { HPMuted("You're not in anyone's private node.") }
            } else {
                HPListCard {
                    ForEach(Array(follows.enumerated()), id: \.element.id) { i, follow in
                        HPListItem(isLast: i == follows.count - 1) {
                            Button { model.path.append(.privateChannel(chatId: follow.chatId)) } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    HPBody(follow.title).lineLimit(1)
                                    HPMonoSmall(follow.verified ? "of @" + follow.card.node : "unconfirmed").lineLimit(1)
                                }
                                .frame(minHeight: HPTokens.Space.touchMin, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(follow.title)")
                        } trailing: {
                            HPButton("Leave", style: .ghost, size: .small) { model.modal = .leavePrivate(follow) }
                        }
                    }
                }
            }
        }
    }
}
