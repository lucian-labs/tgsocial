// Live test — the §12.7 discovery chain against the real network (PROTOCOL.md §12.7 steps 1–3).
//
// Skipped unless `TGS_LIVE_ATPROTO=1` reaches the test process. xcodebuild forwards variables
// prefixed `TEST_RUNNER_`, so run it as:
//
//     TEST_RUNNER_TGS_LIVE_ATPROTO=1 make test
//
// It proves the chain without a login, which is the most this build can prove without a consent
// screen: handle → DID (DNS TXT first; measured 2026-09-25, `bsky.app` answers there and 404s the
// well-known path) → DID document → PDS → the PDS's authorization server → that server's metadata,
// passed through the same checks sign-in makes (issuer equality, S256, ES256 DPoP, PAR endpoint).
// No PAR is sent: a PAR needs a client_id that is being served, and would create server state.

import Foundation
import XCTest
@testable import tgsocial

final class AtprotoLiveTests: XCTestCase {
    private var enabled: Bool { ProcessInfo.processInfo.environment["TGS_LIVE_ATPROTO"] == "1" }

    func testDiscoveryChainAgainstBskySocial() async throws {
        try XCTSkipUnless(enabled, "set TEST_RUNNER_TGS_LIVE_ATPROTO=1 to run against the live network")
        let oauth = AtprotoOAuth(config: .reference, transport: URLSessionTransport.shared)

        // Step 1a: the DNS half on its own, so a pass that fell through to the AppView would show.
        let txt = await DNSTXT.lookup("_atproto.bsky.app")
        XCTAssertTrue(txt.contains("did=did:plc:z72i7hdynmk6r22z27h6tvur"), "DNS TXT answered: \(txt)")

        // Steps 1–3, the path sign-in takes.
        let target = try await oauth.discover("@bsky.app")
        XCTAssertEqual(target.did, "did:plc:z72i7hdynmk6r22z27h6tvur")
        XCTAssertEqual(target.pds.scheme, "https")
        XCTAssertTrue(target.pds.host?.hasSuffix(".bsky.network") == true, "PDS: \(target.pds)")
        XCTAssertEqual(target.metadata.issuer, "https://bsky.social")
        XCTAssertEqual(target.metadata.parEndpoint.host, "bsky.social")
        XCTAssertEqual(target.metadata.tokenEndpoint.host, "bsky.social")
        XCTAssertEqual(target.loginHint, "bsky.app")

        // The signed-out link check's path, on a repo that certainly holds no tgsocial link:
        // a definite "no" (RecordNotFound), not a thrown network failure.
        let reader = AtprotoReader(transport: URLSessionTransport.shared)
        let linked = try await reader.checkLink(did: target.did, node: "tgs_nobody_here")
        XCTAssertFalse(linked)
    }
}
