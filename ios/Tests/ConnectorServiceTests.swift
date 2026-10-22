// Unit tests — the Connector service's decision points (CONNECTOR.md §3, §8, PRODUCT.md §2.14).
//
// Separate from `ConnectorTests.swift` because these need TDLib's `ChatType`, and importing
// TDLibKit into a file that also says `Date` makes `Date` ambiguous — TDLib has one of its own.
//
// Mac only, like the bridge itself: `make mac-test` is where these run.

#if targetEnvironment(macCatalyst)

import TDLibKit
import XCTest
@testable import tgsocial



/// The parts of `ConnectorService` that decide what a request is allowed to do. Both are values
/// rather than methods on the live object, because the live object holds an `AppModel` and a TDLib
/// client and neither belongs in a unit test — but "sign out drops the grants" and "a chat that is
/// not a channel is out of scope" are exactly the claims that must not rot.
final class ConnectorServiceTests: XCTestCase {

    func testModelTestsCannotTouchTheRealConnectorHandshake() throws {
        let testDirectory = try XCTUnwrap(LocalStore.testDirectory)
        XCTAssertTrue(ConnectorHandshakeStore.defaultDirectory.path.hasPrefix(testDirectory.path + "/"))
        XCTAssertNotEqual(ConnectorHandshakeStore.defaultDirectory,
                          ConnectorHandshakeStore.realHome.appendingPathComponent(".tgsocial"))
    }

    func testMediaDirectoryIsTemporaryAndTestsAreIsolated() throws {
        let root = try XCTUnwrap(LocalStore.testDirectory)
        XCTAssertTrue(TDClient.mediaDirectory.path.hasPrefix(root.path + "/"))
        XCTAssertNotEqual(TDClient.mediaDirectory.path, TDClient.databaseDirectory)
    }

    func testTempMigrationRemovesMediaAndPreservesSessionDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("tdlib")
        let video = legacy.appendingPathComponent("videos")
        let temporary = root.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        try Data([1]).write(to: video.appendingPathComponent("cached.mp4"))
        let database = legacy.appendingPathComponent("db.sqlite")
        try Data([2]).write(to: database)
        _ = try TDClient.prepareTemporaryMedia(at: temporary, legacy: legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path))
        XCTAssertEqual(try Data(contentsOf: database), Data([2]))
        try Data([3]).write(to: temporary.appendingPathComponent("crash-leftover"))
        _ = try TDClient.prepareTemporaryMedia(at: temporary, legacy: legacy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path), [])
        let mode = try FileManager.default.attributesOfItem(atPath: temporary.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    @MainActor
    func testUploadChunksRetriesChecksumAndReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = LocalStore(); let key = UUID().uuidString
        let uploads = try ConnectorUploadStore(store: local, directory: directory, key: key)
        let spec = try ConnectorUploadSpec(feed: "@waveloop_devlog", kind: "document", filename: "sample.txt", bytes: 5,
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", caption: "").validated(maxBytes: 100)
        let id = "upload-test-123"
        _ = try uploads.create(id: id, spec: spec)
        let part = Data("hel".utf8)
        XCTAssertEqual(try uploads.append(id: id, offset: 0, data: part).receivedBytes, 3)
        XCTAssertEqual(try uploads.append(id: id, offset: 0, data: part).receivedBytes, 3)
        XCTAssertThrowsError(try uploads.append(id: id, offset: 0, data: Data("bad".utf8)))
        XCTAssertThrowsError(try uploads.append(id: id, offset: 4, data: Data("o".utf8)))
        _ = try uploads.append(id: id, offset: 3, data: Data("lo".utf8))
        var verified = try await uploads.verify(id: id)
        verified.state = "queued"; try uploads.save(verified)
        let reopened = try ConnectorUploadStore(store: local, directory: directory, key: key)
        XCTAssertEqual(try reopened.job(id).state, "uncertain")
        XCTAssertEqual(try reopened.create(id: id, spec: spec).state, "uncertain")
        XCTAssertThrowsError(try reopened.append(id: id, offset: 0, data: part))
        var changed = spec; changed.caption = "different"
        XCTAssertThrowsError(try reopened.create(id: id, spec: changed))
        verified.state = "sent"; verified.postURL = "https://t.me/waveloop_devlog/99"
        try reopened.save(verified)
        let again = try ConnectorUploadStore(store: local, directory: directory, key: key)
        XCTAssertEqual(try again.create(id: id, spec: spec).postURL, verified.postURL)
    }

    @MainActor
    func testUploadMismatchExpiryAndInvalidPaths() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploads = try ConnectorUploadStore(store: LocalStore(), directory: directory, key: UUID().uuidString)
        var spec = ConnectorUploadSpec(feed: "waveloop_devlog", kind: "document", filename: "sample.txt", bytes: 5,
            sha256: String(repeating: "0", count: 64), caption: "")
        XCTAssertFalse(ConnectorUploadStore.validID("../escape"))
        spec.filename = "../escape"
        XCTAssertThrowsError(try spec.validated(maxBytes: 100))
        spec.filename = "sample.txt"
        let id = "upload-mismatch"
        _ = try uploads.create(id: id, spec: spec)
        _ = try uploads.append(id: id, offset: 0, data: Data("hello".utf8))
        do { _ = try await uploads.verify(id: id); XCTFail("bad hash accepted") } catch {}
        XCTAssertEqual(try uploads.job(id).state, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploads.url(try uploads.job(id)).path))
        let next = try uploads.create(id: "upload-expired", spec: spec)
        try uploads.expire(at: next.createdAt.addingTimeInterval(901))
        XCTAssertEqual(try uploads.job(next.id).state, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploads.url(next).path))
    }

    @MainActor
    func testDemoRestoreDoesNotCreateUploadLedger() async {
        let store = LocalStore()
        let before = store.load([String: ConnectorUploadJob].self, "connector-upload-receipts")?.count
        let model = AppModel()
        model.enterDemo()
        await model.connector.restore()
        XCTAssertEqual(store.load([String: ConnectorUploadJob].self, "connector-upload-receipts")?.count, before)
    }

    func testPublicMediaPostingRequiresCreatorOrPostingAdministrator() {
        XCTAssertTrue(ConnectorService.canPostMedia(.chatMemberStatusCreator(ChatMemberStatusCreator(isAnonymous: false, isMember: true))))
        XCTAssertFalse(ConnectorService.canPostMedia(.chatMemberStatusLeft))
        XCTAssertFalse(ConnectorService.canPostMedia(.chatMemberStatusCreator(ChatMemberStatusCreator(isAnonymous: false, isMember: false))))
    }

    private func scopedSource(_ username: String) throws -> ScopedSource {
        var inputs = ScopeInputs()
        inputs.custom = [username]
        return try ScopeResolver.resolve(preset: .custom, inputs: inputs).admit(username)
    }

    /// PRODUCT §2.14: each write toggle "is a grant, not a preference". A grant belongs to the
    /// account that gave it, and the service outlives the account — so sign-out replaces the whole
    /// settings object, not just `enabled`.
    func testSigningOutDropsEveryGrantAndTheCustomList() {
        let granted = ConnectorSettings(enabled: true, port: 9001, preset: .custom,
                                        custom: ["someone_elses_list"],
                                        writes: ConnectorWrites(post: true, comment: true, card: true))
        XCTAssertEqual(ConnectorService.policy(token: "old", settings: granted).writes,
                       ConnectorWrites(post: true, comment: true, card: true))

        // What `signOut()` assigns.
        let after = ConnectorSettings.signedOut
        XCTAssertFalse(after.enabled)
        XCTAssertEqual(after.preset, .graph)
        XCTAssertTrue(after.custom.isEmpty)
        XCTAssertEqual(after.writes, .none)
        XCTAssertEqual(after.port, ConnectorHandshake.defaultPort)

        let policy = ConnectorService.policy(token: "", settings: after)
        XCTAssertEqual(policy.writes, .none)
        XCTAssertEqual(policy.preset, .graph)
        XCTAssertTrue(policy.token.isEmpty)
    }

    /// The connector's own channel lock (§3: "the service additionally refuses any resolved chat
    /// that is not a channel"). Scope membership proves a username was *listed*, never that it
    /// names a channel — a hand-typed `custom` entry can name a person, and `searchPublicChat`
    /// resolves it happily. Every username-bearing read goes through this, `/node` included.
    func testAChatThatIsNotAChannelIsOutOfScope() throws {
        let source = try scopedSource("private_person")
        let refused: [ChatType] = [.chatTypePrivate(ChatTypePrivate(userId: 7)),
                                   .chatTypeBasicGroup(ChatTypeBasicGroup(basicGroupId: 8)),
                                   .chatTypeSupergroup(ChatTypeSupergroup(isChannel: false, supergroupId: 9)),
                                   .chatTypeSecret(ChatTypeSecret(secretChatId: 3, userId: 7))]
        for type in refused {
            XCTAssertFalse(Mapping.isChannel(type))
            XCTAssertThrowsError(try ConnectorService.admitChannel(type, source: source), "\(type)") { error in
                XCTAssertEqual(error as? ConnectorError, .outOfScope("@private_person is not a channel"))
            }
        }

        let channel = ChatType.chatTypeSupergroup(ChatTypeSupergroup(isChannel: true, supergroupId: 9))
        XCTAssertTrue(Mapping.isChannel(channel))
        XCTAssertNoThrow(try ConnectorService.admitChannel(channel, source: source))
    }
}

#endif
