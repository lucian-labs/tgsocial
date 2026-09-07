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
    private let activity: ActivityRegistry

    static let pageSize = 30
    static let drainSize = 30

    private(set) var merger = FeedMerger<Post>(sourceKeys: [])
    private(set) var sources: [String: FeedInfo] = [:]
    /// Newest-first, and its head is never evicted while the reader is inside it — see `FeedWindow`
    /// for the cap, where it may be applied, and why paging must not apply it.
    private(set) var posts: [Post] = []
    private(set) var isExhausted = false
    private var forwardNames: [String: String] = [:]
    /// The inputs attribution derives from (PRODUCT §2.3), kept from the last resolveSources.
    private var myUsername: String?
    private var myFeeds: [String] = []
    private var follows: [String] = []
    /// PROTOCOL §11.5: the private sources' attribution, keyed by `c/<id>`. A verified private
    /// card's channel is attributed to the public node it names; my own private channels to me;
    /// an unverified one to nobody — the channel itself.
    private var privateOwners: [String: PrivateSource] = [:]

    init(td: TDClient, store: LocalStore, nodes: NodeRepository, sends: SendTracker, activity: ActivityRegistry) {
        self.td = td; self.store = store; self.nodes = nodes; self.sends = sends; self.activity = activity
        // Versioned (PRODUCT §2.3): a cache written by an earlier build is discarded, and whatever
        // loads is defensively re-sorted so a cached page can never paint in old order.
        posts = store.loadVersioned([Post].self, LocalStore.postCache) ?? []
        FeedOrder.sortNewestFirst(&posts)
        posts = FeedWindow.trimmed(posts)
    }

    private var api: TDLibClient { td.api }

    func clear() {
        posts = []; sources = [:]; merger = FeedMerger(sourceKeys: []); isExhausted = false
    }

    /// What goes to disk: the newest `FeedWindow.cacheSize` posts. `posts` is newest-first and
    /// nothing ever evicts its head, so its front *is* the newest — a cold start opens at the top
    /// of the feed rather than mid-history.
    private func persist() { store.saveVersioned(Array(posts.prefix(FeedWindow.cacheSize)), LocalStore.postCache) }

    // MARK: Sources

    /// Sources = my feeds ∪ feeds of every node I follow. Resolves channel info (cached). Throws only on FLOOD_WAIT.
    /// A node or channel that cannot be read live (offline, transient Telegram error) falls back to its cached
    /// record however stale it is, so the merge keeps every source it knew about (PRODUCT §4: reads serve cache).
    ///
    /// `privateSources` is §11.5's extension of §4.8's source list — my private node, my private
    /// feeds, every private node I am an approved member of and every listed feed I am in. They
    /// join the same merge under `c/<id>` keys; nothing about the merge changes.
    func resolveSources(me: String?, myFeeds: [String], follows: [String], privateSources: [PrivateSource] = []) async throws {
        myUsername = me
        self.myFeeds = myFeeds
        self.follows = follows
        privateOwners = [:]
        for p in privateSources {
            // §11.3 protects attribution, and a listed link can open onto a channel that carries
            // its own private card — another person's node, which the reader is in by THAT owner's
            // approval — or onto one of mine. Such a channel is attributed by its own entry; a card
            // that merely lists its invite never overwrites it, whichever order they arrive in.
            if p.isListed, privateOwners[p.info.key] != nil { continue }
            privateOwners[p.info.key] = p
        }
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
        for p in privateSources { next[p.info.key] = p.info }
        sources = next
        merger.setSources(Array(next.keys))
    }

    /// The private sources in the current merge — what Compose lists under `POST TO` for my own.
    var privateSources: [PrivateSource] { Array(privateOwners.values) }

    // MARK: Attribution (PRODUCT §2.3)

    /// The node a post from this feed reaches me through: me for my feeds, else the followed node
    /// whose card lists the feed (earliest in follows order), else nil — the card falls back to
    /// the channel itself. Reads cached cards; resolveSources has already fetched the follows.
    func attributionNode(forFeed feedUsername: String) -> String? {
        Attribution.node(feed: feedUsername, me: myUsername, myFeeds: myFeeds,
                         follows: follows.map { ($0, nodes.cachedNode($0)?.card?.feeds ?? []) })
    }

    /// Stamps the attribution node onto a post (PRODUCT §2.3: every post carries it).
    /// Name = the node card's `name`, falling back to `@username`; avatar = the node's photo.
    func stamped(_ post: Post) -> Post {
        var p = post
        if post.isPrivate {
            // §11.5: verified → the node the card names; mine → me; unverified → the channel.
            let owner = privateOwners[post.sourceKey]
            let username = owner?.isMine == true ? myUsername : owner?.owner
            guard let username else {
                p.authorUsername = nil; p.authorName = nil; p.authorPhoto = nil
                return p
            }
            let node = nodes.cachedNode(username)
            let cardName = node?.card?.name
            p.authorUsername = username
            p.authorName = (cardName?.isEmpty == false ? cardName : nil) ?? "@" + username
            p.authorPhoto = node?.photo
            return p
        }
        guard let username = attributionNode(forFeed: post.sourceUsername) else {
            p.authorUsername = nil; p.authorName = nil; p.authorPhoto = nil
            return p
        }
        let node = nodes.cachedNode(username)
        let cardName = node?.card?.name
        p.authorUsername = username
        p.authorName = (cardName?.isEmpty == false ? cardName : nil) ?? "@" + username
        p.authorPhoto = node?.photo
        return p
    }

    private func stamped(_ posts: [Post]) -> [Post] { posts.map { stamped($0) } }

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
        // Albums fold into single posts; the result is strictly newest first (FeedOrder).
        var out = stamped(Mapping.posts(collected, source: source))
        for i in out.indices {
            out[i].forwardedFrom = await forwardName(for: out[i])
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
        let page = try await activity.run(Self.loadingLabel(source)) {
            try await self.fetchPage(source: source, fromMessageId: cursor)
        }
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
        // Committing: the window is rebuilt from the top. This is one of the two points where the
        // `FeedWindow` cap may be applied at all (the other is the cold-start load in `init`) —
        // nothing is scrolled into a list that is being replaced wholesale.
        posts = FeedWindow.trimmed(merger.drain(Self.drainSize))
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
        // Keeps the list strictly newest-first when a page lands on top of posts served from cache.
        FeedOrder.sortNewestFirst(&posts)
        coalesceAlbums()
        // The window is deliberately *not* bounded here. "Load more" only ever runs with the
        // viewport near the tail, and dropping entries above it shifts the content under an offset
        // the app cannot re-anchor: the reader is thrown forward by the number of cards dropped,
        // which lands them at the tail again and re-triggers this very call — paging that never
        // stops. See `FeedWindow`; the cap belongs to refresh and cold start, and the post structs
        // were never the memory term that mattered.
        isExhausted = merger.isExhausted
        persist()
    }

    /// An album can straddle a page boundary: after a sort its parts sit adjacent, so one pass folds them.
    private func coalesceAlbums() {
        var i = 0
        while i + 1 < posts.count {
            if posts[i].albumId != 0, posts[i].albumId == posts[i + 1].albumId, posts[i].chatId == posts[i + 1].chatId {
                posts[i] = Mapping.merged(posts[i], posts[i + 1])
                posts.remove(at: i + 1)
            } else {
                i += 1
            }
        }
    }

    // MARK: Single channel (Feed channel screen)

    /// Newest first, like every list of posts (PRODUCT §2.3).
    func channelPosts(_ source: FeedInfo, fromMessageId: Int64 = 0) async throws -> (posts: [Post], oldestId: Int64, exhausted: Bool) {
        try await activity.run(Self.loadingLabel(source)) {
            try await self.fetchPage(source: source, fromMessageId: fromMessageId)
        }
    }

    /// The Status sheet's pending line names a public feed by username and a private one by title
    /// — a private channel has no username to name, and the title is what its members know it by.
    static func loadingLabel(_ source: FeedInfo) -> String {
        source.isPrivate ? "Loading \(source.title)" : "Loading @\(source.username)"
    }

    /// PROTOCOL §11.8: a source the reader can no longer read — left, removed, deleted — drops
    /// from the merge with its cursor and its cached page. The safety lists keep their keys.
    func drop(sourceKey: String) {
        guard sources[sourceKey] != nil else { return }
        sources.removeValue(forKey: sourceKey)
        privateOwners.removeValue(forKey: sourceKey)
        merger.setSources(Array(sources.keys))
        posts.removeAll { $0.sourceKey == sourceKey }
        persist()
    }

    // MARK: Live updates

    /// Live posts insert at the top (PRODUCT §2.3); album parts fold into the post already on screen.
    func apply(newMessage m: Message) {
        guard let source = sources.values.first(where: { $0.chatId == m.chatId }),
              let mapped = Mapping.post(m, source: source) else { return }
        let post = stamped(mapped)
        if post.albumId != 0, let i = posts.firstIndex(where: { $0.chatId == post.chatId && $0.albumId == post.albumId }) {
            guard !posts[i].albumMessageIds.contains(post.messageId) else { return }
            posts[i] = Mapping.merged(posts[i], post)
        } else {
            guard !posts.contains(where: { $0.id == post.id }) else { return }
            posts.insert(post, at: 0)
        }
        FeedOrder.sortNewestFirst(&posts)
        persist()
    }

    func apply(sent message: Message, oldMessageId: Int64) {
        guard let source = sources.values.first(where: { $0.chatId == message.chatId }) else { return }
        posts.removeAll { $0.chatId == message.chatId && $0.messageId == oldMessageId }
        if let mapped = Mapping.post(message, source: source), !posts.contains(where: { $0.id == mapped.id }) {
            posts.insert(stamped(mapped), at: 0)
            FeedOrder.sortNewestFirst(&posts)
        }
        persist()
    }

    func apply(interaction chatId: Int64, messageId: Int64, info: MessageInteractionInfo?) {
        guard let i = posts.firstIndex(where: { $0.chatId == chatId && ($0.messageId == messageId || $0.albumMessageIds.contains(messageId)) }) else { return }
        posts[i].views = info?.viewCount ?? posts[i].views
        posts[i].reactions = (info?.reactions?.reactions ?? []).compactMap { r in
            if case .reactionTypeEmoji(let e) = r.type { return Reaction(emoji: e.emoji, count: r.totalCount) }
            return nil
        }
    }

    func apply(deleted chatId: Int64, messageIds: [Int64]) {
        let gone = Set(messageIds)
        var changed = false
        posts = posts.compactMap { p in
            guard p.chatId == chatId else { return p }
            // Album: drop only the deleted items; the post goes when nothing is left.
            if p.albumMessageIds.count > 1, p.media.count == p.albumMessageIds.count,
               p.albumMessageIds.contains(where: gone.contains) {
                var q = p
                let keep = q.albumMessageIds.indices.filter { !gone.contains(q.albumMessageIds[$0]) }
                changed = true
                guard !keep.isEmpty else { return nil }
                q.media = keep.map { q.media[$0] }
                q.albumMessageIds = keep.map { q.albumMessageIds[$0] }
                return q
            }
            if gone.contains(p.messageId) { changed = true; return nil }
            return p
        }
        // `posts` is the only source the disk cache is written from, so removing the post here is
        // enough for it not to come back on the next cold start.
        if changed { persist() }
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
        if var optimistic = Mapping.post(pending, source: feed).map({ stamped($0) }) {
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
