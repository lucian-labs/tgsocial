// Screens — Feed channel (PRODUCT.md §2.6): channel header, then its posts chronologically.

import SwiftUI
import TDLibKit

struct FeedChannelScreen: View {
    @Environment(AppModel.self) private var model
    let username: String
    @State private var feed: FeedInfo?
    @State private var posts: [Post] = []
    @State private var cursor: Int64 = 0
    @State private var exhausted = false
    @State private var loading = false
    @State private var failed = false
    @State private var observerId = UUID()

    /// Which node this channel is verified for: my node, or any cached node that lists it.
    private var verifiedFor: String? {
        guard let feed else { return nil }
        if let mine = model.myNode?.username, feed.isVerified(for: mine) { return mine }
        return model.nodes.nodes.values.first { n in n.card?.lists(feed: username) == true && feed.isVerified(for: n.username) }?.username
    }

    var body: some View {
        Screen(back: true, refresh: { await load(reset: true) }) {
            if let feed {
                VStack(alignment: .leading, spacing: 0) {
                    NodeAvatar(photo: feed.photo, size: HPTokens.Space.avatarProfile, initial: String(feed.title.prefix(1)))
                    HPH2(feed.title).padding(.top, HPTokens.Space.rowPad)
                    HPMono("@" + feed.username)
                    if !feed.description.isEmpty { HPMuted(feed.description).padding(.top, HPTokens.Space.rowGap) }
                    HStack(spacing: HPTokens.Space.rowGap) {
                        HPButton("Open in Telegram", style: .ghost, size: .small) { model.open(DeepLink.chat(username: feed.username)) }
                        if verifiedFor != nil { HPPill("Verified", tone: .gold) }
                    }
                    .padding(.top, HPTokens.Space.rowGap)
                }
                .padding(.bottom, HPTokens.Space.cardGap)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(posts) { post in
                        PostCard(post: post) { _ in }
                            .onAppear {
                                if let i = posts.firstIndex(where: { $0.id == post.id }), i >= posts.count - FeedScreen.prefetchDistance {
                                    Task { await load(reset: false) }
                                }
                            }
                    }
                    if exhausted {
                        FeedFooter(text: posts.isEmpty ? "No posts yet." : "That's everything.")
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
        .task(id: username) {
            feed = model.nodes.cachedFeed(username)
            // Live posts insert at the top while the screen is up (PRODUCT §2.3).
            model.observeMessages(observerId) { apply(live: $0) }
            await load(reset: true)
        }
        .onDisappear { model.stopObservingMessages(observerId) }
    }

    /// Mirrors FeedRepository.apply(newMessage:) for this screen's own list: album parts fold
    /// into the post already on screen; everything stays strictly newest first.
    private func apply(live m: Message) {
        guard let feed, m.chatId == feed.chatId, let post = Mapping.post(m, source: feed) else { return }
        if post.albumId != 0, let i = posts.firstIndex(where: { $0.chatId == post.chatId && $0.albumId == post.albumId }) {
            guard !posts[i].albumMessageIds.contains(post.messageId) else { return }
            posts[i] = Mapping.merged(posts[i], post)
        } else {
            guard !posts.contains(where: { $0.id == post.id }) else { return }
            posts.insert(post, at: 0)
        }
        FeedOrder.sortNewestFirst(&posts)
    }

    private func load(reset: Bool) async {
        guard !loading else { return }
        if !reset, exhausted { return }
        loading = true; defer { loading = false }
        do {
            let info = try await model.nodes.readFeed(username: username, force: reset)
            feed = info
            let from = reset ? 0 : cursor
            let page = try await model.perform { try await model.feed.channelPosts(info, fromMessageId: from) }
            if reset { posts = page.posts } else {
                let known = Set(posts.map(\.id))
                posts += page.posts.filter { !known.contains($0.id) }
            }
            exhausted = page.exhausted || (from != 0 && page.oldestId >= from)
            cursor = page.oldestId
        } catch {
            if feed == nil { failed = true }
        }
    }
}
