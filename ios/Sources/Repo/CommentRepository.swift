// Repo — the comment index (PROTOCOL.md §6.3): comments channels of me + my follows + cached +1,
// paged with the same getChatHistory loop as feeds, parsed as `re:` pointers, indexed by target
// link. Network-scoped by design: two users can see different comment sets. Refreshed alongside
// the feed; discardable local state.

import Foundation
import Observation
import TDLibKit

@MainActor @Observable
final class CommentRepository {
    /// One comments channel to scan, with the node it belongs to.
    struct ChannelRef: Equatable {
        var channelUsername: String
        var ownerUsername: String
        var ownerTitle: String
        var ownerPhoto: PhotoRef?
        var isPlusOne: Bool
        var isMine: Bool
    }

    @ObservationIgnored private let td: TDClient
    @ObservationIgnored private let store: LocalStore
    @ObservationIgnored private let nodes: NodeRepository
    @ObservationIgnored private let sends: SendTracker
    @ObservationIgnored private let activity: ActivityRegistry

    /// How much of each comments channel one refresh reads (newest first).
    static let historyLimit = 100
    static let pageSize = 30
    /// How much further one Thread-screen deepening pass may read per channel.
    static let deepenLimit = 1000

    /// Target key (canonical t.me link) → comments pointing at it.
    private(set) var index: [String: [Comment]] = [:]

    init(td: TDClient, store: LocalStore, nodes: NodeRepository, sends: SendTracker, activity: ActivityRegistry) {
        self.td = td; self.store = store; self.nodes = nodes; self.sends = sends; self.activity = activity
        // Versioned (PRODUCT §2.3): a comment cache written by an earlier build is discarded.
        index = store.loadVersioned([String: [Comment]].self, LocalStore.commentIndex) ?? [:]
    }

    private var api: TDLibClient { td.api }

    /// Where the last scan of a channel stopped: the paging cursor, the oldest message date it
    /// reached, and whether history ended. The Thread screen's deepening pass resumes from here.
    struct ScanPosition: Equatable {
        var from: Int64
        var oldestDate: Int
        var exhausted: Bool
    }
    @ObservationIgnored private var positions: [String: ScanPosition] = [:]

    func clear() { index = [:]; channels = []; positions = [:] }

    private func persist() { store.saveVersioned(index, LocalStore.commentIndex) }

    /// The channels of the last refresh, for routing live updates.
    private(set) var channels: [ChannelRef] = []

    // MARK: Reading (§6.3)

    /// Count for a set of target links (a post's deep link plus its album variants).
    func count(forTargets targets: [String]) -> Int {
        comments(forTargets: targets).count
    }

    /// Every comment in the thread rooted at `targets`: direct comments plus `re:` chains, deduped.
    func comments(forTargets targets: [String]) -> [Comment] {
        var keys = targets.compactMap(CommentCodec.targetKey)
        var seenKeys = Set(keys)
        var out: [Comment] = []
        var seen = Set<String>()
        while let key = keys.popLast() {
            for c in index[key] ?? [] where seen.insert(c.id).inserted {
                out.append(c)
                if let childKey = CommentCodec.targetKey(c.link), seenKeys.insert(childKey).inserted {
                    keys.append(childKey)
                }
            }
        }
        return out.sorted { $0.date != $1.date ? $0.date < $1.date : $0.messageId < $1.messageId }
    }

    /// Direct replies to one target key, oldest first.
    func replies(toKey key: String, in thread: [Comment]) -> [Comment] {
        thread.filter { $0.targetKey == key }
    }

    /// Rescans every known comments channel. Best-effort per channel; a FLOOD_WAIT propagates.
    func refresh(channels refs: [ChannelRef]) async throws {
        channels = refs
        var flood: Swift.Error?
        for ref in refs {
            do { try await scan(ref) }
            catch { if flood == nil, TDFailure.isFloodWait(error) { flood = error } }
        }
        persist()
        if let flood { throw flood }
    }

    /// One channel: page newest-first with the repeat-until-filled loop (PROTOCOL §4.8), parse `re:` lines.
    private func scan(_ ref: ChannelRef) async throws {
        let info = try await nodes.readFeed(username: ref.channelUsername)
        try await activity.run("Reading comments @\(ref.channelUsername)") {
            var pos = ScanPosition(from: 0, oldestDate: Int.max, exhausted: false)
            var fetched = 0
            var found: [Comment] = []
            while fetched < Self.historyLimit, !pos.exhausted {
                let messages = try await self.fetchBatch(chatId: info.chatId, position: &pos)
                if messages.isEmpty { break }
                fetched += messages.count
                for m in messages {
                    if let c = Self.comment(from: m, ref: ref, feed: info) { found.append(c) }
                }
            }
            // Comments below the rescan window (found by an earlier deepening pass) stay; when
            // the scan reached the end of history it covered everything, so nothing survives it.
            self.replaceChannel(ref.channelUsername, with: found,
                                keepingOlderThan: pos.exhausted ? Int.min : pos.oldestDate)
            self.positions[Username.key(ref.channelUsername)] = pos
        }
    }

    /// One newest-first batch of at least `pageSize` messages (TDLib may return short pages),
    /// advancing `position` — the cursor, the oldest date seen, and the end-of-history flag.
    private func fetchBatch(chatId: Int64, position: inout ScanPosition) async throws -> [Message] {
        var from = position.from
        var messages: [Message] = []
        var attempts = 0
        while messages.count < Self.pageSize, attempts < 6 {
            attempts += 1
            let page = try await api.getChatHistory(chatId: chatId, fromMessageId: from, limit: Self.pageSize, offset: 0, onlyLocal: false)
            let batch = page.messages ?? []
            if batch.isEmpty { break }
            messages += batch
            guard let next = batch.map(\.id).min(), from == 0 || next < from else { break }
            from = next
        }
        position.from = from
        for m in messages { position.oldestDate = min(position.oldestDate, m.date) }
        if messages.count < Self.pageSize { position.exhausted = true }
        return messages
    }

    /// Thread screen open / pull-to-refresh (PROTOCOL §6.3): channels whose refresh scan has not
    /// reached the post's date read further back, so older comments stay reachable beyond the
    /// per-refresh bound. Bounded per channel by `deepenLimit`; best-effort, FLOOD_WAIT propagates.
    func deepen(untilDate date: Int) async throws {
        var flood: Swift.Error?
        for ref in channels {
            let key = Username.key(ref.channelUsername)
            guard var pos = positions[key], !pos.exhausted, pos.oldestDate > date else { continue }
            do {
                let info = try await nodes.readFeed(username: ref.channelUsername)
                try await activity.run("Reading comments @\(ref.channelUsername)") {
                    var fetched = 0
                    var found: [Comment] = []
                    while fetched < Self.deepenLimit, !pos.exhausted, pos.oldestDate > date {
                        let messages = try await self.fetchBatch(chatId: info.chatId, position: &pos)
                        if messages.isEmpty { break }
                        fetched += messages.count
                        for m in messages {
                            if let c = Self.comment(from: m, ref: ref, feed: info) { found.append(c) }
                        }
                    }
                    self.add(found)
                }
                positions[key] = pos
            } catch { if flood == nil, TDFailure.isFloodWait(error) { flood = error } }
        }
        persist()
        if let flood { throw flood }
    }

    /// Adds comments to the index without disturbing other channels' entries; dedupes by id.
    private func add(_ comments: [Comment]) {
        for c in comments {
            guard let target = c.targetKey else { continue }
            if index[target]?.contains(where: { $0.id == c.id }) ?? false { continue }
            index[target, default: []].append(c)
        }
    }

    /// Swaps one channel's comments within the scanned window, keeping other channels' entries,
    /// my pending sends, and this channel's comments older than the window (`keepingOlderThan`).
    private func replaceChannel(_ channelUsername: String, with comments: [Comment], keepingOlderThan floor: Int) {
        let key = Username.key(channelUsername)
        var next: [String: [Comment]] = [:]
        for (target, list) in index {
            let kept = list.filter { Username.key($0.channelUsername) != key || $0.isPending || $0.date < floor }
            if !kept.isEmpty { next[target] = kept }
        }
        for c in comments {
            guard let target = c.targetKey else { continue }
            if next[target]?.contains(where: { $0.id == c.id }) ?? false { continue }
            next[target, default: []].append(c)
        }
        index = next
    }

    /// A message in a comments channel → Comment; nil when it does not carry the `re:` first line.
    static func comment(from m: Message, ref: ChannelRef, feed: FeedInfo) -> Comment? {
        var raw = ""
        var media: [PostMedia] = []
        switch m.content {
        case .messageText(let t):
            raw = t.text.text
        default:
            guard let post = Mapping.post(m, source: feed) else { return nil }
            raw = post.text.plain
            media = post.media
        }
        guard let (target, body) = CommentCodec.parse(raw) else { return nil }
        return Comment(channelUsername: ref.channelUsername, chatId: m.chatId, messageId: m.id, date: m.date,
                       target: target, body: body, media: media,
                       ownerUsername: ref.ownerUsername, ownerTitle: ref.ownerTitle, ownerPhoto: ref.ownerPhoto,
                       isPlusOne: ref.isPlusOne, isMine: ref.isMine)
    }

    /// Live insert: a new message in a known comments channel joins the index immediately.
    func apply(newMessage m: Message) {
        guard let ref = channels.first(where: { nodes.cachedFeed($0.channelUsername)?.chatId == m.chatId }),
              let info = nodes.cachedFeed(ref.channelUsername),
              let c = Self.comment(from: m, ref: ref, feed: info),
              let target = c.targetKey else { return }
        guard !(index[target]?.contains(where: { $0.id == c.id }) ?? false) else { return }
        index[target, default: []].append(c)
        persist()
    }

    func apply(deleted chatId: Int64, messageIds: [Int64]) {
        let gone = Set(messageIds)
        var changed = false
        for (target, list) in index {
            let kept = list.filter { !($0.chatId == chatId && gone.contains($0.messageId)) }
            if kept.count != list.count {
                changed = true
                if kept.isEmpty { index.removeValue(forKey: target) } else { index[target] = kept }
            }
        }
        if changed { persist() }
    }

    // MARK: Writing (§6.4)

    /// Creates the comments channel (§4.3 steps 1–2 with the `_r` username). The caller adds
    /// `replies:` to the card and retries the send.
    func createChannel(username: String, node: String, title: String) async throws {
        let chat = try await api.createNewSupergroupChat(
            description: "tgsocial v1 replies \u{00B7} @\(node)", forImport: false, isChannel: true, isForum: false,
            location: nil, messageAutoDeleteTime: 0, title: title)
        guard let sgId = Mapping.supergroupId(of: chat) else { throw TDFailure(code: 500, message: "Channel was not created.") }
        do {
            switch try await nodes.checkUsername(username, chatId: chat.id) {
            case .available: break
            case .taken: throw TDFailure(code: 400, message: "Taken")
            case .invalid: throw TDFailure(code: 400, message: "USERNAME_INVALID")
            case .tooMany: throw TDFailure(code: 400, message: "Too many public channels.")
            case .unavailable: throw TDFailure(code: 400, message: "Public channels are unavailable.")
            }
            try await api.setSupergroupUsername(supergroupId: sgId, username: username)
        } catch {
            _ = try? await api.deleteChat(chatId: chat.id)
            throw error
        }
    }

    /// Sends one comment into my comments channel with the `re:` line prepended (as text, or as
    /// the caption's first line). Optimistic: the pending comment is indexed immediately and
    /// removed when Telegram rejects the send.
    func post(body: String, photoPath: String?, target: CommentTarget, channelUsername: String,
              ownerUsername: String, ownerTitle: String, ownerPhoto: PhotoRef?) async throws {
        let info = try await nodes.readFeed(username: channelUsername)
        let serialised = CommentCodec.serialise(target: target.link, body: body)
        let formatted = FormattedText(entities: [], text: serialised)
        let content: InputMessageContent
        if let photoPath {
            let photo = InputPhoto(addedStickerFileIds: [], height: 0, photo: .inputFileLocal(InputFileLocal(path: photoPath)), thumbnail: nil, video: nil, width: 0)
            content = .inputMessagePhoto(InputMessagePhoto(caption: formatted, hasSpoiler: false, photo: photo, selfDestructType: nil, showCaptionAboveMedia: false))
        } else {
            content = .inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: NodeRepository.noPreview, text: formatted))
        }
        let pending = try await api.sendMessage(chatId: info.chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: nil, topicId: nil)
        let ref = ChannelRef(channelUsername: channelUsername, ownerUsername: ownerUsername,
                             ownerTitle: ownerTitle, ownerPhoto: ownerPhoto, isPlusOne: false, isMine: true)
        // The pending message already carries its content (the local photo), so mapping it keeps
        // a photo comment's photo visible while it posts instead of popping in on confirmation.
        var optimistic = Self.comment(from: pending, ref: ref, feed: info)
            ?? Comment(channelUsername: channelUsername, chatId: pending.chatId, messageId: pending.id,
                       date: pending.date, target: target.link, body: body, media: [],
                       ownerUsername: ownerUsername, ownerTitle: ownerTitle, ownerPhoto: ownerPhoto,
                       isPlusOne: false, isMine: true)
        optimistic.isPending = true
        if let key = optimistic.targetKey { index[key, default: []].append(optimistic) }
        do {
            let sent = try await sends.awaitSent(pending.id, seconds: 60)
            remove(chatId: pending.chatId, messageId: pending.id)
            if let c = Self.comment(from: sent, ref: ref, feed: info), let key = c.targetKey,
               !(index[key]?.contains(where: { $0.id == c.id }) ?? false) {
                index[key, default: []].append(c)
            }
            persist()
        } catch {
            remove(chatId: pending.chatId, messageId: pending.id)
            persist()
            throw error
        }
    }

    /// Deletes my comment: deletes the message in my channel (§6.2), then drops it from the index.
    func delete(_ comment: Comment) async throws {
        guard comment.isMine else { return }
        try await api.deleteMessages(chatId: comment.chatId, messageIds: [comment.messageId], revoke: true)
        remove(chatId: comment.chatId, messageId: comment.messageId)
        persist()
    }

    private func remove(chatId: Int64, messageId: Int64) {
        for (target, list) in index {
            let kept = list.filter { !($0.chatId == chatId && $0.messageId == messageId) }
            if kept.isEmpty { index.removeValue(forKey: target) } else if kept.count != list.count { index[target] = kept }
        }
    }
}
