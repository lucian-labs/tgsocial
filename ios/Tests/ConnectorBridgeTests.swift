// Integration tests — the Connector bridge end to end (CONNECTOR.md §1, §2, §3, §4, §6).
//
// A real `ConnectorServer` on an ephemeral loopback port, a real `ConnectorRouter`, a stub reader
// standing in for the repositories, and a raw socket client. Raw sockets rather than URLSession
// on purpose: no ATS to reason about, and the bytes on the wire are the thing under test.
//
// The claims proved here are the ones the design rests on:
//   * no token and a wrong token are both 401;
//   * a read outside the scope is 403 `out of scope`, whatever the token;
//   * a write while read-only is 403 `read only`, before scope is even consulted;
//   * an in-scope read is 200 and carries only in-scope posts;
//   * the listener is not reachable on this machine's LAN address.

#if targetEnvironment(macCatalyst)

import Foundation
import XCTest
@testable import tgsocial

// MARK: - A reader that answers from fixtures

/// The bridge's shared secret for the suite. A file-level constant so the tests can quote it from
/// a nonisolated context without hopping to the main actor for every request.
let stubConnectorToken = "test-token-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

@MainActor
final class StubConnectorReader: ConnectorReader {
    var token = stubConnectorToken
    var preset: ScopePreset = .graph
    var writes = ConnectorWrites.none
    var isSignedIn = true
    var inputs = ConnectorFixture.inputs

    /// One post from a source in scope, one from a source that is not. The out-of-scope post is
    /// here to be *absent* from every response.
    var window: [Post] = [
        ConnectorFixture.post(feed: "waveloop_devlog", title: "WaveLoop devlog", node: "tgs_ana"),
        ConnectorFixture.post(feed: "private_person", title: "Not in scope", node: nil,
                              messageId: 7 << 20, chatId: -100_9, text: "secret"),
    ]
    private(set) var wroteText: String?

    var policy: ConnectorPolicy { ConnectorPolicy(token: token, preset: preset, writes: writes) }
    var accountLabel: String? { "+1 604 \u{2022}\u{2022}\u{2022} 0199" }
    var myNodeUsername: String? { inputs.myNode }
    var myFeeds: [String] { inputs.myCard.feeds }
    var tdlibVersion: String { "1.8.66" }
    var appLabel: String { "1.0.0 (202608240210)" }
    var maxMediaBytes: Int64 { 25 * 1024 * 1024 }

    func scopeInputs() -> ScopeInputs { inputs }
    func mergedPosts() async throws -> [Post] { window }

    func channelPosts(_ source: ScopedSource, limit: Int, before: Foundation.Date?) async throws -> [Post] {
        window.filter { Username.key($0.sourceUsername) == source.key }
    }

    func cachedFeed(_ source: ScopedSource) -> FeedInfo? { ConnectorFixture.feed(source.username) }
    func nodeInfo(_ source: ScopedSource) async throws -> NodeInfo {
        ConnectorFixture.node(source.username, card: Card(name: "Ana Iliovic", feeds: ["waveloop_devlog"]))
    }
    func cachedCard(_ username: String) -> Card? {
        Username.key(username) == "tgs_me" ? Card(feeds: ["my_feed"], follows: ["tgs_ana"]) : Card(follows: ["tgs_far"])
    }
    func isFollowing(_ username: String) -> Bool { Username.key(username) == "tgs_ana" }
    func commentCount(for post: Post) -> Int { 1 }
    func commentTargets(for post: Post) -> [String] { [post.deepLink] }
    func threadComments(for post: Post) -> [Comment] {
        [ConnectorFixture.comment(channel: "tgs_ana_r", target: post.deepLink),
         // From a channel no preset admits: it must never reach the wire.
         ConnectorFixture.comment(channel: "stranger_r", owner: "stranger", target: post.deepLink,
                                  body: "should not be visible", messageId: 11 << 20)]
    }

    func findPost(_ source: ScopedSource, serverMessageId: Int64) async throws -> Post {
        guard let hit = window.first(where: {
            Username.key($0.sourceUsername) == source.key && DeepLink.serverMessageId($0.messageId) == serverMessageId
        }) else { throw ConnectorError.notFound("post") }
        return hit
    }

    func findPost(id: String) async throws -> Post {
        guard let hit = window.first(where: { $0.id == id }) else { throw ConnectorError.notFound("post \(id)") }
        return hit
    }

    func mediaBytes(post: Post, index: Int, maxBytes: Int64) async throws -> (data: Data, contentType: String) {
        (Data(repeating: 0x2A, count: 8), "image/jpeg")
    }

    func writePost(to source: ScopedSource, text: String) async throws -> Post {
        wroteText = text
        return ConnectorFixture.post(feed: source.username, node: inputs.myNode, text: text)
    }

    func writeComment(target: String, text: String) async throws -> Comment {
        wroteText = text
        return ConnectorFixture.comment(channel: "tgs_me_r", owner: "tgs_me", target: target, body: text)
    }

    func writeCard(name: String?, bio: String?, link: String?) async throws -> NodeInfo {
        wroteText = name
        return ConnectorFixture.node("tgs_me", card: Card(name: name, bio: bio, link: link))
    }
}

// MARK: - A raw HTTP client

struct RawResponse {
    var status: Int
    var headers: [String: String]
    var body: String

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
    }
    var error: String? { json?["error"] as? String }
}

enum RawHTTP {
    /// Blocking; always called from a dispatch queue, never a cooperative thread.
    static func send(_ raw: String, host: String, port: UInt16, timeout: TimeInterval = 5) -> RawResponse? {
        guard let fd = connectSocket(host: host, port: port, timeout: timeout) else { return nil }
        defer { close(fd) }
        let outgoing = Array(raw.utf8)
        var sent = 0
        while sent < outgoing.count {
            let n = outgoing.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), outgoing.count - sent) }
            guard n > 0 else { return nil }
            sent += n
        }
        var incoming = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            incoming.append(contentsOf: chunk[0..<n])
        }
        return parse(incoming)
    }

    static func parse(_ data: Data) -> RawResponse? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines where line.contains(":") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let body = String(data: data[separator.upperBound...], encoding: .utf8) ?? ""
        return RawResponse(status: status, headers: headers, body: body)
    }

    /// True when a TCP connection to `host:port` completes. The bind test needs this to be false.
    static func canConnect(host: String, port: UInt16, timeout: TimeInterval = 2) -> Bool {
        guard let fd = connectSocket(host: host, port: port, timeout: timeout) else { return false }
        close(fd)
        return true
    }

    private static func connectSocket(host: String, port: UInt16, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { close(fd); return nil }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { close(fd); return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&poller, 1, Int32(timeout * 1000)) == 1 else { close(fd); return nil }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags)
        return fd
    }

    /// This machine's first non-loopback IPv4 address, or nil when it is not on a network.
    static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &name, socklen_t(name.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: name)
            if address.hasPrefix("169.254.") { continue }
            return address
        }
        return nil
    }
}

// MARK: - The suite

final class ConnectorBridgeTests: XCTestCase {

    private var reader: StubConnectorReader!
    private var ring: AuditRing!
    private var server: ConnectorServer!
    private var port: UInt16 = 0
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = ConnectorFixture.temporaryDirectory("bridge")
        let (reader, ring, router) = await MainActor.run { () -> (StubConnectorReader, AuditRing, ConnectorRouter) in
            let reader = StubConnectorReader()
            let ring = AuditRing(file: AuditLogFile(directory: directory))
            return (reader, ring, ConnectorRouter(reader: reader, audit: ring))
        }
        self.reader = reader
        self.ring = ring
        let server = ConnectorServer { request in await router.handle(request) }
        self.server = server
        // Port 0: the kernel picks a free one, so the suite never collides with a running bridge.
        try await server.start(port: 0)
        port = server.port
        XCTAssertGreaterThan(port, 0)
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: Helpers

    /// The bridge did not answer at all — a connect that failed or a socket that closed silent.
    /// Only the bind test expects it; everywhere else it is a failure, so `send` throws.
    private struct Unreachable: Swift.Error {}

    /// Raw request, off the cooperative pool: the router runs on the main actor, and blocking a
    /// cooperative thread on a socket read while waiting for it is how a suite deadlocks.
    private func attempt(_ method: String, _ target: String, token: String?, body: String? = nil,
                         host: String = "127.0.0.1") async -> RawResponse? {
        var raw = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let token { raw += "Authorization: Bearer \(token)\r\n" }
        if let body {
            raw += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        } else {
            raw += "\r\n"
        }
        let port = self.port
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: RawHTTP.send(raw, host: host, port: port))
            }
        }
    }

    private func send(_ method: String, _ target: String, token: String?, body: String? = nil,
                      host: String = "127.0.0.1") async throws -> RawResponse {
        guard let response = await attempt(method, target, token: token, body: body, host: host) else {
            throw Unreachable()
        }
        return response
    }

    private func get(_ target: String, token: String? = nil) async throws -> RawResponse {
        try await send("GET", target, token: token ?? reader.tokenValue)
    }

    private func reachable(_ host: String) async -> Bool {
        let port = self.port
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async { continuation.resume(returning: RawHTTP.canConnect(host: host, port: port)) }
        }
    }

    // MARK: 1 — auth

    func testNoTokenIsRejected() async throws {
        let response = try await send("GET", "/status", token: nil)
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.error, "unauthorized")
        // Nothing about the app leaks past the door.
        XCTAssertNil(response.json?["signedIn"])
    }

    func testWrongTokenIsRejected() async throws {
        let response = try await send("GET", "/status", token: "not-the-token")
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.error, "unauthorized")
    }

    func testATokenThatIsAPrefixOfTheRealOneIsRejected() async throws {
        let real = await reader.tokenValue
        let response = try await send("GET", "/status", token: String(real.dropLast()))
        XCTAssertEqual(response.status, 401)
    }

    func testTheRightTokenGetsIn() async throws {
        let response = try await get("/status")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json?["signedIn"] as? Bool, true)
        XCTAssertEqual(response.json?["node"] as? String, "tgs_me")
        XCTAssertEqual(response.headers["content-type"], "application/json; charset=utf-8")
    }

    func testSignedOutIs409ExceptForStatus() async throws {
        await MainActor.run { reader.isSignedIn = false }
        let feed = try await get("/feed")
        XCTAssertEqual(feed.status, 409)
        XCTAssertEqual(feed.error, "signed out")

        let status = try await get("/status")
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(status.json?["signedIn"] as? Bool, false)
    }

    // MARK: 2 — scope

    func testAnInScopeReadIs200() async throws {
        let response = try await get("/feed/waveloop_devlog")
        XCTAssertEqual(response.status, 200)
        let posts = try XCTUnwrap(response.json?["posts"] as? [[String: Any]])
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0]["feed"] as? String, "waveloop_devlog")
    }

    func testAnOutOfScopeReadIs403() async throws {
        let response = try await get("/feed/private_person")
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.error, "out of scope")
        XCTAssertEqual(response.json?["detail"] as? String, "private_person")
        // Nothing about the chat comes back with the refusal.
        XCTAssertFalse(response.body.contains("secret"))
    }

    func testTheMergedFeedNeverCarriesAnOutOfScopeSource() async throws {
        let response = try await get("/feed")
        XCTAssertEqual(response.status, 200)
        let posts = try XCTUnwrap(response.json?["posts"] as? [[String: Any]])
        XCTAssertEqual(posts.map { $0["feed"] as? String }, ["waveloop_devlog"])
        XCTAssertFalse(response.body.contains("private_person"))
        XCTAssertFalse(response.body.contains("secret"))
    }

    func testNarrowingThePresetNarrowsWhatComesBackImmediately() async throws {
        await MainActor.run { reader.preset = .mine }
        let feed = try await get("/feed")
        // `waveloop_devlog` belongs to a node I follow: readable under `graph`, not under `mine`.
        XCTAssertEqual((feed.json?["posts"] as? [[String: Any]])?.count, 0)
        let channel = try await get("/feed/waveloop_devlog")
        XCTAssertEqual(channel.status, 403)
        XCTAssertEqual(channel.error, "out of scope")
    }

    func testSearchCannotReachOutsideTheScope() async throws {
        let response = try await get("/search?q=secret")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual((response.json?["posts"] as? [[String: Any]])?.count, 0)

        let inScope = try await get("/search?q=sequencer")
        XCTAssertEqual((inScope.json?["posts"] as? [[String: Any]])?.count, 1)
    }

    func testAThreadDropsCommentsFromChannelsNoPresetAdmits() async throws {
        let response = try await get("/thread/waveloop_devlog/144")
        XCTAssertEqual(response.status, 200)
        let comments = try XCTUnwrap(response.json?["comments"] as? [[String: Any]])
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0]["channel"] as? String, "tgs_ana_r")
        XCTAssertFalse(response.body.contains("should not be visible"))
    }

    func testThereIsNoEndpointThatWidensScope() async throws {
        // §3 is explicit that scope is set in the app and nowhere else. The reporting endpoint is
        // read-only, and the obvious guesses are not routes.
        let write = try await send("POST", "/scope", token: reader.tokenValue,
                                             body: #"{"preset":"custom","sources":["private_person"]}"#)
        XCTAssertEqual(write.status, 400)
        let patch = try await send("PATCH", "/scope", token: reader.tokenValue, body: #"{"preset":"custom"}"#)
        XCTAssertEqual(patch.status, 400)

        // …and a query parameter is not a back door either.
        let smuggled = try await get("/feed?scope=custom&sources=private_person")
        XCTAssertEqual((smuggled.json?["posts"] as? [[String: Any]])?.map { $0["feed"] as? String }, ["waveloop_devlog"])

        let reported = try await get("/scope")
        XCTAssertEqual(reported.json?["preset"] as? String, "graph")
    }

    // MARK: 3 — writes

    func testAWriteWhileReadOnlyIs403() async throws {
        let response = try await send("POST", "/post", token: reader.tokenValue,
                                                body: #"{"feed":"my_feed","text":"hello"}"#)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.error, "read only")
        let wrote = await reader.wroteTextValue
        XCTAssertNil(wrote)
    }

    func testEveryWriteHasItsOwnSwitch() async throws {
        await MainActor.run { reader.writes = ConnectorWrites(post: true, comment: false, card: false) }

        let post = try await send("POST", "/post", token: reader.tokenValue,
                                            body: #"{"feed":"my_feed","text":"hello"}"#)
        XCTAssertEqual(post.status, 200)
        XCTAssertEqual(post.json?["feed"] as? String, "my_feed")

        // The other two grants are untouched by the first.
        let comment = try await send("POST", "/comment", token: reader.tokenValue,
                                               body: #"{"target":"https://t.me/waveloop_devlog/144","text":"hi"}"#)
        XCTAssertEqual(comment.status, 403)
        XCTAssertEqual(comment.error, "read only")

        let card = try await send("PATCH", "/card", token: reader.tokenValue, body: #"{"bio":"hi"}"#)
        XCTAssertEqual(card.status, 403)
        XCTAssertEqual(card.error, "read only")
    }

    func testPostingIsRefusedIntoAFeedThatIsReadableButNotMine() async throws {
        await MainActor.run { reader.writes = ConnectorWrites(post: true, comment: false, card: false) }
        // `waveloop_devlog` is in scope to read and belongs to someone else (PROTOCOL §4.9).
        let response = try await send("POST", "/post", token: reader.tokenValue,
                                                body: #"{"feed":"waveloop_devlog","text":"hello"}"#)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.error, "out of scope")
    }

    func testCommentingOnAnOutOfScopePostIsRefused() async throws {
        await MainActor.run { reader.writes = ConnectorWrites(post: false, comment: true, card: false) }
        let response = try await send("POST", "/comment", token: reader.tokenValue,
                                                body: #"{"target":"https://t.me/private_person/7","text":"hi"}"#)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.error, "out of scope")
    }

    // MARK: 4 — the bind

    /// The claim from §1: "The bridge binds `127.0.0.1`. It is not reachable from the network."
    func testTheListenerIsNotReachableOnTheLANAddress() async throws {
        let loopbackReachable = await reachable("127.0.0.1")
        XCTAssertTrue(loopbackReachable, "the control connection failed; the rest of this test would prove nothing")

        guard let lan = RawHTTP.lanAddress() else {
            throw XCTSkip("this machine has no non-loopback IPv4 address to try")
        }
        let lanReachable = await reachable(lan)
        XCTAssertFalse(lanReachable, "the bridge answered on \(lan):\(port) — it is bound wider than loopback")

        // And an HTTP request over that address gets nothing at all, token or no token.
        let response = await attempt("GET", "/status", token: reader.tokenValue, host: lan)
        XCTAssertNil(response, "a request from \(lan) reached the bridge")
    }

    func testStoppingTheBridgeStopsAnsweringImmediately() async throws {
        server.stop()
        let stillReachable = await reachable("127.0.0.1")
        XCTAssertFalse(stillReachable)
        XCTAssertFalse(server.isListening)
    }

    // MARK: 5 — audit

    func testEveryRequestIsAuditedAndNoBodyIsWritten() async throws {
        await MainActor.run { reader.writes = ConnectorWrites(post: true, comment: false, card: false) }
        _ = try await get("/feed")
        _ = try await get("/feed/private_person")
        _ = try await send("GET", "/status", token: "wrong")
        _ = try await send("POST", "/post", token: reader.tokenValue, body: #"{"feed":"my_feed","text":"a secret sentence"}"#)

        let entries = await ring.entries
        XCTAssertEqual(entries.count, 4)
        let byTool = Dictionary(grouping: entries, by: \.tool)
        XCTAssertEqual(byTool["GET /feed"]?.first?.outcome, .ok)
        XCTAssertEqual(byTool["GET /feed"]?.first?.detail, "posts=1")
        XCTAssertEqual(byTool["GET /feed/private_person"]?.first?.outcome, .refused("out-of-scope"))
        XCTAssertEqual(byTool["GET /status"]?.first?.outcome, .refused("unauthorized"))
        XCTAssertEqual(byTool["POST /post"]?.first?.decision, "feed=my_feed")

        // §6: the log records what was asked and what was decided — never message bodies.
        let file = AuditLogFile(directory: directory)
        let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("a secret sentence"))
        XCTAssertTrue(contents.contains("REFUSED out-of-scope private_person"))
        XCTAssertEqual(contents.split(separator: "\n").count, 4)
    }

    /// §1 "Audited", §6. The target is percent-decoded before it becomes the tool column, and the
    /// 401 branch audits *before* it authenticates — so without a guard, an unauthenticated local
    /// process could append a plausible `ok` row to `audit.log` and leave the genuine entry
    /// truncated. No token is sent here on purpose: that is the whole attack.
    func testAnUnauthenticatedCallerCannotForgeAnAuditLine() async throws {
        let forged = "2026-08-24T00:00:00Z  GET /feed         scope=graph  ok      posts=30"
        let target = "/feed%0d%0a" + forged.replacingOccurrences(of: " ", with: "%20")
                                           .replacingOccurrences(of: "/", with: "%2F")
        let response = try await send("GET", target, token: nil)
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(response.error, "bad request")

        // Not audited at all: the request never became a request.
        let entries = await ring.entries
        XCTAssertTrue(entries.isEmpty, "a malformed target reached the log")
        let file = AuditLogFile(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))

        // And a real refusal that follows is still one whole line with its outcome column intact.
        _ = try await send("GET", "/feed", token: "wrong")
        let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(contents.contains("REFUSED unauthorized"))
        XCTAssertFalse(contents.contains("posts=30"))
    }

    // MARK: 6 — shape of the rest of §4

    func testTheRemainingReadEndpointsAnswer() async throws {
        let feeds = try await get("/feeds")
        XCTAssertEqual(feeds.status, 200)
        XCTAssertEqual((feeds.json?["feeds"] as? [[String: Any]])?.count, 6)

        let node = try await get("/node/tgs_ana")
        XCTAssertEqual(node.status, 200)
        XCTAssertEqual(node.json?["following"] as? Bool, true)

        let graph = try await get("/graph?depth=2")
        XCTAssertEqual(graph.status, 200)
        XCTAssertNotNil(graph.json?["edges"])

        let audit = try await get("/audit?limit=2")
        XCTAssertEqual(audit.status, 200)
        XCTAssertLessThanOrEqual((audit.json?["entries"] as? [[String: Any]])?.count ?? 99, 2)

        let unknown = try await get("/chats")
        XCTAssertEqual(unknown.status, 404)
    }

    func testMediaIsServedAsBytesWithItsRealContentType() async throws {
        let post = await MainActor.run { reader.window[0] }
        let response = try await get("/media/\(post.id)/0")
        // The fixture post has no media, so the index is refused rather than invented.
        XCTAssertEqual(response.status, 404)

        await MainActor.run { reader.window[0].media = [ConnectorFixture.photo()] }
        let bytes = try await get("/media/\(post.id)/0")
        XCTAssertEqual(bytes.status, 200)
        XCTAssertEqual(bytes.headers["content-type"], "image/jpeg")
        XCTAssertEqual(bytes.headers["content-length"], "8")
    }

    func testMediaForAnOutOfScopePostIsRefused() async throws {
        let outOfScope = await MainActor.run { reader.window[1] }
        await MainActor.run { reader.window[1].media = [ConnectorFixture.photo()] }
        let response = try await get("/media/\(outOfScope.id)/0")
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.error, "out of scope")
    }
}

extension StubConnectorReader {
    /// Readable without a hop: the token never changes during a test.
    nonisolated var tokenValue: String { stubConnectorToken }
    /// Main-actor accessor so a nonisolated test body can check what a write actually wrote.
    var wroteTextValue: String? { wroteText }
}

#endif
