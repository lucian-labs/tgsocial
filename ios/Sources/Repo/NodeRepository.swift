// Repo — nodes, cards, feeds (PROTOCOL.md §4.2–§4.7, §3). Caches parsed cards keyed by username with fetchedAt.

import Foundation
import TDLibKit

@MainActor
final class NodeRepository {
    private let td: TDClient
    private let store: LocalStore
    private let sends: SendTracker
    private let activity: ActivityRegistry

    private(set) var nodes: [String: NodeInfo] = [:]
    private(set) var feeds: [String: FeedInfo] = [:]
    /// Cache freshness window for profile reads that are not forced.
    static let staleAfter: TimeInterval = 300

    init(td: TDClient, store: LocalStore, sends: SendTracker, activity: ActivityRegistry) {
        self.td = td; self.store = store; self.sends = sends; self.activity = activity
        // Versioned (PRODUCT §2.3): caches written by an earlier build are discarded, not painted.
        nodes = store.loadVersioned([String: NodeInfo].self, LocalStore.nodeCache) ?? [:]
        feeds = store.loadVersioned([String: FeedInfo].self, LocalStore.feedCache) ?? [:]
    }

    private var api: TDLibClient { td.api }

    func persist() {
        store.saveVersioned(nodes, LocalStore.nodeCache)
        store.saveVersioned(feeds, LocalStore.feedCache)
    }

    func clear() { nodes = [:]; feeds = [:] }

    func cachedNode(_ username: String) -> NodeInfo? { nodes[Username.key(username)] }
    func cachedFeed(_ username: String) -> FeedInfo? { feeds[Username.key(username)] }

    // MARK: §4.5 Read any node

    func readNode(username: String, force: Bool = false) async throws -> NodeInfo {
        let key = Username.key(username)
        if !force, let hit = nodes[key], Foundation.Date().timeIntervalSince(hit.fetchedAt) < Self.staleAfter { return hit }
        let info = try await activity.run("Reading card @\(username)") {
            let chat = try await self.api.searchPublicChat(username: username)
            return try await self.nodeInfo(chat: chat, username: username)
        }
        nodes[key] = info
        persist()
        return info
    }

    /// Builds a NodeInfo from a chat by reading its pinned message.
    func nodeInfo(chat: Chat, username: String) async throws -> NodeInfo {
        var info = NodeInfo(username: username, chatId: chat.id, title: chat.title, card: nil,
                            state: .notANode, photo: Mapping.photoRef(chat.photo), fetchedAt: Foundation.Date())
        guard Mapping.isChannel(chat) else { return info }
        if let pinned = try? await api.getChatPinnedMessage(chatId: chat.id),
           case .messageText(let t) = pinned.content {
            switch CardCodec.parse(t.text.text) {
            case .card(let card): info.card = card; info.state = .ok
            case .newerVersion: info.state = .newerVersion
            case .notACard: info.state = .notANode
            }
        }
        return info
    }

    /// Reads several nodes concurrently. A node that fails to load is dropped, except that a FLOOD_WAIT
    /// is rethrown once the group finishes so the caller can back off (PRODUCT §4).
    func readNodes(_ usernames: [String], force: Bool = false) async throws -> [NodeInfo] {
        try await tolerantGroup(usernames) { [weak self] u in try await self?.readNode(username: u, force: force) }
    }

    /// Runs `op` for every input on the main actor; swallows ordinary failures, rethrows the first FLOOD_WAIT.
    private func tolerantGroup<T: Sendable>(_ inputs: [String], _ op: @escaping @MainActor (String) async throws -> T?) async throws -> [T] {
        try await withThrowingTaskGroup(of: Result<T?, Swift.Error>.self) { group in
            for u in inputs {
                group.addTask { @MainActor in
                    do { return .success(try await op(u)) } catch { return .failure(error) }
                }
            }
            var out: [T] = []
            var flood: Swift.Error?
            for try await result in group {
                switch result {
                case .success(let value): if let value { out.append(value) }
                case .failure(let error): if flood == nil, TDFailure.isFloodWait(error) { flood = error }
                }
            }
            if let flood { throw flood }
            return out
        }
    }

    // MARK: Feeds (channels)

    func readFeed(username: String, force: Bool = false) async throws -> FeedInfo {
        let key = Username.key(username)
        if !force, let hit = feeds[key], Foundation.Date().timeIntervalSince(hit.fetchedAt) < Self.staleAfter { return hit }
        let token = activity.begin("Loading @\(username)")
        defer { activity.end(token) }
        let chat = try await api.searchPublicChat(username: username)
        var description = ""
        if let sgId = Mapping.supergroupId(of: chat), let full = try? await api.getSupergroupFullInfo(supergroupId: sgId) {
            description = full.description
        }
        let info = FeedInfo(username: username, chatId: chat.id, title: chat.title, description: description,
                            photo: Mapping.photoRef(chat.photo), fetchedAt: Foundation.Date())
        feeds[key] = info
        persist()
        return info
    }

    /// Same tolerance rules as `readNodes`.
    func readFeeds(_ usernames: [String], force: Bool = false) async throws -> [FeedInfo] {
        try await tolerantGroup(usernames) { [weak self] u in try await self?.readFeed(username: u, force: force) }
    }

    /// Applies a live chat photo / title update to caches.
    func apply(chatId: Int64, title: String? = nil, photo: ChatPhotoInfo?? = nil) {
        for (k, var n) in nodes where n.chatId == chatId {
            if let title { n.title = title }
            if let photo { n.photo = Mapping.photoRef(photo) }
            nodes[k] = n
        }
        for (k, var f) in feeds where f.chatId == chatId {
            if let title { f.title = title }
            if let photo { f.photo = Mapping.photoRef(photo) }
            feeds[k] = f
        }
    }

    // MARK: §4.2 Find my node

    /// The first created public channel whose pinned message carries the marker. A newer-version card
    /// (PROTOCOL §8) still counts as my node — returned with `state == .newerVersion` and no parsed card —
    /// so the app says "Newer card. Update the app." instead of offering to create a second node.
    func findMyNode() async throws -> (MyNode, NodeInfo)? {
        let token = activity.begin("Looking for your node")
        defer { activity.end(token) }
        let created = try await api.getCreatedPublicChats(type: .publicChatTypeHasUsername)
        for chatId in created.chatIds {
            guard let chat = try? await api.getChat(chatId: chatId), Mapping.isChannel(chat),
                  let sgId = Mapping.supergroupId(of: chat) else { continue }
            guard let pinned = try? await api.getChatPinnedMessage(chatId: chatId),
                  case .messageText(let t) = pinned.content else { continue }
            let state: CardState
            let card: Card?
            switch CardCodec.parse(t.text.text) {
            case .card(let c): state = .ok; card = c
            case .newerVersion: state = .newerVersion; card = nil
            case .notACard: continue
            }
            let sg = try? await api.getSupergroup(supergroupId: sgId)
            guard let username = Mapping.username(of: chat, supergroup: sg) else { continue }
            let node = MyNode(chatId: chatId, supergroupId: sgId, username: username, pinnedMessageId: pinned.id)
            let info = NodeInfo(username: username, chatId: chatId, title: chat.title, card: card, state: state,
                                photo: Mapping.photoRef(chat.photo), fetchedAt: Foundation.Date())
            nodes[info.key] = info
            persist()
            return (node, info)
        }
        return nil
    }

    /// Whether I already own a public channel with this username (getCreatedPublicChats).
    /// Lets the comments-channel flow reuse a channel left over from a failed card write
    /// instead of reporting my own channel as Taken. Best-effort: nil on any API failure.
    func ownedPublicChannel(username: String) async -> Chat? {
        let key = Username.key(username)
        guard let created = try? await api.getCreatedPublicChats(type: .publicChatTypeHasUsername) else { return nil }
        for chatId in created.chatIds {
            guard let chat = try? await api.getChat(chatId: chatId),
                  let sgId = Mapping.supergroupId(of: chat),
                  let sg = try? await api.getSupergroup(supergroupId: sgId),
                  let name = Mapping.username(of: chat, supergroup: sg) else { continue }
            if Username.key(name) == key { return chat }
        }
        return nil
    }

    // MARK: §4.3 Create my node

    enum UsernameCheck: Equatable { case available, taken, invalid, tooMany, unavailable }

    func checkUsername(_ username: String, chatId: Int64 = 0) async throws -> UsernameCheck {
        switch try await api.checkChatUsername(chatId: chatId, username: username) {
        case .checkChatUsernameResultOk: return .available
        case .checkChatUsernameResultUsernameOccupied, .checkChatUsernameResultUsernamePurchasable: return .taken
        case .checkChatUsernameResultUsernameInvalid: return .invalid
        case .checkChatUsernameResultPublicChatsTooMany: return .tooMany
        case .checkChatUsernameResultPublicGroupsUnavailable: return .unavailable
        }
    }

    func createNode(username: String, title: String, card: Card) async throws -> (MyNode, NodeInfo) {
        let chat = try await api.createNewSupergroupChat(
            description: CardCodec.description(bio: card.bio), forImport: false, isChannel: true, isForum: false,
            location: nil, messageAutoDeleteTime: 0, title: title)
        guard let sgId = Mapping.supergroupId(of: chat) else { throw TDFailure(code: 500, message: "Channel was not created.") }
        let check = try await checkUsername(username, chatId: chat.id)
        if check != .available {
            _ = try? await api.deleteChat(chatId: chat.id)
            switch check {
            case .taken: throw TDFailure(code: 400, message: "Taken")
            case .invalid: throw TDFailure(code: 400, message: "USERNAME_INVALID")
            case .tooMany: throw TDFailure(code: 400, message: "Too many public channels.")
            default: throw TDFailure(code: 400, message: "Public channels are unavailable.")
            }
        }
        do {
            try await api.setSupergroupUsername(supergroupId: sgId, username: username)
        } catch {
            _ = try? await api.deleteChat(chatId: chat.id)
            throw error
        }
        let message = try await sendCardMessage(chatId: chat.id, card: card)
        try await api.pinChatMessage(chatId: chat.id, disableNotification: true, messageId: message.id, onlyForSelf: false)
        // Optional: the node wears the user's profile photo.
        if let me = try? await api.getMe(), let photo = me.profilePhoto {
            _ = try? await api.setChatPhoto(chatId: chat.id, photo: .inputChatPhotoStatic(InputChatPhotoStatic(photo: .inputFileId(InputFileId(id: photo.big.id)))))
        }
        let node = MyNode(chatId: chat.id, supergroupId: sgId, username: username, pinnedMessageId: message.id)
        let info = NodeInfo(username: username, chatId: chat.id, title: title, card: card, state: .ok,
                            photo: Mapping.photoRef(chat.photo), fetchedAt: Foundation.Date())
        nodes[info.key] = info
        persist()
        return (node, info)
    }

    private func sendCardMessage(chatId: Int64, card: Card) async throws -> Message {
        let text = FormattedText(entities: [], text: CardCodec.serialise(card))
        let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: Self.noPreview, text: text))
        let pending = try await api.sendMessage(chatId: chatId, inputMessageContent: content, options: Self.quiet, replyMarkup: nil, replyTo: nil, topicId: nil)
        return try await sends.awaitSent(pending.id)
    }

    static let noPreview = LinkPreviewOptions(forceLargeMedia: false, forceSmallMedia: false, isDisabled: true, showAboveText: false, url: "")
    static let quiet = MessageSendOptions(allowPaidBroadcast: false, disableNotification: true, effectId: 0, fromBackground: false,
                                          onlyPreview: false, paidMessageStarCount: 0, protectContent: false, schedulingState: nil,
                                          sendingId: 0, suggestedPostInfo: nil, updateOrderOfInstalledStickerSets: false)

    // MARK: §4.4 Write my card

    /// Edits the pinned card in place; re-pins if the pin was lost. Returns the (possibly updated) node pointer.
    func writeCard(_ card: Card, node: MyNode) async throws -> MyNode {
        guard !CardCodec.isFull(card) else { throw TDFailure(code: 400, message: "Card is full.") }
        let token = activity.begin("Writing your card")
        defer { activity.end(token) }
        let text = FormattedText(entities: [], text: CardCodec.serialise(card))
        let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: Self.noPreview, text: text))
        var messageId = node.pinnedMessageId
        var needsPin = false
        if let pinned = try? await api.getChatPinnedMessage(chatId: node.chatId),
           case .messageText(let t) = pinned.content, CardCodec.isCard(t.text.text) {
            messageId = pinned.id
        } else if (try? await api.getMessage(chatId: node.chatId, messageId: node.pinnedMessageId)) != nil {
            needsPin = true
        } else {
            // The card message itself is gone: the only way to restore the record is a fresh card, pinned.
            let fresh = try await sendCardMessage(chatId: node.chatId, card: card)
            try await api.pinChatMessage(chatId: node.chatId, disableNotification: true, messageId: fresh.id, onlyForSelf: false)
            return updatedNode(node, pinnedMessageId: fresh.id, card: card)
        }
        _ = try await api.editMessageText(chatId: node.chatId, inputMessageContent: content, messageId: messageId, replyMarkup: nil)
        if needsPin {
            try await api.pinChatMessage(chatId: node.chatId, disableNotification: true, messageId: messageId, onlyForSelf: false)
        }
        _ = try? await api.setChatDescription(chatId: node.chatId, description: CardCodec.description(bio: card.bio))
        return updatedNode(node, pinnedMessageId: messageId, card: card)
    }

    private func updatedNode(_ node: MyNode, pinnedMessageId: Int64, card: Card) -> MyNode {
        var n = node; n.pinnedMessageId = pinnedMessageId
        if var info = nodes[Username.key(node.username)] {
            info.card = card; info.state = .ok; info.fetchedAt = Foundation.Date()
            nodes[info.key] = info
        }
        persist()
        return n
    }

    // MARK: §4.7 My feeds

    /// Channels where I am creator or an administrator with post rights.
    func myFeedCandidates(excluding myNodeChatId: Int64?) async throws -> [FeedCandidate] {
        var ids: [Int64] = []
        if let created = try? await api.getCreatedPublicChats(type: .publicChatTypeHasUsername) { ids += created.chatIds }
        ids += await loadMainChatList(limit: 200)
        var seen = Set<Int64>()
        var out: [FeedCandidate] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            if id == myNodeChatId { continue }
            guard let chat = try? await api.getChat(chatId: id), Mapping.isChannel(chat),
                  let sgId = Mapping.supergroupId(of: chat),
                  let sg = try? await api.getSupergroup(supergroupId: sgId) else { continue }
            let canPost: Bool
            switch sg.status {
            case .chatMemberStatusCreator: canPost = true
            case .chatMemberStatusAdministrator(let a): canPost = a.rights.canPostMessages
            default: canPost = false
            }
            guard canPost else { continue }
            let username = Mapping.username(of: chat, supergroup: sg)
            var description = ""
            if username != nil, let full = try? await api.getSupergroupFullInfo(supergroupId: sgId) { description = full.description }
            out.append(FeedCandidate(chatId: id, supergroupId: sgId, title: chat.title, username: username, description: description))
        }
        out.sort { ($0.isPublic ? 0 : 1, $0.title.lowercased()) < ($1.isPublic ? 0 : 1, $1.title.lowercased()) }
        store.save(out, LocalStore.feedCandidates)
        return out
    }

    /// loadChats until TDLib answers 404 (fully loaded) or we have enough, then getChats.
    func loadMainChatList(limit: Int) async -> [Int64] {
        var rounds = 0
        while rounds < 5 {
            rounds += 1
            do {
                try await api.loadChats(chatList: .chatListMain, limit: limit)
            } catch {
                if TDFailure(error).isNotFound { break }
                break
            }
            if let ids = try? await api.getChats(chatList: .chatListMain, limit: limit).chatIds, ids.count >= limit { return ids }
        }
        return (try? await api.getChats(chatList: .chatListMain, limit: limit).chatIds) ?? []
    }

    // MARK: §3 Backlink

    func addBacklink(feed: FeedCandidate, node: String) async throws {
        let next = Backlink.appended(to: feed.description, node: node)
        guard next != feed.description else { return }
        try await api.setChatDescription(chatId: feed.chatId, description: next)
        if let username = feed.username, var f = feeds[Username.key(username)] {
            f.description = next; feeds[f.key] = f; persist()
        }
    }

    // MARK: §5.3 Index group

    /// One `node: @x` line read from @tgsocial_index.
    struct IndexEntry: Equatable {
        var node: String
        var isMine: Bool
    }

    static let indexHistoryLimit = 200

    /// The last 200 messages of @tgsocial_index parsed as `node: @x`, newest first. Nil when the group does not exist.
    func indexEntries() async throws -> (chatId: Int64, entries: [IndexEntry])? {
        guard let chat = try? await api.searchPublicChat(username: IndexGroup.username) else { return nil }
        var entries: [IndexEntry] = []
        var from: Int64 = 0
        var fetched = 0
        while fetched < Self.indexHistoryLimit {
            let page = try await api.getChatHistory(chatId: chat.id, fromMessageId: from, limit: 100, offset: 0, onlyLocal: false)
            guard let messages = page.messages, !messages.isEmpty else { break }
            fetched += messages.count
            for m in messages {
                if case .messageText(let t) = m.content, let name = IndexGroup.parse(t.text.text) {
                    entries.append(IndexEntry(node: name, isMine: m.isOutgoing))
                }
            }
            guard let next = messages.map(\.id).min(), from == 0 || next < from else { break }
            from = next
        }
        return (chat.id, entries)
    }

    enum AnnounceResult: Equatable { case announced, alreadyAnnounced }

    /// Members post one message (PROTOCOL §5.3): if my line is already in the last 200, nothing is sent.
    func announce(node: String) async throws -> AnnounceResult {
        let chat = try await api.searchPublicChat(username: IndexGroup.username)
        _ = try? await api.joinChat(chatId: chat.id)
        let key = Username.key(node)
        if let (_, entries) = try await indexEntries(), entries.contains(where: { $0.isMine && Username.key($0.node) == key }) {
            return .alreadyAnnounced
        }
        let text = FormattedText(entities: [], text: IndexGroup.announcement(node: node))
        let content = InputMessageContent.inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: Self.noPreview, text: text))
        let pending = try await api.sendMessage(chatId: chat.id, inputMessageContent: content, options: Self.quiet, replyMarkup: nil, replyTo: nil, topicId: nil)
        _ = try await sends.awaitSent(pending.id)
        return .announced
    }
}
