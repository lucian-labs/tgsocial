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
        // The floating bottom chrome sits over the content (PRODUCT §1: "content scrolls under
        // it") and reports its measured height; every Screen pads its scroll content by that.
        .overlay(alignment: .bottom) { BottomChrome() }
        .onPreferenceChange(BottomChromeHeightKey.self) { [model] height in
            Task { @MainActor in model.bottomChromeHeight = height }
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
            case .postSheet(let post): PostSheetModal(post: post)
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
        }
    }
}

/// Reports the measured height of the floating bottom chrome up to the shell. A preference key
/// rather than a constant: the dock's height is whatever its type and the reader's Dynamic Type
/// setting make it, and it has to leave the inset the instant playback stops.
struct BottomChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The floating bottom chrome (PRODUCT §1, §2.11): the docked now-playing row above the floating
/// tab bar, `cardGap` above the safe-area bottom. It measures itself, so a scroll surface's bottom
/// inset is always exactly what is on screen — it grows when the dock appears and shrinks back the
/// moment playback stops. The tab bar is hidden on Sign in, on Setup, and inside full-screen
/// viewers; the dock follows the audio, so it stays docked on Setup and on pushed screens where
/// there is no tab bar under it.
struct BottomChrome: View {
    @Environment(AppModel.self) private var model

    private var showsTabs: Bool { !model.secretsMissing && model.auth == .ready && !model.needsSetup }
    private var showsDock: Bool { model.audio.current != nil }

    var body: some View {
        if model.viewer == nil, showsTabs || showsDock {
            VStack(spacing: HPTokens.Space.rowGap) {
                if let item = model.audio.current {
                    HPNowPlaying(title: item.title,
                                 elapsed: PostTime.duration(seconds: Int(model.audio.elapsed)),
                                 playing: model.audio.isPlaying) { model.audio.toggle() }
                }
                if showsTabs {
                    HPFloatingTabs(items: Tab.allCases, selected: tabSelection) { $0.label }
                }
            }
            .padding(.bottom, HPTokens.Space.cardGap)
            .padding(.horizontal, HPTokens.Space.columnSide)
            // Measurement only: a Color is hit-testable in SwiftUI, and this one sits over the
            // scroll content, so it must never swallow a tap or a drag meant for the page.
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: BottomChromeHeightKey.self, value: geo.size.height)
                }
                .allowsHitTesting(false)
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
