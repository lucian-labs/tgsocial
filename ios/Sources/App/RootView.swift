// App — the shell (PRODUCT.md §1): backdrop, sign-in / setup / tabbed stack, the floating
// bottom tab bar, the docked now-playing row, full-screen viewers, modals, toast.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            HPBackdrop()
            content
        }
        .overlay {
            // Full-screen media viewer (PRODUCT §2.11): covers the topbar and the tab bar.
            if let request = model.viewer {
                ViewerOverlay(request: request)
                    .transition(.opacity)
            }
        }
        .animation(HPMotion.toast, value: model.viewer != nil)
        .hpModal(isPresented: Binding(get: { model.modal != nil }, set: { if !$0 { model.modal = nil } })) {
            switch model.modal {
            case .compose(let feed): ComposeModal(preselected: feed)
            case .editCard: EditCardModal()
            case .signOut: SignOutModal()
            case .status: StatusSheetModal()
            case .comment(let target): CommentComposerModal(target: target)
            case .deleteComment(let comment): DeleteCommentModal(comment: comment)
            case nil: EmptyView()
            }
        }
        .hpToastHost($model.toast)
        .environment(\.openURL, OpenURLAction { url in
            UIApplication.shared.open(url)
            return .handled
        })
        .tint(HPTokens.Colors.accent)
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        if model.secretsMissing {
            SecretsMissingScreen()
        } else if model.auth != .ready {
            SignInScreen()
        } else if model.needsSetup {
            SetupScreen()
        } else {
            NavigationStack(path: $model.path) {
                TabRoot()
                    .navigationDestination(for: Route.self) { route in
                        Group {
                            switch route {
                            case .profile(let username): NodeProfileScreen(username: username)
                            case .feedChannel(let username): FeedChannelScreen(username: username)
                            case .manageFeeds: ManageFeedsScreen()
                            case .thread(let post): ThreadScreen(post: post)
                            }
                        }
                        .background(HPBackdrop())
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
            // The floating tab bar (PRODUCT §1): hugging pill, centred, cardGap above the
            // safe-area bottom; scroll views inset under it. Hidden inside full-screen viewers;
            // present on pushed screens. Sign in and Setup render on other branches without it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.viewer == nil {
                    VStack(spacing: HPTokens.Space.rowGap) {
                        if let item = model.audio.current {
                            HPNowPlaying(title: item.title,
                                         elapsed: PostTime.duration(seconds: Int(model.audio.elapsed)),
                                         playing: model.audio.isPlaying) { model.audio.toggle() }
                        }
                        HPFloatingTabs(items: Tab.allCases, selected: tabSelection) { $0.label }
                    }
                    .padding(.bottom, HPTokens.Space.cardGap)
                    .padding(.horizontal, HPTokens.Space.columnSide)
                }
            }
        }
    }

    /// Selecting a tab pops to the tab root.
    private var tabSelection: Binding<Tab> {
        Binding(get: { model.tab }, set: { tab in
            model.tab = tab
            model.path = []
        })
    }
}

struct TabRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Group {
            switch model.tab {
            case .feed: FeedScreen()
            case .explore: ExploreScreen()
            case .graph: GraphScreen()
            case .you: YouScreen()
            }
        }
        .background(HPBackdrop())
    }
}
