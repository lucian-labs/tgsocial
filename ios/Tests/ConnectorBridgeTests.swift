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
    /// Empty by default: every existing expectation in this suite is what an unfiltered reader
    /// sees, and the safety tests set the lists they need.
    var safety = SafetyLists()

    /// One post from a source in scope, one from a source that is not. The out-of-scope post is
    /// here to be *absent* from every response.
    var window: [Post] = [
        ConnectorFixture.post(feed: "waveloop_devlog", title: "WaveLoop devlog", node: "tgs_ana"),
        ConnectorFixture.post(feed: "private_person", title: "Not in scope", node: nil,
                              messageId: 7 << 20, chatId: -100_9, text: "secret"),
    ]
    var revokeMediaScope = false
    var mediaLength = 8
    private(set) var wroteText: String?

    var policy: ConnectorPolicy { ConnectorPolicy(token: token, preset: preset, writes: writes) }
    var accountLabel: String? { "+1 604 \u{2022}\u{2022}\u{2022} 0199" }
    var myNodeUsername: String? { inputs.myNode }
    var myFeeds: [String] { inputs.myCard.feeds }
    var tdlibVersion: String { "1.8.66" }
    var appLabel: String { "1.0.0 (202608240210)" }
    var maxMediaBytes: Int64 { 25 * 1024 * 1024 }

    var discoveryQueries: [String] = []
    var refreshCount = 0
    func connections() -> [String: Any] { ["telegram": ["signedIn": isSignedIn]] }
    func discoverChannels(_ query: String) async throws -> [[String: String]] {
        discoveryQueries.append(query)
        return [["title": "Public channel", "username": "public_channel"]]
    }
    func refreshApp() async -> [String: Any] { refreshCount += 1; return connections() }
    func scopeInputs() -> ScopeInputs { inputs }
    func updateScope(add: [String], remove: [String]) async throws -> ScopeResolution {
        let current = ScopeResolver.resolve(preset: preset, inputs: inputs)
        inputs.custom = ConnectorScopeChange.applying(add: add, remove: remove, to: current)
        preset = .custom
        return ScopeResolver.resolve(preset: preset, inputs: inputs)
    }
    func mergedPosts() async throws -> [Post] { window }

    func channelPosts(_ source: ScopedSource, limit: Int, before: Foundation.Date?) async throws -> [Post] {
        window.filter { Username.key($0.sourceUsername) == source.key }
    }

    func history(_ source: ScopedSource, limit: Int, cursor: String?) async throws -> ConnectorHistoryPage {
        let before = try ConnectorHistoryCursor.decode(cursor, source: source.username)
        let posts = Array(window.filter { $0.sourceUsername == source.username && (before == 0 || $0.messageId < before) }
            .sorted { $0.messageId > $1.messageId }.prefix(limit))
        return ConnectorHistoryPage(posts: posts,
            nextCursor: posts.last.map { ConnectorHistoryCursor.encode(source: source.username, before: $0.messageId) },
            exhausted: posts.isEmpty)
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

    func mediaResponse(post: Post, index: Int, maxBytes: Int64) async throws -> ConnectorResponse {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0x2A, count: mediaLength).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        if revokeMediaScope { preset = .custom; inputs.custom = [] }
        return .file(try ConnectorFileBody(url: url, maxBytes: maxBytes, expectedBytes: Int64(mediaLength)), contentType: "image/jpeg")
    }
    func mediaStatus(post: Post, index: Int) async throws -> [String: Any] {
        ["downloadedBytes": 8, "expectedBytes": 8, "active": false, "complete": true]
    }

    func uploadFeed(_ id: String) throws -> String { "waveloop_devlog" }
    func upload(_ request: ConnectorRequest, source: ScopedSource) async throws -> ConnectorResponse {
        .json(200, ["requestId": request.segments[1]])
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

    func testHistoryTraversesBeyondThirtyMessagesWithEqualDates() async throws {
        await MainActor.run {
            reader.window = (1...65).map { n in
                ConnectorFixture.post(feed: "waveloop_devlog", title: "Feed", node: "tgs_ana",
                                      messageId: Int64(n) << 20)
            }
        }
        var cursor: String?
        var ids = Set<String>()
        var exhausted = false
        for _ in 0..<70 {
            let suffix = cursor.map { "&cursor=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!.replacingOccurrences(of: "+", with: "%2B") } ?? ""
            let response = try await get("/history/waveloop_devlog?limit=1" + suffix)
            XCTAssertEqual(response.status, 200)
            for post in try XCTUnwrap(response.json?["posts"] as? [[String: Any]]) {
                XCTAssertTrue(ids.insert(try XCTUnwrap(post["id"] as? String)).inserted)
            }
            if response.json?["exhausted"] as? Bool == true {
                exhausted = true
                XCTAssertTrue(response.json?["nextCursor"] is NSNull)
                break
            }
            let next = try XCTUnwrap(response.json?["nextCursor"] as? String)
            XCTAssertNotEqual(next, cursor)
            cursor = next
        }
        XCTAssertTrue(exhausted)
        XCTAssertEqual(ids.count, 65)
    }

    func testHistoryRejectsOutOfScopeAndInvalidCursors() async throws {
        let outside = try await get("/history/not_allowed")
        XCTAssertEqual(outside.status, 403)
        let invalid = try await get("/history/waveloop_devlog?cursor=garbage")
        XCTAssertEqual(invalid.status, 400)
        let wrong = ConnectorHistoryCursor.encode(source: "another_feed", before: 20 << 20)
        let response = try await get("/history/waveloop_devlog?cursor=" + wrong)
        XCTAssertEqual(response.status, 400)
    }

    func testFilteredHistoryPageStillHasContinuation() async throws {
        await MainActor.run { reader.safety = SafetyLists(blocked: ["tgs_ana"]) }
        let response = try await get("/history/waveloop_devlog?limit=1")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual((response.json?["posts"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(response.json?["exhausted"] as? Bool, false)
        XCTAssertNotNil(response.json?["nextCursor"] as? String)
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

    func testScopeRejectsUnsupportedReplacementBodies() async throws {
        // Only the explicit PATCH delta is accepted; replacement bodies and read queries fail closed.
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

    func testAgentScopeDeltaPreservesSourcesAndWriteGrants() async throws {
        let before = try await get("/scope")
        let oldNames = Set(try XCTUnwrap(before.json?["sources"] as? [[String: Any]]).compactMap { $0["username"] as? String })
        await MainActor.run { reader.writes = ConnectorWrites(post: true, comment: false, card: false) }
        let result = try await send("PATCH", "/scope", token: reader.tokenValue,
                                    body: #"{"add":["@Captain_Log","captain_log"]}"#)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.json?["preset"] as? String, "custom")
        let names = Set(try XCTUnwrap(result.json?["sources"] as? [[String: Any]]).compactMap { $0["username"] as? String })
        XCTAssertEqual(names, oldNames.union(["captain_log"]))
        let status = try await get("/status")
        XCTAssertEqual(status.json?["writes"] as? [String: Bool], ["post": true, "comment": false, "card": false])
        let audit = try await get("/audit")
        XCTAssertTrue(audit.body.contains("captain_log"))
        let removed = try await send("PATCH", "/scope", token: reader.tokenValue,
                                     body: #"{"remove":["captain_log"]}"#)
        XCTAssertEqual(removed.status, 200)
        XCTAssertEqual(removed.json?["count"] as? Int, oldNames.count)
    }

    func testScopeEditsRequireAuthAndRejectAmbiguousNames() async throws {
        let denied = try await send("PATCH", "/scope", token: nil, body: #"{"add":["captain_log"]}"#)
        XCTAssertEqual(denied.status, 401)
        for body in [#"{"add":["*"]}"#, #"{"add":["captain_log"],"remove":["@CAPTAIN_LOG"]}"#, #"{}"#] {
            let response = try await send("PATCH", "/scope", token: reader.tokenValue, body: body)
            XCTAssertEqual(response.status, 400)
        }
        let scope = try await get("/scope")
        XCTAssertEqual(scope.json?["preset"] as? String, "graph")
    }

    // MARK: 2b — the safety lists (PRODUCT §2.15–§2.20, PROTOCOL §7.1)

    /// A second in-scope post in the same channel, by a node the reader has not blocked, so every
    /// test below can tell "the blocked one is gone" apart from "the response came back empty".
    private func addUnblockedPost() async -> Post {
        let post = ConnectorFixture.post(feed: "waveloop_devlog", title: "WaveLoop devlog",
                                         node: "tgs_bob", nodeName: "Bob",
                                         messageId: 145 << 20, date: 1_787_501_920, text: "still here")
        await MainActor.run { reader.window.insert(post, at: 0) }
        return post
    }

    /// Settings, verbatim: "Blocked and reported content is hidden everywhere in the app" (§2.20),
    /// and §2.18's filter has no switch. The bridge is one of the places it is hidden.
    func testABlockedNodesPostsAreNotServedAnywhere() async throws {
        _ = await addUnblockedPost()
        await MainActor.run { reader.safety = SafetyLists(blocked: ["tgs_ana"]) }

        let feed = try await get("/feed")
        XCTAssertEqual((feed.json?["posts"] as? [[String: Any]])?.map { $0["node"] as? String }, ["tgs_bob"])
        XCTAssertFalse(feed.body.contains("shipped the sequencer"))

        // The channel's own route, which the app filters too (§2.16: "feed channel screens").
        let channel = try await get("/feed/waveloop_devlog")
        XCTAssertEqual((channel.json?["posts"] as? [[String: Any]])?.map { $0["node"] as? String }, ["tgs_bob"])

        // And search, whose corpus is the same window (§2.18 names it).
        let search = try await get("/search?q=sequencer")
        XCTAssertEqual((search.json?["posts"] as? [[String: Any]])?.count, 0)
    }

    /// The case number 2 in §2.15: reported, hidden immediately, and hidden everywhere — including
    /// the bytes behind it, which are the post.
    func testAReportedPostIsGoneAndItsThreadAndMediaAre404() async throws {
        _ = await addUnblockedPost()
        let hidden = HiddenItem(key: "waveloop_devlog/144", reason: "Spam", at: "2026-09-04T21:02:11Z")
        await MainActor.run {
            reader.safety = SafetyLists(hidden: [hidden])
            reader.window[1].media = [ConnectorFixture.photo()]
        }
        let reported = await MainActor.run { reader.window[1] }

        let feed = try await get("/feed")
        XCTAssertEqual((feed.json?["posts"] as? [[String: Any]])?.map { $0["node"] as? String }, ["tgs_bob"])

        let thread = try await get("/thread/waveloop_devlog/144")
        XCTAssertEqual(thread.status, 404)
        XCTAssertEqual(thread.error, "not found")
        // The reason the reader gave is theirs; nothing about the list crosses the bridge.
        XCTAssertFalse(thread.body.contains("Spam"))

        let media = try await get("/media/\(reported.id)/0")
        XCTAssertEqual(media.status, 404)
    }

    /// A block reaches the comment tree as well, and transitively (PRODUCT §2.18) — the post it
    /// hangs under is someone else's and stays.
    func testABlockedNodesCommentsLeaveTheThread() async throws {
        let post = await addUnblockedPost()
        await MainActor.run { reader.safety = SafetyLists(blocked: ["tgs_ana"]) }

        let thread = try await get("/thread/waveloop_devlog/145")
        XCTAssertEqual(thread.status, 200)
        XCTAssertEqual((thread.json?["post"] as? [String: Any])?["id"] as? String, post.id)
        XCTAssertEqual((thread.json?["comments"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(thread.body.contains("nice"))
    }

    /// Mute is the softer one (§2.17): the feed's posts leave the merge and nothing else changes,
    /// so the channel's own route still answers with the whole channel.
    func testAMutedFeedLeavesTheMergedFeedAndNothingElse() async throws {
        await MainActor.run { reader.safety = SafetyLists(mutedFeeds: ["waveloop_devlog"]) }

        let feed = try await get("/feed")
        XCTAssertEqual((feed.json?["posts"] as? [[String: Any]])?.count, 0)

        let channel = try await get("/feed/waveloop_devlog")
        XCTAssertEqual((channel.json?["posts"] as? [[String: Any]])?.count, 1)
    }

    /// §2.16 removes a blocked node from "both graph lists"; this is the same graph.
    func testABlockedNodeIsNotInTheGraph() async throws {
        let before = try await get("/graph?depth=2")
        XCTAssertTrue(before.body.contains("tgs_ana"), "the fixture graph has to contain them to prove they leave")

        await MainActor.run { reader.safety = SafetyLists(blocked: ["tgs_ana"]) }
        let after = try await get("/graph?depth=2")
        XCTAssertEqual(after.status, 200)
        XCTAssertFalse(after.body.contains("tgs_ana"))
    }

    /// A page the filter thinned still hands back a cursor: §2.18 says pagination compensates, and
    /// a short page whose `nextBefore` was null would strand every older post behind the one that
    /// was dropped.
    func testAThinnedChannelPageStillOffersACursor() async throws {
        _ = await addUnblockedPost()
        await MainActor.run { reader.safety = SafetyLists(blocked: ["tgs_ana"]) }

        // Two posts in the channel, one of them blocked, asked for two.
        let response = try await get("/feed/waveloop_devlog?limit=2")
        XCTAssertEqual((response.json?["posts"] as? [[String: Any]])?.count, 1)
        // The oldest post considered was @tgs_ana's, so that is where the next page starts.
        XCTAssertEqual(response.json?["nextBefore"] as? String, "2026-08-23T16:02:00Z")
    }

    /// The lists are compared through `usernameKey` (PROTOCOL §7.1), so a card that spells the
    /// username with capitals is not a hole in the filter.
    func testTheFilterIsCaseInsensitive() async throws {
        _ = await addUnblockedPost()
        await MainActor.run {
            reader.window[1].authorUsername = "TGS_Ana"
            reader.safety = SafetyLists(blocked: ["tgs_ana"])
        }
        let feed = try await get("/feed")
        XCTAssertEqual((feed.json?["posts"] as? [[String: Any]])?.map { $0["node"] as? String }, ["tgs_bob"])
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

    func testControlDiscoveryAndRefreshRequireAuthentication() async throws {
        for (method, path) in [("GET", "/capabilities"), ("GET", "/connections"),
                               ("GET", "/channels?q=Captain"), ("POST", "/refresh")] {
            let response = try await send(method, path, token: nil)
            XCTAssertEqual(response.status, 401)
        }
        let capabilities = try await get("/capabilities")
        let actions = try XCTUnwrap(capabilities.json?["actions"] as? [[String: Any]])
        XCTAssertTrue(actions.contains { $0["path"] as? String == "/history/{username}" })
        XCTAssertEqual(capabilities.json?["uiRequiredForRequests"] as? Bool, false)
        let channels = try await get("/channels?q=Captain")
        XCTAssertEqual(channels.status, 200)
        XCTAssertEqual((channels.json?["channels"] as? [[String: String]])?.first?["username"], "public_channel")
        let invalid = try await get("/channels")
        XCTAssertEqual(invalid.status, 400)
        let refreshed = try await send("POST", "/refresh", token: stubConnectorToken)
        XCTAssertEqual(refreshed.status, 200)
        await MainActor.run {
            XCTAssertEqual(reader.discoveryQueries, ["Captain"])
            XCTAssertEqual(reader.refreshCount, 1)
            XCTAssertEqual(reader.writes, .none)
        }
    }

    func testUploadRoutesRequirePostGrantScopeAndAuthentication() async throws {
        let id = "upload-router-test"
        let spec = #"{"feed":"waveloop_devlog","kind":"document","filename":"test.txt","bytes":5,"sha256":"0000000000000000000000000000000000000000000000000000000000000000","caption":""}"#
        let denied = try await send("POST", "/uploads/\(id)", token: stubConnectorToken, body: spec)
        XCTAssertEqual(denied.status, 403)
        let unauthenticated = try await send("GET", "/uploads/\(id)", token: nil)
        XCTAssertEqual(unauthenticated.status, 401)
        await MainActor.run { reader.writes.post = true }
        let allowed = try await send("POST", "/uploads/\(id)", token: stubConnectorToken, body: spec)
        XCTAssertEqual(allowed.status, 200)
        let outside = spec.replacingOccurrences(of: "waveloop_devlog", with: "stranger_feed")
        let refused = try await send("POST", "/uploads/\(id)", token: stubConnectorToken, body: outside)
        XCTAssertEqual(refused.status, 403)
        let invalid = try await get("/uploads/a")
        XCTAssertEqual(invalid.status, 404)
    }

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

    func testFileTransferCrossesChunkBoundariesAndReportsProgress() async throws {
        let count = ConnectorServer.fileChunkBytes * 3 + 17
        let post = await MainActor.run {
            reader.mediaLength = count
            reader.window[0].media = [ConnectorFixture.photo()]
            return reader.window[0]
        }
        let response = try await get("/media/\(post.id)/0")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-length"], String(count))
        XCTAssertEqual(response.body, String(repeating: "*", count: count))
        let progress = try await get("/media/\(post.id)/0/status")
        XCTAssertEqual(progress.json?["complete"] as? Bool, true)
        let refused = try await send("GET", "/media/\(post.id)/0/status", token: nil)
        XCTAssertEqual(refused.status, 401)
    }

    func testMediaScopeRevokedDuringPreparationIsRechecked() async throws {
        let post = await MainActor.run {
            reader.revokeMediaScope = true
            reader.window[0].media = [ConnectorFixture.photo()]
            return reader.window[0]
        }
        let response = try await get("/media/\(post.id)/0")
        XCTAssertEqual(response.status, 403)
    }

    func testTemporaryFileCleanupWaitsForLastResponseOwner() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([42]).write(to: url)
        var body: ConnectorFileBody? = try ConnectorFileBody(url: url, maxBytes: 8, onClose: {
            try? FileManager.default.removeItem(at: url)
        })
        var owners = [try XCTUnwrap(body)]
        body = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try owners[0].read(upToCount: 1), Data([42]))
        owners.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFileSizeChecksRejectOversizedOrIncompleteCache() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 42, count: 9).write(to: url)
        XCTAssertThrowsError(try ConnectorFileBody(url: url, maxBytes: 8)) { error in
            XCTAssertEqual(error as? ConnectorError, .tooLarge(bytes: 9, maxBytes: 8))
        }
        XCTAssertThrowsError(try ConnectorFileBody(url: url, maxBytes: 20, expectedBytes: 10))
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
