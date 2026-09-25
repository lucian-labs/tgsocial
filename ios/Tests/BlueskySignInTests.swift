// Unit tests — Sign in with Bluesky, the app half (PRODUCT.md §2.35, PROTOCOL.md
// §12.7 steps 1, 6 and 7). The wire half is AtprotoOAuthTests.
//
// Measured, not assumed: the whole of `BlueskyService.signIn` runs against a stubbed bsky.social
// (discovery, PAR, token, the PDS), the browser is a recorder, and the callback is a synthesized
// URL on the registered redirect handed to `receiveCallback` — the exact call `onOpenURL` makes.
// The `state` a callback carries is read back out of the PAR body the app actually sent.

import Foundation
import XCTest
@testable import tgsocial

@MainActor
final class BlueskySignInTests: XCTestCase {

    nonisolated private static let did = BskyFixture.me
    nonisolated private static let pds = BskyFixture.pds
    private static let redirect = AtprotoClientConfig.reference.redirectURI

    /// bsky.social as measured on 2026-09-25, trimmed to what sign-in reads, and a PDS that serves
    /// an empty profile and no block records.
    private static func network() -> StubTransport { StubTransport { req, _ in answer(req) } }

    /// Internal, not private: `SessionTests` signs a whole app model in against the same server.
    nonisolated static func answer(_ req: URLRequest) -> StubTransport.Reply {
            let url = req.url!
            switch (url.host ?? "", url.path) {
            case ("plc.directory", _):
                return .json(200, ["id": did, "alsoKnownAs": ["at://elijah.bsky.social"],
                                   "service": [["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": pds.absoluteString]]])
            case (_, "/.well-known/oauth-protected-resource"):
                return .json(200, ["authorization_servers": ["https://bsky.social"]])
            case ("bsky.social", "/.well-known/oauth-authorization-server"):
                return .json(200, [
                    "issuer": "https://bsky.social",
                    "authorization_endpoint": "https://bsky.social/oauth/authorize",
                    "token_endpoint": "https://bsky.social/oauth/token",
                    "pushed_authorization_request_endpoint": "https://bsky.social/oauth/par",
                    "revocation_endpoint": "https://bsky.social/oauth/revoke",
                    "code_challenge_methods_supported": ["S256"],
                    "dpop_signing_alg_values_supported": ["ES256"],
                    "require_pushed_authorization_requests": true,
                ])
            case ("bsky.social", "/oauth/par"):
                return .json(201, ["request_uri": "urn:ietf:params:oauth:request_uri:req-1", "expires_in": 299])
            case ("bsky.social", "/oauth/token"):
                return .json(200, ["access_token": "at-1", "refresh_token": "rt-1", "expires_in": 300, "token_type": "DPoP",
                                   "scope": AtprotoClientConfig.scope, "sub": did])
            default:
                return .json(200, [:])
            }
    }

    private struct Rig {
        let service: BlueskyService
        let stub: StubTransport
        let vault: MemoryVault
        let browser: BrowserRecorder
    }

    /// The browser the app opens: records every URL, and says it opened.
    final class BrowserRecorder {
        var opened: [URL] = []
        var answer = true
    }

    private func rig() -> Rig {
        let store = LocalStore()
        store.save(Optional<BlueskyPrefs>.none, LocalStore.blueskyPrefs)
        let stub = Self.network()
        let vault = MemoryVault()
        let browser = BrowserRecorder()
        let service = BlueskyService(store: store, activity: ActivityRegistry(), config: .reference, transport: stub, vault: vault,
                                     openBrowser: { url in browser.opened.append(url); return browser.answer })
        return Rig(service: service, stub: stub, vault: vault, browser: browser)
    }

    /// Polls the main actor until `condition` holds; fails after `seconds`.
    private func until(_ what: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The `state` the app put in its PAR body — what Bluesky would echo on the callback.
    private func sentState(_ stub: StubTransport) throws -> String {
        let par = try XCTUnwrap(stub.requests.last { $0.url?.path == "/oauth/par" }, "PAR was sent")
        let body = String(data: try XCTUnwrap(par.httpBody), encoding: .utf8) ?? ""
        let items = URLComponents(string: "?" + body)?.queryItems ?? []
        return try XCTUnwrap(items.first { $0.name == "state" }?.value)
    }

    private func callback(_ query: String) -> URL { URL(string: "\(Self.redirect)?\(query)")! }

    private func tokenRequests(_ stub: StubTransport) -> Int { stub.requests.filter { $0.url?.path == "/oauth/token" }.count }

    /// Starts a sign-in and returns once the app is in §2.35's waiting state, with its `state`.
    private func startWaiting(_ r: Rig, typed: String = BskyFixture.me) async throws -> (Task<BlueskyAccount, Error>, String) {
        let task = Task { try await r.service.signIn(typed) }
        try await until("the waiting state") { r.service.waitingHandle != nil && !r.browser.opened.isEmpty }
        return (task, try sentState(r.stub))
    }

    private func ending(_ task: Task<BlueskyAccount, Error>) async -> BlueskyService.SignInError? {
        do { _ = try await task.value; return nil } catch { return error as? BlueskyService.SignInError }
    }

    // MARK: §12.7 step 6 — the system default browser

    /// The page opens through the injected opener (UIApplication.shared.open in the app), at the
    /// issuer's authorization endpoint with only `client_id` and `request_uri`, and the app shows
    /// the handle it resolved while it waits.
    func testAuthorizationOpensInTheSystemBrowser() async throws {
        let r = rig()
        let (task, _) = try await startWaiting(r)
        XCTAssertEqual(r.browser.opened.count, 1)
        let page = try XCTUnwrap(URLComponents(url: r.browser.opened[0], resolvingAgainstBaseURL: false))
        XCTAssertEqual(page.host, "bsky.social")
        XCTAssertEqual(page.path, "/oauth/authorize")
        XCTAssertEqual(Set(page.queryItems?.map(\.name) ?? []), ["client_id", "request_uri"])
        XCTAssertEqual(r.service.waitingHandle, "@elijah.bsky.social")
        XCTAssertTrue(r.service.signingIn)
        r.service.cancelSignIn()
        _ = await ending(task)
    }

    /// The reference build registers the scheme its redirect comes back on — without it, the
    /// system browser has nowhere to send the callback and sign-in waits forever (the Catalyst hang).
    func testTheRedirectSchemeIsRegistered() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
                                  "CFBundleURLTypes is in the built Info.plist")
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        // The one the app will redirect to, whichever client this build is — and only that one: a
        // fork's build must not also claim the reference app's scheme.
        XCTAssertEqual(schemes, [AtprotoClientConfig.fromBundle().callbackScheme])
        if AtprotoClientConfig.fromBundle() == .reference { XCTAssertEqual(schemes, ["ca.lucianlabs"]) }
    }

    // MARK: §12.7 step 7 — the callback

    /// A callback with the attempt's `state` completes it: code exchanged, session in the vault.
    func testMatchingStateCompletes() async throws {
        let r = rig()
        let (task, state) = try await startWaiting(r)
        XCTAssertTrue(r.service.receiveCallback(callback("code=c-1&state=\(state)&iss=https%3A%2F%2Fbsky.social")))
        let acct = try await task.value
        XCTAssertEqual(acct.did, Self.did)
        XCTAssertEqual(r.service.account?.did, Self.did)
        XCTAssertEqual(r.vault.load()?.0.refreshToken, "rt-1")
        let token = try XCTUnwrap(r.stub.requests.last { $0.url?.path == "/oauth/token" })
        XCTAssertTrue(String(data: token.httpBody ?? Data(), encoding: .utf8)?.contains("code=c-1") == true)
        XCTAssertNil(r.service.waitingHandle)
        XCTAssertFalse(r.service.signingIn)
    }

    /// A callback with an unknown `state` is swallowed: no token request, no ending, still
    /// waiting — then the right one completes. A URL not on the redirect is not ours at all.
    func testWrongStateIsIgnored() async throws {
        let r = rig()
        let (task, state) = try await startWaiting(r)
        XCTAssertTrue(r.service.receiveCallback(callback("code=evil&state=not-\(state)&iss=https%3A%2F%2Fbsky.social")))
        XCTAssertTrue(r.service.receiveCallback(callback("code=evil&iss=https%3A%2F%2Fbsky.social")), "no state at all")
        XCTAssertFalse(r.service.receiveCallback(URL(string: "ca.lucianlabs:/elsewhere?state=\(state)&code=x")!))
        XCTAssertFalse(r.service.receiveCallback(URL(string: "https://t.me/tgs_ana")!))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tokenRequests(r.stub), 0, "nothing was exchanged")
        XCTAssertTrue(r.service.authWait.isWaiting)
        XCTAssertNotNil(r.service.waitingHandle)
        r.service.receiveCallback(callback("code=c-2&state=\(state)&iss=https%3A%2F%2Fbsky.social"))
        let acct = try await task.value
        XCTAssertEqual(acct.did, Self.did)
    }

    /// `error=access_denied` is the person declining: it ends the attempt as `refused`, which the
    /// app tells as `Not signed in to Bluesky.` Any other error is §2.39's generic failure.
    func testAccessDeniedEndsWithTheRefusal() async throws {
        let r = rig()
        let (task, state) = try await startWaiting(r)
        r.service.receiveCallback(callback("error=access_denied&state=\(state)&iss=https%3A%2F%2Fbsky.social"))
        let e = await ending(task)
        XCTAssertEqual(e, .refused)
        XCTAssertEqual(BlueskyCopy.toast(for: .refused), "Not signed in to Bluesky.")
        XCTAssertEqual(tokenRequests(r.stub), 0)
        XCTAssertNil(r.service.account)

        let r2 = rig()
        let (task2, state2) = try await startWaiting(r2)
        r2.service.receiveCallback(callback("error=server_error&state=\(state2)&iss=https%3A%2F%2Fbsky.social"))
        let e2 = await ending(task2)
        XCTAssertEqual(e2, .denied)
        XCTAssertEqual(BlueskyCopy.toast(for: .denied), "Bluesky didn't finish signing you in.")
    }

    /// Cancel ends it with nothing said, and the ended attempt's `state` is gone: its late callback
    /// is ignored and signs nobody in.
    func testCancelEndsItAndALateCallbackIsIgnored() async throws {
        let r = rig()
        let (task, state) = try await startWaiting(r)
        r.service.cancelSignIn()
        let e = await ending(task)
        XCTAssertEqual(e, .cancelled)
        XCTAssertNil(BlueskyCopy.toast(for: .cancelled), "a cancel says nothing")
        XCTAssertNil(r.service.waitingHandle)
        XCTAssertFalse(r.service.signingIn)
        XCTAssertTrue(r.service.receiveCallback(callback("code=late&state=\(state)&iss=https%3A%2F%2Fbsky.social")))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tokenRequests(r.stub), 0)
        XCTAssertNil(r.service.account)
        XCTAssertNil(r.vault.load())
    }

    /// Cancel before the browser opens ends the attempt at once, not when the server lookup gives
    /// up: the lookup here would take 30 s, and the ending has to arrive in well under one. Nothing
    /// after the cancel is sent — no PAR, no browser.
    func testCancelDuringTheLookupEndsAtOnce() async throws {
        let stub = StubTransport { req, _ in
            var reply = Self.answer(req)
            if req.url?.host == "plc.directory" { reply.delay = .seconds(30) }
            return reply
        }
        let service = BlueskyService(store: LocalStore(), activity: ActivityRegistry(), config: .reference, transport: stub,
                                     vault: MemoryVault(), openBrowser: { _ in XCTFail("the browser opened after Cancel"); return true })
        let task = Task { try await service.signIn(BskyFixture.me) }
        try await until("the lookup to start") { !stub.requests.isEmpty }
        let cancelledAt = Date()
        service.cancelSignIn()
        let e = await ending(task)
        let took = Date().timeIntervalSince(cancelledAt)
        XCTAssertEqual(e, .cancelled)
        XCTAssertLessThan(took, 1, "Cancel took \(took) s to end the attempt")
        XCTAssertFalse(service.signingIn)
        XCTAssertNil(service.waitingHandle)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(stub.requests.contains { $0.url?.path == "/oauth/par" }, "nothing is sent after Cancel")
    }

    /// A lookup that fails AFTER Cancel says nothing, and it cannot end the next attempt either:
    /// attempt 1's 404 lands at 0.3 s, while attempt 2 (started right after the cancel) is still
    /// looking up, and attempt 2 still reaches the browser.
    func testALookupErrorAfterCancelIsDropped() async throws {
        let stub = StubTransport { req, n in
            // A server that ignores cancellation: the thread is held, then it answers anyway.
            if n == 0 { usleep(300_000); return .json(404, ["error": "NotFound"]) }
            if n == 1 { usleep(600_000) }
            return Self.answer(req)
        }
        let browser = BrowserRecorder()
        let service = BlueskyService(store: LocalStore(), activity: ActivityRegistry(), config: .reference, transport: stub,
                                     vault: MemoryVault(), openBrowser: { url in browser.opened.append(url); return true })
        let first = Task { try await service.signIn(BskyFixture.me) }
        try await until("attempt 1's lookup") { stub.requests.count == 1 }
        service.cancelSignIn()
        let e1 = await ending(first)
        XCTAssertEqual(e1, .cancelled, "the 404 that arrives later is not told")
        XCTAssertNil(BlueskyCopy.toast(for: e1!))

        let second = Task { try await service.signIn(BskyFixture.me) }
        try await until("attempt 2 at the browser", seconds: 5) { !browser.opened.isEmpty }
        XCTAssertEqual(service.waitingHandle, "@elijah.bsky.social")
        service.cancelSignIn()
        let e2 = await ending(second)
        XCTAssertEqual(e2, .cancelled)
    }

    /// The hard end: no callback within the timeout ends the attempt as `timedOut`, with its copy.
    func testNoCallbackTimesOut() async throws {
        let r = rig()
        r.service.authWait.timeout = .milliseconds(150)
        let (task, _) = try await startWaiting(r)
        let started = Date()
        let e = await ending(task)
        XCTAssertEqual(e, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(BlueskyCopy.toast(for: .timedOut), "Bluesky sign-in timed out.")
        XCTAssertFalse(r.service.authWait.isWaiting)
        XCTAssertEqual(AuthorizationWait(redirectURI: Self.redirect, openBrowser: { _ in true }).timeout, .seconds(600),
                       "PRODUCT §2.35: ten minutes in the app")
    }

    /// One sign-in at a time: a second while the first waits is refused, and the first is untouched.
    func testOneSignInAtATime() async throws {
        let r = rig()
        let (task, state) = try await startWaiting(r)
        do { _ = try await r.service.signIn("someone.else"); XCTFail("a second attempt ran") } catch {
            XCTAssertEqual(error as? BlueskyService.SignInError, .busy)
        }
        XCTAssertEqual(r.browser.opened.count, 1)
        r.service.receiveCallback(callback("code=c-3&state=\(state)&iss=https%3A%2F%2Fbsky.social"))
        _ = try await task.value
    }

    /// A browser that refuses to open ends the attempt instead of leaving it waiting.
    func testABrowserThatWontOpenEndsIt() async throws {
        let r = rig()
        r.browser.answer = false
        let e = await ending(Task { try await r.service.signIn(BskyFixture.me) })
        XCTAssertEqual(e, .failed("Couldn't open the browser."))
        XCTAssertFalse(r.service.signingIn)
    }

    // MARK: §12.7 step 1 — handle entry

    func testHandleInputVectors() throws {
        let cases = try XCTUnwrap(AtprotoVectorTests.loadAtprotoVectors()["handleInput"]["cases"].array)
        XCTAssertEqual(cases.count, 8)
        for c in cases {
            XCTAssertEqual(AtprotoIdentity.handleInput(c["in"].string ?? ""), c["out"].string, c["in"].string ?? "?")
        }
    }

    /// A bare name is resolved as `<name>.bsky.social`: the request goes to that host, and the PAR
    /// `login_hint` carries the full handle.
    func testABareNameResolvesAsBskySocial() async throws {
        let stub = StubTransport { req, _ in
            if req.url?.host == "elijah.bsky.social", req.url?.path == "/.well-known/atproto-did" {
                return StubTransport.Reply(status: 200, body: Data(Self.did.utf8))
            }
            return Self.answer(req)
        }
        var oauth = AtprotoOAuth(config: .reference, transport: stub)
        oauth.identity.txtLookup = { _ in [] }
        for typed in ["elijah", "@elijah", " Elijah "] {
            let target = try await oauth.discover(typed)
            XCTAssertEqual(target.did, Self.did, typed)
            XCTAssertEqual(target.loginHint, "elijah.bsky.social", typed)
        }
        XCTAssertTrue(stub.requests.contains { $0.url?.host == "elijah.bsky.social" })
        XCTAssertFalse(stub.requests.contains { $0.url?.host == "elijah" }, "the bare name is never a host")
    }
}
