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
        return model.knownNodes.first { n in n.card?.lists(feed: username) == true && feed.isVerified(for: n.username) }?.username
    }

    var body: some View {
        Screen(back: true, refresh: { await load(reset: true) }) {
            if let feed {
                VStack(alignment: .leading, spacing: 0) {
                    // §2.6: avatar left; the Verified pill and the kebab menu in the top right corner.
                    HStack(alignment: .top, spacing: HPTokens.Space.rowGap) {
                        NodeAvatar(photo: feed.photo, size: HPTokens.Space.avatarProfile, initial: String(feed.title.prefix(1)))
                        Spacer(minLength: HPTokens.Space.rowGap)
                        HStack(spacing: HPTokens.Space.rowGap) {
                            if verifiedFor != nil { HPPill("Verified", tone: .gold) }
                            HPMenu(items: [
                                HPMenuItem("Open in Telegram") { model.openInTelegram(DeepLink.chat(username: feed.username)) },
                                HPMenuItem("Copy Link") { model.copyLink(PublicLink.feed(username: feed.username)) },
                                // §2.17: one tap, no confirm — it is one tap to undo in the same place.
                                model.isMuted(feed: feed.username)
                                    ? HPMenuItem("Unmute Feed") { model.unmute(feed: feed.username, title: feed.title) }
                                    : HPMenuItem("Mute Feed") { model.mute(feed: feed.username, title: feed.title) },
                            ])
                        }
                    }
                    HPH2(feed.title).padding(.top, HPTokens.Space.rowPad)
                    HPMono("@" + feed.username)
                    if !feed.description.isEmpty { HPMuted(feed.description).padding(.top, HPTokens.Space.rowGap) }
                }
                .padding(.bottom, HPTokens.Space.cardGap)
                // §2.18: blocked and reported posts drop out here too. Mute does not apply — a muted
                // feed stays complete on its own screen (§2.17).
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
        .task(id: username) {
            feed = model.feedInfo(username)
            // Live posts insert at the top while the screen is up (PRODUCT §2.3). The demo has no
            // update stream, so nothing arrives — which is the same as a quiet channel.
            model.observeMessages(observerId) { apply(live: $0) }
            await load(reset: true)
        }
        .onDisappear { model.stopObservingMessages(observerId) }
    }

    /// Mirrors FeedRepository.apply(newMessage:) for this screen's own list: album parts fold
    /// into the post already on screen; everything stays strictly newest first.
    private func apply(live m: Message) {
        guard let feed, m.chatId == feed.chatId, let mapped = Mapping.post(m, source: feed) else { return }
        let post = model.feed.stamped(mapped)
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
        guard let page = await model.loadChannel(username: username, loaded: posts.count,
                                                 cursor: cursor, reset: reset) else {
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
