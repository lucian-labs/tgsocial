// Unit tests — the Connector's pure parts (CONNECTOR.md §2, §3, §4, §6).
//
// Mac only, like the bridge itself: `make test` builds the iOS simulator, where these compile to
// nothing, and `make mac-test` is where they run.

#if targetEnvironment(macCatalyst)

import Foundation
import XCTest
@testable import tgsocial

// MARK: - Fixtures

enum ConnectorFixture {
    static func post(feed: String = "waveloop_devlog",
                     title: String = "WaveLoop devlog",
                     node: String? = "tgs_ana",
                     nodeName: String? = "Ana Iliovic",
                     messageId: Int64 = 144 << 20,
                     chatId: Int64 = -100_1,
                     date: Int = 1_787_500_920,
                     text: String = "shipped the sequencer",
                     media: [PostMedia] = [],
                     views: Int = 1200,
                     reactions: [Reaction] = [Reaction(emoji: "\u{1F525}", count: 14)]) -> Post {
        Post(messageId: messageId, chatId: chatId, sourceKey: Username.key(feed),
             sourceUsername: feed, sourceTitle: title, sourcePhoto: nil,
             date: date, text: RichText(spans: [RichSpan(text: text, kind: .plain, url: nil)]),
             media: media, albumId: 0, albumMessageIds: [messageId],
             views: views, reactions: reactions,
             forwardedFrom: nil, forwardedChatId: nil, forwardedUserId: nil,
             isPending: false, authorUsername: node, authorName: nodeName, authorPhoto: nil)
    }

    static func photo(width: Int = 1280, height: Int = 960) -> PostMedia {
        let ref = PhotoRef(fileId: 7, uniqueId: "u7", width: width, height: height, minithumbnail: nil)
        return .photo(preview: ref, full: ref)
    }

    static func node(_ username: String, card: Card?, state: CardState = .ok) -> NodeInfo {
        NodeInfo(username: username, chatId: -100_2, title: "Node", card: card, state: state,
                 photo: nil, fetchedAt: Date(timeIntervalSince1970: 1_787_500_000))
    }

    static func feed(_ username: String, title: String = "A feed", description: String = "") -> FeedInfo {
        FeedInfo(username: username, chatId: -100_3, title: title, description: description,
                 photo: nil, fetchedAt: Date(timeIntervalSince1970: 1_787_500_000))
    }

    static func comment(channel: String = "tgs_ana_r", owner: String = "tgs_ana",
                        target: String = "https://t.me/waveloop_devlog/144",
                        body: String = "nice", messageId: Int64 = 9 << 20) -> Comment {
        Comment(channelUsername: channel, chatId: -100_4, messageId: messageId,
                date: 1_787_500_930, target: target, body: body, media: [],
                ownerUsername: owner, ownerTitle: "Ana Iliovic", ownerPhoto: nil,
                isPlusOne: false, isMine: false, isPending: false)
    }

    /// A graph with me (`tgs_me`, feeds `my_feed`, replies `tgs_me_r`) following `tgs_ana`
    /// (feed `waveloop_devlog`, replies `tgs_ana_r`), plus a stranger nobody lists.
    static var inputs: ScopeInputs {
        var inputs = ScopeInputs()
        inputs.myNode = "tgs_me"
        inputs.myCard = ScopeCardFacts(feeds: ["my_feed"], replies: "tgs_me_r")
        inputs.follows = ["tgs_ana"]
        inputs.followCards["tgs_ana"] = ScopeCardFacts(feeds: ["waveloop_devlog"], replies: "tgs_ana_r")
        inputs.custom = ["listed_only"]
        return inputs
    }

    static func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("connector-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Scope (CONNECTOR.md §3)

final class ConnectorScopeTests: XCTestCase {

    func testGraphResolvesMyCardAndTheCardsOfNodesIFollow() {
        let scope = ScopeResolver.resolve(preset: .graph, inputs: ConnectorFixture.inputs)
        XCTAssertEqual(scope.sources.map(\.username),
                       ["tgs_me", "my_feed", "tgs_me_r", "tgs_ana", "waveloop_devlog", "tgs_ana_r"])
        XCTAssertEqual(scope.sources.map(\.kind), [.node, .feed, .replies, .node, .feed, .replies])
        XCTAssertEqual(scope.preset, .graph)
        XCTAssertEqual(scope.count, 6)
    }

    func testMineStopsAtMyOwnCard() {
        let scope = ScopeResolver.resolve(preset: .mine, inputs: ConnectorFixture.inputs)
        XCTAssertEqual(scope.sources.map(\.username), ["tgs_me", "my_feed", "tgs_me_r"])
        // The whole point of `mine`: a node I follow, and its feed, are not readable.
        XCTAssertFalse(scope.contains("tgs_ana"))
        XCTAssertFalse(scope.contains("waveloop_devlog"))
    }

    func testCustomIsExactlyTheListedUsernames() {
        let scope = ScopeResolver.resolve(preset: .custom, inputs: ConnectorFixture.inputs)
        XCTAssertEqual(scope.sources.map(\.username), ["listed_only"])
        // A custom entry drags nothing in behind it — not my own feeds, not my own card.
        XCTAssertFalse(scope.contains("tgs_me"))
        XCTAssertFalse(scope.contains("my_feed"))
    }

    func testAnEmptyCustomListExposesNothing() {
        var inputs = ConnectorFixture.inputs
        inputs.custom = []
        let scope = ScopeResolver.resolve(preset: .custom, inputs: inputs)
        XCTAssertEqual(scope.count, 0)
        XCTAssertThrowsError(try scope.admit("tgs_me"))
    }

    func testAdmitRefusesAnythingOutsideTheResolvedSet() {
        let scope = ScopeResolver.resolve(preset: .graph, inputs: ConnectorFixture.inputs)
        XCTAssertThrowsError(try scope.admit("some_stranger")) { error in
            XCTAssertEqual(error as? ConnectorError, .outOfScope("some_stranger"))
        }
        // A username that is not a username at all is refused the same way, not crashed on.
        XCTAssertThrowsError(try scope.admit("../../etc/passwd"))
        XCTAssertThrowsError(try scope.admit(""))
    }

    /// The refusal detail is echoed in the 403 body and written to the audit log, so it carries a
    /// normalised username or a fixed phrase — never whatever the caller put in the path.
    func testARefusalNeverQuotesTheRawInputBack() {
        let scope = ScopeResolver.resolve(preset: .graph, inputs: ConnectorFixture.inputs)
        XCTAssertThrowsError(try scope.admit("@Some_Stranger")) { error in
            XCTAssertEqual(error as? ConnectorError, .outOfScope("Some_Stranger"))
        }
        for raw in ["../../etc/passwd", "tgs_ana\r\nforged", "", "@"] {
            XCTAssertThrowsError(try scope.admit(raw)) { error in
                XCTAssertEqual(error as? ConnectorError, .outOfScope("not a username"))
            }
        }
    }

    func testAdmitNormalisesTheFormsAPathCanCarry() throws {
        let scope = ScopeResolver.resolve(preset: .graph, inputs: ConnectorFixture.inputs)
        XCTAssertEqual(try scope.admit("TGS_ANA").username, "TGS_ANA")
        XCTAssertEqual(try scope.admit("@tgs_ana").username, "tgs_ana")
        XCTAssertEqual(try scope.admit("https://t.me/tgs_ana").username, "tgs_ana")
        XCTAssertEqual(try scope.admit("TGS_ANA").key, "tgs_ana")
    }

    func testAFollowWithNoCachedCardContributesOnlyItself() {
        var inputs = ConnectorFixture.inputs
        inputs.followCards = [:]
        let scope = ScopeResolver.resolve(preset: .graph, inputs: inputs)
        XCTAssertTrue(scope.contains("tgs_ana"))
        // Its feeds are simply not in scope yet — never guessed at.
        XCTAssertFalse(scope.contains("waveloop_devlog"))
    }

    func testDuplicatesCollapseAcrossCards() {
        var inputs = ConnectorFixture.inputs
        inputs.myCard = ScopeCardFacts(feeds: ["waveloop_devlog"], replies: nil)
        let scope = ScopeResolver.resolve(preset: .graph, inputs: inputs)
        XCTAssertEqual(scope.sources.filter { Username.key($0.username) == "waveloop_devlog" }.count, 1)
    }

    func testSummaryIsTheScreenCopyWithTheLiveCount() {
        let graph = ScopeResolver.resolve(preset: .graph, inputs: ConnectorFixture.inputs)
        XCTAssertEqual(graph.summary,
                       "6 sources \u{2014} your feeds and the feeds of the nodes you follow. Private chats are never included.")
        let custom = ScopeResolver.resolve(preset: .custom, inputs: ConnectorFixture.inputs)
        XCTAssertEqual(custom.summary,
                       "1 source \u{2014} exactly the usernames you list. Private chats are never included.")
    }

    func testNoPresetAdmitsAUsernameThatIsInNoCard() {
        // The stand-in for a private chat or a DM: a username that appears in no card's feeds,
        // follows or replies list. There is no preset under which it resolves.
        for preset in ScopePreset.allCases {
            let scope = ScopeResolver.resolve(preset: preset, inputs: ConnectorFixture.inputs)
            XCTAssertThrowsError(try scope.admit("private_person"), "\(preset) admitted a chat no card names")
        }
    }
}

// MARK: - Token (CONNECTOR.md §2)

final class ConnectorTokenTests: XCTestCase {

    func testGeneratedTokenIs32Base64urlBytes() throws {
        let token = ConnectorToken.generate()
        XCTAssertEqual(token.count, ConnectorToken.encodedLength)
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertNil(token.unicodeScalars.first { !allowed.contains($0) })

        var padded = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        let decoded = try XCTUnwrap(Data(base64Encoded: padded))
        XCTAssertEqual(decoded.count, ConnectorToken.byteCount)
    }

    func testTokensDoNotRepeat() {
        let tokens = Set((0..<64).map { _ in ConnectorToken.generate() })
        XCTAssertEqual(tokens.count, 64)
    }

    func testMatchesAcceptsOnlyTheExactToken() {
        let token = ConnectorToken.generate()
        XCTAssertTrue(ConnectorToken.matches(expected: token, presented: token))
        XCTAssertFalse(ConnectorToken.matches(expected: token, presented: String(token.dropLast())))
        XCTAssertFalse(ConnectorToken.matches(expected: token, presented: token + "x"))
        XCTAssertFalse(ConnectorToken.matches(expected: token, presented: ""))
        XCTAssertFalse(ConnectorToken.matches(expected: token, presented: token.uppercased() + " "))
    }

    func testAnEmptySecretMatchesNothing() {
        // Before the first enable there is no token; that state must not authenticate anyone,
        // least of all a client that also sends nothing.
        XCTAssertFalse(ConnectorToken.matches(expected: "", presented: ""))
        XCTAssertFalse(ConnectorToken.matches(expected: "", presented: "anything"))
    }

    /// The comparison must not short-circuit at the first differing byte. With a 4096-byte secret,
    /// a naive `==` would return roughly a thousand times faster when the mismatch is at byte 0
    /// than when it is at the last byte; a constant-time fold shows no such gap. The assertion
    /// band is deliberately enormous (0.4×–2.5×) so ordinary scheduler noise cannot fail it while
    /// a short-circuit still cannot pass it.
    func testMatchesDoesNotShortCircuit() {
        let secret = String(repeating: "a", count: 4096)
        var earlyMiss = secret; earlyMiss.replaceSubrange(earlyMiss.startIndex...earlyMiss.startIndex, with: "b")
        var lateMiss = secret; lateMiss.replaceSubrange(lateMiss.index(before: lateMiss.endIndex)..<lateMiss.endIndex, with: "b")

        func elapsed(_ presented: String) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = false
            for _ in 0..<2_000 { sink = ConnectorToken.matches(expected: secret, presented: presented) || sink }
            XCTAssertFalse(sink)
            return Double(DispatchTime.now().uptimeNanoseconds - start)
        }

        // Medians over several trials: one slow trial should not decide a timing question.
        var ratios: [Double] = []
        for _ in 0..<9 {
            let early = elapsed(earlyMiss)
            let late = elapsed(lateMiss)
            ratios.append(early / max(late, 1))
        }
        let median = ratios.sorted()[ratios.count / 2]
        XCTAssertGreaterThan(median, 0.4, "an early mismatch returned far too fast — the compare is short-circuiting")
        XCTAssertLessThan(median, 2.5, "timing is wildly asymmetric")
    }

    func testBearerParsing() {
        XCTAssertEqual(ConnectorToken.bearer("Bearer abc"), "abc")
        XCTAssertEqual(ConnectorToken.bearer("bearer   abc  "), "abc")
        XCTAssertNil(ConnectorToken.bearer("Basic abc"))
        XCTAssertNil(ConnectorToken.bearer("Bearer"))
        XCTAssertNil(ConnectorToken.bearer("Bearer "))
        XCTAssertNil(ConnectorToken.bearer(nil))
    }
}

// MARK: - Handshake file (CONNECTOR.md §2)

final class ConnectorHandshakeTests: XCTestCase {

    func testHandshakeIsWritten0600InsideA0700Directory() throws {
        let home = ConnectorFixture.temporaryDirectory("handshake")
        let store = ConnectorHandshakeStore(directory: home.appendingPathComponent(".tgsocial", isDirectory: true))
        let handshake = ConnectorHandshake(port: 8477, token: ConnectorToken.generate(),
                                           enabled: true, version: ConnectorHandshake.currentVersion)
        try store.write(handshake)

        XCTAssertEqual(store.mode(of: store.fileURL), 0o600)
        XCTAssertEqual(store.mode(of: store.directory), 0o700)
        XCTAssertEqual(store.read(), handshake)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["port", "token", "enabled", "version"])
        XCTAssertEqual(json["version"] as? Int, 1)
    }

    func testRemoveWipesTheToken() throws {
        let home = ConnectorFixture.temporaryDirectory("wipe")
        let store = ConnectorHandshakeStore(directory: home.appendingPathComponent(".tgsocial", isDirectory: true))
        try store.write(ConnectorHandshake(port: 8477, token: "t", enabled: true, version: 1))
        store.remove()
        XCTAssertNil(store.read())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testALooseDirectoryIsTightenedBeforeTheTokenLands() throws {
        let home = ConnectorFixture.temporaryDirectory("loose")
        let directory = home.appendingPathComponent(".tgsocial", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: NSNumber(value: 0o755)])
        let store = ConnectorHandshakeStore(directory: directory)
        try store.write(ConnectorHandshake(port: 1, token: "t", enabled: false, version: 1))
        XCTAssertEqual(store.mode(of: directory), 0o700)
    }
}

// MARK: - Audit (CONNECTOR.md §6)

final class ConnectorAuditTests: XCTestCase {

    private func at(_ iso: String) -> Date {
        ConnectorJSON.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    func testLinesMatchTheDocumentedFormat() {
        let feed = AuditEntry(tool: "GET /feed", decision: "scope=graph", outcome: .ok,
                              detail: "posts=30", at: at("2026-08-24T14:02:03Z"))
        XCTAssertEqual(feed.line, "2026-08-24T14:02:03Z  GET /feed        scope=graph ok      posts=30")

        let node = AuditEntry(tool: "GET /node/tgs_ana", decision: "scope=graph", outcome: .ok,
                              detail: "cached", at: at("2026-08-24T14:02:11Z"))
        XCTAssertEqual(node.line, "2026-08-24T14:02:11Z  GET /node/tgs_ana scope=graph ok      cached")

        let refusal = AuditEntry(tool: "POST /post", decision: "feed=waveloop_devlog",
                                 outcome: .refused("read-only"), at: at("2026-08-24T14:03:40Z"))
        XCTAssertEqual(refusal.line, "2026-08-24T14:03:40Z  POST /post       feed=waveloop_devlog REFUSED read-only")
    }

    func testTimestampsAreUTCWhateverTheDeviceIsSetTo() {
        let entry = AuditEntry(tool: "GET /status", decision: "scope=mine", outcome: .ok,
                               at: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(entry.line.hasPrefix("1970-01-01T00:00:00Z"))
    }

    func testTheRingKeepsTheNewestHundredNewestFirst() async {
        let ring = await AuditRing(file: nil)
        for i in 0..<(AuditRing.capacity + 20) {
            await ring.append(AuditEntry(tool: "GET /feed", decision: "scope=graph", outcome: .ok, detail: "n=\(i)"))
        }
        let entries = await ring.entries
        XCTAssertEqual(entries.count, AuditRing.capacity)
        XCTAssertEqual(entries.first?.detail, "n=\(AuditRing.capacity + 19)")
        XCTAssertEqual(entries.last?.detail, "n=20")
    }

    func testClearEmptiesTheRingAndLeavesTheFile() async throws {
        let directory = ConnectorFixture.temporaryDirectory("clear")
        let file = AuditLogFile(directory: directory)
        let ring = await AuditRing(file: file)
        await ring.append(AuditEntry(tool: "GET /feed", decision: "scope=graph", outcome: .ok, detail: "posts=1"))
        await ring.clear()
        let entries = await ring.entries
        XCTAssertTrue(entries.isEmpty)
        // PRODUCT §2.14: "clears the on-screen ring, not the log file."
        let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("posts=1"))
    }

    func testTheLogFileIs0600AndAppends() throws {
        let directory = ConnectorFixture.temporaryDirectory("append")
        let file = AuditLogFile(directory: directory)
        file.append("one")
        file.append("two")
        let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "one\ntwo\n")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size] != nil
            ? (FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
            : nil)
        XCTAssertEqual(mode, 0o600)
    }

    func testItRotatesAtFiveMegabytes() throws {
        let directory = ConnectorFixture.temporaryDirectory("rotate")
        let file = AuditLogFile(directory: directory)
        // One line short of the threshold, then one line over it.
        let filler = String(repeating: "x", count: 1024)
        func size() -> UInt64 {
            ((try? FileManager.default.attributesOfItem(atPath: file.fileURL.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        }
        while size() < AuditLogFile.rotateAtBytes { file.append(filler) }
        XCTAssertGreaterThanOrEqual(size(), AuditLogFile.rotateAtBytes)

        file.append("after rotation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.rotatedURL.path))
        let current = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertEqual(current, "after rotation\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.rotatedURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testARefusalCarriesTheReasonAndNeverABody() {
        let entry = AuditEntry(tool: "GET /feed/private_person", decision: "scope=graph",
                               outcome: .refused("out-of-scope"), detail: "private_person")
        XCTAssertEqual(entry.detailColumn, "out-of-scope private_person")
        XCTAssertTrue(entry.line.contains("REFUSED"))
    }

    /// The tool column is the method plus the *percent-decoded* request target, and it is written
    /// on the 401 branch — before any token is checked. A field that could carry a newline would
    /// let an unauthenticated local process append a plausible `ok` row and strip the outcome
    /// column off the genuine one. One entry, one line, whatever the field holds.
    func testAFieldCannotEndTheLineOrStartAnother() {
        let forged = "2026-08-24T00:00:00Z  GET /feed  scope=graph ok      posts=30"
        let entry = AuditEntry(tool: "GET /feed\r\n" + forged, decision: "auth=bearer",
                               outcome: .refused("unauthorized"), detail: "x\u{2028}y\u{0085}z\tw",
                               at: at("2026-08-24T17:00:00Z"))

        XCTAssertEqual(entry.line.components(separatedBy: "\n").count, 1)
        XCTAssertFalse(entry.line.contains("\r"))
        XCTAssertTrue(entry.line.hasPrefix("2026-08-24T17:00:00Z  GET /feed\\x0d\\x0a"))
        // Escaped, not dropped: the log still says what was asked, it just cannot be asked to lie.
        XCTAssertTrue(entry.tool.contains("\\x0d\\x0a"))
        XCTAssertTrue(entry.detail.contains("\\u{2028}"))
        XCTAssertTrue(entry.detail.contains("\\x85"))
        XCTAssertTrue(entry.detail.contains("\\x09"))
        XCTAssertFalse(AuditField.isPrintable("\u{202E}"))
        XCTAssertFalse(AuditField.isPrintable("\u{200B}"))
    }

    func testTheFileSinkGetsExactlyOneLinePerEntry() async throws {
        let directory = ConnectorFixture.temporaryDirectory("injection")
        let file = AuditLogFile(directory: directory)
        let ring = await AuditRing(file: file)
        await ring.append(AuditEntry(tool: "GET /feed\r\n2026-08-24T00:00:00Z  GET /feed  scope=graph ok  posts=30",
                                     decision: "auth=bearer", outcome: .refused("unauthorized")))
        let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(contents.hasSuffix("REFUSED unauthorized\n"))
        let entries = await ring.entries
        XCTAssertEqual(entries.count, 1)
    }

    func testFieldsAreCappedSoOneRequestCannotFloodTheLog() {
        let long = String(repeating: "a", count: 4096)
        let entry = AuditEntry(tool: "GET /" + long, decision: long, outcome: .ok, detail: long)
        XCTAssertEqual(entry.tool.count, AuditField.toolLimit + AuditField.cut.count)
        XCTAssertEqual(entry.decision.count, AuditField.decisionLimit + AuditField.cut.count)
        XCTAssertEqual(entry.detail.count, AuditField.detailLimit + AuditField.cut.count)
        XCTAssertTrue(entry.tool.hasSuffix(AuditField.cut))
        XCTAssertLessThan(entry.line.count, 1024)
    }

    /// The scrub is not allowed to rewrite the lines §6 documents, and a legible non-ASCII
    /// character — the em dash the refusal copy uses — is not a control character.
    func testOrdinaryFieldsPassThroughUntouched() {
        XCTAssertEqual(AuditField.clean("GET /node/tgs_ana", limit: AuditField.toolLimit), "GET /node/tgs_ana")
        XCTAssertEqual(AuditField.clean("posts=30", limit: AuditField.detailLimit), "posts=30")
        let detail = "post to @tgs_ana \u{2014} not one of your feeds"
        XCTAssertEqual(AuditField.clean(detail, limit: AuditField.detailLimit), detail)
    }
}

// MARK: - JSON bodies (CONNECTOR.md §4)

final class ConnectorBodyTests: XCTestCase {

    private var scope: ScopeResolution {
        ScopeResolver.resolve(preset: .graph, inputs: ConnectorFixture.inputs)
    }

    private func roundTrip(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testStatusShape() throws {
        let body = try roundTrip(ConnectorBodies.status(signedIn: true, account: "+1 604 \u{2022}\u{2022}\u{2022} 0199",
                                                        node: "tgs_me", scope: scope,
                                                        writes: ConnectorWrites(post: false, comment: true, card: false),
                                                        tdlib: "1.8.66", app: "1.0.0 (202608240210)"))
        XCTAssertEqual(Set(body.keys), ["signedIn", "account", "node", "scope", "writes", "tdlib", "app"])
        XCTAssertEqual(body["signedIn"] as? Bool, true)
        let scopeBody = try XCTUnwrap(body["scope"] as? [String: Any])
        XCTAssertEqual(scopeBody["preset"] as? String, "graph")
        XCTAssertEqual(scopeBody["sources"] as? Int, 6)
        let writes = try XCTUnwrap(body["writes"] as? [String: Any])
        XCTAssertEqual(Set(writes.keys), ["post", "comment", "card"])
        XCTAssertEqual(writes["comment"] as? Bool, true)
    }

    func testStatusKeepsEveryKeyWhenSignedOut() throws {
        let body = try roundTrip(ConnectorBodies.status(signedIn: false, account: nil, node: nil, scope: scope,
                                                        writes: .none, tdlib: "", app: "1.0.0 (1)"))
        XCTAssertEqual(Set(body.keys), ["signedIn", "account", "node", "scope", "writes", "tdlib", "app"])
        XCTAssertTrue(body["account"] is NSNull)
        XCTAssertTrue(body["node"] is NSNull)
    }

    func testPostShape() throws {
        let post = ConnectorFixture.post(media: [ConnectorFixture.photo()])
        let body = try roundTrip(ConnectorBodies.post(post, comments: 3))
        XCTAssertEqual(Set(body.keys), ["id", "date", "node", "nodeName", "feed", "feedTitle",
                                        "text", "media", "views", "reactions", "comments", "link"])
        XCTAssertEqual(body["feed"] as? String, "waveloop_devlog")
        XCTAssertEqual(body["node"] as? String, "tgs_ana")
        XCTAssertEqual(body["views"] as? Int, 1200)
        // §4 shows a single number: reaction counts summed, not the emoji breakdown.
        XCTAssertEqual(body["reactions"] as? Int, 14)
        XCTAssertEqual(body["comments"] as? Int, 3)
        XCTAssertEqual(body["link"] as? String, "https://t.me/waveloop_devlog/144")
        XCTAssertEqual(body["date"] as? String, ConnectorJSON.string(fromUnix: post.date))
        XCTAssertTrue((body["date"] as? String)?.hasSuffix("Z") ?? false)
    }

    func testMediaIsDescribedAndNeverCarried() throws {
        let post = ConnectorFixture.post(media: [ConnectorFixture.photo()])
        let body = try roundTrip(ConnectorBodies.post(post, comments: 0))
        let media = try XCTUnwrap((body["media"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(media.keys), ["index", "kind", "caption", "durationSeconds", "width", "height", "fileName", "bytes"])
        XCTAssertEqual(media["kind"] as? String, "photo")
        XCTAssertEqual(media["width"] as? Int, 1280)
        // §4's example is explicit: a photo's duration is null, not missing.
        XCTAssertTrue(media["durationSeconds"] is NSNull)
        // The caption of the first item is the message text, which is Telegram's own model.
        XCTAssertEqual(media["caption"] as? String, "shipped the sequencer")
        XCTAssertNil(media["data"])
        XCTAssertNil(media["url"])
    }

    func testVideoCarriesItsDurationAndDimensions() throws {
        let file = FileRef(fileId: 3, uniqueId: "v3", size: 4096, mimeType: "video/mp4",
                           fileName: "clip.mp4", streamable: true)
        let post = ConnectorFixture.post(media: [.video(file: file, thumbnail: nil, duration: 42, width: 1920, height: 1080)])
        let media = try XCTUnwrap((try roundTrip(ConnectorBodies.post(post, comments: 0))["media"] as? [[String: Any]])?.first)
        XCTAssertEqual(media["kind"] as? String, "video")
        XCTAssertEqual(media["durationSeconds"] as? Int, 42)
        XCTAssertEqual(media["width"] as? Int, 1920)
        XCTAssertEqual(media["bytes"] as? Int, 4096)
        XCTAssertEqual(media["fileName"] as? String, "clip.mp4")
    }

    func testFeedPageCarriesNextBefore() throws {
        let posts = [ConnectorFixture.post()]
        let body = try roundTrip(ConnectorBodies.posts(posts, comments: { _ in 0 },
                                                       nextBefore: Date(timeIntervalSince1970: 1_787_000_000)))
        XCTAssertEqual(Set(body.keys), ["posts", "nextBefore"])
        XCTAssertEqual((body["posts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(body["nextBefore"] as? String,
                       ConnectorJSON.string(from: Date(timeIntervalSince1970: 1_787_000_000)))
        XCTAssertEqual(body["nextBefore"] as? String, "2026-08-17T20:53:20Z")

        let last = try roundTrip(ConnectorBodies.posts(posts, comments: { _ in 0 }, nextBefore: nil))
        XCTAssertTrue(last["nextBefore"] is NSNull)
    }

    func testFeedsShape() throws {
        let info = ConnectorFixture.feed("waveloop_devlog", title: "WaveLoop devlog")
        let body = try roundTrip(ConnectorBodies.feeds([(info, "waveloop_devlog", true),
                                                        (nil, "not_cached_yet", false)]))
        let rows = try XCTUnwrap(body["feeds"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows[0].keys), ["username", "title", "verified"])
        XCTAssertEqual(rows[0]["title"] as? String, "WaveLoop devlog")
        XCTAssertEqual(rows[0]["verified"] as? Bool, true)
        XCTAssertTrue(rows[1]["title"] is NSNull)
    }

    func testNodeShape() throws {
        let card = Card(name: "Ana Iliovic", bio: "builds things", link: "https://thevii.app",
                        isPublic: true, feeds: ["waveloop_devlog"], follows: ["tgs_me"], replies: "tgs_ana_r")
        let body = try roundTrip(ConnectorBodies.node(ConnectorFixture.node("tgs_ana", card: card), following: true))
        XCTAssertEqual(Set(body.keys), ["username", "name", "bio", "link", "feeds", "follows", "public", "following"])
        XCTAssertEqual(body["name"] as? String, "Ana Iliovic")
        XCTAssertEqual(body["feeds"] as? [String], ["waveloop_devlog"])
        XCTAssertEqual(body["public"] as? Bool, true)
        XCTAssertEqual(body["following"] as? Bool, true)
    }

    func testGraphShape() throws {
        let body = try roundTrip(ConnectorBodies.graph(nodes: [("tgs_me", "Me", false), ("tgs_ana", nil, true)],
                                                       edges: [("tgs_me", "tgs_ana")]))
        XCTAssertEqual(Set(body.keys), ["nodes", "edges"])
        let nodes = try XCTUnwrap(body["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.count, 2)
        XCTAssertTrue(nodes[1]["name"] is NSNull)
        XCTAssertEqual(body["edges"] as? [[String]], [["tgs_me", "tgs_ana"]])
    }

    func testThreadNestsComments() throws {
        let reply = ConnectorBodies.comment(ConnectorFixture.comment(target: "https://t.me/tgs_ana_r/9",
                                                                     body: "agreed", messageId: 10 << 20),
                                            replies: [])
        let root = ConnectorBodies.comment(ConnectorFixture.comment(), replies: [reply])
        let body = try roundTrip(ConnectorBodies.thread(post: ConnectorBodies.post(ConnectorFixture.post(), comments: 2),
                                                        comments: [root]))
        XCTAssertEqual(Set(body.keys), ["post", "comments"])
        let comments = try XCTUnwrap(body["comments"] as? [[String: Any]])
        XCTAssertEqual(Set(comments[0].keys), ["id", "link", "date", "node", "nodeName", "channel",
                                               "text", "media", "plusOne", "mine", "replies"])
        XCTAssertEqual((comments[0]["replies"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(comments[0]["channel"] as? String, "tgs_ana_r")
    }

    func testAuditShape() throws {
        let entry = AuditEntry(tool: "GET /feed", decision: "scope=graph", outcome: .ok, detail: "posts=30",
                               at: Date(timeIntervalSince1970: 1_787_500_923))
        let body = try roundTrip(ConnectorBodies.audit([entry]))
        let rows = try XCTUnwrap(body["entries"] as? [[String: Any]])
        XCTAssertEqual(Set(rows[0].keys), ["at", "tool", "decision", "outcome", "detail", "line"])
        XCTAssertEqual(rows[0]["outcome"] as? String, "ok")
        XCTAssertEqual(rows[0]["line"] as? String, entry.line)
    }

    func testScopeShapeReportsThePresetAndTheResolvedList() throws {
        let body = try roundTrip(ConnectorBodies.scope(scope))
        XCTAssertEqual(Set(body.keys), ["preset", "sources", "count"])
        XCTAssertEqual(body["preset"] as? String, "graph")
        XCTAssertEqual(body["count"] as? Int, 6)
        let sources = try XCTUnwrap(body["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.first?["username"] as? String, "tgs_me")
        XCTAssertEqual(sources.first?["kind"] as? String, "node")
    }

    func testErrorShapesAreTheOnesDocumented() throws {
        XCTAssertEqual(ConnectorError.unauthorized.status, 401)
        XCTAssertEqual(try roundTrip(ConnectorError.unauthorized.body) as? [String: String], ["error": "unauthorized"])
        XCTAssertEqual(ConnectorError.signedOut.status, 409)
        XCTAssertEqual(try roundTrip(ConnectorError.signedOut.body) as? [String: String], ["error": "signed out"])
        XCTAssertEqual(ConnectorError.readOnly.status, 403)
        XCTAssertEqual(try roundTrip(ConnectorError.readOnly.body) as? [String: String], ["error": "read only"])

        let scoped = try roundTrip(ConnectorError.outOfScope("private_person").body)
        XCTAssertEqual(ConnectorError.outOfScope("x").status, 403)
        XCTAssertEqual(scoped["error"] as? String, "out of scope")
        XCTAssertEqual(scoped["detail"] as? String, "private_person")

        let telegram = try roundTrip(ConnectorError.telegram(code: 400, message: "CHAT_INVALID").body)
        XCTAssertEqual(ConnectorError.telegram(code: 400, message: "x").status, 502)
        XCTAssertEqual(telegram["error"] as? String, "telegram")
        XCTAssertEqual(telegram["code"] as? Int, 400)
        XCTAssertEqual(telegram["message"] as? String, "CHAT_INVALID")

        let flood = try roundTrip(ConnectorError.floodWait(seconds: 23).body)
        XCTAssertEqual(ConnectorError.floodWait(seconds: 23).status, 429)
        XCTAssertEqual(flood["error"] as? String, "flood wait")
        XCTAssertEqual(flood["seconds"] as? Int, 23)

        let large = try roundTrip(ConnectorError.tooLarge(bytes: 40_000_000, maxBytes: 25 * 1024 * 1024).body)
        XCTAssertEqual(ConnectorError.tooLarge(bytes: 1, maxBytes: 2).status, 413)
        XCTAssertEqual(large["error"] as? String, "too large")
    }

    func testTDLibFailuresBecomeTheRightWireError() {
        XCTAssertEqual(ConnectorError.from(TDFailure(code: 429, message: "Too Many Requests: retry after 23")),
                       .floodWait(seconds: 23))
        XCTAssertEqual(ConnectorError.from(TDFailure(code: 400, message: "USERNAME_INVALID")),
                       .telegram(code: 400, message: "USERNAME_INVALID"))
        // A ConnectorError passing back through keeps its own identity.
        XCTAssertEqual(ConnectorError.from(ConnectorError.readOnly), .readOnly)
    }
}

// MARK: - HTTP framing

final class ConnectorHTTPTests: XCTestCase {

    private func parse(_ raw: String) -> ConnectorHTTP.ParseResult {
        ConnectorHTTP.parse(Data(raw.utf8))
    }

    func testParsesMethodPathQueryAndHeaders() throws {
        guard case .request(let request) = parse("GET /feed?limit=5&before=2026-08-24T14%3A02%3A00Z HTTP/1.1\r\nAuthorization: Bearer abc\r\n\r\n") else {
            return XCTFail("expected a request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/feed")
        XCTAssertEqual(request.query["limit"], "5")
        XCTAssertEqual(request.authorization, "Bearer abc")
        XCTAssertEqual(request.segments, ["feed"])
        XCTAssertEqual(request.intQuery("limit", default: 30, max: 100), 5)
        XCTAssertEqual(request.dateQuery("before"), ConnectorJSON.date(from: "2026-08-24T14:02:00Z"))
    }

    func testWaitsForTheBodyBeforeDispatching() {
        if case .incomplete = parse("POST /post HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"feed\"") {} else {
            XCTFail("a short body should be incomplete, not dispatched")
        }
        if case .incomplete = parse("GET /feed HTT") {} else { XCTFail("a partial head should be incomplete") }
    }

    func testLimitsAreClamped() throws {
        guard case .request(let request) = parse("GET /feed?limit=99999 HTTP/1.1\r\n\r\n") else { return XCTFail("parse") }
        XCTAssertEqual(request.intQuery("limit", default: 30, max: 100), 100)
        guard case .request(let negative) = parse("GET /feed?limit=-4 HTTP/1.1\r\n\r\n") else { return XCTFail("parse") }
        XCTAssertEqual(negative.intQuery("limit", default: 30, max: 100), 1)
    }

    /// `%0d%0a` in the target is decoded into `path` before `path` becomes the audit log's tool
    /// column, and the 401 branch audits before it authenticates. No path this bridge serves has a
    /// control character in it, so the request never becomes a request at all.
    func testAControlCharacterInTheTargetIsRefusedOnTheWire() {
        for target in ["/feed%0d%0a2026-08-24T00%3A00%3A00Z%20%20GET%20%2Ffeed%20ok",
                       "/feed%0a", "/feed%00", "/feed%09x", "/feed%c2%85"] {
            if case .malformed(let why) = parse("GET \(target) HTTP/1.1\r\n\r\n") {
                XCTAssertTrue(why.contains("control characters"), "\(target): \(why)")
            } else {
                XCTFail("\(target) should be malformed, not served")
            }
        }
        // A percent-encoded space is not a control character; it is still not a route, but it is
        // the router's 404 to give, not the parser's 400.
        guard case .request(let request) = parse("GET /feed%20x HTTP/1.1\r\n\r\n") else {
            return XCTFail("a space in the target is not malformed")
        }
        XCTAssertEqual(request.path, "/feed x")
    }

    func testAnOversizedDeclaredBodyIsRefusedRatherThanAllocated() {
        if case .malformed = parse("POST /post HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n") {} else {
            XCTFail("an absurd Content-Length should be malformed")
        }
    }

    func testResponsesCloseTheConnectionAndDeclareTheirLength() throws {
        let raw = String(decoding: ConnectorResponse.json(200, ["ok": true]).serialised(), as: UTF8.self)
        XCTAssertTrue(raw.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(raw.contains("Connection: close\r\n"))
        XCTAssertTrue(raw.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(raw.contains("Content-Length: \(Data(#"{"ok":true}"#.utf8).count)\r\n"))
    }
}

#endif
