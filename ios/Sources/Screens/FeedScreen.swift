// Screens — Feed (PRODUCT.md §2.3): the chronological main feed.

import SwiftUI

struct FeedScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Screen(refresh: { await model.refreshFeed() }) {
            if model.posts.isEmpty {
                if model.feedLoading && !model.feedReady {
                    FeedFooter(text: "Loading\u{2026}")
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
                    ForEach(model.posts) { post in
                        PostCard(post: post) { username in model.path.append(.feedChannel(username: username)) }
                            .onAppear {
                                // Load more when the last card is within two screens of the bottom.
                                if let i = model.posts.firstIndex(where: { $0.id == post.id }), i >= model.posts.count - Self.prefetchDistance {
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
