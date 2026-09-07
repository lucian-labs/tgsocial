// App — the private layer (PRODUCT.md §2.27–§2.34, PROTOCOL.md §11).
//
// Private is a layer on the node, not a second account (PRODUCT §2.27), and this file is that
// sentence as code: nothing here has its own sign-in, its own tab, or its own feed. It adds
// sources to §4.8's merge, a record to §7, one line to the public card, and a handful of
// TDLib operations (§11.4) that `PrivateRepository` owns. Every piece of copy a reader sees on a
// private surface is here or in `PrivateScreens.swift`, verbatim from PRODUCT §2.27–§2.34.
//
// What is deliberately absent, so nobody adds it back by accident: no `private.follows` line
// (membership is the edge, and Telegram records it — §11.2), no private +1 (§11.5), no comments
// on private posts (§11.5), nothing handed to the Connector (§11.5), nothing in the demo (§2.34).

import Foundation
import SwiftUI
import UIKit

/// How the private half of Delete My Node ended (PROTOCOL §11.4.12).
enum PrivateDeleteOutcome: Equatable {
    /// There was nothing private to delete.
    case nothing
    /// Every private channel is gone.
    case deleted
    /// A private channel refused; nothing public was touched.
    case failed(DeleteNodeResult)
}

extension AppModel {

    // MARK: Copy (PRODUCT §2.27–§2.34), verbatim

    enum PrivateCopy {
        static let ready = "Your private node is ready."
        static let inviteCopied = "Invite copied. Anyone with it can ask to join."
        static let newInvite = "New invite. The old one is dead."
        static let asked = "Asked. You'll see it here when they approve."
        static func youAreIn(_ title: String) -> String { "You're in. \(title) is in your feed now." }
        static let needsBot = "This channel uses a bot to approve members. Open it in Telegram."
        static let privateLinkCopied = "Link copied. Only members can open it."
        static let cardRepaired = "Card repaired."
        static let declined = "Declined."
        static func approved(_ name: String) -> String { "Approved \(name)." }
        static func removed(_ name: String) -> String { "Removed \(name)." }
        static func added(_ title: String) -> String { "Added \(title)." }
        static func left(_ title: String) -> String { "Left \(title)." }
        static let notAnInvite = "That's not an invite link."
    }

    // MARK: Reading the record

    /// PRODUCT §2.34: the demo carries no private fixtures, so every private surface reads empty
    /// there whatever the record on disk says — the record is the signed-in account's, not the
    /// demo's to show.
    var hasPrivateNode: Bool { !isDemo && privateRecord.privateNode != nil }

    /// The `private.id` line every public card write carries (PROTOCOL §11.6): my private node's
    /// supergroup id while `Confirm on public card` is on, nil otherwise — and nil strips it.
    var myPrivateId: String? {
        guard confirmPrivateOnCard, let node = privateRecord.privateNode else { return nil }
        return String(node.supergroupId)
    }

    /// `<name> · private` — the reference client's title for the private node (§11.4.1).
    var privateNodeTitle: String {
        if let node = privateRecord.privateNode, let info = privateChannelInfo[node.chatId] { return info.title }
        return Self.privateTitle(for: (myCard?.name?.isEmpty == false ? myCard?.name : nil) ?? myTitle)
    }

    static func privateTitle(for name: String) -> String { name + " \u{00B7} private" }

    /// The private channels I own, node first, as the requests inbox and the delete run walk them.
    var ownedPrivateChats: [(chatId: Int64, title: String)] {
        guard !isDemo else { return [] }
        var out: [(Int64, String)] = []
        if let node = privateRecord.privateNode { out.append((node.chatId, privateNodeTitle)) }
        for f in privateRecord.privateFeeds { out.append((f.chatId, privateChannelInfo[f.chatId]?.title ?? f.title)) }
        return out
    }

    func ownsPrivateChat(_ chatId: Int64) -> Bool { ownedPrivateChats.contains { $0.chatId == chatId } }

    /// Pending requests across every channel I own — the number on You and on the Private screen.
    var totalPendingRequests: Int {
        ownedPrivateChats.reduce(0) { $0 + (pendingRequestCounts[$1.chatId] ?? 0) }
    }

    /// Whether the reader has any private surface at all — the Settings card's presence (§2.33).
    var hasPrivateLayer: Bool { !isDemo && (hasPrivateNode || !privateFollows.isEmpty) }

    func privateFollow(chatId: Int64) -> PrivateFollow? {
        privateFollows.first { $0.chatId == chatId }
    }

    /// A chat id for a `c/<id>` source key: mine, a follow's, or a follow's feed.
    func privateChatId(supergroupId: Int64) -> Int64? {
        if let node = privateRecord.privateNode, node.supergroupId == supergroupId { return node.chatId }
        if let f = privateRecord.privateFeeds.first(where: { $0.supergroupId == supergroupId }) { return f.chatId }
        for follow in privateFollows {
            if follow.supergroupId == supergroupId { return follow.chatId }
            if let f = follow.feeds.first(where: { $0.supergroupId == supergroupId }) { return f.chatId }
        }
        return nil
    }

    /// The channel facts for a private chat the reader can see: the live info where it was read,
    /// else what the record and the follows list know.
    func privateChannel(chatId: Int64) -> FeedInfo? {
        if let info = privateChannelInfo[chatId] { return info }
        if let node = privateRecord.privateNode, node.chatId == chatId {
            return FeedInfo(username: "", chatId: chatId, title: privateNodeTitle, description: "", photo: myPhoto,
                            fetchedAt: Date(), privateSupergroupId: node.supergroupId)
        }
        if let f = privateRecord.privateFeeds.first(where: { $0.chatId == chatId }) {
            return FeedInfo(username: "", chatId: chatId, title: f.title, description: "", photo: nil,
                            fetchedAt: Date(), privateSupergroupId: f.supergroupId)
        }
        for follow in privateFollows {
            if follow.chatId == chatId {
                return FeedInfo(username: "", chatId: chatId, title: follow.title, description: "", photo: follow.photo,
                                fetchedAt: Date(), privateSupergroupId: follow.supergroupId)
            }
            if let f = follow.feeds.first(where: { $0.chatId == chatId }) {
                return FeedInfo(username: "", chatId: chatId, title: f.title, description: "", photo: f.photo,
                                fetchedAt: Date(), privateSupergroupId: f.supergroupId)
            }
        }
        return nil
    }

    /// The follow a private channel belongs to — the owner's node for a follow's feed too. A
    /// channel that is itself a follow's node is that follow's, whoever else lists its invite
    /// (§11.3: a channel is attributed by its own card).
    func privateOwner(chatId: Int64) -> PrivateFollow? {
        if let node = privateFollows.first(where: { $0.chatId == chatId }) { return node }
        return privateFollows.first { $0.feeds.contains { $0.chatId == chatId } }
    }

    /// §11.5's extension of §4.8's source list: my private node, my private feeds, every private
    /// node I am an approved member of, and every private feed listed on those cards that I am in.
    /// Attribution rides with each: mine to me, a verified card's channels to the node it names,
    /// an unverified card's to nobody.
    ///
    /// One entry per channel. Mine and the nodes come first and own their keys; a listed feed is
    /// emitted only for a channel nothing else already accounts for, because a listed link can
    /// open onto another person's private node — the reader is in it by THAT owner's approval,
    /// and §11.3 attributes it by its own card, never by a card that happens to hold its invite.
    var privateSources: [PrivateSource] {
        guard !isDemo else { return [] }
        var out: [PrivateSource] = []
        var taken = Set<Int64>()
        for chat in ownedPrivateChats {
            guard let info = privateChannel(chatId: chat.chatId) else { continue }
            out.append(PrivateSource(info: info, owner: myNode?.username, isMine: true))
            taken.insert(chat.chatId)
        }
        for follow in privateFollows {
            guard taken.insert(follow.chatId).inserted, let info = privateChannel(chatId: follow.chatId) else { continue }
            out.append(PrivateSource(info: info, owner: follow.attributedNode, isMine: false))
        }
        for follow in privateFollows {
            for f in follow.feeds {
                guard taken.insert(f.chatId).inserted, let info = privateChannel(chatId: f.chatId) else { continue }
                out.append(PrivateSource(info: info, owner: follow.attributedNode, isMine: false, isListed: true))
            }
        }
        return out
    }

    /// Compose's `POST TO` list (PRODUCT §2.28): my public feeds, then my private channels by
    /// `c/<id>` key. The tab label carries the title and, for a private channel, says so.
    var composeTargets: [String] {
        (myCard?.feeds ?? []) + ownedPrivateChats.compactMap { privateChannel(chatId: $0.chatId)?.key }
    }

    func composeLabel(_ target: String) -> String {
        if let id = PrivateLink.supergroupId(fromSourceKey: target), let chatId = privateChatId(supergroupId: id) {
            return (privateChannel(chatId: chatId)?.title ?? "Private") + " \u{00B7} Private"
        }
        return feedInfo(target)?.title ?? target
    }

    func isPrivateTarget(_ target: String) -> Bool { PrivateLink.supergroupId(fromSourceKey: target) != nil }

    // MARK: Refresh (PROTOCOL §11.4.9)

    /// Recovers the record and the private follows from the chat list. Best-effort and silent:
    /// a failure keeps whatever was on screen, and the next refresh tries again.
    func refreshPrivate() async {
        guard !isDemo, auth == .ready, !isOffline else { return }
        guard let channels = try? await activity.run("Checking your private channels", { try await self.privateLayer.privateChannels() }) else { return }
        if let node = myNode {
            await privateLayer.recoverMine(node: node.username, from: channels)
        }
        privateFollows = await privateLayer.follows(me: myNode?.username, from: channels) { node, supergroupId in
            await self.verifyPrivate(node: node, supergroupId: supergroupId)
        }
        privateRecord = privateLayer.record
        for chat in ownedPrivateChats {
            // A dead node takes its feeds out of the record mid-loop; nothing is read for those.
            guard ownsPrivateChat(chat.chatId), let facts = await privateLayer.channelFacts(chatId: chat.chatId) else { continue }
            // A channel Telegram no longer lists me as the creator of is gone from under me —
            // deleted from Telegram's own client, or handed away. `getChat` keeps answering from
            // the local database after a deletion, so "the chat is still there" proves nothing;
            // the supergroup's status is the tell, and only a definite answer counts (§11.8).
            if facts.owned == false, let sgId = facts.info.privateSupergroupId { noteOwnedPrivateGone(supergroupId: sgId); continue }
            privateChannelInfo[chat.chatId] = facts.info
            privateMemberCounts[chat.chatId] = facts.memberCount
            pendingRequestCounts[chat.chatId] = facts.pendingRequests
        }
        await repairAfterOwnedLoss()
    }

    /// The writes a loss seen on the update stream deferred to here: a public card still naming a
    /// private node that died stops naming it (`private.id` off — `myPrivateId` is already nil,
    /// and this write is what strips the line, the same repair §11.4.12 makes), and a private card
    /// still listing a dead feed's link is rewritten without it. Never while Delete My Node is
    /// running its own writes, never offline, never over a newer card.
    private func repairAfterOwnedLoss() async {
        guard !deletingNode, !isOffline, auth == .ready, let node = myNode, myCardState == .ok else { return }
        if privateIdStale {
            privateIdStale = false
            if let card = myCard, !(await writeCard(card)) { privateIdStale = true }
        }
        if privateCardStale, hasPrivateNode {
            if (try? await privateLayer.rewritePrivateCard(node: node.username)) != nil { privateCardStale = false }
        }
    }

    /// §11.3, from the cache the app already holds: `@node`'s public card names `supergroupId`.
    func verifyPrivate(node: String, supergroupId: Int64) async -> Bool {
        let info = (try? await nodes.readNode(username: node)) ?? nodes.cachedNode(node)
        return PrivateCodec.verified(publicId: info?.privateId, supergroupId: supergroupId)
    }

    /// §11.4.7: re-checks every request I have out. An approval toasts once and pulls the new
    /// source into the follows list; the caller's feed refresh then reads it.
    func checkPendingApprovals() async {
        guard !isDemo, auth == .ready, !isOffline, !privateRecord.pending.isEmpty else { return }
        let approved = await privateLayer.checkPending()
        privateRecord = privateLayer.record
        guard !approved.isEmpty else { return }
        for entry in approved { showToast(PrivateCopy.youAreIn(entry.title), tone: .good) }
        await refreshPrivate()
    }

    /// PROTOCOL §11.6: a missing or wrong `private.id` on my own card — a §2-only client rewrote
    /// it — is repaired on the next read, while the owner has not withheld the line.
    func repairPrivateId(found: String?) async {
        guard hasPrivateNode, confirmPrivateOnCard, myCardState == .ok, let expected = myPrivateId, found != expected else { return }
        if await writeCard(myCard ?? Card()) { showToast(PrivateCopy.cardRepaired) }
    }

    func clearPrivateState() {
        privateLayer.clear()
        privateRecord = PrivateRecord()
        privateFollows = []
        pendingRequestCounts = [:]
        joinRequests = []
        privateMembers = [:]
        privateChannelInfo = [:]
        privateMemberCounts = [:]
        privateArrivalTask?.cancel()
        privateArrivalTask = nil
        privateIdStale = false
        privateCardStale = false
    }

    // MARK: Update signals (PROTOCOL §11.4.5, §11.4.7, §11.8)

    /// `updateChatPendingJoinRequests` on a channel I own: the count changes at once, and the
    /// inbox re-lists while it is open. Never polled.
    func notePendingRequests(chatId: Int64, info: ChatJoinRequestsInfoFacts?) {
        guard ownsPrivateChat(chatId) else { return }
        pendingRequestCounts[chatId] = info?.totalCount ?? 0
        if requestsSurfaces > 0 { Task { await loadRequests() } }
    }

    /// `updateSupergroup` with `chatMemberStatusBanned` / `Left` on a private follow: Telegram has
    /// stopped serving the channel (§11.8). Same cleanup as leaving; no toast — there is nothing
    /// to send it from, and the channel is simply gone from the feed. The same update on a channel
    /// I OWN means it is gone for everyone — deleted from Telegram's own client — and the record
    /// must not keep offering it.
    func notePrivateMembership(supergroupId: Int64, isMember: Bool) {
        guard !isMember else { return }
        if ownsPrivateSupergroup(supergroupId) { noteOwnedPrivateGone(supergroupId: supergroupId); return }
        guard let follow = privateFollows.first(where: { $0.supergroupId == supergroupId || $0.feeds.contains { $0.supergroupId == supergroupId } }) else { return }
        if follow.supergroupId == supergroupId {
            dropPrivateSource(chatId: follow.chatId, supergroupId: follow.supergroupId)
            privateFollows.removeAll { $0.chatId == follow.chatId }
        } else if let f = follow.feeds.first(where: { $0.supergroupId == supergroupId }) {
            dropPrivateSource(chatId: f.chatId, supergroupId: f.supergroupId)
            if let i = privateFollows.firstIndex(where: { $0.chatId == follow.chatId }) {
                privateFollows[i].feeds.removeAll { $0.chatId == f.chatId }
            }
        }
    }

    func ownsPrivateSupergroup(_ supergroupId: Int64) -> Bool {
        privateRecord.privateNode?.supergroupId == supergroupId || privateRecord.privateFeeds.contains { $0.supergroupId == supergroupId }
    }

    /// A channel I own is gone from under me (§11.8, the owner's side). The private node takes the
    /// record's feeds with it — their links lived on its card, which is the only thing that could
    /// recover them (§11.4.9), and a record with feeds under no node would offer Compose and Delete
    /// My Node channels the copy never names. A feed alone leaves the record; its dead link comes
    /// off the private card on the next refresh. The public card's `private.id` is stripped there
    /// too, never from here: the update stream reacts, it does not write.
    func noteOwnedPrivateGone(supergroupId: Int64) {
        if let node = privateRecord.privateNode, node.supergroupId == supergroupId {
            for f in privateRecord.privateFeeds { forgetOwnedChannel(chatId: f.chatId, supergroupId: f.supergroupId) }
            forgetOwnedChannel(chatId: node.chatId, supergroupId: node.supergroupId)
            privateLayer.update { $0.privateNode = nil; $0.privateFeeds = [] }
            privateRecord = privateLayer.record
            // Delete My Node's own deletes announce themselves here too; that run makes its own
            // card writes (§11.4.12), so it owes nothing to the next refresh.
            privateIdStale = !deletingNode
            privateCardStale = false
        } else if let f = privateRecord.privateFeeds.first(where: { $0.supergroupId == supergroupId }) {
            forgetOwnedChannel(chatId: f.chatId, supergroupId: f.supergroupId)
            privateLayer.update { $0.privateFeeds.removeAll { $0.chatId == f.chatId } }
            privateRecord = privateLayer.record
            privateCardStale = true
        }
    }

    private func forgetOwnedChannel(chatId: Int64, supergroupId: Int64) {
        dropPrivateSource(chatId: chatId, supergroupId: supergroupId)
        privateMemberCounts.removeValue(forKey: chatId)
        privateMembers.removeValue(forKey: chatId)
        pendingRequestCounts.removeValue(forKey: chatId)
        joinRequests.removeAll { $0.chatId == chatId }
    }

    /// A channel arrived while a request of mine is out (§11.4.7 names `updateNewChat` as the
    /// earlier signal). Re-check soon rather than on the next refresh — and once per burst, not
    /// once per channel: TDLib replays `updateNewChat` for every chat it knows on each start and
    /// again as the list loads, so with one request out — the ordinary state for days after
    /// asking — an unguarded pass here ran `checkChatInviteLink`, every node read and every
    /// source's `getChatHistory` once per channel in the account. A new arrival cancels the armed
    /// pass and re-arms it; the pass runs ~1 s after the last, as `scheduleCandidateRefresh` does.
    func notePrivateArrival(isChannel: Bool, hasUsername: Bool) {
        guard isChannel, !hasUsername, !privateRecord.pending.isEmpty else { return }
        privateArrivalTask?.cancel()
        privateArrivalTask = Task { [weak self] in
            try? await Task.sleep(for: Self.privateArrivalDebounce)
            guard !Task.isCancelled, let self else { return }
            self.privateArrivalPasses += 1
            await self.checkPendingApprovals()
            await self.refreshFeed()
        }
    }

    nonisolated static let privateArrivalDebounce: Duration = .seconds(1)

    private func dropPrivateSource(chatId: Int64, supergroupId: Int64) {
        feed.drop(sourceKey: PrivateLink.sourceKey(supergroupId: supergroupId))
        privateChannelInfo.removeValue(forKey: chatId)
        posts = feed.posts
    }

    // MARK: Make (PRODUCT §2.27, PROTOCOL §11.4.1)

    @discardableResult
    func makePrivateNode() async -> Bool {
        if refuseDemoWrite() { return false }
        guard let node = myNode, myCardState == .ok else { showToast(Self.newerCardText, tone: .bad); return false }
        guard !hasPrivateNode else { return true }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        let title = privateNodeTitle
        let name = (myCard?.name?.isEmpty == false ? myCard?.name : nil) ?? myTitle
        do {
            let ref = try await activity.run("Making your private node") {
                try await self.perform { try await self.privateLayer.createPrivateNode(title: title, node: node.username, name: name) }
            }
            privateRecord = privateLayer.record
            privateChannelInfo[ref.chatId] = FeedInfo(username: "", chatId: ref.chatId, title: title, description: "",
                                                      photo: myPhoto, fetchedAt: Date(), privateSupergroupId: ref.supergroupId)
            privateMemberCounts[ref.chatId] = 1
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
        // Step 4: `private.id` on the public card, unless withheld (§2.33). `writeCard` carries it.
        if confirmPrivateOnCard { await writeCard(myCard ?? Card()) }
        // §2.27: onto the Private screen with the invite sheet already open — the next thing
        // anyone does with a private node is hand somebody the way in.
        modal = nil
        path.append(.privateNode)
        if let ref = privateRecord.privateNode { modal = .privateInvite(chatId: ref.chatId, title: title) }
        showToast(PrivateCopy.ready, tone: .good)
        await refreshFeed()
        return true
    }

    // MARK: Private feeds (PRODUCT §2.28, PROTOCOL §11.4.2)

    @discardableResult
    func addPrivateFeed(title: String) async -> Bool {
        if refuseDemoWrite() { return false }
        guard let node = myNode, hasPrivateNode else { return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let ref = try await activity.run("Adding \(trimmed)") {
                try await self.perform { try await self.privateLayer.createPrivateFeed(title: trimmed, node: node.username) }
            }
            privateRecord = privateLayer.record
            privateChannelInfo[ref.chatId] = FeedInfo(username: "", chatId: ref.chatId, title: trimmed, description: "",
                                                      photo: nil, fetchedAt: Date(), privateSupergroupId: ref.supergroupId)
            privateMemberCounts[ref.chatId] = 1
            showToast(PrivateCopy.added(trimmed), tone: .good)
            modal = .privateInvite(chatId: ref.chatId, title: trimmed)
            await refreshFeed()
            return true
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
    }

    // MARK: Invites (PRODUCT §2.29, PROTOCOL §11.4.3, §11.4.4, §11.7)

    /// The one link the app ever shows: stored, else recovered, else created — always join-approval.
    func inviteLink(forChat chatId: Int64) async -> String? {
        guard !isDemo, !isOffline else { return nil }
        do {
            let link = try await perform { try await self.privateLayer.invite(forChat: chatId) }
            privateRecord = privateLayer.record
            return link
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return nil
        }
    }

    /// `Copy Invite`: the warning rides on the toast too, because the toast is what people read.
    func copyInvite(_ link: String) {
        UIPasteboard.general.string = link
        showToast(PrivateCopy.inviteCopied)
    }

    /// §11.4.4: the old link dies, a fresh one is minted, members stay. The sheet reopens on it.
    func revokeInvite(chatId: Int64, title: String) async {
        if refuseDemoWrite() { return }
        guard let node = myNode else { return }
        if isOffline { showToast("You're offline.", tone: .bad); return }
        do {
            _ = try await activity.run("Revoking the invite") {
                try await self.perform { try await self.privateLayer.revokeInvite(forChat: chatId, node: node.username) }
            }
            privateRecord = privateLayer.record
            modal = .privateInvite(chatId: chatId, title: title)
            showToast(PrivateCopy.newInvite, tone: .good)
        } catch {
            modal = nil
            showToast(TDFailure(error).message, tone: .bad)
        }
    }

    // MARK: Requests (PRODUCT §2.30, PROTOCOL §11.4.5)

    func requestsSurfaceAppeared() {
        requestsSurfaces += 1
        Task { await loadRequests() }
    }

    func requestsSurfaceDisappeared() { requestsSurfaces = max(0, requestsSurfaces - 1) }

    func loadRequests() async {
        guard !isDemo, auth == .ready, !isOffline, !requestsLoading else { return }
        let chats = ownedPrivateChats
        guard !chats.isEmpty else { joinRequests = []; return }
        requestsLoading = true
        defer { requestsLoading = false }
        do {
            let list = try await activity.run("Reading requests") {
                try await self.perform {
                    try await self.privateLayer.joinRequests(chats: chats) { username in await self.guessNode(forUsername: username) }
                }
            }
            joinRequests = list
            for chat in chats { pendingRequestCounts[chat.chatId] = list.filter { $0.chatId == chat.chatId }.count }
        } catch {
            if !isOffline { showToast(TDFailure(error).message, tone: .bad) }
        }
    }

    /// §4.3's convention, as a guess and nothing more: `tgs_<username>` resolves to a card, or
    /// it does not. Never presented as the requester's identity (§11.4.5).
    func guessNode(forUsername username: String) async -> String? {
        let candidate = DiscoveryRepository.prefix + username
        guard Username.isValid(candidate) else { return nil }
        guard let info = try? await nodes.readNode(username: candidate), info.state == .ok else { return nil }
        return info.username
    }

    /// One tap either way (§2.30): the row leaves at once and comes back only if Telegram refused.
    func decideRequest(_ request: JoinRequest, approve: Bool) async {
        if refuseDemoWrite() { return }
        if isOffline { showToast("You're offline.", tone: .bad); return }
        joinRequests.removeAll { $0.id == request.id }
        pendingRequestCounts[request.chatId] = max(0, (pendingRequestCounts[request.chatId] ?? 1) - 1)
        do {
            try await perform { try await self.privateLayer.decide(chatId: request.chatId, userId: request.userId, approve: approve) }
            showToast(approve ? PrivateCopy.approved(request.name) : PrivateCopy.declined, tone: approve ? .good : .neutral)
            if approve { privateMemberCounts[request.chatId, default: 0] += 1 }
        } catch {
            joinRequests.append(request)
            joinRequests.sort { $0.date > $1.date }
            pendingRequestCounts[request.chatId, default: 0] += 1
            showToast(TDFailure(error).message, tone: .bad)
        }
    }

    // MARK: Members (PRODUCT §2.28, PROTOCOL §11.4.10)

    func loadMembers(chatId: Int64) async {
        guard !isDemo, auth == .ready, !isOffline else { return }
        guard let info = privateChannel(chatId: chatId), let sgId = info.privateSupergroupId else { return }
        do {
            let list = try await perform { try await self.privateLayer.members(supergroupId: sgId, me: self.me?.id) }
            privateMembers[chatId] = list.filter { !$0.isMe }
            privateMemberCounts[chatId] = list.count
        } catch {
            if !isOffline { showToast(TDFailure(error).message, tone: .bad) }
        }
    }

    /// The private feeds a member is also in, for the remove confirm's checkbox row.
    func privateFeedsContaining(userId: Int64) -> [PrivateFeedRef] {
        privateRecord.privateFeeds.filter { (privateMembers[$0.chatId] ?? []).contains { $0.userId == userId } }
    }

    func removeMember(_ member: PrivateMember, chatId: Int64, alsoFeeds: Bool) async {
        modal = nil
        if refuseDemoWrite() { return }
        if isOffline { showToast("You're offline.", tone: .bad); return }
        var chats = [chatId]
        if alsoFeeds { chats += privateFeedsContaining(userId: member.userId).map(\.chatId).filter { $0 != chatId } }
        do {
            for id in chats {
                try await perform { try await self.privateLayer.remove(chatId: id, userId: member.userId) }
                privateMembers[id]?.removeAll { $0.userId == member.userId }
                privateMemberCounts[id] = max(0, (privateMemberCounts[id] ?? 1) - 1)
            }
            showToast(PrivateCopy.removed(member.name))
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
        }
    }

    // MARK: Asking to join (PRODUCT §2.31, PROTOCOL §11.4.6, §11.4.7)

    /// An invite link, pasted or opened. `is_public` opens the channel as any public channel; a
    /// chat the reader already has access to opens directly; otherwise the preview.
    @discardableResult
    func openInvite(_ input: String) async -> Bool {
        if isDemo { showToast(DemoCopy.notOnTelegram); return false }
        guard InviteLink.normalise(input) != nil else { return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        do {
            guard let preview = try await perform({ try await self.privateLayer.preview(input) }) else {
                showToast(PrivateCopy.notAnInvite, tone: .bad)
                return false
            }
            if preview.isPublic, preview.chatId != 0, let username = await privateLayer.publicUsername(chatId: preview.chatId) {
                path.append(.feedChannel(username: username))
                return true
            }
            if preview.chatId != 0, privateChannel(chatId: preview.chatId) != nil {
                path.append(.privateChannel(chatId: preview.chatId))
                return true
            }
            modal = .invitePreview(preview)
            return true
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
    }

    func askToJoin(_ preview: InvitePreview) async {
        if refuseDemoWrite() { return }
        if isOffline { showToast("You're offline.", tone: .bad); return }
        do {
            let result = try await activity.run("Asking to join") { try await self.perform { try await self.privateLayer.ask(preview) } }
            privateRecord = privateLayer.record
            switch result {
            case .requestSent:
                modal = nil
                showToast(PrivateCopy.asked)
            case .joined:
                // §11.4.6: the link did not require approval; say nothing about approval, because
                // none happened.
                modal = nil
                await refreshPrivate()
                await refreshFeed()
                showToast(PrivateCopy.youAreIn(preview.title), tone: .good)
            case .needsBot:
                modal = nil
                showToast(PrivateCopy.needsBot, tone: .bad)
            }
        } catch {
            // A duplicate request is whatever TDLib says, verbatim (§11.4.6).
            showToast(TDFailure(error).message, tone: .bad)
        }
    }

    /// `Ask Again` is 11.4.6 step 3 over again, from the pending row.
    func askAgain(_ pending: PendingRequest) async {
        let preview = InvitePreview(invite: pending.invite, title: pending.title, photo: pending.photo,
                                    memberCount: 0, isPublic: false, createsJoinRequest: true, chatId: 0)
        await askToJoin(preview)
    }

    /// `Forget`: the row leaves, locally and nothing else — there is no call to withdraw a request.
    func forgetPending(_ pending: PendingRequest) {
        privateLayer.forget(invite: pending.invite)
        privateRecord = privateLayer.record
    }

    // MARK: Leaving (PRODUCT §2.33, PROTOCOL §11.4.11, §11.8)

    func leavePrivate(_ follow: PrivateFollow, alsoFeeds: Bool) async {
        modal = nil
        if refuseDemoWrite() { return }
        if isOffline { showToast("You're offline.", tone: .bad); return }
        var chats = [(follow.chatId, follow.supergroupId)]
        if alsoFeeds { chats += follow.feeds.map { ($0.chatId, $0.supergroupId) } }
        do {
            for (chatId, sgId) in chats {
                try await perform { try await self.privateLayer.leave(chatId: chatId) }
                dropPrivateSource(chatId: chatId, supergroupId: sgId)
            }
            if alsoFeeds {
                privateFollows.removeAll { $0.chatId == follow.chatId }
            } else if let i = privateFollows.firstIndex(where: { $0.chatId == follow.chatId }) {
                // Left the node, kept their feeds: the feeds stay readable but nothing attributes
                // them to the card any more, so they are re-read on the next refresh as they are.
                privateFollows.remove(at: i)
                await refreshPrivate()
            }
            showToast(PrivateCopy.left(follow.title))
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
        }
    }

    // MARK: Settings (PRODUCT §2.33)

    /// `Confirm on public card`: writes or strips `private.id` in one card write (§11.2, §4.4).
    func setConfirmPrivateOnCard(_ on: Bool) async {
        if refuseDemoWrite() { return }
        let previous = confirmPrivateOnCard
        confirmPrivateOnCard = on
        guard hasPrivateNode else { return }
        if !(await writeCard(myCard ?? Card())) { confirmPrivateOnCard = previous }
    }

    // MARK: Delete My Node, the private half (PROTOCOL §11.4.12)

    /// Private feeds first, then the private node, each refusing by name. Nothing public is
    /// touched by this method; the caller goes on to §4.11 only when this returns `.deleted` or
    /// `.nothing`.
    func deletePrivateChannels() async -> PrivateDeleteOutcome {
        let feeds = privateRecord.privateFeeds
        let node = privateRecord.privateNode
        guard node != nil || !feeds.isEmpty else { return .nothing }
        for f in feeds {
            do {
                try await perform { try await self.deleteOwnedChat(f.chatId) }
                privateLayer.update { $0.privateFeeds.removeAll { $0.chatId == f.chatId } }
                privateRecord = privateLayer.record
            } catch {
                return .failed(.privateFailed(title: privateChannelInfo[f.chatId]?.title ?? f.title, error: TDFailure(error).message))
            }
        }
        if let node {
            let title = privateNodeTitle
            do {
                try await perform { try await self.deleteOwnedChat(node.chatId) }
                privateLayer.update { $0.privateNode = nil }
                privateRecord = privateLayer.record
            } catch {
                return .failed(.privateFailed(title: title, error: TDFailure(error).message))
            }
        }
        return .deleted
    }

    /// §11.4.12, one channel: `canBeDeletedForAllUsers` then `deleteChat`, through the seam §4.11's
    /// public deletes go through, so the whole run's order is one measurable thing.
    private func deleteOwnedChat(_ chatId: Int64) async throws {
        guard try await chatDeleter.canDeleteForAll(chatId: chatId) else { throw TDFailure(code: 400, message: "Only the owner can delete it.") }
        try await chatDeleter.deleteChat(chatId: chatId)
    }

    /// PRODUCT §2.33: `your private node and 1 private feed` — derived, never typed.
    var deleteNodePrivateClause: String? {
        guard hasPrivateNode else { return nil }
        let n = privateRecord.privateFeeds.count
        if n == 0 { return "your private node" }
        return "your private node and \(n) private feed\(n == 1 ? "" : "s")"
    }

    // MARK: The private channel screen (PRODUCT §2.28, §2.31)

    func loadPrivateChannel(chatId: Int64, cursor: Int64, reset: Bool) async
        -> (feed: FeedInfo, posts: [Post], exhausted: Bool, cursor: Int64)? {
        guard !isDemo else { return nil }
        var info = privateChannel(chatId: chatId)
        if reset || info == nil, let live = await privateLayer.feedInfo(chatId: chatId) {
            privateChannelInfo[chatId] = live
            info = live
        }
        guard let info else { return nil }
        do {
            let from = reset ? 0 : cursor
            let page = try await perform { try await self.feed.channelPosts(info, fromMessageId: from) }
            let exhausted = page.exhausted || (from != 0 && page.oldestId >= from)
            return (info, page.posts, exhausted, page.oldestId)
        } catch {
            return nil
        }
    }

    // MARK: Share (PRODUCT §2.32)

    /// `Share` on a private post copies the `t.me/c/` link — the only link it has — and says who
    /// can open it. No `t.me/s/` preview, no public route, nothing manufactured.
    func copyPrivateLink(_ post: Post) {
        UIPasteboard.general.string = post.deepLink
        showToast(PrivateCopy.privateLinkCopied)
    }
}

/// The two fields of TDLib's `chatJoinRequestsInfo` the model reads, so the update path can be
/// exercised without a TDLib value.
struct ChatJoinRequestsInfoFacts: Equatable {
    var totalCount: Int
    var userIds: [Int64]
}
