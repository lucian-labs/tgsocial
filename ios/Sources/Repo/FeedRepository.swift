// Repo — the main feed (PROTOCOL.md §4.8) and posting (§4.9). k-way merge by date with per-source cursors.
// Strictly chronological; there is no ranking code anywhere in this file.

import Foundation
import TDLibKit

@MainActor
final class FeedRepository {
    private let td: TDClient
    private let store: LocalStore
    private let nodes: NodeRepository
    private let sends: SendTracker

    static let pageSize = 30
    static let drainSize = 30

    private(set) var merger = FeedMerger<Post>(sourceKeys: [])
    private(set) var sources: [String: FeedInfo] = [:]
    private(set) var posts: [Post] = []
    private(set) var isExhausted = false
    private var forwardNames: [String: String] = [:]

    init(td: TDClient, store: LocalStore, nodes: NodeRepository, sends: SendTracker) {
        self.td = td; self.store = store; self.nodes = nodes; self.sends = sends
        posts = store.load([Post].self, LocalStore.postCache) ?? []
    }

    private var api: TDLibClient { td.api }

    func clear() { posts = []; sources = [:]; merger = FeedMerger(sourceKeys: []); isExhausted = false }

    private func persist() { store.save(Array(posts.prefix(60)), LocalStore.postCache) }

    // MARK: Sources

    /// Sources = my feeds ∪ feeds of every node I follow. Resolves channel info (cached). Throws only on FLOOD_WAIT.
    /// A node or channel that cannot be read live (offline, transient Telegram error) falls back to its cached
    /// record however stale it is, so the merge keeps every source it knew about (PRODUCT §4: reads serve cache).
    func resolveSources(myFeeds: [String], follows: [String]) async throws {
        var usernames = myFeeds
        var followed: [String: NodeInfo] = [:]
        for n in try await nodes.readNodes(follows) { followed[n.key] = n }
        for f in follows {
            let node = followed[Username.key(f)] ?? nodes.cachedNode(f)
            usernames += node?.card?.feeds ?? []
        }
        var seen = Set<String>()
        let unique = usernames.filter { seen.insert(Username.key($0)).inserted }
        var next: [String: FeedInfo] = [:]
        for f in try await nodes.readFeeds(unique) { next[f.key] = f }
        for u in unique where next[Username.key(u)] == nil {
            if let cached = nodes.cachedFeed(u) ?? sources[Username.key(u)] { next[cached.key] = cached }
        }
        sources = next
        merger.setSources(Array(next.keys))
    }

    // MARK: Fetching

    /// One page from a source, repeating while TDLib returns fewer than requested (it serves cache first).
    private func fetchPage(source: FeedInfo, fromMessageId: Int64) async throws -> (posts: [Post], oldestId: Int64, exhausted: Bool) {
        var collected: [Message] = []
        var from = fromMessageId
        var attempts = 0
        var exhausted = false
        while collected.count < Self.pageSize, attempts < 6 {
            attempts += 1
            let page = try await api.getChatHistory(chatId: source.chatId, fromMessageId: from, limit: Self.pageSize, offset: 0, onlyLocal: false)
            let messages = page.messages ?? []
            if messages.isEmpty { exhausted = true; break }
            collected += messages
            guard let next = messages.map(\.id).min(), from == 0 || next < from else { break }
            from = next
        }
        let oldest = collected.map(\.id).min() ?? fromMessageId
        var out: [Post] = []
        for m in collected {
            guard var p = Mapping.post(m, source: source) else { continue }
            p.forwardedFrom = await forwardName(for: p)
            out.append(p)
        }
        return (out, oldest, exhausted)
    }

    private func forwardName(for post: Post) async -> String? {
        if let name = post.forwardedFrom { return name }
        if let chatId = post.forwardedChatId {
            let key = "c\(chatId)"
            if let hit = forwardNames[key] { return hit }
            if let chat = try? await api.getChat(chatId: chatId) { forwardNames[key] = chat.title; return chat.title }
            return nil
        }
        if let userId = post.forwardedUserId {
            let key = "u\(userId)"
            if let hit = forwardNames[key] { return hit }
            if let user = try? await api.getUser(userId: userId) {
                let name = [user.firstName, user.lastName].filter { !$0.isEmpty }.joined(separator: " ")
                forwardNames[key] = name; return name
            }
        }
        return nil
    }

    private func refill(_ key: String) async throws {
        guard let source = sources[key] else { merger.add([], to: key, exhausted: true); return }
        let cursor = merger.cursor(for: key)
        let page = try await fetchPage(source: source, fromMessageId: cursor)
        let stuck = cursor != 0 && page.oldestId >= cursor
        merger.add(page.posts, to: key, oldestFetchedId: page.oldestId, exhausted: page.exhausted || stuck)
    }

    /// Full refresh: reset cursors, fetch the first page of every source concurrently, merge.
    ///
    /// The result is committed only when at least one source actually fetched. When every source failed
    /// (offline cold start, transient Telegram errors) the cached posts stay exactly as they are, nothing is
    /// persisted, the cursors stay unfetched so "Load more" retries, and the failure is rethrown for the caller
    /// to surface (PRODUCT §4: never a blank screen behind a spinner if there is a cache).
    func refresh() async throws {
        merger.reset()
        isExhausted = false
        let keys = merger.sourceKeys
        var failures: [Swift.Error] = []
        await withTaskGroup(of: Swift.Error?.self) { group in
            for k in keys {
                group.addTask { @MainActor [weak self] in
                    do { try await self?.refill(k); return nil } catch { return error }
                }
            }
            for await failure in group { if let failure { failures.append(failure) } }
        }
        let fetched = keys.filter { merger.sources[$0]?.fetchedOnce ?? false }
        if fetched.isEmpty, !keys.isEmpty {
            // Nothing reached Telegram: keep the cache, leave every source unfetched, report the first failure
            // (a FLOOD_WAIT wins so the caller backs off and retries).
            throw failures.first(where: TDFailure.isFloodWait) ?? failures.first ?? TDFailure(code: 500, message: "Couldn't reach Telegram.")
        }
        // With a partial result, the sources that failed are treated as exhausted for this merge so the
        // ones that did fetch can be shown; the next refresh retries them.
        for k in keys where !(merger.sources[k]?.fetchedOnce ?? true) { merger.add([], to: k, exhausted: true) }
        posts = merger.drain(Self.drainSize)
        isExhausted = merger.isExhausted
        if posts.isEmpty, !isExhausted { try await loadMore() }
        persist()
    }

    /// "Load more": refill the source whose buffer is empty and whose last-known item was newest, then continue the merge.
    func loadMore() async throws {
        guard !isExhausted else { return }
        var rounds = 0
        var batch: [Post] = []
        while batch.count < Self.drainSize, rounds < 8 {
            rounds += 1
            if let key = merger.sourceToRefill { try await refill(key) }
            batch += merger.drain(Self.drainSize - batch.count)
            if merger.isExhausted { break }
            if merger.sourceToRefill == nil, !merger.canEmit { break }
        }
        let known = Set(posts.map(\.id))
        posts += batch.filter { !known.contains($0.id) }
        // Keeps the list strictly chronological when a page lands on top of posts served from cache.
        posts.sort { $0.date != $1.date ? $0.date > $1.date : $0.messageId > $1.messageId }
        isExhausted = merger.isExhausted
        persist()
    }

    // MARK: Single channel (Feed channel screen)

    func channelPosts(_ source: FeedInfo, fromMessageId: Int64 = 0) async throws -> (posts: [Post], oldestId: Int64, exhausted: Bool) {
        try await fetchPage(source: source, fromMessageId: fromMessageId)
    }

    // MARK: Live updates

    func apply(newMessage m: Message) {
        guard let source = sources.values.first(where: { $0.chatId == m.chatId }), let post = Mapping.post(m, source: source) else { return }
        guard !posts.contains(where: { $0.id == post.id }) else { return }
        posts.insert(post, at: 0)
        posts.sort { $0.date != $1.date ? $0.date > $1.date : $0.messageId > $1.messageId }
        persist()
    }

    func apply(sent message: Message, oldMessageId: Int64) {
        guard let source = sources.values.first(where: { $0.chatId == message.chatId }) else { return }
        posts.removeAll { $0.chatId == message.chatId && $0.messageId == oldMessageId }
        if let post = Mapping.post(message, source: source), !posts.contains(where: { $0.id == post.id }) {
            posts.insert(post, at: 0)
            posts.sort { $0.date != $1.date ? $0.date > $1.date : $0.messageId > $1.messageId }
        }
        persist()
    }

    func apply(interaction chatId: Int64, messageId: Int64, info: MessageInteractionInfo?) {
        guard let i = posts.firstIndex(where: { $0.chatId == chatId && $0.messageId == messageId }) else { return }
        posts[i].views = info?.viewCount ?? posts[i].views
        posts[i].reactions = (info?.reactions?.reactions ?? []).compactMap { r in
            if case .reactionTypeEmoji(let e) = r.type { return Reaction(emoji: e.emoji, count: r.totalCount) }
            return nil
        }
    }

    func apply(deleted chatId: Int64, messageIds: [Int64]) {
        let gone = Set(messageIds)
        let before = posts.count
        posts.removeAll { $0.chatId == chatId && gone.contains($0.messageId) }
        if posts.count != before { persist() }
    }

    // MARK: §4.9 Post

    /// Sends text (and optionally a photo) into one of my feeds. Returns the confirmed message.
    func post(text: String, photoPath: String?, to feed: FeedInfo) async throws -> Message {
        let formatted = FormattedText(entities: [], text: text)
        let content: InputMessageContent
        if let photoPath {
            let photo = InputPhoto(addedStickerFileIds: [], height: 0, photo: .inputFileLocal(InputFileLocal(path: photoPath)), thumbnail: nil, video: nil, width: 0)
            content = .inputMessagePhoto(InputMessagePhoto(caption: formatted, hasSpoiler: false, photo: photo, selfDestructType: nil, showCaptionAboveMedia: false))
        } else {
            content = .inputMessageText(InputMessageText(clearDraft: true, linkPreviewOptions: nil, text: formatted))
        }
        let pending = try await api.sendMessage(chatId: feed.chatId, inputMessageContent: content, options: nil, replyMarkup: nil, replyTo: nil, topicId: nil)
        if var optimistic = Mapping.post(pending, source: feed) {
            optimistic.isPending = true
            if !posts.contains(where: { $0.id == optimistic.id }) { posts.insert(optimistic, at: 0) }
        }
        do {
            let sent = try await sends.awaitSent(pending.id, seconds: 60)
            apply(sent: sent, oldMessageId: pending.id)
            return sent
        } catch {
            posts.removeAll { $0.chatId == feed.chatId && $0.messageId == pending.id }
            throw error
        }
    }
}
