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
    var label: String {
        switch self {
        case .feed: return "Feed"
        case .explore: return "Explore"
        case .graph: return "Graph"
        case .you: return "You"
        }
    }
}

enum Route: Hashable {
    case profile(username: String)
    case feedChannel(username: String)
    case manageFeeds
}

enum Modal: Equatable {
    case compose(feed: String?)
    case editCard
    case signOut
}

@MainActor @Observable
final class AppModel {
    // Infrastructure
    @ObservationIgnored private(set) var td: TDClient!
    @ObservationIgnored let store = LocalStore()
    @ObservationIgnored let sends = SendTracker()
    @ObservationIgnored private(set) var media: MediaLoader!
    @ObservationIgnored private(set) var nodes: NodeRepository!
    @ObservationIgnored private(set) var feed: FeedRepository!
    @ObservationIgnored private(set) var discovery: DiscoveryRepository!

    // Auth / connection
    var auth: AuthPhase = .loading
    var connection: ConnectionState = .connectionStateConnecting
    var authError: String?
    var secretsMissing = false
    var tdlibVersion = ""

    // Navigation
    var tab: Tab = .feed
    var path: [Route] = []
    var modal: Modal?
    var toast: HPToastMessage?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

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

    // Discovery mirrored for views
    var nearby: [DirectoryEntry] = []
    var directory: [DirectoryEntry] = []
    var direct: [NodeInfo] = []
    var edges: [String: [String]] = [:]
    var exploreLoading = false

    // Feed candidates (Setup / Manage)
    var candidates: [FeedCandidate] = []
    var candidatesLoading = false

    var busyCount = 0
    @ObservationIgnored private var floodUntil: Foundation.Date?

    // MARK: Init

    init() {
        td = TDClient { [weak self] update in self?.handle(update) }
        media = MediaLoader(td: td)
        nodes = NodeRepository(td: td, store: store, sends: sends)
        feed = FeedRepository(td: td, store: store, nodes: nodes, sends: sends)
        discovery = DiscoveryRepository(td: td, nodes: nodes)
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
    }

    func terminate() { td.closeClients() }

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }
    var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    // MARK: Status

    var status: StatusKind {
        if auth != .ready { return .signedOut }
        switch connection {
        case .connectionStateWaitingForNetwork: return .offline
        case .connectionStateConnecting, .connectionStateConnectingToProxy, .connectionStateUpdating: return .syncing
        case .connectionStateReady: return busyCount > 0 ? .syncing : .synced
        }
    }

    var isOffline: Bool { if case .connectionStateWaitingForNetwork = connection { return true } else { return false } }

    /// Setup screen shows when signed in, no node, and the user has not skipped it — or while a setup is in progress.
    var needsSetup: Bool { auth == .ready && (inSetup || (myNode == nil && !setupSkipped && nodeLookupDone)) }

    // MARK: Toast

    func showToast(_ text: String, tone: HPToastTone = .neutral) {
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
            }
        case .updateChatTitle(let u):
            nodes.apply(chatId: u.chatId, title: u.title)
            if u.chatId == myNode?.chatId { myTitle = u.title }
        case .updateChatPhoto(let u):
            nodes.apply(chatId: u.chatId, photo: .some(u.photo))
            if u.chatId == myNode?.chatId { myPhoto = Mapping.photoRef(u.photo) }
        default:
            break
        }
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
        busyCount += 1; defer { busyCount -= 1 }
        do { _ = try await op() }
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
        busyCount += 1; defer { busyCount -= 1 }
        me = try? await td.api.getMe()
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
        } catch {
            if !isOffline { showToast(TDFailure(error).message, tone: .bad) }
        }
    }

    private func adopt(node: MyNode, info: NodeInfo) {
        let wasNewer = myNode != nil && myCardState == .newerVersion
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
        feedLoading = true; busyCount += 1
        defer { feedLoading = false; busyCount -= 1; feedReady = true }
        do {
            try await perform {
                try await self.feed.resolveSources(myFeeds: self.myCard?.feeds ?? [], follows: self.myCard?.follows ?? [])
                try await self.feed.refresh()
            }
            feedStale = false
        } catch {
            // The repository kept the cached posts; only the failure is surfaced.
            feedStale = true
            if !isOffline { showToast(TDFailure(error).message, tone: .bad) }
        }
        posts = feed.posts
        feedExhausted = feed.isExhausted
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
        guard auth == .ready else { return }
        exploreLoading = true; busyCount += 1
        defer { exploreLoading = false; busyCount -= 1 }
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
            switch try await perform({ try await self.nodes.announce(node: node.username) }) {
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
        busyCount += 1; defer { busyCount -= 1 }
        let card = Card(name: suggestedTitle, isPublic: true)
        do {
            let (node, info) = try await perform { try await self.nodes.createNode(username: username, title: self.suggestedTitle, card: card) }
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
        busyCount += 1; defer { busyCount -= 1 }
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
        busyCount += 1; defer { busyCount -= 1 }
        await refreshMyCard()
        if myCardState == .ok {
            let feeds = myCard?.feeds ?? []
            if !feeds.isEmpty { _ = try? await nodes.readFeeds(feeds, force: true) }
        }
    }

    func loadCandidates() async {
        guard auth == .ready else { return }
        candidatesLoading = true; defer { candidatesLoading = false }
        if let list = try? await nodes.myFeedCandidates(excluding: myNode?.chatId) { candidates = list }
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
        busyCount += 1; defer { busyCount -= 1 }
        do {
            _ = try await perform { try await self.feed.post(text: text, photoPath: photoPath, to: info) }
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

    // MARK: Sign out (wipes local state)

    func signOut() async {
        modal = nil
        auth = .loggingOut
        _ = try? await td.api.logOut()
        store.clear()
        myNode = nil; myCard = nil; myCardState = .ok; myTitle = ""; myPhoto = nil; me = nil
        setupSkipped = false; nodeLookupDone = false; inSetup = false
        posts = []; nearby = []; directory = []; direct = []; edges = [:]; candidates = []
        feed.clear(); nodes.clear(); discovery.clear()
        path = []; tab = .feed
        feedReady = false; feedStale = false; feedExhausted = false
    }

    // MARK: Links

    func open(_ string: String) {
        guard let url = DeepLink.url(string) else { return }
        UIApplication.shared.open(url)
    }
}
