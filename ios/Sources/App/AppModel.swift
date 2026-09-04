// App — the one observable model. Owns the TDLib client, auth state machine, navigation, toasts, and the repositories.

import Foundation
import Observation
import SwiftUI
import TDLibKit

enum AuthPhase: Equatable {
    case loading
    case phone
    case code(phone: String)
    case password(hint: String)
    case otherDevice(link: String)
    case registration
    /// A TDLib step this client does not implement (login email, premium purchase). Surfaced, never a dead end.
    case unsupported(state: String)
    case ready
    case loggingOut
}

enum Tab: String, CaseIterable, Hashable {
    case feed, explore, graph, you
    #if targetEnvironment(macCatalyst)
    /// PRODUCT §2.14: a fifth tab, present only on macOS. On iOS and Android it does not exist
    /// and the bridge is not compiled in — a phone is not a host for a local service.
    case connector
    #endif

    var label: String {
        switch self {
        case .feed: return "Feed"
        case .explore: return "Explore"
        case .graph: return "Graph"
        case .you: return "You"
        #if targetEnvironment(macCatalyst)
        case .connector: return "Connector"
        #endif
        }
    }
}

enum Route: Hashable {
    case profile(username: String)
    case feedChannel(username: String)
    case manageFeeds
    /// PRODUCT §2.20: the safety lists, contact, and the two destructive actions.
    case settings
    /// PRODUCT §2.12: the post with its comment tree.
    case thread(post: Post)
    #if targetEnvironment(macCatalyst)
    /// PRODUCT §2.14: "the answer to 'what can it see' is always one tap away".
    case connectorSources
    /// PRODUCT §2.14: the editable custom scope list.
    case connectorCustom
    #endif
}

enum Modal: Equatable {
    case compose(feed: String?)
    case editCard
    case signOut
    /// PRODUCT §2.10: opened by tapping the status pill.
    case status
    /// PRODUCT §2.12: the comment composer. It carries BOTH links — the post's and the selected
    /// comment's — so the quote's × can drop the reply target without closing and reopening.
    case comment(targeting: CommentTargeting)
    /// PRODUCT §2.12: `Delete this comment?` confirm.
    case deleteComment(Comment)
    /// PRODUCT §2.3: the long-press post sheet — Posted, Views, Feed, Open in Telegram, SAFETY.
    case postSheet(Post)
    /// PRODUCT §2.12: the same sheet for a comment, with the comment's own rows.
    case commentSheet(Comment)
    /// PRODUCT §2.15: the report confirm — the reason list and the email it sends.
    case report(ReportSubject)
    /// PRODUCT §2.16: `Block @tgs_ana?`
    case block(username: String)
    /// PRODUCT §2.21: type-the-username confirm, then the two deletes in order.
    case deleteNode
}

/// How `deleteMyNode` ended (PRODUCT §2.21, PROTOCOL §4.11). Every case but `.deleted` names what
/// is still there, because "nothing was deleted" and "your comments channel is gone" are different
/// situations and the modal has to say which one happened.
enum DeleteNodeResult: Equatable {
    case deleted
    case offline
    /// `canBeDeletedForAllUsers` is false on this channel; nothing was deleted.
    case notOwner(username: String)
    /// The comments channel failed. The node channel was not touched.
    case commentsFailed(username: String, error: String)
    /// The node failed after the comments channel went; `replies:` has been stripped from the card.
    case nodeFailed(username: String, error: String)
}

/// The fields of a supergroup that decide feed candidacy (PRODUCT §2.2): its usernames, the
/// class of my membership, and whether that membership may post. Everything else about a
/// supergroup — member counts, boosts, slow mode — can change all day without changing
/// whether the channel can be one of my feeds, so only these three are watched.
struct SupergroupCandidacy: Equatable {
    let usernames: [String]
    let status: String
    let canPost: Bool

    init(_ sg: Supergroup) {
        usernames = sg.usernames.map { [$0.editableUsername] + $0.activeUsernames } ?? []
        switch sg.status {
        case .chatMemberStatusCreator: status = "creator"; canPost = true
        case .chatMemberStatusAdministrator(let a): status = "administrator"; canPost = a.rights.canPostMessages
        case .chatMemberStatusMember: status = "member"; canPost = false
        case .chatMemberStatusRestricted: status = "restricted"; canPost = false
        case .chatMemberStatusLeft: status = "left"; canPost = false
        case .chatMemberStatusBanned: status = "banned"; canPost = false
        }
    }
}

@MainActor @Observable
final class AppModel {
    // Infrastructure
    @ObservationIgnored private(set) var td: TDClient!
    @ObservationIgnored let store = LocalStore()
    /// The block / mute / report lists and the filter every surface renders through
    /// (PRODUCT §2.18, PROTOCOL §7.1). Observable: a block repaints the app on the next render.
    let moderation: ModerationStore
    @ObservationIgnored let sends = SendTracker()
    /// Every in-flight operation registers here (PRODUCT §2.10); the pill derives from it.
    let activity = ActivityRegistry()
    let audio = AudioPlayback()
    let video = VideoCoordinator()
    @ObservationIgnored private(set) var media: MediaLoader!
    /// The audio scrubber's spectrogram strips (PRODUCT §2.11.1). Its own store because a strip
    /// outlives the row that asked for it and is shared between the feed and a thread.
    @ObservationIgnored private(set) var spectrograms: SpectrogramStore!
    @ObservationIgnored private(set) var nodes: NodeRepository!
    @ObservationIgnored private(set) var feed: FeedRepository!
    @ObservationIgnored private(set) var discovery: DiscoveryRepository!
    private(set) var comments: CommentRepository!
    #if targetEnvironment(macCatalyst)
    /// CONNECTOR.md: the local bridge and the switches that govern it. Mac only.
    private(set) var connector: ConnectorService!
    #endif

    // Auth / connection
    var auth: AuthPhase = .loading
    var connection: ConnectionState = .connectionStateConnecting
    var authError: String?
    var secretsMissing = false
    var tdlibVersion = ""
    /// The last surfaced failure, for the Status sheet (`FLOOD_WAIT 23 s at 13:58`).
    var lastError: LastError?

    // Navigation
    var tab: Tab = .feed
    var path: [Route] = []
    var modal: Modal?
    /// PRODUCT §2.21: "while the delete runs … the modal cannot be dismissed". The scrim and the
    /// binding both go through `dismissModal`, so there is one place that can refuse.
    var modalLocked = false
    /// The full-screen media viewer (PRODUCT §2.11); non-nil hides topbar and tab bar.
    var viewer: ViewerRequest?
    var toast: HPToastMessage?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Screens with their own post list (Feed channel) register here to receive live
    /// `updateNewMessage`s while they are up (PRODUCT §2.3 "inserted at the top").
    @ObservationIgnored private var messageObservers: [UUID: (Message) -> Void] = [:]

    func observeMessages(_ id: UUID, _ handler: @escaping (Message) -> Void) { messageObservers[id] = handler }
    func stopObservingMessages(_ id: UUID) { messageObservers.removeValue(forKey: id) }

    // My node
    var myNode: MyNode?
    var myCard: Card?
    /// `.newerVersion` when my pinned card carries a later protocol version (PROTOCOL §8): reads show the notice, writes refuse.
    var myCardState: CardState = .ok
    var myTitle = ""
    var myPhoto: PhotoRef?
    var setupSkipped = false
    var nodeLookupDone = false
    /// Setup stays on screen after the node is created until feeds are saved or it is skipped.
    var inSetup = false
    var me: User?

    // Feed state mirrored for views
    var posts: [Post] = []
    var feedExhausted = false
    var feedLoading = false
    var feedLoadingMore = false
    var feedReady = false
    /// The last refresh was skipped (offline) or reached no source; the cache is on screen and the next
    /// reconnect refreshes again (PRODUCT §4).
    var feedStale = false
    /// When the last feed refresh completed (Status sheet "refreshed 14:02").
    var lastFeedRefresh: Foundation.Date?
    /// When my card was last read (Status sheet "card 2 min ago").
    var myCardFetchedAt: Foundation.Date?

    // Discovery mirrored for views
    var nearby: [DirectoryEntry] = []
    var directory: [DirectoryEntry] = []
    var direct: [NodeInfo] = []
    var edges: [String: [String]] = [:]
    var exploreLoading = false

    // Feed candidates (Setup / Manage)
    var candidates: [FeedCandidate] = []
    var candidatesLoading = false
    /// A candidacy-relevant TDLib update arrived while a query was in flight; one more
    /// pass runs when it finishes (debounced), so nothing is missed and nothing loops.
    @ObservationIgnored private var candidatesDirty = false
    /// How many Setup/Manage feeds surfaces are on screen. Candidacy updates re-query
    /// live only while this is > 0 — never on a timer, never in the background.
    @ObservationIgnored private var feedsSurfaces = 0
    @ObservationIgnored private var candidatesRefreshTask: Task<Void, Never>?
    /// The one live query in flight. A second caller joins it instead of firing a second
    /// loadChats burst at Telegram; the scheduler uses it to tell "in flight" from "idle".
    @ObservationIgnored private var candidatesQuery: Task<Void, Never>?
    /// Candidacy fingerprint per supergroup id — the fields that decide whether a channel
    /// can appear in "Your feeds". Updates that do not change it (echoes of our own
    /// getChat/getSupergroup traffic, unrelated flags) never trigger a re-query.
    @ObservationIgnored private var supergroupCandidacy: [Int64: SupergroupCandidacy] = [:]
    /// Chat ids already seen via updateNewChat (channels) / updateChatPosition (main list),
    /// so only genuinely new arrivals trigger a re-query.
    @ObservationIgnored private var knownChannelChats = Set<Int64>()
    @ObservationIgnored private var mainListChats = Set<Int64>()

    // Floating bottom chrome (PRODUCT §1, §2.11)
    /// Measured height of the floating bottom chrome: the tab bar pill plus, while audio
    /// plays, the docked now-playing row and its gap. RootView reports it from the real
    /// layout; every Screen pads its scroll content by it, so the inset grows when the
    /// dock appears and shrinks back the moment playback stops.
    var bottomChromeHeight: CGFloat = 0

    @ObservationIgnored private var floodUntil: Foundation.Date?

    // MARK: Init

    init() {
        moderation = ModerationStore(store: store)
        // §2.11 both ways: a starting video pauses audio (VideoCoordinator.willPlay), and
        // starting or resuming audio pauses the audible inline video.
        audio.onWillPlay = { [weak self] in self?.video.pauseActive() }
        td = TDClient { [weak self] update in self?.handle(update) }
        // ONE decoded-pixel budget (derived in ImageCache.swift), split — not two ceilings side by
        // side. A spectrogram strip is a bitmap like any photo rendition, and the whole point of
        // that derivation is that the app's decoded pixels have a single bound; giving strips their
        // own full-size cache would quietly raise it by a quarter again. Photos get three quarters
        // because a full-width card rendition is ~5 MB against a strip's ~0.7 MB.
        let pixelBudget = ImageMemoryCache.budget(availableBytes: ImageMemoryCache.availableAppMemory())
        let stripBudget = pixelBudget / 4
        media = MediaLoader(td: td, activity: activity,
                            images: ImageMemoryCache(byteLimit: pixelBudget - stripBudget))
        spectrograms = SpectrogramStore(byteLimit: stripBudget)
        nodes = NodeRepository(td: td, store: store, sends: sends, activity: activity)
        feed = FeedRepository(td: td, store: store, nodes: nodes, sends: sends, activity: activity)
        discovery = DiscoveryRepository(td: td, nodes: nodes)
        comments = CommentRepository(td: td, store: store, nodes: nodes, sends: sends, activity: activity)
        myNode = store.load(MyNode.self, LocalStore.myNode)
        myCard = store.load(Card.self, LocalStore.myCard)
        myTitle = store.load(String.self, LocalStore.myTitle) ?? ""
        setupSkipped = store.load(Bool.self, LocalStore.setupSkipped) ?? false
        candidates = store.load([FeedCandidate].self, LocalStore.feedCandidates) ?? []
        posts = feed.posts
        if let node = myNode, let cached = nodes.cachedNode(node.username) {
            myPhoto = cached.photo
            myCardState = cached.state == .newerVersion ? .newerVersion : .ok
        }
        secretsMissing = TGSecrets.fromBundle() == nil
        #if targetEnvironment(macCatalyst)
        // Last: it reads `store` and holds this model unowned, so everything it can reach is
        // already in place by the time it exists.
        connector = ConnectorService(model: self)
        #endif
    }

    /// Called once from the scene. The bridge restores itself here rather than in `init` because
    /// binding a socket is work, and `init` runs before there is a window to report a failure in.
    func startServices() async {
        #if targetEnvironment(macCatalyst)
        await connector.restore()
        #endif
    }

    func terminate() {
        #if targetEnvironment(macCatalyst)
        connector.shutdown()
        #endif
        td.closeClients()
    }

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    // MARK: Status (PRODUCT §2.10)

    /// `Syncing` exactly while the activity registry is non-empty or TDLib is
    /// connecting/updating; `Synced` when the registry is empty and the connection is
    /// `Connected`; `Offline` while TDLib waits for network. Registry entries clear
    /// themselves on success, failure, cancellation, and after 30 s regardless
    /// (ActivityRegistry), so the pill cannot stick.
    var status: StatusKind {
        if auth != .ready { return .signedOut }
        switch connection {
        case .connectionStateWaitingForNetwork: return .offline
        case .connectionStateConnecting, .connectionStateConnectingToProxy, .connectionStateUpdating: return .syncing
        case .connectionStateReady: return activity.isEmpty ? .synced : .syncing
        }
    }

    var connectionLabel: String {
        switch connection {
        case .connectionStateReady: return "Connected"
        case .connectionStateConnecting: return "Connecting"
        case .connectionStateUpdating: return "Updating"
        case .connectionStateWaitingForNetwork: return "Waiting for network"
        case .connectionStateConnectingToProxy: return "Connecting to proxy"
        }
    }

    var telegramLabel: String {
        guard auth == .ready else { return "Signed out" }
        let phone = PhoneMask.format(me?.phoneNumber ?? "")
        return phone.isEmpty ? "Signed in" : "Signed in \u{00B7} " + phone
    }

    var nodeLabel: String {
        guard let node = myNode else { return "None" }
        guard let at = myCardFetchedAt else { return "@" + node.username }
        return "@\(node.username) \u{00B7} card \(RelativeTime.format(at))"
    }

    var feedLabel: String {
        let s = feed.sources.count
        var parts = ["\(s) source\(s == 1 ? "" : "s")", "\(posts.count) post\(posts.count == 1 ? "" : "s")"]
        if let at = lastFeedRefresh { parts.append("refreshed " + PostTime.format(at)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    var pendingLabel: String {
        let lines = activity.summary
        return lines.isEmpty ? "Nothing" : lines.joined(separator: "\n")
    }

    var lastErrorLabel: String {
        guard let e = lastError else { return "None" }
        return "\(e.text) at \(PostTime.format(e.at))"
    }

    struct LastError: Equatable {
        var text: String
        var at: Foundation.Date
    }

    func noteError(_ text: String) { lastError = LastError(text: text, at: Foundation.Date()) }

    /// Status sheet: re-runs the feed refresh and re-reads my card (PRODUCT §2.10).
    func refreshNow() async {
        await refreshMyCard()
        await refreshFeed()
    }

    var isOffline: Bool { if case .connectionStateWaitingForNetwork = connection { return true } else { return false } }

    /// Setup screen shows when signed in, no node, and the user has not skipped it — or while a setup is in progress.
    var needsSetup: Bool { auth == .ready && (inSetup || (myNode == nil && !setupSkipped && nodeLookupDone)) }

    // MARK: Toast

    func showToast(_ text: String, tone: HPToastTone = .neutral) {
        if tone == .bad { noteError(text) }
        toastTask?.cancel()
        toast = HPToastMessage(text, tone: tone)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(HPToastMessage.autoDismiss))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Update routing

    private func handle(_ update: Update) {
        sends.handle(update)
        switch update {
        case .updateAuthorizationState(let u):
            apply(authState: u.authorizationState)
        case .updateConnectionState(let u):
            connection = u.state
            if case .connectionStateReady = u.state, auth == .ready, feedStale, !feedLoading {
                Task { await refreshFeed() }
            }
        case .updateOption(let u):
            if u.name == "version", case .optionValueString(let s) = u.value { tdlibVersion = s.value }
        case .updateFile(let u):
            media.handle(file: u.file)
        case .updateNewMessage(let u):
            feed.apply(newMessage: u.message)
            posts = feed.posts
            comments.apply(newMessage: u.message)
            for handler in messageObservers.values { handler(u.message) }
        case .updateMessageSendSucceeded(let u):
            feed.apply(sent: u.message, oldMessageId: u.oldMessageId)
            posts = feed.posts
        case .updateMessageInteractionInfo(let u):
            feed.apply(interaction: u.chatId, messageId: u.messageId, info: u.interactionInfo)
            posts = feed.posts
        case .updateDeleteMessages(let u):
            if u.isPermanent, !u.fromCache {
                feed.apply(deleted: u.chatId, messageIds: u.messageIds)
                posts = feed.posts
                comments.apply(deleted: u.chatId, messageIds: u.messageIds)
            }
        case .updateChatTitle(let u):
            nodes.apply(chatId: u.chatId, title: u.title)
            if u.chatId == myNode?.chatId { myTitle = u.title }
        case .updateChatPhoto(let u):
            nodes.apply(chatId: u.chatId, photo: .some(u.photo))
            if u.chatId == myNode?.chatId { myPhoto = Mapping.photoRef(u.photo) }
        // PRODUCT §2.2 — the three updates that can change feed candidacy. Each one decides for
        // itself whether anything actually changed; only then does a re-query get scheduled.
        case .updateNewChat(let u):
            note(newChat: u.chat)
        case .updateChatPosition(let u):
            note(chatId: u.chatId, position: u.position)
        case .updateSupergroup(let u):
            note(supergroup: u.supergroup)
        default:
            break
        }
    }

    // MARK: Feed candidacy signals (PRODUCT §2.2)

    /// A channel arrived. Here a first sighting *is* the signal — a channel created in Telegram
    /// while Setup / Manage feeds is up can become a feed the moment it appears — so this
    /// re-queries. Anything that is not a channel is not a candidate and is ignored.
    private func note(newChat chat: Chat) {
        guard Mapping.isChannel(chat) else { return }
        knownChannelChats.insert(chat.id)
        // Seed the main-list baseline from the positions TDLib already handed us here. Without it the
        // first `updateChatPosition` for this channel reads as a fresh join — and ordinary message
        // traffic fires one for every channel, because order derives from the last message date — so a
        // quiet screen full of channels would trickle out a full candidate scan per channel.
        if chat.positions.contains(where: { if case .chatListMain = $0.list { return $0.order.rawValue != 0 } else { return false } }) {
            mainListChats.insert(chat.id)
        }
        scheduleCandidateRefresh()
    }

    /// Main-list membership flipped for a channel we have seen. `order` churns constantly from
    /// ordinary message traffic; only joining or leaving the list changes candidacy, so a bare
    /// reorder never re-queries.
    private func note(chatId: Int64, position: ChatPosition) {
        guard case .chatListMain = position.list, knownChannelChats.contains(chatId) else { return }
        let inList = position.order.rawValue != 0
        let flipped = inList ? mainListChats.insert(chatId).inserted : mainListChats.remove(chatId) != nil
        guard flipped else { return }
        scheduleCandidateRefresh()
    }

    /// The candidacy fingerprint changed for a supergroup we have already seen — a channel made
    /// public, a username dropped, posting rights granted or taken away. The *first* fingerprint
    /// for a supergroup is TDLib's initial sync telling us what it already knew, not a change, so
    /// it is recorded silently; that is what keeps cold start from firing hundreds of re-queries.
    private func note(supergroup sg: Supergroup) {
        let next = SupergroupCandidacy(sg)
        guard let previous = supergroupCandidacy.updateValue(next, forKey: sg.id), previous != next else { return }
        scheduleCandidateRefresh()
    }

    /// Per-session memory (Android clears it on every client attach): a new TDLib client re-announces
    /// every chat and supergroup, and those are first sightings again, not changes.
    private func resetCandidacyMemory() {
        candidatesRefreshTask?.cancel(); candidatesRefreshTask = nil
        candidatesQuery?.cancel(); candidatesQuery = nil
        candidatesDirty = false
        supergroupCandidacy = [:]
        knownChannelChats = []
        mainListChats = []
    }

    // MARK: Auth state machine (PROTOCOL §4.1)

    private func apply(authState: AuthorizationState) {
        switch authState {
        case .authorizationStateWaitTdlibParameters:
            Task { await sendParameters() }
        case .authorizationStateWaitPhoneNumber:
            auth = .phone
        case .authorizationStateWaitCode(let c):
            auth = .code(phone: c.codeInfo.phoneNumber)
        case .authorizationStateWaitPassword(let p):
            auth = .password(hint: p.passwordHint)
        case .authorizationStateWaitOtherDeviceConfirmation(let o):
            auth = .otherDevice(link: o.link)
        case .authorizationStateWaitRegistration:
            auth = .registration
            showToast("Sign up in Telegram first.", tone: .bad)
        case .authorizationStateReady:
            let wasReady = auth == .ready
            auth = .ready
            if !wasReady { Task { await onReady() } }
        case .authorizationStateLoggingOut:
            auth = .loggingOut
        case .authorizationStateClosing:
            auth = .loading
        case .authorizationStateClosed:
            auth = .loading
            resetCandidacyMemory()
            td.recreate()
        default:
            auth = .unsupported(state: Self.stateName(authState))
        }
    }

    /// TDLib's case name without its payload, e.g. `authorizationStateWaitEmailAddress`.
    static func stateName(_ state: AuthorizationState) -> String {
        let raw = String(describing: state)
        return String(raw.prefix { $0 != "(" })
    }

    private func sendParameters() async {
        guard let secrets = TGSecrets.fromBundle() else { secretsMissing = true; return }
        do { try await td.setParameters(secrets: secrets, appVersion: appVersion) }
        catch { showToast(TDFailure(error).message, tone: .bad) }
    }

    func submitPhone(_ phone: String) async {
        let trimmed = phone.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await authCall { try await self.td.api.setAuthenticationPhoneNumber(phoneNumber: trimmed, settings: nil) }
    }

    func submitCode(_ code: String) async {
        await authCall { try await self.td.api.checkAuthenticationCode(code: code.trimmingCharacters(in: .whitespaces)) }
    }

    func submitPassword(_ password: String) async {
        await authCall { try await self.td.api.checkAuthenticationPassword(password: password) }
    }

    /// TDLib accepts a new setAuthenticationPhoneNumber while waiting for a code, so going back is local.
    func useAnotherNumber() { auth = .phone }

    private func authCall(_ op: @escaping () async throws -> Ok) async {
        do { _ = try await activity.run("Signing in") { try await op() } }
        catch {
            let f = TDFailure(error)
            showToast(Self.authErrorText(f), tone: .bad)
        }
    }

    static func authErrorText(_ f: TDFailure) -> String {
        let m = f.message.uppercased()
        if let s = f.floodWaitSeconds, s > 0 { return "Too many tries. Wait a moment. (\(s) s)" }
        if m.contains("FLOOD") { return "Too many tries. Wait a moment." }
        if m.contains("PHONE_CODE_INVALID") || m.contains("CODE_INVALID") { return "That code didn't match." }
        if m.contains("PASSWORD_HASH_INVALID") || m.contains("PASSWORD_INVALID") { return "That password didn't match." }
        if m.contains("PHONE_NUMBER_INVALID") || m.contains("PHONE_NUMBER_BANNED") || m.contains("PHONE_NUMBER_FLOOD") { return "Telegram didn't accept that number." }
        return f.message
    }

    // MARK: Ready → cold start (PRODUCT §4)

    private func onReady() async {
        // No blanket counter here: each operation on this path registers itself with the
        // activity registry, so the pill reflects what is actually in flight.
        me = try? await td.api.getMe()
        // PROTOCOL §7.1: the safety lists belong to the account that wrote them. Same id, they
        // carry over a sign-out; a different id and they are replaced with empty ones, because a
        // shared device must not hand one person another person's judgement.
        if let me { moderation.adopt(userId: me.id) }
        if myNode == nil {
            if let (node, info) = try? await nodes.findMyNode() { adopt(node: node, info: info) }
        } else {
            await refreshMyCard()
        }
        nodeLookupDone = true
        await refreshFeed()
        await refreshDiscovery()
    }

    /// Re-reads my own card (PROTOCOL §4.5 "refresh on pull-to-refresh"). A card that no longer parses is
    /// left as cached rather than dropped; a newer-version card flips `myCardState`.
    private func refreshMyCard() async {
        guard let node = myNode else { return }
        do {
            let info = try await perform { try await self.nodes.readNode(username: node.username, force: true) }
            if info.state != .notANode { adopt(node: node, info: info) }
            myCardFetchedAt = info.fetchedAt
        } catch {
            if !isOffline { showToast(TDFailure(error).message, tone: .bad) }
        }
    }

    private func adopt(node: MyNode, info: NodeInfo) {
        let wasNewer = myNode != nil && myCardState == .newerVersion
        myCardFetchedAt = info.fetchedAt
        myNode = node
        myCardState = info.state == .newerVersion ? .newerVersion : .ok
        if myCardState == .ok { myCard = info.card } else { myCard = nil }
        myTitle = info.title
        myPhoto = info.photo
        store.save(node, LocalStore.myNode)
        store.save(myCard, LocalStore.myCard)
        store.save(info.title, LocalStore.myTitle)
        if myCardState == .newerVersion, !wasNewer { showToast(Self.newerCardText, tone: .bad) }
    }

    static let newerCardText = "Newer card. Update the app."

    func skipSetup() {
        inSetup = false
        setupSkipped = true
        store.save(true, LocalStore.setupSkipped)
        Task { await refreshFeed() }
    }

    func openSetup() {
        inSetup = true
        setupSkipped = false
        store.save(false, LocalStore.setupSkipped)
        tab = .feed
        path = []
    }

    // MARK: Flood-wait aware wrapper (PRODUCT §4)

    func perform<T>(_ op: @escaping () async throws -> T) async throws -> T {
        if let until = floodUntil, until > Foundation.Date() {
            try await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
        }
        do { return try await op() }
        catch {
            let f = TDFailure(error)
            if let s = f.floodWaitSeconds, s > 0 {
                showToast("Telegram asked us to wait \(s) s.", tone: .bad)
                noteError("FLOOD_WAIT \(s) s")
                floodUntil = Foundation.Date().addingTimeInterval(TimeInterval(s))
                try await Task.sleep(for: .seconds(s))
                return try await op()
            }
            throw f
        }
    }

    // MARK: Feed

    func refreshFeed() async {
        guard auth == .ready else { return }
        // Offline, reads serve cache: the cached posts are already on screen; refresh again when the network returns.
        if isOffline { feedStale = true; feedReady = true; posts = feed.posts; return }
        feedLoading = true
        defer { feedLoading = false; feedReady = true }
        do {
            try await perform {
                try await self.feed.resolveSources(me: self.myNode?.username, myFeeds: self.myCard?.feeds ?? [], follows: self.myCard?.follows ?? [])
                try await self.feed.refresh()
            }
            feedStale = false
            lastFeedRefresh = Foundation.Date()
        } catch {
            // The repository kept the cached posts; only the failure is surfaced.
            feedStale = true
            if !isOffline { showToast(TDFailure(error).message, tone: .bad) }
        }
        posts = feed.posts
        feedExhausted = feed.isExhausted
        // The comment index refreshes alongside the feed (PROTOCOL §6.3).
        await refreshComments()
    }

    func loadMoreFeed() async {
        guard !feedLoadingMore, !feedExhausted, feedReady, !isOffline else { return }
        feedLoadingMore = true; defer { feedLoadingMore = false }
        do { try await perform { try await self.feed.loadMore() } } catch {}
        posts = feed.posts
        feedExhausted = feed.isExhausted
    }

    // MARK: Discovery

    /// Graph walk + directory, through the flood-wait wrapper: a FLOOD_WAIT inside the per-chat burst toasts
    /// and backs off like every other call (PRODUCT §4); any other failure keeps the last results.
    func refreshDiscovery(force: Bool = false) async {
        guard auth == .ready, !exploreLoading else { return }
        exploreLoading = true
        defer { exploreLoading = false }
        let me = myNode?.username
        let follows = myCard?.follows ?? []
        do {
            try await perform { try await self.discovery.walk(me: me, follows: follows, force: force) }
        } catch {}
        nearby = discovery.nearby; direct = discovery.direct; edges = discovery.edges
        do {
            try await perform { try await self.discovery.loadDirectory(me: me, follows: follows) }
        } catch {}
        directory = discovery.directory
    }

    // MARK: Card writes (optimistic, rolled back with a toast)

    func isFollowing(_ username: String) -> Bool { myCard?.follows(username) ?? false }
    func isMe(_ username: String) -> Bool { myNode.map { Username.key($0.username) == Username.key(username) } ?? false }

    @discardableResult
    private func writeCard(_ next: Card) async -> Bool {
        guard let node = myNode else { showToast("Make your node first.", tone: .bad); return false }
        // PROTOCOL §8: a v1 client must not overwrite a newer card.
        guard myCardState == .ok else { showToast(Self.newerCardText, tone: .bad); return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        let previous = myCard
        myCard = next
        store.save(next, LocalStore.myCard)
        do {
            let updated = try await perform { try await self.nodes.writeCard(next, node: node) }
            myNode = updated
            store.save(updated, LocalStore.myNode)
            return true
        } catch {
            myCard = previous
            store.save(previous, LocalStore.myCard)
            let f = TDFailure(error)
            showToast(f.message == "Card is full." ? "Card is full." : "Couldn't update your card. \(f.message)", tone: .bad)
            return false
        }
    }

    func follow(_ username: String) async {
        guard let card = myCard ?? (myNode != nil ? Card() : nil) else { showToast("Make your node first.", tone: .bad); return }
        guard !card.follows(username) else { return }
        if await writeCard(card.following(username)) {
            await refreshFeed()
            await refreshDiscovery()
        }
    }

    func unfollow(_ username: String) async {
        guard let card = myCard, card.follows(username) else { return }
        if await writeCard(card.unfollowing(username)) {
            await refreshFeed()
            await refreshDiscovery()
        }
    }

    func saveFeeds(_ feeds: [String]) async -> Bool {
        let card = myCard ?? Card()
        var next = card; next.feeds = feeds
        let ok = await writeCard(next)
        if ok { await refreshFeed() }
        return ok
    }

    func editCard(name: String, bio: String, link: String) async -> Bool {
        var next = myCard ?? Card()
        next.name = name.isEmpty ? nil : name
        next.bio = bio.isEmpty ? nil : bio
        next.link = link.isEmpty ? nil : link
        return await writeCard(next)
    }

    func setPublic(_ isPublic: Bool) async {
        var next = myCard ?? Card()
        next.isPublic = isPublic
        await writeCard(next)
    }

    func announce() async {
        guard let node = myNode, myCardState == .ok, myCard?.isPublic ?? true else { return }
        if isOffline { showToast("You're offline.", tone: .bad); return }
        do {
            switch try await activity.run("Announcing", { try await self.perform { try await self.nodes.announce(node: node.username) } }) {
            case .announced: showToast("Announced.", tone: .good)
            case .alreadyAnnounced: showToast("Already announced.")
            }
        } catch { showToast(TDFailure(error).message, tone: .bad) }
    }

    // MARK: Node creation (Setup)

    var suggestedUsername: String {
        if let u = me?.usernames?.editableUsername, !u.isEmpty { return "tgs_" + u }
        if let u = me?.usernames?.activeUsernames.first, !u.isEmpty { return "tgs_" + u }
        let first = (me?.firstName ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        let digits = String(format: "%04d", Int.random(in: 0...9999))
        return "tgs_" + (first.isEmpty ? "node" : first) + digits
    }

    var suggestedTitle: String {
        let name = [me?.firstName ?? "", me?.lastName ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "tgsocial node" : name
    }

    func createNode(username: String) async -> Bool {
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        let card = Card(name: suggestedTitle, isPublic: true)
        do {
            let (node, info) = try await activity.run("Creating your node") {
                try await self.perform { try await self.nodes.createNode(username: username, title: self.suggestedTitle, card: card) }
            }
            inSetup = true
            adopt(node: node, info: info)
            await loadCandidates()
            return true
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
    }

    func findExistingNode() async {
        if isOffline { showToast("You're offline.", tone: .bad); return }
        do {
            if let (node, info) = try await perform({ try await self.nodes.findMyNode() }) {
                inSetup = needsSetup && info.state == .ok
                adopt(node: node, info: info)
                if info.state == .ok { await loadCandidates() }
                await refreshFeed()
            } else {
                showToast("No node found.")
            }
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
        }
    }

    /// You → pull-to-refresh: re-read my card when I have a node; otherwise look for one.
    func refreshYou() async {
        guard auth == .ready else { return }
        if myNode == nil { await findExistingNode(); return }
        await refreshMyCard()
        if myCardState == .ok {
            let feeds = myCard?.feeds ?? []
            if !feeds.isEmpty { _ = try? await nodes.readFeeds(feeds, force: true) }
        }
    }

    // MARK: Feed candidates (PRODUCT §2.2)

    /// Setup's feeds card and Manage feeds register while they are on screen. Candidacy updates
    /// re-query live only while at least one of them is up: with none on screen nothing runs, and
    /// opening one always re-queries anyway, so the cache is never served stale. There is no timer.
    func feedsSurfaceAppeared() { feedsSurfaces += 1 }

    func feedsSurfaceDisappeared() {
        feedsSurfaces = max(0, feedsSurfaces - 1)
        guard feedsSurfaces == 0 else { return }
        candidatesRefreshTask?.cancel()
        candidatesRefreshTask = nil
        candidatesDirty = false
    }

    /// PRODUCT §2.2 — the candidate list is never trusted stale: every open of the Setup feeds card
    /// or Manage feeds re-queries live (getCreatedPublicChats + the admin-channel scan). The cached
    /// list stays on screen while the query runs and only a success replaces it.
    ///
    /// Offline it does not query at all — reads serve cache (PRODUCT §4), same guard as createNode /
    /// findExistingNode / verifyFeed. Silent, because this is a read: no `You're offline.` toast.
    func loadCandidates() async {
        guard auth == .ready, !isOffline else { return }
        // Never two live queries at once: a second caller joins the one in flight rather than
        // firing another loadChats burst at Telegram.
        if let running = candidatesQuery { await running.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCandidatesQuery()
        }
        candidatesQuery = task
        await task.value
    }

    /// One pass. Wrapped in the activity registry so the pill reads `Syncing` while it is in flight
    /// (PRODUCT §2.10). A failure — offline, timeout, FLOOD_WAIT — leaves `candidates` alone: the
    /// card keeps showing the cache instead of blanking.
    private func runCandidatesQuery() async {
        candidatesLoading = true
        candidatesDirty = false
        defer {
            candidatesLoading = false
            candidatesQuery = nil
            // An update that landed mid-query gets exactly one more pass, debounced like any other.
            // That pass echoes nothing new (TDLib announces each chat once per session), so it sets
            // no flag and the chain stops.
            if candidatesDirty { candidatesDirty = false; scheduleCandidateRefresh() }
        }
        // `myFeedCandidates` throws on any read it could not complete, so `list` is only ever a list
        // that saw everything. A failure leaves `candidates` — and the disk cache — exactly as they were.
        if let list = try? await activity.run("Checking your channels", { try await self.nodes.myFeedCandidates(excluding: self.myNode?.chatId) }) {
            candidates = list
        }
    }

    /// A candidacy-changing update arrived. While a feeds surface is on screen, re-query live after a
    /// ~1 s debounce so a burst collapses into one query. While a query is already in flight this only
    /// marks the list dirty — the query's own loadChats traffic echoes back as these very updates, and
    /// re-querying per echo would loop.
    private func scheduleCandidateRefresh() {
        guard auth == .ready, feedsSurfaces > 0 else { return }
        guard candidatesQuery == nil else { candidatesDirty = true; return }
        candidatesRefreshTask?.cancel()
        candidatesRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.feedsSurfaces > 0 else { return }
            await self.loadCandidates()
        }
    }

    func verifyFeed(_ candidate: FeedCandidate) async -> Bool {
        guard let node = myNode else { return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        do {
            try await perform { try await self.nodes.addBacklink(feed: candidate, node: node.username) }
            if let i = candidates.firstIndex(where: { $0.id == candidate.id }) {
                candidates[i].description = Backlink.appended(to: candidate.description, node: node.username)
            }
            return true
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
    }

    // MARK: Compose (§4.9)

    func post(text: String, photoPath: String?, to feedUsername: String) async -> Bool {
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        var resolved = feed.sources[Username.key(feedUsername)] ?? nodes.cachedFeed(feedUsername)
        if resolved == nil { resolved = try? await nodes.readFeed(username: feedUsername) }
        guard let info = resolved else { showToast("Feed not found.", tone: .bad); return false }
        do {
            _ = try await activity.run("Posting") {
                try await self.perform { try await self.feed.post(text: text, photoPath: photoPath, to: info) }
            }
            posts = feed.posts
            showToast("Posted.", tone: .good)
            await refreshFeed()
            return true
        } catch {
            posts = feed.posts
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
    }

    // MARK: Comments (PROTOCOL §6, PRODUCT §2.12)

    /// The comments channels of me, my follows, and the cached +1 nodes.
    private var commentChannels: [CommentRepository.ChannelRef] {
        var refs: [CommentRepository.ChannelRef] = []
        var seen = Set<String>()
        func add(_ channel: String?, owner: String, title: String, photo: PhotoRef?, plusOne: Bool, mine: Bool) {
            guard let channel, seen.insert(Username.key(channel)).inserted else { return }
            refs.append(CommentRepository.ChannelRef(channelUsername: channel, ownerUsername: owner,
                                                     ownerTitle: title, ownerPhoto: photo,
                                                     isPlusOne: plusOne, isMine: mine))
        }
        if let node = myNode {
            add(myCard?.replies, owner: node.username,
                title: (myCard?.name?.isEmpty == false ? myCard?.name : nil) ?? myTitle,
                photo: myPhoto, plusOne: false, mine: true)
        }
        for follow in myCard?.follows ?? [] {
            guard let info = nodes.cachedNode(follow), let card = info.card else { continue }
            add(card.replies, owner: info.username, title: info.displayName, photo: info.photo, plusOne: false, mine: false)
        }
        for entry in nearby {
            guard let card = entry.node.card else { continue }
            add(card.replies, owner: entry.node.username, title: entry.node.displayName,
                photo: entry.node.photo, plusOne: true, mine: false)
        }
        return refs
    }

    /// Best-effort: a channel that cannot be read is skipped; a FLOOD_WAIT backs off like every other call.
    func refreshComments() async {
        guard auth == .ready, !isOffline else { return }
        let refs = commentChannels
        guard !refs.isEmpty else { return }
        do { try await perform { try await self.comments.refresh(channels: refs) } } catch {}
    }

    /// Thread open / pull-to-refresh (§6.3): rescan, then read deeper into channels whose scan
    /// has not reached the post's date, so comments older than the refresh window are reachable.
    func refreshComments(for post: Post) async {
        await refreshComments()
        guard auth == .ready, !isOffline else { return }
        do { try await perform { try await self.comments.deepen(untilDate: post.date) } } catch {}
    }

    /// Every t.me link that points at this post (an album has one per item).
    func commentTargets(for post: Post) -> [String] {
        var links = [post.deepLink]
        for id in post.albumMessageIds where id != post.messageId {
            links.append(DeepLink.post(username: post.sourceUsername, messageId: id))
        }
        return links
    }

    /// "Comments from your network" — the honest, serverless number (PRODUCT §2.12), through the
    /// filter: a hidden comment is not in the post footer's `N comments` (PRODUCT §2.18).
    func commentCount(for post: Post) -> Int {
        threadComments(for: post).count
    }

    func threadComments(for post: Post) -> [Comment] {
        threadComments(targets: commentTargets(for: post))
    }

    /// The comments on a chosen set of links. The Thread screen passes every album item; the
    /// carousel passes just the one it is showing, which is what "paging … re-targets the thread to
    /// that item's post" means (PRODUCT §2.12).
    func threadComments(targets: [String]) -> [Comment] {
        moderation.lists.filtered(comments: comments.comments(forTargets: targets))
    }

    // MARK: The reply target (PRODUCT §2.12)

    /// The comment a tap selected as the reply target. It lifts into the quoted line above the
    /// composer and the placeholder becomes `Reply to <name>.`; tapping the same comment again, or
    /// the quote's ×, clears it and the reply goes to the post. This is `PROTOCOL §6.2`'s `re:`
    /// chain made direct — whatever is selected here is what the written comment's first line
    /// points at, on the Thread screen and in the carousel alike.
    var replySelection: Comment?

    /// Tapping a comment toggles it, which is what makes "tapping it again clears the target" the
    /// same gesture as selecting it.
    func selectReply(_ comment: Comment) {
        replySelection = replySelection?.id == comment.id ? nil : comment
    }

    func clearReply() { replySelection = nil }

    /// Where a comment written now would point. `itemLink` is the album item the carousel is
    /// showing (PRODUCT §2.12: "paging … re-targets the thread to that item's post"); without one
    /// it is the post's own link.
    func targeting(for post: Post, itemLink: String? = nil) -> CommentTargeting {
        CommentTargeting.make(post: post, itemLink: itemLink, reply: replySelection)
    }

    /// The card's Comment button, the thread's gold action and the carousel's composer all land
    /// here: the composer opens against whatever is selected right now.
    func startComment(on post: Post, itemLink: String? = nil) {
        guard myNode != nil else { showToast("Make your node first.", tone: .bad); return }
        modal = .comment(targeting: targeting(for: post, itemLink: itemLink))
    }

    /// `Reply` on a comment targets that comment's t.me link (PRODUCT §2.12) — the same target a
    /// tap on the comment selects, so the button and the tap cannot disagree.
    func startReply(to comment: Comment, on post: Post) {
        guard myNode != nil else { showToast("Make your node first.", tone: .bad); return }
        replySelection = comment
        modal = .comment(targeting: targeting(for: post))
    }

    /// Opens the post a docked clip came from (PRODUCT §2.11: "tapping the row anywhere but its
    /// controls opens the post the audio came from").
    func openPost(_ post: Post) {
        viewer = nil
        guard path.last != .thread(post: post) else { return }
        path.append(.thread(post: post))
    }

    var suggestedRepliesUsername: String {
        (myNode?.username ?? "") + "_r"
    }

    /// First comment ever: create the channel, then add `replies:` to the card (PROTOCOL §6.4).
    func makeCommentsChannel(username: String) async -> Bool {
        guard let node = myNode, myCardState == .ok else { showToast(Self.newerCardText, tone: .bad); return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        let title = ((myCard?.name?.isEmpty == false ? myCard?.name : nil) ?? myTitle) + " comments"
        do {
            try await activity.run("Making your comments channel") {
                try await self.perform {
                    // A channel left over from an attempt whose card write failed is reused, not
                    // recreated — otherwise the orphan wedges the first-comment flow for good.
                    if await self.nodes.ownedPublicChannel(username: username) == nil {
                        try await self.comments.createChannel(username: username, node: node.username, title: title)
                    }
                }
            }
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
        var next = myCard ?? Card()
        next.replies = username
        return await writeCard(next)
    }

    /// Optimistic (PRODUCT §2.12): the repository shows the pending comment immediately and rolls
    /// it back on failure; only the failure toasts.
    func postComment(text: String, photoPath: String?, target: CommentTarget) async -> Bool {
        guard let node = myNode, let replies = myCard?.replies else { return false }
        if isOffline { showToast("You're offline.", tone: .bad); return false }
        do {
            try await activity.run("Posting") {
                try await self.perform {
                    try await self.comments.post(body: text, photoPath: photoPath, target: target,
                                                 channelUsername: replies,
                                                 ownerUsername: node.username,
                                                 ownerTitle: (self.myCard?.name?.isEmpty == false ? self.myCard?.name : nil) ?? self.myTitle,
                                                 ownerPhoto: self.myPhoto)
                }
            }
            return true
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
            return false
        }
    }

    func deleteComment(_ comment: Comment) async {
        modal = nil
        if isOffline { showToast("You're offline.", tone: .bad); return }
        do {
            try await activity.run("Deleting your comment") {
                try await self.perform { try await self.comments.delete(comment) }
            }
        } catch {
            showToast(TDFailure(error).message, tone: .bad)
        }
    }

    // MARK: Safety (PRODUCT §2.15–§2.20, PROTOCOL §7.1)

    /// The main feed, filtered. Mute applies here and only here: a muted feed stays complete on its
    /// own screen (PRODUCT §2.17).
    var visiblePosts: [Post] { moderation.lists.filtered(posts: posts, inMainFeed: true) }

    /// A single channel's posts (PRODUCT §2.6): blocked and reported drop out, muted does not.
    func visible(posts list: [Post]) -> [Post] {
        moderation.lists.filtered(posts: list, inMainFeed: false)
    }

    var visibleNearby: [DirectoryEntry] { moderation.lists.filtered(entries: nearby) }
    var visibleDirectory: [DirectoryEntry] { moderation.lists.filtered(entries: directory) }
    var visibleDirect: [NodeInfo] { moderation.lists.filtered(nodes: direct) }
    var visibleEdges: [String: [String]] { moderation.lists.filtered(edges: edges) }

    func isBlocked(_ username: String) -> Bool { moderation.isBlocked(username) }
    func isMuted(feed username: String) -> Bool { moderation.isMuted(feed: username) }

    /// PRODUCT §2.16. The card is never touched: rewriting `follows:` to enforce a block would
    /// publish the block, which is the one thing this feature promises to keep private.
    func block(_ username: String) {
        modal = nil
        moderation.block(username)
        showToast("Blocked @\(username).")
    }

    /// One tap, no confirm, here and in Settings (PRODUCT §2.16).
    func unblock(_ username: String) {
        moderation.unblock(username)
        showToast("Unblocked @\(username).")
    }

    /// PRODUCT §2.17. `title` is what the toast names — the channel's title, not its username.
    func mute(feed username: String, title: String) {
        moderation.mute(feed: username)
        showToast("Muted \(title).")
    }

    func unmute(feed username: String, title: String) {
        moderation.unmute(feed: username)
        showToast("Unmuted \(title).")
    }

    func unhide(_ item: HiddenItem) {
        moderation.unhide(key: item.key)
        showToast("Unhidden. It's back in your feed.")
    }

    /// The version line the You footer and the report email share (PRODUCT §2.15, §6), so the two
    /// cannot drift apart.
    var versionLine: String { "tgsocial \(appVersion) (\(buildNumber))" }
    /// `App:` in the report email — the same string plus the platform.
    var reportAppLine: String { versionLine + " \u{00B7} " + Self.platformName }

    #if targetEnvironment(macCatalyst)
    static let platformName = "Mac"
    #else
    static let platformName = "iOS"
    #endif

    /// PRODUCT §2.15: hiding is immediate and unconditional — it does not wait on the mail, because
    /// the app cannot know whether anything was sent and the reader has already said they do not
    /// want to see it. Only the toast depends on whether a composer opened, and it arrives when
    /// that composer closes rather than behind it (`MailLauncher`).
    func sendReport(_ subject: ReportSubject, reason: String) {
        modal = nil
        moderation.hide(key: subject.hiddenKey, reason: reason)
        MailLauncher.shared.send(to: ReportMail.to,
                                 subject: ReportMail.subject(reason: reason),
                                 body: ReportMail.body(subject: subject, reason: reason, app: reportAppLine)) { [weak self] opened in
            self?.showToast(opened ? "Reported. It's hidden here now."
                                   : "No mail app. Write to \(Moderation.contactAddress).")
        }
    }

    /// The contact address, opened as a plain composer (PRODUCT §2.19). No subject, no body: this
    /// is a person writing to a person.
    func contactByMail() {
        MailLauncher.shared.send(to: Moderation.contactAddress, subject: "", body: "") { [weak self] opened in
            guard !opened else { return }
            self?.showToast("No mail app. Write to \(Moderation.contactAddress).")
        }
    }

    /// Closing a modal goes through here so the delete-my-node run can refuse (PRODUCT §2.21).
    func dismissModal() {
        guard !modalLocked else { return }
        modal = nil
    }

    // MARK: Delete my node (PRODUCT §2.21, PROTOCOL §4.11)

    /// Comments channel first, node channel second: deleting the node first and then failing would
    /// leave a public comments channel backlinking to a node that no longer exists, with no route
    /// back to it from an app now sitting at Setup.
    ///
    /// Both ownership checks run *before* either delete. §4.11 checks each channel as it reaches
    /// it, but §2.21 promises that "not the owner" means nothing was deleted — and with the checks
    /// inline, a node I do not own would be discovered only after its comments channel was already
    /// gone. Checking both first is what makes that promise true.
    func deleteMyNode() async -> DeleteNodeResult {
        guard let node = myNode else { return .deleted }
        if isOffline { showToast("You're offline.", tone: .bad); return .offline }
        let repliesUsername = myCard?.replies
        var repliesChat: Chat?
        if let repliesUsername {
            do {
                // A card pointing at a channel that is already gone has nothing to delete; that is
                // step one being skipped, not a failure.
                repliesChat = try await nodes.publicChat(username: repliesUsername)
            } catch {
                return .commentsFailed(username: repliesUsername, error: TDFailure(error).message)
            }
            if let chat = repliesChat, !chat.canBeDeletedForAllUsers {
                return .notOwner(username: repliesUsername)
            }
        }
        do {
            let nodeChat = try await perform { try await self.td.api.getChat(chatId: node.chatId) }
            guard nodeChat.canBeDeletedForAllUsers else { return .notOwner(username: node.username) }
        } catch {
            // Nothing has been deleted yet, so this reads as the first failure it is.
            return .commentsFailed(username: node.username, error: TDFailure(error).message)
        }
        if let chat = repliesChat, let repliesUsername {
            do { try await perform { _ = try await self.td.api.deleteChat(chatId: chat.id) } }
            catch { return .commentsFailed(username: repliesUsername, error: TDFailure(error).message) }
        }
        do {
            try await perform { _ = try await self.td.api.deleteChat(chatId: node.chatId) }
        } catch {
            let message = TDFailure(error).message
            // The comments channel is gone; the card must stop pointing at it (PROTOCOL §4.4).
            if repliesChat != nil, var next = myCard {
                next.replies = nil
                await writeCard(next)
            }
            return .nodeFailed(username: node.username, error: message)
        }
        // PROTOCOL §4.11 step 3: everything §7 calls discardable goes, the session stays authorized,
        // and the client is nodeless — no logOut. The safety lists survive (LocalStore.clear).
        discardLocalState()
        nodeLookupDone = true
        modal = nil
        showToast("Your node is gone.", tone: .good)
        return .deleted
    }

    // MARK: Sign out (wipes local state)

    /// Everything PROTOCOL §7 calls discardable, in one place: sign out and delete-my-node both
    /// wipe exactly this, and only sign out also drops the session.
    private func discardLocalState() {
        store.clear()
        myNode = nil; myCard = nil; myCardState = .ok; myTitle = ""; myPhoto = nil
        setupSkipped = false; inSetup = false
        posts = []; nearby = []; directory = []; direct = []; edges = [:]; candidates = []
        feed.clear(); nodes.clear(); discovery.clear(); comments.clear()
        path = []; tab = .feed
        feedReady = false; feedStale = false; feedExhausted = false
        lastFeedRefresh = nil; myCardFetchedAt = nil
    }

    func signOut() async {
        #if targetEnvironment(macCatalyst)
        // PRODUCT §2.14: signing out turns the bridge off and wipes the token. Before `logOut`,
        // so no request can be served against a session that is on its way out.
        connector.signOut()
        #endif
        modal = nil
        viewer = nil
        audio.stop()
        auth = .loggingOut
        _ = try? await td.api.logOut()
        // The safety lists survive this by design (PROTOCOL §7.1); LocalStore.clear keeps them.
        discardLocalState()
        me = nil
        nodeLookupDone = false
        resetCandidacyMemory()
        lastError = nil
    }

    // MARK: Links

    func open(_ string: String) {
        guard let url = DeepLink.url(string) else { return }
        UIApplication.shared.open(url)
    }

    /// PRODUCT §2.6: `Copy Link` puts the public URL on the clipboard and says so.
    func copyLink(_ string: String) {
        UIPasteboard.general.string = string
        showToast("Link copied.")
    }

    #if targetEnvironment(macCatalyst)
    /// PRODUCT §2.14: `Copy` puts the token on the clipboard, toast `Token copied.`
    func copyToken(_ token: String) {
        UIPasteboard.general.string = token
        showToast("Token copied.")
    }
    #endif
}
