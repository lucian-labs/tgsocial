// Connector — the router (CONNECTOR.md §2, §3, §4, §6). Mac only.
//
// This is the enforcement point, and it is deliberately the *only* one. Every request that
// reaches the app goes through `handle`, in this order, with no way around any step:
//
//   1. Bearer token, compared in constant time. No token, wrong token → 401. Nothing below runs.
//   2. Signed in. Not signed in → 409, because the bridge is the app's own TDLib session and
//      there is nothing behind it when the app is signed out.
//   3. Scope, resolved fresh from app state (`reader.scopeInputs()`), never from the request.
//   4. Dispatch. Reads take `ScopedSource`, which only `scope.admit` can mint, and every list of
//      posts is filtered through `scope.contains` on the way out. A handler cannot name a chat
//      the scope did not admit, and cannot return one it did not filter.
//   5. Writes check their own switch first — post, comment and card are three separate grants —
//      and refuse with `read only` when it is off.
//   6. Audit, always: on the way out of every branch, including the refusals, including the
//      failures. Counts and verdicts; never bodies.
//
// The "no code path widens its own scope" claim rests on there being no setter: `ScopeResolution`
// is a `let` built at step 3, `admit` is the only way to turn a string into something readable,
// and no endpoint in §4 writes scope — §3 says that on purpose.

#if targetEnvironment(macCatalyst)

import Foundation

/// The three independent write grants (PRODUCT §2.14: "Each one is separate").
struct ConnectorWrites: Codable, Equatable {
    var post: Bool = false
    var comment: Bool = false
    var card: Bool = false

    static let none = ConnectorWrites()
}

/// The policy snapshot the router reads once per request.
struct ConnectorPolicy {
    var token: String
    var preset: ScopePreset
    var writes: ConnectorWrites
}

/// Everything the router can ask the app for. Note what is *not* here: there is no
/// "read chat by id", no "list my chats", no "search Telegram". The bridge's vocabulary is the
/// vocabulary of §4, and a chat that is not a feed, a node or a comments channel has no verb.
@MainActor
protocol ConnectorReader: AnyObject {
    var policy: ConnectorPolicy { get }
    var isSignedIn: Bool { get }
    var accountLabel: String? { get }
    var myNodeUsername: String? { get }
    var myFeeds: [String] { get }
    var tdlibVersion: String { get }
    var appLabel: String { get }
    var maxMediaBytes: Int64 { get }

    func scopeInputs() -> ScopeInputs

    /// The merged main feed as the app holds it (PROTOCOL §4.8). Unfiltered — the router filters.
    func mergedPosts() async throws -> [Post]
    /// One channel's history, newest first. The source is already proved in scope.
    func channelPosts(_ source: ScopedSource, limit: Int, before: Date?) async throws -> [Post]
    func cachedFeed(_ source: ScopedSource) -> FeedInfo?
    func nodeInfo(_ source: ScopedSource) async throws -> NodeInfo
    func cachedCard(_ username: String) -> Card?
    func isFollowing(_ username: String) -> Bool
    func commentCount(for post: Post) -> Int
    func commentTargets(for post: Post) -> [String]
    func threadComments(for post: Post) -> [Comment]
    func findPost(_ source: ScopedSource, serverMessageId: Int64) async throws -> Post
    func findPost(id: String) async throws -> Post
    func mediaBytes(post: Post, index: Int, maxBytes: Int64) async throws -> (data: Data, contentType: String)

    func writePost(to source: ScopedSource, text: String) async throws -> Post
    func writeComment(target: String, text: String) async throws -> Comment
    func writeCard(name: String?, bio: String?, link: String?) async throws -> NodeInfo
}

@MainActor
final class ConnectorRouter {
    static let defaultLimit = 30
    static let maxLimit = 100
    static let defaultGraphDepth = 2
    static let maxGraphDepth = 2

    private unowned let reader: any ConnectorReader
    private let audit: AuditRing

    init(reader: any ConnectorReader, audit: AuditRing) {
        self.reader = reader
        self.audit = audit
    }

    // MARK: The pipeline

    func handle(_ request: ConnectorRequest) async -> ConnectorResponse {
        let policy = reader.policy

        // 1. Auth. Constant-time, and before anything reads app state — an unauthenticated caller
        //    must not even be able to tell whether the app is signed in.
        guard let presented = ConnectorToken.bearer(request.authorization),
              ConnectorToken.matches(expected: policy.token, presented: presented) else {
            return refuse(request, decision: "auth=bearer", error: .unauthorized, detail: "")
        }

        // 2. Signed in. `/status` still answers, because "is it signed in" is the one question
        //    worth answering when it is not (§7: tools report it as a plain, actionable message).
        let isStatus = request.path == "/status"
        guard reader.isSignedIn || isStatus else {
            return refuse(request, decision: "auth=ok", error: .signedOut, detail: "")
        }

        // 3. Scope, derived. Nothing in `request` reaches this call.
        let scope = ScopeResolver.resolve(preset: policy.preset, inputs: reader.scopeInputs())
        let decision = "scope=" + scope.preset.rawValue

        do {
            let (response, detail) = try await dispatch(request, scope: scope, policy: policy)
            audit.append(AuditEntry(tool: request.tool, decision: auditDecision(request, fallback: decision),
                                    outcome: .ok, detail: detail))
            return response
        } catch {
            let connectorError = ConnectorError.from(error)
            let outcome: AuditEntry.Outcome = connectorError.status == 403 || connectorError.status == 401
                ? .refused(connectorError.auditReason)
                : .failed(connectorError.auditReason)
            audit.append(AuditEntry(tool: request.tool, decision: auditDecision(request, fallback: decision),
                                    outcome: outcome, detail: auditDetail(connectorError)))
            return .error(connectorError)
        }
    }

    /// §6's middle column: a write names what it aimed at, a read names the scope it read under.
    private func auditDecision(_ request: ConnectorRequest, fallback: String) -> String {
        switch (request.method, request.path) {
        case ("POST", "/post"):
            let feed = (try? request.decode(ConnectorPostBody.self))?.feed
            return "feed=" + (feed.flatMap(Username.normalise) ?? "?")
        case ("POST", "/comment"):
            let target = (try? request.decode(ConnectorCommentBody.self))?.target
            return "target=" + (target.flatMap { CommentCodec.components(of: $0)?.username } ?? "?")
        case ("PATCH", "/card"):
            return "card=mine"
        default:
            return fallback
        }
    }

    /// The refusal detail is what was *asked*, never what would have been returned.
    private func auditDetail(_ error: ConnectorError) -> String {
        switch error {
        case .outOfScope(let what): return what
        case .notFound(let what), .badRequest(let what): return what
        case .floodWait(let seconds): return "\(seconds)s"
        case .telegram(let code, _): return "code=\(code)"
        case .tooLarge(let bytes, _): return "bytes=\(bytes)"
        default: return ""
        }
    }

    private func refuse(_ request: ConnectorRequest, decision: String,
                        error: ConnectorError, detail: String) -> ConnectorResponse {
        audit.append(AuditEntry(tool: request.tool, decision: decision,
                                outcome: .refused(error.auditReason), detail: detail))
        return .error(error)
    }

    // MARK: Dispatch

    private func dispatch(_ request: ConnectorRequest, scope: ScopeResolution,
                          policy: ConnectorPolicy) async throws -> (ConnectorResponse, String) {
        let segments = request.segments
        // Nouns that take no path argument: `/status/anything` is a 404, and rejecting it here
        // means no handler runs — and no work is done — for a path the bridge does not serve.
        if let noun = segments.first, Self.leafNouns.contains(noun), segments.count != 1 {
            throw ConnectorError.notFound(request.path)
        }
        switch (request.method, segments.first ?? "") {
        case ("GET", "status"): return status(scope: scope, policy: policy)
        case ("GET", "scope"): return (.json(200, ConnectorBodies.scope(scope)), "sources=\(scope.count)")
        case ("GET", "feeds"): return feeds(scope: scope)
        case ("GET", "audit"): return auditBody(request)
        case ("GET", "graph"): return graph(request, scope: scope)
        case ("GET", "search"): return try await search(request, scope: scope)

        case ("GET", "feed"):
            if segments.count == 1 { return try await mergedFeed(request, scope: scope) }
            guard segments.count == 2 else { throw ConnectorError.notFound(request.path) }
            return try await channelFeed(request, scope: scope, username: segments[1])

        case ("GET", "node"):
            guard segments.count == 2 else { throw ConnectorError.notFound(request.path) }
            return try await node(scope: scope, username: segments[1])

        case ("GET", "thread"):
            guard segments.count == 3, let messageId = Int64(segments[2]) else {
                throw ConnectorError.notFound(request.path)
            }
            return try await thread(scope: scope, username: segments[1], serverMessageId: messageId)

        case ("GET", "media"):
            guard segments.count == 3, let index = Int(segments[2]) else {
                throw ConnectorError.notFound(request.path)
            }
            return try await media(scope: scope, postId: segments[1], index: index)

        case ("POST", "post"): return try await writePost(request, scope: scope, policy: policy)
        case ("POST", "comment"): return try await writeComment(request, scope: scope, policy: policy)
        case ("PATCH", "card"): return try await writeCard(request, policy: policy)

        // A known noun reached with the wrong verb is a 405, not a 404: the difference tells an
        // MCP tool "you asked wrong" apart from "this bridge does not do that".
        case (_, let noun) where Self.nouns.contains(noun):
            throw ConnectorError.badRequest("\(request.method) is not allowed on /\(noun)")

        default:
            throw ConnectorError.notFound(request.path)
        }
    }

    private static let nouns: Set<String> = ["status", "scope", "feed", "feeds", "node", "graph",
                                             "thread", "search", "audit", "media", "post", "comment", "card"]
    /// Everything except `/feed/{username}`, `/node/{username}`, `/thread/…` and `/media/…`.
    private static let leafNouns: Set<String> = ["status", "scope", "feeds", "graph", "search",
                                                "audit", "post", "comment", "card"]

    // MARK: Reads

    private func status(scope: ScopeResolution, policy: ConnectorPolicy) -> (ConnectorResponse, String) {
        let body = ConnectorBodies.status(signedIn: reader.isSignedIn,
                                          account: reader.accountLabel,
                                          node: reader.myNodeUsername,
                                          scope: scope,
                                          writes: policy.writes,
                                          tdlib: reader.tdlibVersion,
                                          app: reader.appLabel)
        return (.json(200, body), reader.isSignedIn ? "signed-in" : "signed-out")
    }

    private func feeds(scope: ScopeResolution) -> (ConnectorResponse, String) {
        let node = reader.myNodeUsername
        // Cached only: `GET /feeds` answers "what is exposed", and answering it must not fan out
        // into one `searchPublicChat` per source every time an assistant orients itself.
        let rows = scope.sources.map { source -> (info: FeedInfo?, username: String, verified: Bool) in
            let scoped = try? scope.admit(source.username)
            let info = scoped.flatMap { reader.cachedFeed($0) }
            let verified = node.map { info?.isVerified(for: $0) ?? false } ?? false
            return (info, source.username, verified)
        }
        return (.json(200, ConnectorBodies.feeds(rows)), "feeds=\(rows.count)")
    }

    private func auditBody(_ request: ConnectorRequest) -> (ConnectorResponse, String) {
        let limit = request.intQuery("limit", default: AuditRing.capacity, max: AuditRing.capacity)
        let entries = Array(audit.entries.prefix(limit))
        return (.json(200, ConnectorBodies.audit(entries)), "entries=\(entries.count)")
    }

    private func mergedFeed(_ request: ConnectorRequest, scope: ScopeResolution) async throws -> (ConnectorResponse, String) {
        let limit = request.intQuery("limit", default: Self.defaultLimit, max: Self.maxLimit)
        let before = request.dateQuery("before")
        let window = try await reader.mergedPosts()
        let visible = filter(window, scope: scope, before: before, limit: limit)
        let nextBefore = visible.count == limit ? visible.last.map { Date(timeIntervalSince1970: TimeInterval($0.date)) } : nil
        let body = ConnectorBodies.posts(visible, comments: { [reader] in reader.commentCount(for: $0) }, nextBefore: nextBefore)
        return (.json(200, body), "posts=\(visible.count)")
    }

    private func channelFeed(_ request: ConnectorRequest, scope: ScopeResolution,
                             username: String) async throws -> (ConnectorResponse, String) {
        let source = try scope.admit(username)
        let limit = request.intQuery("limit", default: Self.defaultLimit, max: Self.maxLimit)
        let before = request.dateQuery("before")
        let page = try await reader.channelPosts(source, limit: limit, before: before)
        let visible = filter(page, scope: scope, before: before, limit: limit)
        let nextBefore = visible.count == limit ? visible.last.map { Date(timeIntervalSince1970: TimeInterval($0.date)) } : nil
        let body = ConnectorBodies.posts(visible, comments: { [reader] in reader.commentCount(for: $0) }, nextBefore: nextBefore)
        return (.json(200, body), "posts=\(visible.count)")
    }

    /// The output filter. Every list of posts the bridge emits passes through it, so a repository
    /// whose window is wider than the current preset (which is normal — the app's own feed is the
    /// `graph` set whatever the connector's preset says) cannot leak the difference.
    private func filter(_ posts: [Post], scope: ScopeResolution, before: Date?, limit: Int) -> [Post] {
        var out: [Post] = []
        let cutoff = before.map { Int($0.timeIntervalSince1970) }
        for post in posts where scope.contains(post.sourceUsername) {
            if let cutoff, post.date >= cutoff { continue }
            out.append(post)
            if out.count == limit { break }
        }
        return out
    }

    private func node(scope: ScopeResolution, username: String) async throws -> (ConnectorResponse, String) {
        let source = try scope.admit(username)
        let info = try await reader.nodeInfo(source)
        // A username that resolves to something that is not a node is not a node; saying so is
        // more useful than an empty card, and it never reveals what the chat actually is.
        guard info.state != .notANode else { throw ConnectorError.notFound("@\(source.username) is not a node") }
        let body = ConnectorBodies.node(info, following: reader.isFollowing(source.username))
        return (.json(200, body), info.card == nil ? "no-card" : "card")
    }

    /// §4: my follows and, at depth 2, their follows. Only cards already in scope are walked, so
    /// under `mine` depth 2 yields nothing and under `custom` only the listed nodes expand.
    private func graph(_ request: ConnectorRequest, scope: ScopeResolution) -> (ConnectorResponse, String) {
        let depth = request.intQuery("depth", default: Self.defaultGraphDepth, max: Self.maxGraphDepth)
        var order: [String] = []
        var seen = Set<String>()
        var edges: [(from: String, to: String)] = []

        func note(_ username: String) {
            guard seen.insert(Username.key(username)).inserted else { return }
            order.append(username)
        }

        var frontier = scope.sources.filter { $0.kind == .node || $0.kind == .listed }.map(\.username)
        frontier.forEach(note)
        for _ in 0..<depth {
            var next: [String] = []
            for username in frontier {
                // Expansion reads a card, and a card is a chat: only in-scope ones are opened.
                guard scope.contains(username), let card = reader.cachedCard(username) else { continue }
                for follow in card.follows {
                    edges.append((from: username, to: follow))
                    note(follow)
                    next.append(follow)
                }
            }
            frontier = next
        }

        let nodes = order.map { username -> (username: String, name: String?, following: Bool) in
            // Names come from cards already read; a node that is only a name in someone else's
            // card stays a name. Fetching it would be reading a chat nobody admitted.
            let name = scope.contains(username) ? reader.cachedCard(username)?.name : nil
            return (username, name, reader.isFollowing(username))
        }
        return (.json(200, ConnectorBodies.graph(nodes: nodes, edges: edges)), "nodes=\(nodes.count)")
    }

    private func thread(scope: ScopeResolution, username: String,
                        serverMessageId: Int64) async throws -> (ConnectorResponse, String) {
        let source = try scope.admit(username)
        let post = try await reader.findPost(source, serverMessageId: serverMessageId)
        _ = try scope.admit(post.sourceUsername)

        // PROTOCOL §6.3 gives the network-scoped comment set; the connector narrows it again to
        // the comments channels the preset admits, so a thread can never be the way a chat that
        // is not in scope gets read.
        let visible = reader.threadComments(for: post).filter { scope.contains($0.channelUsername) }
        let rootKeys = reader.commentTargets(for: post).compactMap(CommentCodec.targetKey)
        var used = Set<String>()

        func children(of keys: [String], depth: Int) -> [[String: Any]] {
            guard depth < CommentCodec.maxDepth else { return [] }
            let keySet = Set(keys)
            return visible
                .filter { comment in
                    guard let key = comment.targetKey, keySet.contains(key) else { return false }
                    return used.insert(comment.id).inserted
                }
                .map { comment in
                    let replies = CommentCodec.targetKey(comment.link).map { children(of: [$0], depth: depth + 1) } ?? []
                    return ConnectorBodies.comment(comment, replies: replies)
                }
        }

        let tree = children(of: rootKeys, depth: 0)
        let body = ConnectorBodies.thread(post: ConnectorBodies.post(post, comments: reader.commentCount(for: post)),
                                          comments: tree)
        return (.json(200, body), "comments=\(visible.count)")
    }

    private func search(_ request: ConnectorRequest, scope: ScopeResolution) async throws -> (ConnectorResponse, String) {
        guard let query = request.query["q"]?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw ConnectorError.badRequest("q is required")
        }
        let limit = request.intQuery("limit", default: 20, max: Self.maxLimit)
        // §4: "within the sources in scope only. Not a global Telegram search." The corpus is the
        // app's own merged window, filtered to scope — there is no call to Telegram's search here,
        // which is the only way to be certain nothing outside the scope can come back.
        let window = try await reader.mergedPosts()
        var hits: [Post] = []
        for post in window where scope.contains(post.sourceUsername) {
            let haystack = post.text.plain + " " + post.sourceTitle
            guard haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { continue }
            hits.append(post)
            if hits.count == limit { break }
        }
        let body = ConnectorBodies.posts(hits, comments: { [reader] in reader.commentCount(for: $0) }, nextBefore: nil)
        return (.json(200, body), "posts=\(hits.count)")
    }

    private func media(scope: ScopeResolution, postId: String, index: Int) async throws -> (ConnectorResponse, String) {
        let post = try await reader.findPost(id: postId)
        _ = try scope.admit(post.sourceUsername)
        guard index >= 0, index < post.media.count else { throw ConnectorError.notFound("media index \(index)") }
        let (data, contentType) = try await reader.mediaBytes(post: post, index: index, maxBytes: reader.maxMediaBytes)
        return (.bytes(data, contentType: contentType), "bytes=\(data.count)")
    }

    // MARK: Writes (§4 — each refused unless its switch is on)

    private func writePost(_ request: ConnectorRequest, scope: ScopeResolution,
                           policy: ConnectorPolicy) async throws -> (ConnectorResponse, String) {
        guard policy.writes.post else { throw ConnectorError.readOnly }
        let body = try request.decode(ConnectorPostBody.self)
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConnectorError.badRequest("text is empty") }
        let source = try scope.admit(body.feed)
        // PROTOCOL §4.9: only into my own feeds. Being readable is not being writable.
        let mine = Set(reader.myFeeds.map(Username.key))
        guard mine.contains(source.key) else {
            throw ConnectorError.outOfScope("post to @\(source.username) \u{2014} not one of your feeds")
        }
        let post = try await reader.writePost(to: source, text: text)
        let echo = ConnectorBodies.post(post, comments: reader.commentCount(for: post))
        return (.json(200, echo), "id=\(DeepLink.serverMessageId(post.messageId))")
    }

    private func writeComment(_ request: ConnectorRequest, scope: ScopeResolution,
                              policy: ConnectorPolicy) async throws -> (ConnectorResponse, String) {
        guard policy.writes.comment else { throw ConnectorError.readOnly }
        let body = try request.decode(ConnectorCommentBody.self)
        let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ConnectorError.badRequest("text is empty") }
        guard let target = CommentCodec.components(of: body.target) else {
            throw ConnectorError.badRequest("target is not a t.me post link")
        }
        // Commenting on a post is reading it first: the thing being replied to has to be in scope.
        _ = try scope.admit(target.username)
        let comment = try await reader.writeComment(target: body.target, text: text)
        let echo = ConnectorBodies.comment(comment, replies: [])
        return (.json(200, echo), "id=\(DeepLink.serverMessageId(comment.messageId))")
    }

    private func writeCard(_ request: ConnectorRequest, policy: ConnectorPolicy) async throws -> (ConnectorResponse, String) {
        guard policy.writes.card else { throw ConnectorError.readOnly }
        let body = try request.decode(ConnectorCardBody.self)
        let info = try await reader.writeCard(name: body.name, bio: body.bio, link: body.link)
        let echo = ConnectorBodies.node(info, following: false)
        return (.json(200, echo), "card")
    }
}

#endif
