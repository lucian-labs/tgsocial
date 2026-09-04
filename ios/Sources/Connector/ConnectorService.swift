// Connector — the app-side service (CONNECTOR.md, PRODUCT.md §2.14). Mac only.
//
// This is the object the Connector tab drives and the object the bridge reads through. It owns
// the switches, the token, the audit ring and the listener's lifetime; it does *not* own a second
// TDLib client, a second cache or a second copy of the feed. §8: "not a second session to
// maintain" — every read below goes through the repositories the app itself reads through
// (FeedRepository, NodeRepository, CommentRepository, MediaLoader), and every one of those
// registers with the same `ActivityRegistry`, so a request from an assistant turns the status
// pill `Syncing` exactly like a pull-to-refresh does.

#if targetEnvironment(macCatalyst)

import Foundation
import Observation
import TDLibKit

/// What the user set, persisted next to the rest of the app's local state so signing out — which
/// wipes that directory — takes the bridge's configuration with it.
struct ConnectorSettings: Codable, Equatable {
    var enabled: Bool = false
    var port: Int = ConnectorHandshake.defaultPort
    var preset: ScopePreset = .graph
    var custom: [String] = []
    var writes: ConnectorWrites = .none

    /// What the bridge's configuration becomes when the account behind it goes away. Every field,
    /// not just `enabled`: PRODUCT §2.14 treats each write switch as a grant ("it is a grant, not
    /// a preference"), and a grant belongs to the account that gave it. The custom source list is
    /// the same — a list of usernames one person chose to expose is not the next person's scope.
    static let signedOut = ConnectorSettings()
}

@MainActor @Observable
final class ConnectorService: ConnectorReader {
    /// §5: "a file above `maxMediaBytes` (default 25 MB) is refused with `413`".
    static let maxMediaBytes: Int64 = 25 * 1024 * 1024
    static let storeKey = "connector"
    /// How far `findPost` will page a channel looking for a post that is not in the window.
    static let lookupRounds = 6

    enum Status: Equatable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)

        var isOn: Bool { if case .listening = self { return true } else { return false } }
    }

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let handshakeStore: ConnectorHandshakeStore
    @ObservationIgnored private var server: ConnectorServer?
    @ObservationIgnored private var router: ConnectorRouter!

    private(set) var settings: ConnectorSettings
    private(set) var status: Status = .off
    /// The bearer token. Minted on first enable and never regenerated behind the user's back.
    private(set) var token: String
    let audit: AuditRing

    init(model: AppModel, handshakeDirectory: URL = ConnectorHandshakeStore.defaultDirectory) {
        self.model = model
        self.handshakeStore = ConnectorHandshakeStore(directory: handshakeDirectory)
        self.audit = AuditRing(file: AuditLogFile(directory: handshakeDirectory))
        let stored = model.store.load(ConnectorSettings.self, Self.storeKey) ?? ConnectorSettings()
        self.settings = stored
        // The token outlives a relaunch — an assistant configured yesterday keeps working — but a
        // handshake file whose token has gone (wiped on sign out) means minting a new one.
        self.token = handshakeStore.read()?.token ?? ""
        self.router = ConnectorRouter(reader: self, audit: audit)
    }

    // MARK: Lifecycle

    /// Restores the listener at launch when the user left it on. Not automatic beyond that:
    /// enabling is a grant, and a grant survives a relaunch but is never invented by one.
    func restore() async {
        guard settings.enabled else {
            writeHandshake()
            return
        }
        await start()
    }

    func setEnabled(_ enabled: Bool) async {
        guard enabled != settings.enabled else { return }
        settings.enabled = enabled
        persist()
        if enabled { await start() } else { stop() }
    }

    func setPort(_ port: Int) {
        // §2.14: the port is editable only while the bridge is off, so there is no running
        // listener to move and no in-flight request to strand.
        guard !settings.enabled, port > 0, port <= 65535 else { return }
        settings.port = port
        persist()
        writeHandshake()
    }

    func setPreset(_ preset: ScopePreset) {
        settings.preset = preset
        persist()
    }

    func setCustom(_ usernames: [String]) {
        settings.custom = usernames.compactMap(Username.normalise)
        persist()
    }

    func setWrite(_ keyPath: WritableKeyPath<ConnectorWrites, Bool>, _ on: Bool) {
        settings.writes[keyPath: keyPath] = on
        persist()
    }

    /// §2: "Rotating writes a new token and drops all in-flight requests."
    func rotateToken() async {
        token = ConnectorToken.generate()
        writeHandshake()
        guard settings.enabled else { return }
        // Restarting is what drops the in-flight work: a request that authenticated with the old
        // token must not be answered after the rotation that was meant to revoke it.
        stop()
        await start()
    }

    /// PRODUCT §2.14: "Signing out turns the bridge off and wipes the token."
    ///
    /// The whole settings object goes, not just `enabled`. The service is built once in
    /// `AppModel.init` and outlives a sign-out, so anything left on it is re-persisted by the next
    /// `persist()` and applies to whoever signs in next: a live `Post to my feeds` grant with no
    /// second confirm, and a custom source list naming the previous account's choices.
    func signOut() {
        stop()
        settings = .signedOut
        persist()
        token = ""
        handshakeStore.remove()
        audit.clear()
    }

    func clearActivity() { audit.clear() }

    /// App termination: stop listening, keep the grant. The handshake drops to `enabled: false`
    /// so a client dialling a dead port is told why rather than left guessing, and `restore()`
    /// brings the listener back on the next launch.
    func shutdown() { stop() }

    private func start() async {
        if token.isEmpty { token = ConnectorToken.generate() }
        status = .starting
        let server = ConnectorServer { [weak self] request in
            guard let self else { return .error(.signedOut) }
            return await self.serve(request)
        }
        self.server = server
        do {
            try await server.start(port: UInt16(clamping: settings.port))
            status = .listening(port: server.port)
            writeHandshake()
        } catch {
            self.server = nil
            settings.enabled = false
            persist()
            writeHandshake()
            status = .failed(Self.message(for: error))
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        status = .off
        writeHandshake()
    }

    static func message(for error: Swift.Error) -> String {
        if let failure = error as? ConnectorServer.StartFailure {
            switch failure {
            case .portTaken: return "That port is taken."
            case .invalidPort: return "That port is taken."
            case .failed(let why): return "The bridge didn't start. \(why)"
            }
        }
        return "The bridge didn't start."
    }

    private func persist() { model.store.save(settings, Self.storeKey) }

    /// The handshake file (§2). Written on every state change so the MCP server never dials a
    /// port the app is not on, and never with a token the app has rotated away from.
    private func writeHandshake() {
        guard !token.isEmpty else { handshakeStore.remove(); return }
        let handshake = ConnectorHandshake(port: settings.port, token: token,
                                           enabled: status.isOn, version: ConnectorHandshake.currentVersion)
        try? handshakeStore.write(handshake)
    }

    var handshakePath: String { handshakeStore.fileURL.path }

    // MARK: Serving

    /// Wraps every request in the app's own activity registry, so `Syncing` covers the assistant's
    /// work the same way it covers the reader's (PRODUCT §2.10).
    private func serve(_ request: ConnectorRequest) async -> ConnectorResponse {
        await model.activity.run("Connector \(request.method) \(request.path)") {
            await router.handle(request)
        }
    }

    /// What the screen shows and what every request is checked against — the same resolution.
    var scope: ScopeResolution {
        ScopeResolver.resolve(preset: settings.preset, inputs: scopeInputs())
    }

    // MARK: ConnectorReader

    var policy: ConnectorPolicy { Self.policy(token: token, settings: settings) }

    /// The settings → policy mapping, as a value. Every grant the router enforces comes from here
    /// and from nowhere else, which is what makes "sign out drops the grants" checkable without a
    /// live app behind it.
    nonisolated static func policy(token: String, settings: ConnectorSettings) -> ConnectorPolicy {
        ConnectorPolicy(token: token, preset: settings.preset, writes: settings.writes)
    }

    var isSignedIn: Bool { model.auth == .ready }

    var accountLabel: String? {
        let masked = PhoneMask.format(model.me?.phoneNumber ?? "")
        return masked.isEmpty ? nil : masked
    }

    var myNodeUsername: String? { model.myNode?.username }
    var myFeeds: [String] { model.myCard?.feeds ?? [] }
    var tdlibVersion: String { model.tdlibVersion }
    var appLabel: String { "\(model.appVersion) (\(model.buildNumber))" }
    var maxMediaBytes: Int64 { Self.maxMediaBytes }

    /// The lists as the app holds them (PROTOCOL §7.1), read live: the store is observable and the
    /// screens render through the same value, so the bridge and the screens can never disagree
    /// about what is blocked, muted or hidden.
    var safety: SafetyLists { model.moderation.lists }

    func scopeInputs() -> ScopeInputs {
        var inputs = ScopeInputs()
        inputs.myNode = model.myNode?.username
        inputs.myCard = ScopeCardFacts(model.myCard)
        inputs.follows = model.myCard?.follows ?? []
        for follow in inputs.follows {
            inputs.followCards[Username.key(follow)] = ScopeCardFacts(model.nodes.cachedNode(follow)?.card)
        }
        inputs.custom = settings.custom
        return inputs
    }

    /// The window the app holds, unfiltered on both counts: the router applies the scope and the
    /// safety lists (`ConnectorRouter`, step 4 and 4b), and it is the only place that does.
    func mergedPosts() async throws -> [Post] {
        // A cold app has nothing to serve yet; one refresh through the app's own path fills it.
        if model.feed.posts.isEmpty, !model.feedReady { await model.refreshFeed() }
        return model.feed.posts
    }

    func channelPosts(_ source: ScopedSource, limit: Int, before: Foundation.Date?) async throws -> [Post] {
        let info = try await channel(source)
        var out: [Post] = []
        var from: Int64 = 0
        var rounds = 0
        while out.count < limit, rounds < Self.lookupRounds {
            rounds += 1
            let page = try await model.perform { try await self.model.feed.channelPosts(info, fromMessageId: from) }
            out += page.posts
            if page.exhausted || page.posts.isEmpty || page.oldestId == from { break }
            from = page.oldestId
            // Paging further only helps when the caller asked for older posts than this page holds.
            if let before, let oldest = out.last, oldest.date < Int(before.timeIntervalSince1970), out.count >= limit { break }
        }
        return out
    }

    func cachedFeed(_ source: ScopedSource) -> FeedInfo? { model.nodes.cachedFeed(source.username) }

    /// `GET /node/{username}` goes through the same channel lock as `/feed/{username}` and
    /// `/thread`. It used to call `readNode` straight, which resolves the username itself and
    /// caches the chat's id, title and photo *before* deciding it is not a node — so a `custom`
    /// entry naming a person left that person's private chat in the app's on-disk node cache, and
    /// the only thing refusing the read was a guard inside a repository the connector does not
    /// own. The boundary belongs here.
    func nodeInfo(_ source: ScopedSource) async throws -> NodeInfo {
        _ = try await channelChat(source)
        return try await model.perform { try await self.model.nodes.readNode(username: source.username) }
    }

    func cachedCard(_ username: String) -> Card? {
        if model.isMe(username) { return model.myCard }
        return model.nodes.cachedNode(username)?.card
    }

    func isFollowing(_ username: String) -> Bool { model.isFollowing(username) }
    func commentCount(for post: Post) -> Int { model.commentCount(for: post) }
    func commentTargets(for post: Post) -> [String] { model.commentTargets(for: post) }
    func threadComments(for post: Post) -> [Comment] { model.threadComments(for: post) }

    func findPost(_ source: ScopedSource, serverMessageId: Int64) async throws -> Post {
        func matches(_ post: Post) -> Bool {
            guard Username.key(post.sourceUsername) == source.key else { return false }
            if DeepLink.serverMessageId(post.messageId) == serverMessageId { return true }
            return post.albumMessageIds.contains { DeepLink.serverMessageId($0) == serverMessageId }
        }
        if let hit = model.feed.posts.first(where: matches) { return hit }
        let info = try await channel(source)
        var from: Int64 = 0
        for _ in 0..<Self.lookupRounds {
            let page = try await model.perform { try await self.model.feed.channelPosts(info, fromMessageId: from) }
            if let hit = page.posts.first(where: matches) { return hit }
            if page.exhausted || page.posts.isEmpty || page.oldestId == from { break }
            from = page.oldestId
        }
        throw ConnectorError.notFound("post \(source.username)/\(serverMessageId)")
    }

    func findPost(id: String) async throws -> Post {
        guard let hit = model.feed.posts.first(where: { $0.id == id }) else {
            throw ConnectorError.notFound("post \(id)")
        }
        return hit
    }

    func mediaBytes(post: Post, index: Int, maxBytes: Int64) async throws -> (data: Data, contentType: String) {
        guard index >= 0, index < post.media.count else { throw ConnectorError.notFound("media index \(index)") }
        let (fileId, declared, contentType) = Self.file(for: post.media[index])
        guard let fileId else { throw ConnectorError.notFound("media index \(index) has no file") }
        // A declared size over budget is refused before a byte is downloaded — §5's cap is there
        // to keep megabytes out of tool calls, and downloading first would defeat it.
        if declared > 0, declared > maxBytes { throw ConnectorError.tooLarge(bytes: declared, maxBytes: maxBytes) }
        guard let path = await model.media.download(fileId, priority: MediaLoader.tappedPriority,
                                                    label: "Connector downloading media") else {
            throw ConnectorError.telegram(code: 500, message: "The download didn't finish.")
        }
        let url = URL(fileURLWithPath: path)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.int64Value ?? 0
        if size > maxBytes { throw ConnectorError.tooLarge(bytes: size, maxBytes: maxBytes) }
        guard let data = try? Data(contentsOf: url) else {
            throw ConnectorError.telegram(code: 500, message: "The file couldn't be read.")
        }
        return (data, contentType)
    }

    /// The file behind one media item, its declared size, and what to serve it as.
    private static func file(for media: PostMedia) -> (fileId: Int?, size: Int64, contentType: String) {
        func typed(_ file: FileRef, _ fallback: String) -> (Int?, Int64, String) {
            (file.fileId, file.size, file.mimeType.isEmpty ? fallback : file.mimeType)
        }
        switch media {
        // A photo's size is not in the model; the post-download check catches an oversized one.
        case .photo(_, let full): return (full.fileId, 0, "image/jpeg")
        case .video(let file, _, _, _, _): return typed(file, "video/mp4")
        case .animation(let file, _, _, _, _): return typed(file, "video/mp4")
        case .audio(let file, _, _, _): return typed(file, "audio/mpeg")
        case .voice(let file, _, _): return typed(file, "audio/ogg")
        case .videoNote(let file, _, _): return typed(file, "video/mp4")
        case .document(let file, _): return typed(file, "application/octet-stream")
        case .sticker(let file, _, _, _, _, _): return typed(file, "image/webp")
        case .linkPreview, .summary: return (nil, 0, "application/octet-stream")
        }
    }

    // MARK: Writes

    func writePost(to source: ScopedSource, text: String) async throws -> Post {
        guard !model.isOffline else { throw ConnectorError.telegram(code: 500, message: "You're offline.") }
        let info = try await channel(source)
        let message = try await model.activity.run("Connector posting") {
            try await self.model.perform { try await self.model.feed.post(text: text, photoPath: nil, to: info) }
        }
        model.posts = model.feed.posts
        guard let post = Mapping.post(message, source: info) else {
            throw ConnectorError.telegram(code: 500, message: "The post was sent but could not be read back.")
        }
        return post
    }

    func writeComment(target: String, text: String) async throws -> Comment {
        guard let node = model.myNode else { throw ConnectorError.badRequest("no node yet") }
        guard let replies = model.myCard?.replies else {
            throw ConnectorError.badRequest("no comments channel yet \u{2014} make one in the app first")
        }
        guard !model.isOffline else { throw ConnectorError.telegram(code: 500, message: "You're offline.") }
        let title = (model.myCard?.name?.isEmpty == false ? model.myCard?.name : nil) ?? model.myTitle
        let commentTarget = CommentTarget(link: target, quoteTitle: title, quoteText: "")
        try await model.activity.run("Connector commenting") {
            try await self.model.perform {
                try await self.model.comments.post(body: text, photoPath: nil, target: commentTarget,
                                                   channelUsername: replies, ownerUsername: node.username,
                                                   ownerTitle: title, ownerPhoto: self.model.myPhoto)
            }
        }
        // The repository indexes by target; the newest of mine against this link is the one just
        // written. Reading it back is how the echo (§4) stays the truth rather than the request.
        guard let written = model.comments.comments(forTargets: [target])
            .filter({ $0.isMine && !$0.isPending })
            .max(by: { ($0.date, $0.messageId) < ($1.date, $1.messageId) }) else {
            throw ConnectorError.telegram(code: 500, message: "The comment was sent but could not be read back.")
        }
        return written
    }

    func writeCard(name: String?, bio: String?, link: String?) async throws -> NodeInfo {
        guard let node = model.myNode else { throw ConnectorError.badRequest("no node yet") }
        guard model.myCardState == .ok else { throw ConnectorError.badRequest(AppModel.newerCardText) }
        // PATCH: an omitted field keeps its value. An assistant sending `{"bio": "…"}` must not
        // silently erase the name.
        let current = model.myCard ?? Card()
        let ok = await model.editCard(name: name ?? current.name ?? "",
                                      bio: bio ?? current.bio ?? "",
                                      link: link ?? current.link ?? "")
        guard ok else { throw ConnectorError.telegram(code: 500, message: "Couldn't update your card.") }
        if let info = model.nodes.cachedNode(node.username) { return info }
        return NodeInfo(username: node.username, chatId: node.chatId, title: model.myTitle,
                        card: model.myCard, state: .ok, photo: model.myPhoto, fetchedAt: Foundation.Date())
    }

    // MARK: Channel resolution

    /// The second lock on private chats. Scope membership already means a username came from a
    /// card's `feeds:`, `follows:` or `replies:` list — but a hand-typed `custom` entry has no
    /// such provenance, and `searchPublicChat` will happily resolve a *person's* username to a
    /// private chat. Anything that is not a channel is refused here, before it is read.
    ///
    /// Every read that names a username — `/feed/{u}`, `/node/{u}`, `/thread`, and the writes —
    /// passes through this, so the lock is the connector's own and does not depend on what a
    /// repository happens to check on the way past.
    private func channelChat(_ source: ScopedSource) async throws -> Chat {
        let chat = try await model.perform { try await self.model.td.api.searchPublicChat(username: source.username) }
        try Self.admitChannel(chat.type, source: source)
        return chat
    }

    /// The decision itself, as a value: a chat type either is a channel or the request is out of
    /// scope. Kept `nonisolated` and free of TDLib calls so it can be exercised directly against a
    /// private chat, a basic group and a supergroup that is not a channel.
    nonisolated static func admitChannel(_ type: ChatType, source: ScopedSource) throws {
        guard Mapping.isChannel(type) else {
            throw ConnectorError.outOfScope("@\(source.username) is not a channel")
        }
    }

    private func channel(_ source: ScopedSource) async throws -> FeedInfo {
        _ = try await channelChat(source)
        return try await model.perform { try await self.model.nodes.readFeed(username: source.username) }
    }
}

#endif
