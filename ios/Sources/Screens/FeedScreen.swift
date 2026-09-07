// Screens — Feed (PRODUCT.md §2.3): the chronological main feed.

import SwiftUI

struct FeedScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Screen(refresh: { await model.refreshFeed() }) {
            // PRODUCT §2.24: a MODE, not a fifth tab. A tab would say there are two networks and
            // there is one — the same nodes, the same follows, the same cards, read two ways. The
            // control is absent until at least one node in my follows, or I, mark a feed as work,
            // so a reader whose network has no work in it sees Feed exactly as it is today; and it
            // is visible in BOTH modes, so it is never a state someone is stuck in. When it goes
            // away again — the last work feed unfollowed, or its card not read yet — the content
            // falls back with it (`renderedFeedMode`), because a control that can vanish over a
            // column only it can leave is that state by another route.
            if model.workModeAvailable {
                HPTabs(items: FeedMode.allCases, selected: $model.feedMode, bottomPadded: false) { $0.label }
                    .padding(.bottom, HPTokens.Space.rowGap)
            }
        } content: {
            // PRODUCT §2.18: the filter is applied at render, always, with no preference behind it.
            let visible = model.feedPosts
            // `renderedFeedMode`, not `feedMode`: the stored mode outlives the network that made it
            // available, and the work column with no All/Work control above it is the one state
            // §2.24 wrote a sentence to forbid.
            if model.renderedFeedMode == .work {
                // The work column is a FILTER over §4.8's merge, so a window whose posts all come
                // from unmarked feeds is a page, not an empty network — a work feed that posts
                // monthly among daily ones lands there every time. Page on exactly as All mode
                // does, and keep the empty state for when there is genuinely nothing more to read.
                let waiting = model.feedLoading && !model.feedReady
                let more = !model.posts.isEmpty && !model.feedExhausted && !model.isOffline
                WorkModeView(posts: visible, showEmptyColumn: visible.isEmpty && !waiting && !more) { username in
                    model.path.append(.feedChannel(username: username))
                }
                if visible.isEmpty, waiting {
                    FeedFooter(text: "Loading\u{2026}")
                } else if more {
                    // "More" is more of the same merge — the mode never pages a second stream.
                    FeedFooter(text: "Loading\u{2026}")
                        .onAppear { Task { await model.loadMoreFeed() } }
                }
            } else if visible.isEmpty {
                if model.feedLoading && !model.feedReady {
                    FeedFooter(text: "Loading\u{2026}")
                } else if !model.posts.isEmpty && !model.feedExhausted && !model.isOffline {
                    // A page whose items are all filtered fetches the next one rather than
                    // rendering an empty list (§2.18).
                    FeedFooter(text: "Loading\u{2026}")
                        .onAppear { Task { await model.loadMoreFeed() } }
                } else if model.myNode == nil {
                    // PRODUCT §2.2: the skip path lands here with the §2.3 empty state linking back to Setup.
                    EmptyCard("Nothing here yet.", message: "Follow a node and their feeds show up here, newest first.",
                              action: ("Set Up", { model.openSetup() }))
                } else {
                    EmptyCard("Nothing here yet.", message: "Follow a node and their feeds show up here, newest first.",
                              action: ("Explore", { model.tab = .explore }))
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { post in
                        PostCard(post: post) { key in model.openFeed(sourceKey: key) }
                            .onAppear {
                                // Load more when the last card is within two screens of the bottom.
                                if let i = visible.firstIndex(where: { $0.id == post.id }), i >= visible.count - Self.prefetchDistance {
                                    Task { await model.loadMoreFeed() }
                                }
                            }
                    }
                    if model.feedExhausted {
                        FeedFooter(text: "That's everything.")
                    } else if !model.isOffline {
                        // Offline the cached list ends without a footer; the status pill already says why.
                        FeedFooter(text: "Loading\u{2026}")
                            .onAppear { Task { await model.loadMoreFeed() } }
                    }
                }
            }
        }
    }

    /// Roughly two screens of cards.
    static let prefetchDistance = 6
}
