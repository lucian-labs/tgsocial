// Repo — the private layer (PROTOCOL.md §11.4). Every TDLib call §11 names lives here and nowhere
// else, one method per numbered operation, so the whole of "what the app does to Telegram for a
// private channel" is this file.
//
// Two rules the shape enforces:
//
//  1. The only invite link this repository ever hands out is one it created with
//     `creates_join_request: true` (§11.4.1 step 3, §11.4.3). Telegram's own primary link joins
//     without approval and `editChatInviteLink` cannot change that ("edits a non-primary invite
//     link", td_api.tl 13905), so the primary is rotated at creation and never read back.
//  2. `setSupergroupUsername` is never called on anything here. A private channel is private
//     because it has no username, and this is the one channel the client creates that must stay
//     that way (§11.4.1).

import Foundation
import TDLibKit

@MainActor
final class PrivateRepository {
    private let td: TDClient
    private let store: LocalStore
    private let nodes: NodeRepository
    private let sends: SendTracker
    private let activity: ActivityRegistry

    /// The §7.2 record, written through on every change.
    private(set) var record: PrivateRecord

    static let inviteName = "tgsocial"
    static let descriptionPrefix = "tgsocial v1 private"

    init(td: TDClient, store: LocalStore, nodes: NodeRepository, sends: SendTracker, activity: ActivityRegistry) {
        self.td = td; self.store = store; self.nodes = nodes; self.sends = sends; self.activity = activity
        record = store.load(PrivateRecord.self, LocalStore.privateRecord) ?? PrivateRecord()
    }

    private var api: TDLibClient { td.api }

    private func persist() { store.save(record.isEmpty ? nil : record, LocalStore.privateRecord) }

    func clear() { record = PrivateRecord(); persist() }

    func update(_ change: (inout PrivateRecord) -> Void) {
        change(&record)
        persist()
    }

    // MARK: Descriptions (§11.4.1, §11.4.2, §11.5)

    static func nodeDescription(node: String) -> String { descriptionPrefix + " \u{00B7} @" + node }
    static func feedDescription(node: String) -> String { descriptionPrefix + " feed \u{00B7} @" + node }

    // MARK: §11.4.1 Create my private node

    /// Steps 1–3 and 5. Step 4 — `private.id` on the public card — is the caller's, because it is
    /// a public card write and every one of those goes through `AppModel.writeCard`.
    func createPrivateNode(title: String, node: String, name: String?) async throws -> PrivateNodeRef {
        let chat = try await api.createNewSupergroupChat(
            description: Self.nodeDescription(node: node), forImport: false, isChannel: true, isForum: false,
            location: nil, messageAutoDeleteTime: 0, title: title)
        guard let sgId = Mapping.supergroupId(of: chat) else { throw TDFailure(code: 500, message: "Channel was not created.") }
        do {
            // Step 2: the private card — marker, name, `public: no`, `private.node` (§11.2).
            let card = Card(name: name, isPublic: false)
            let message = try await sendCard(chatId: chat.id, card: card, private: PrivateCard(node: node))
            try await api.pinChatMessage(chatId: chat.id, disableNotification: true, messageId: message.id, onlyForSelf: false)
            // The primary link joins without approval and cannot be edited into approval mode:
            // rotate it so any primary Telegram showed the owner in the meantime is dead, then never
            // read it again (§11.4.1).
            _ = try? await api.replacePrimaryChatInviteLink(chatId: chat.id)
            // Step 3: the one kind of link the client ever shows the owner.
            let invite = try await createInvite(chatId: chat.id)
            // Step 5, optional: the private node wears the public node's photo.
            if let mine = nodes.cachedNode(node)?.photo {
                _ = try? await api.setChatPhoto(chatId: chat.id, photo: .inputChatPhotoStatic(InputChatPhotoStatic(photo: .inputFileId(InputFileId(id: mine.fileId)))))
            }
            let ref = PrivateNodeRef(chatId: chat.id, supergroupId: sgId, pinnedMessageId: message.id, invite: invite)
            update { $0.privateNode = ref }
            return ref
        } catch {
            _ = try? await api.deleteChat(chatId: chat.id)
            throw error
        }
    }

    /// `createChatInviteLink` with `creates_join_request: true` (td_api.tl 13896: "In this case,
    /// member_limit must be 0"), no expiry (§11.7: an owner who wants a short-lived one revokes).
    private func createInvite(chatId: Int64) async throws -> String {
        let link = try await api.createChatInviteLink(chatId: chatId, createsJoinRequest: true, expirationDate: 0,
                                                       memberLimit: 0, name: Self.inviteName)
        return InviteLink.normalise(link.inviteLink) ?? link.inviteLink
    }

    private func sendCard(chatId: Int64, card: Card, private priv: PrivateCard) async throws -> Message {
        let text = FormattedText(entities: [], text: CardCodec.serialise(card, work: nil, privateId: nil, private: priv))
        let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: NodeRepository.noPreview, text: text))
        let pending = try await api.sendMessage(chatId: chatId, inputMessageContent: content, options: NodeRepository.quiet, replyMarkup: nil, replyTo: nil, topicId: nil)
        return try await sends.awaitSent(pending.id)
    }

    // MARK: §11.4.2 Create a private feed

    func createPrivateFeed(title: String, node: String) async throws -> PrivateFeedRef {
        let chat = try await api.createNewSupergroupChat(
            description: Self.feedDescription(node: node), forImport: false, isChannel: true, isForum: false,
            location: nil, messageAutoDeleteTime: 0, title: title)
        guard let sgId = Mapping.supergroupId(of: chat) else { throw TDFailure(code: 500, message: "Channel was not created.") }
        do {
            _ = try? await api.replacePrimaryChatInviteLink(chatId: chat.id)
            let invite = try await createInvite(chatId: chat.id)
            let ref = PrivateFeedRef(chatId: chat.id, supergroupId: sgId, invite: invite, title: title)
            update { $0.privateFeeds.append(ref) }
            // The card lists the feed by its link (§11.2); the private node's own link is never listed.
            try await writePrivateCard(node: node, name: name(ofPrivateNode: record.privateNode))
            return ref
        } catch {
            _ = try? await api.deleteChat(chatId: chat.id)
            throw error
        }
    }

    /// The private card's `name:` as it was last written — read back from the pin so a rewrite
    /// carries it, since nothing else in the app stores it.
    private func name(ofPrivateNode ref: PrivateNodeRef?) async -> String? {
        guard let ref, let pinned = try? await api.getChatPinnedMessage(chatId: ref.chatId),
              case .messageText(let t) = pinned.content else { return nil }
        return CardCodec.parse(t.text.text).card?.name
    }

    /// §4.4 against the private node's pinned message: `private.node` and every feed link in the
    /// record. Edits in place; re-sends and re-pins when the pin is gone.
    func writePrivateCard(node: String, name: String?) async throws {
        guard let ref = record.privateNode else { return }
        let priv = PrivateCard(node: node, feeds: record.privateFeeds.compactMap(\.invite))
        let card = Card(name: name, isPublic: false)
        let text = FormattedText(entities: [], text: CardCodec.serialise(card, work: nil, privateId: nil, private: priv))
        let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: NodeRepository.noPreview, text: text))
        if let pinned = try? await api.getChatPinnedMessage(chatId: ref.chatId),
           case .messageText(let t) = pinned.content, CardCodec.isCard(t.text.text) {
            _ = try await api.editMessageText(chatId: ref.chatId, inputMessageContent: content, messageId: pinned.id, replyMarkup: nil)
            if pinned.id != ref.pinnedMessageId { update { $0.privateNode?.pinnedMessageId = pinned.id } }
        } else {
            let fresh = try await sendCard(chatId: ref.chatId, card: card, private: priv)
            try await api.pinChatMessage(chatId: ref.chatId, disableNotification: true, messageId: fresh.id, onlyForSelf: false)
            update { $0.privateNode?.pinnedMessageId = fresh.id }
        }
    }

    // MARK: §11.4.3 Share an invite

    /// The stored link, else the first of my own links that requires approval, else a fresh one.
    /// A link with `creates_join_request == false` is never offered, whoever made it.
    func invite(forChat chatId: Int64) async throws -> String {
        if let node = record.privateNode, node.chatId == chatId, let link = node.invite { return link }
        if let feed = record.privateFeeds.first(where: { $0.chatId == chatId }), let link = feed.invite { return link }
        let me = try await api.getMe()
        let links = try await api.getChatInviteLinks(chatId: chatId, creatorUserId: me.id, isRevoked: false,
                                                     limit: 100, offsetDate: 0, offsetInviteLink: "")
        let link: String
        if let found = links.inviteLinks.first(where: { $0.createsJoinRequest && !$0.isPrimary }) {
            link = InviteLink.normalise(found.inviteLink) ?? found.inviteLink
        } else {
            link = try await createInvite(chatId: chatId)
        }
        remember(invite: link, forChat: chatId)
        return link
    }

    private func remember(invite: String, forChat chatId: Int64) {
        update { r in
            if r.privateNode?.chatId == chatId { r.privateNode?.invite = invite }
            if let i = r.privateFeeds.firstIndex(where: { $0.chatId == chatId }) { r.privateFeeds[i].invite = invite }
        }
    }

    // MARK: §11.4.4 Revoke and reissue

    /// Kills the link; members already approved stay members. Then a fresh one, and if the revoked
    /// link was listed on the private card, the card is rewritten with the new one.
    func revokeInvite(forChat chatId: Int64, node: String) async throws -> String {
        let old = try await invite(forChat: chatId)
        _ = try await api.revokeChatInviteLink(chatId: chatId, inviteLink: old)
        let fresh = try await createInvite(chatId: chatId)
        remember(invite: fresh, forChat: chatId)
        if record.privateFeeds.contains(where: { $0.chatId == chatId }) {
            try await writePrivateCard(node: node, name: await name(ofPrivateNode: record.privateNode))
        }
        return fresh
    }

    // MARK: §11.4.5 Pending requests, owner's side

    /// Every pending request on the channels I own, newest first. `guess` runs §4.3's convention
    /// against a requester's username and is labelled as a guess by the row (PRODUCT §2.30).
    func joinRequests(chats: [(chatId: Int64, title: String)], guess: (String) async -> String?) async throws -> [JoinRequest] {
        var out: [JoinRequest] = []
        for chat in chats {
            var offset: ChatJoinRequest?
            var rounds = 0
            while rounds < 10 {
                rounds += 1
                let page = try await api.getChatJoinRequests(chatId: chat.chatId, inviteLink: "", limit: 50, offsetRequest: offset, query: "")
                guard !page.requests.isEmpty else { break }
                for r in page.requests {
                    let user = try? await api.getUser(userId: r.userId)
                    let username = user?.usernames.flatMap { Self.username($0) }
                    var guessed: String?
                    if let username { guessed = await guess(username) }
                    out.append(JoinRequest(chatId: chat.chatId, chatTitle: chat.title, userId: r.userId,
                                           name: Self.displayName(user) ?? "Telegram user",
                                           username: username, bio: r.bio, date: r.date,
                                           photo: Self.photoRef(user?.profilePhoto),
                                           guessedNode: guessed,
                                           raw: JoinRequestRaw(userId: r.userId, date: r.date, bio: r.bio)))
                }
                offset = page.requests.last
                if page.requests.count < 50 { break }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    /// One request at a time (§11.4.5). `processChatJoinRequests` — everyone on a link at once —
    /// exists and is deliberately not exposed.
    func decide(chatId: Int64, userId: Int64, approve: Bool) async throws {
        _ = try await api.processChatJoinRequest(approve: approve, chatId: chatId, userId: userId)
    }

    // MARK: §11.4.6 Join by link, requester's side

    /// `getInternalLinkType` proceeds only on `internalLinkTypeChatInvite`; then
    /// `checkChatInviteLink` is the preview — what a non-member is shown, and all they are shown.
    func preview(_ input: String) async throws -> InvitePreview? {
        guard let link = InviteLink.normalise(input) else { return nil }
        guard let kind = try? await api.getInternalLinkType(link: link),
              case .internalLinkTypeChatInvite = kind else { return nil }
        let info = try await api.checkChatInviteLink(inviteLink: link)
        return InvitePreview(invite: link, title: info.title, photo: Mapping.photoRef(info.photo),
                             memberCount: info.memberCount, isPublic: info.isPublic,
                             createsJoinRequest: info.createsJoinRequest, chatId: info.chatId)
    }

    func ask(_ preview: InvitePreview) async throws -> AskResult {
        switch try await api.joinChatByInviteLink(inviteLink: preview.invite) {
        case .chatJoinResultRequestSent:
            update { $0.recordPending(invite: preview.invite, title: preview.title, photo: preview.photo) }
            return .requestSent
        case .chatJoinResultSuccess(let s):
            update { $0.clearPending(invite: preview.invite) }
            return .joined(chatId: s.chatId)
        case .chatJoinResultGuardBotApprovalRequired, .chatJoinResultDeclined:
            return .needsBot
        }
    }

    func forget(invite: String) { update { $0.clearPending(invite: invite) } }

    // MARK: §11.4.7 Waiting

    /// Re-runs `checkChatInviteLink` for every pending entry: a non-zero `chat_id` means approved
    /// (td_api.tl 2653, and no other signal). Returns the entries that were approved, now cleared.
    /// A declined request looks exactly like an unanswered one, forever.
    func checkPending() async -> [PendingRequest] {
        var approved: [PendingRequest] = []
        for entry in record.pending {
            guard let info = try? await api.checkChatInviteLink(inviteLink: entry.invite), info.chatId != 0 else { continue }
            approved.append(entry)
            update { $0.clearPending(invite: entry.invite) }
        }
        return approved
    }

    // MARK: §11.4.8 Read a private channel

    /// `getChat` keyed on the chat id — the same call §4.5 makes, which never asked whether the
    /// chat had a username. Nil when the reader cannot see it (left, removed, deleted).
    func feedInfo(chatId: Int64) async -> FeedInfo? {
        guard let chat = try? await api.getChat(chatId: chatId), Mapping.isChannel(chat),
              let sgId = Mapping.supergroupId(of: chat) else { return nil }
        return FeedInfo(username: "", chatId: chat.id, title: chat.title, description: "",
                        photo: Mapping.photoRef(chat.photo), fetchedAt: Date(), privateSupergroupId: sgId)
    }

    /// The live facts of a channel I own: title and photo, member count, pending request count
    /// (`chat.pending_join_requests`, td_api.tl 3596) — the numbers the Private screen shows —
    /// and `owned`: whether Telegram still lists me as its creator. `getChat` answers from the
    /// local database and keeps answering after a supergroup is deleted for everyone, so the chat
    /// being readable proves nothing; the supergroup's `status` is what changes (§11.8). Nil when
    /// the supergroup could not be read at all — unknown, never "gone".
    func channelFacts(chatId: Int64) async -> (info: FeedInfo, memberCount: Int, pendingRequests: Int, owned: Bool?)? {
        guard let chat = try? await api.getChat(chatId: chatId), Mapping.isChannel(chat),
              let sgId = Mapping.supergroupId(of: chat) else { return nil }
        let sg = try? await api.getSupergroup(supergroupId: sgId)
        let info = FeedInfo(username: "", chatId: chat.id, title: chat.title, description: "",
                            photo: Mapping.photoRef(chat.photo), fetchedAt: Date(), privateSupergroupId: sgId)
        var owned: Bool?
        if let sg {
            if case .chatMemberStatusCreator = sg.status { owned = true } else { owned = false }
        }
        return (info, sg?.memberCount ?? 0, chat.pendingJoinRequests?.totalCount ?? 0, owned)
    }

    /// A public channel's username, for an invite link that turned out to be a public channel's.
    func publicUsername(chatId: Int64) async -> String? {
        guard let chat = try? await api.getChat(chatId: chatId), let sgId = Mapping.supergroupId(of: chat),
              let sg = try? await api.getSupergroup(supergroupId: sgId) else { return nil }
        return Mapping.username(of: chat, supergroup: sg)
    }

    /// The private card in a channel, as text, and the chat's own facts. Nil when there is no pin
    /// or the pin is not a private card — a private channel with no private card is not
    /// tgsocial's and is left alone (§11.4.9).
    func privateCard(chatId: Int64) async -> (card: PrivateCard, pinnedMessageId: Int64)? {
        guard let pinned = try? await api.getChatPinnedMessage(chatId: chatId),
              case .messageText(let t) = pinned.content,
              let card = PrivateCodec.parse(t.text.text) else { return nil }
        return (card, pinned.id)
    }

    // MARK: §11.4.9 Find my private things

    /// Every channel in the main list with no username, with the reader's membership class.
    func privateChannels() async throws -> [(chat: Chat, supergroup: Supergroup)] {
        var out: [(Chat, Supergroup)] = []
        for id in try await nodes.loadMainChatList(limit: 200) {
            guard let chat = try? await api.getChat(chatId: id), Mapping.isChannel(chat),
                  let sgId = Mapping.supergroupId(of: chat),
                  let sg = try? await api.getSupergroup(supergroupId: sgId),
                  Mapping.username(of: chat, supergroup: sg) == nil else { continue }
            out.append((chat, sg))
        }
        return out
    }

    /// Recovers the record on a fresh device: the private channel I created whose card names my
    /// node is my private node; my private feeds are the links on that card, each resolved
    /// through `checkChatInviteLink` (a creator has access, so `chat_id` is non-zero).
    func recoverMine(node: String, from channels: [(chat: Chat, supergroup: Supergroup)]) async {
        guard record.privateNode == nil else { return }
        let key = Username.key(node)
        for (chat, sg) in channels {
            guard case .chatMemberStatusCreator = sg.status else { continue }
            guard let (card, pinnedId) = await privateCard(chatId: chat.id), Username.key(card.node) == key else { continue }
            var feeds: [PrivateFeedRef] = []
            for link in card.feeds {
                guard let info = try? await api.checkChatInviteLink(inviteLink: link), info.chatId != 0,
                      let feedChat = try? await api.getChat(chatId: info.chatId),
                      let feedSg = Mapping.supergroupId(of: feedChat),
                      // A link on my card that opens onto a channel I did not create is not my feed,
                      // whatever the card says — a hand-edited card, somebody's invite pasted in.
                      // Recording it would put a channel I cannot delete in front of Delete My Node
                      // (§11.4.12) and attribute it to me in every member's merge.
                      let feedSupergroup = try? await api.getSupergroup(supergroupId: feedSg),
                      case .chatMemberStatusCreator = feedSupergroup.status else { continue }
                feeds.append(PrivateFeedRef(chatId: info.chatId, supergroupId: feedSg, invite: link, title: feedChat.title))
            }
            update { r in
                r.privateNode = PrivateNodeRef(chatId: chat.id, supergroupId: sg.id, pinnedMessageId: pinnedId, invite: nil)
                r.privateFeeds = feeds
            }
            return
        }
    }

    /// Every other private card in my chat list is a private follow, verified or not (§11.3).
    /// `verify` reads the named node's public card and answers §11.3's check; it is injected
    /// because the public card comes through `NodeRepository`'s cache, which the caller owns.
    func follows(me: String?, from channels: [(chat: Chat, supergroup: Supergroup)],
                 verify: (String, Int64) async -> Bool) async -> [PrivateFollow] {
        var out: [PrivateFollow] = []
        var memberChats = Set<Int64>()
        for (chat, sg) in channels {
            switch sg.status {
            case .chatMemberStatusMember, .chatMemberStatusAdministrator, .chatMemberStatusRestricted: memberChats.insert(chat.id)
            default: continue
            }
        }
        for (chat, sg) in channels where memberChats.contains(chat.id) {
            guard let (card, pinnedId) = await privateCard(chatId: chat.id) else { continue }
            if let me, Username.key(card.node) == Username.key(me) { continue }
            let verified = await verify(card.node, sg.id)
            var feeds: [PrivateFollowFeed] = []
            for link in card.feeds {
                guard let info = try? await api.checkChatInviteLink(inviteLink: link), info.chatId != 0,
                      info.chatId != chat.id, !owns(chatId: info.chatId),
                      let feedChat = try? await api.getChat(chatId: info.chatId),
                      let feedSg = Mapping.supergroupId(of: feedChat) else { continue }
                // §11.5 lets a listed feed ride on its card's verification because the reader can
                // only be in it through that card — which is false when the link opens onto a
                // channel with a private card of its own: somebody's private node, which the reader
                // is in by THAT owner's approval. Such a channel is attributed by its own card
                // (§11.3), and a card that holds its invite does not get to re-attribute it.
                guard await privateCard(chatId: info.chatId) == nil else { continue }
                feeds.append(PrivateFollowFeed(chatId: info.chatId, supergroupId: feedSg, title: feedChat.title,
                                               photo: Mapping.photoRef(feedChat.photo), invite: link))
            }
            out.append(PrivateFollow(chatId: chat.id, supergroupId: sg.id, title: chat.title,
                                     photo: Mapping.photoRef(chat.photo), pinnedMessageId: pinnedId,
                                     card: card, verified: verified, feeds: feeds))
        }
        return out.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    // MARK: §11.4.10 Remove a member

    /// `getSupergroupMembers` — channel admins only, and a private node's owner is its creator.
    func members(supergroupId: Int64, me: Int64?) async throws -> [PrivateMember] {
        var out: [PrivateMember] = []
        var offset = 0
        var rounds = 0
        while rounds < 10 {
            rounds += 1
            let page = try await api.getSupergroupMembers(filter: .supergroupMembersFilterRecent, limit: 200, offset: offset, supergroupId: supergroupId)
            guard !page.members.isEmpty else { break }
            for m in page.members {
                guard case .messageSenderUser(let u) = m.memberId else { continue }
                let user = try? await api.getUser(userId: u.userId)
                out.append(PrivateMember(userId: u.userId, name: Self.displayName(user) ?? "Telegram user",
                                         username: user?.usernames.flatMap { Self.username($0) },
                                         joinedDate: m.joinedChatDate, photo: Self.photoRef(user?.profilePhoto),
                                         isMe: u.userId == me))
            }
            offset += page.members.count
            if page.members.count < 200 { break }
        }
        return out.sorted { $0.joinedDate > $1.joinedDate }
    }

    /// `banChatMember`: "the user will not be able to return to the group on their own using invite
    /// links, etc., unless unbanned first" — which is what the owner means by removing someone.
    func remove(chatId: Int64, userId: Int64) async throws {
        _ = try await api.banChatMember(bannedUntilDate: 0, chatId: chatId,
                                        memberId: .messageSenderUser(MessageSenderUser(userId: userId)), revokeMessages: false)
    }

    // MARK: §11.4.11 Leave

    func leave(chatId: Int64) async throws {
        _ = try await api.leaveChat(chatId: chatId)
    }

    // MARK: §11.4.12 Delete, one channel

    // `canBeDeletedForAllUsers` then `deleteChat` — the same two calls as §4.11's public deletes,
    // and made through the same seam (`ChatDeleting`, `AppModel.deletePrivateChannels`) so the
    // run's order and its outcomes are one measurable thing (`PrivateTests`). Nothing here.

    /// Whether a chat is one of the channels the record says I own.
    func owns(chatId: Int64) -> Bool {
        record.privateNode?.chatId == chatId || record.privateFeeds.contains { $0.chatId == chatId }
    }

    /// The private card rewritten from the record as it stands — after a listed feed died outside
    /// the app and left its link on the card (§11.8, the owner's side).
    func rewritePrivateCard(node: String) async throws {
        try await writePrivateCard(node: node, name: await name(ofPrivateNode: record.privateNode))
    }

    // MARK: Telegram users, as rows

    static func displayName(_ user: User?) -> String? {
        guard let user else { return nil }
        let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    static func username(_ names: Usernames) -> String? {
        if !names.editableUsername.isEmpty { return names.editableUsername }
        return names.activeUsernames.first
    }

    static func photoRef(_ photo: ProfilePhoto?) -> PhotoRef? {
        guard let photo else { return nil }
        return PhotoRef(fileId: photo.small.id, uniqueId: photo.small.remote.uniqueId,
                        width: photo.minithumbnail?.width ?? 0, height: photo.minithumbnail?.height ?? 0,
                        minithumbnail: photo.minithumbnail?.data)
    }
}
