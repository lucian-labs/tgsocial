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
