// App — the shell (PRODUCT.md §1): backdrop, sign-in / setup / tabbed stack, modals, toast.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            HPBackdrop()
            content
        }
        .hpModal(isPresented: Binding(get: { model.modal != nil }, set: { if !$0 { model.modal = nil } })) {
            switch model.modal {
            case .compose(let feed): ComposeModal(preselected: feed)
            case .editCard: EditCardModal()
            case .signOut: SignOutModal()
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
                            }
                        }
                        .background(HPBackdrop())
                    }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
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
