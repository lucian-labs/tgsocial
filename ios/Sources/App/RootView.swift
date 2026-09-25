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
                ZStack(alignment: .top) {
                    ViewerOverlay(request: request)
                        // A new opening is a new view: the page, the drag and the comments toggle live in
                        // ViewerOverlay's @State, which survives a request → request change otherwise. That
                        // change is a real path (§2.12 puts a comment's own media inside the open viewer),
                        // and without this the second viewer keeps the first one's page.
                        .id(request.openingID)
                    // §2.22: the strip persists into the viewer and the carousel — the one place
                    // the topbar hides, and the one screenshot that could be mistaken for someone's
                    // real Telegram. Under the chrome row, and hit-testing nothing: the pager owns
                    // every touch it did before.
                    if model.isDemo {
                        DemoViewerStrip()
                            .padding(.top, HPViewerChrome.height)
                            .allowsHitTesting(false)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(HPMotion.toast, value: model.viewer != nil)
        // The scrim's dismissal goes through the model so a run that must not be interrupted can
        // refuse it (PRODUCT §2.21: the delete modal is not dismissible while it runs).
        .hpModal(isPresented: Binding(get: { model.modal != nil }, set: { if !$0 { model.dismissModal() } })) {
            switch model.modal {
            case .compose(let feed): ComposeModal(preselected: feed)
            case .editCard: EditCardModal()
            case .signOut: SignOutModal()
            case .status: StatusSheetModal()
            case .comment(let targeting): CommentComposerModal(targeting: targeting)
            case .deleteComment(let comment): DeleteCommentModal(comment: comment)
            case .postSheet(let post): PostSheetModal(post: post)
            case .commentSheet(let comment): CommentSheetModal(comment: comment)
            case .report(let subject): ReportModal(subject: subject)
            case .block(let username): BlockModal(username: username)
            case .deleteNode: DeleteNodeModal()
            case .demo: DemoSheetModal()
            case .vouch(let node): VouchModal(node: node)
            case .vouchSheet(let vouch): VouchSheetModal(vouch: vouch)
            case .deleteVouch(let vouch): DeleteVouchModal(vouch: vouch)
            case .makePrivateNode: MakePrivateNodeModal()
            case .addPrivateFeed: AddPrivateFeedModal()
            case .privateInvite(let chatId, let title): PrivateInviteModal(chatId: chatId, title: title)
            case .revokeInvite(let chatId, let title): RevokeInviteModal(chatId: chatId, title: title)
            case .removeMember(let member, let chatId): RemoveMemberModal(member: member, chatId: chatId)
            case .invitePreview(let preview): InvitePreviewModal(preview: preview)
            case .leavePrivate(let follow): LeavePrivateModal(follow: follow)
            // PRODUCT §2.35–§2.40: Bluesky. Reachable only from Settings and a Bluesky post.
            case .blueskySignIn(let prefill): BlueskySignInModal(prefill: prefill)
            case .blueskySignOut: BlueskySignOutModal()
            case .blueskyLink: BlueskyLinkModal()
            case .blueskyUnlink: BlueskyUnlinkModal()
            case .blockAccount(let did, let handle): BlockAccountModal(did: did, handle: handle)
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

    /// One switch over one value (`AppModel.root`, AppSession.swift): signed in means Telegram,
    /// Bluesky or both (PRODUCT §1), and no branch here decides that for itself. The demo is `.app`
    /// — it IS the app on an invented network (§2.22), the same stack, not a second one.
    @ViewBuilder private var content: some View {
        switch model.root {
        case .secretsMissing: SecretsMissingScreen()
        case .signIn: SignInScreen(mode: .both)
        case .offer(let network): SignInScreen(mode: .offer(network))
        case .setup: SetupScreen()
        case .app: stack
        }
    }

    @ViewBuilder private var stack: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
                TabRoot()
                    .navigationDestination(for: Route.self) { route in
                        Group {
                            switch route {
                            case .profile(let username): NodeProfileScreen(username: username)
                            case .feedChannel(let username): FeedChannelScreen(username: username)
                            case .manageFeeds: ManageFeedsScreen()
                            case .settings: SettingsScreen()
                            case .telegramSignIn: TelegramSignInScreen()
                            case .thread(let post): ThreadScreen(post: post)
                            case .vouches(let node, let tag): VouchesScreen(node: node, tag: tag)
                            case .privateNode: PrivateScreen()
                            case .privateRequests: RequestsScreen()
                            case .privateChannel(let chatId): PrivateChannelScreen(chatId: chatId)
                            #if targetEnvironment(macCatalyst)
                            case .connectorSources: ConnectorSourcesScreen()
                            case .connectorCustom: ConnectorCustomScreen()
                            #endif
                            }
                        }
                        .background(HPBackdrop())
                    }
        }
        .toolbar(.hidden, for: .navigationBar)
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

    /// The same tabs in every signed-in state (PRODUCT §1: "The shell is the same in every state").
    /// Hidden on Sign in, the offer and Setup — which is exactly "the root is not the stack".
    private var showsTabs: Bool { model.root == .app }
    private var showsDock: Bool { model.audio.current != nil }

    var body: some View {
        if model.viewer == nil, showsTabs || showsDock {
            VStack(spacing: HPTokens.Space.rowGap) {
                if let item = model.audio.current {
                    // §2.11.2: the dock's mini waveform is a VIEW of the strip's analysis, so it is
                    // handed the clip's identity and nothing else — no path, no duration, nothing
                    // it could start a second analysis with.
                    HPNowPlaying(title: item.title,
                                 elapsed: PostTime.duration(seconds: Int(model.audio.elapsed)),
                                 playing: model.audio.isPlaying,
                                 onToggle: { model.audio.toggle() },
                                 // §2.11: tapping the row anywhere but its controls opens the post.
                                 onOpen: item.post.map { post in { model.openPost(post) } },
                                 playRegion: DockRegion.play) {
                        DockWaveform(key: item.key, title: item.title)
                    }
                }
                if showsTabs {
                    // PRODUCT §1: the last item is your avatar, not the word — which stays as its
                    // accessibility label and its hidden width, so the bar is no taller for it.
                    HPFloatingTabs(items: Tab.allCases, selected: tabSelection, label: { $0.label }) { tab, selected in
                        tab == .you ? AnyView(TabAvatarView(avatar: model.tabAvatar, selected: selected)) : nil
                    }
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
            #if targetEnvironment(macCatalyst)
            case .connector: ConnectorScreen()
            #endif
            }
        }
        .background(HPBackdrop())
    }
}
