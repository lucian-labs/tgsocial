// Unit tests — Sign in with Bluesky, the wire half (PROTOCOL.md §12.7). Every assertion here is a
// measurement of bytes the app would put on the network, taken where the network stands
// (`StubTransport`), and checked against an outside reference: RFC 7636's own test vector for
// PKCE, CryptoKit verifying a proof's ES256 signature with the public key the proof carries, and
// the server behaviour measured against bsky.social on 2026-09-25 (a 400 `use_dpop_nonce` with a
// `DPoP-Nonce` header, then success on the retry).

import CryptoKit
import Foundation
import XCTest
@testable import tgsocial

// MARK: - The network, stubbed

/// Answers each request with whatever `handler` says and records what was sent. A class with a
/// lock rather than an actor so `HTTPTransport.send` stays a plain async call.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data("{}".utf8)
        var delay: Duration? = nil

        static func json(_ status: Int, _ object: [String: Any], headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
                  body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) -> Reply

    /// `handler(request, n)`: `n` is how many requests reached the stub before this one.
    init(_ handler: @escaping @Sendable (URLRequest, Int) -> Reply) { self.handler = handler }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        let n = _requests.count
        _requests.append(request)
        lock.unlock()
        let reply = handler(request, n)
        if let delay = reply.delay { try await Task.sleep(for: delay) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }
}

// MARK: - Reading a proof back

/// A DPoP proof taken apart, and its signature checked with the key its own header carries —
/// which is exactly the check a server makes (RFC 9449 §4.3 steps 5–6).
struct DecodedProof {
    let header: [String: Any]
    let claims: [String: Any]
    let signatureValid: Bool

    init?(_ jwt: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let h = Base64URL.decode(parts[0]), let c = Base64URL.decode(parts[1]), let s = Base64URL.decode(parts[2]),
              let header = (try? JSONSerialization.jsonObject(with: h)) as? [String: Any],
              let claims = (try? JSONSerialization.jsonObject(with: c)) as? [String: Any] else { return nil }
        self.header = header
        self.claims = claims
        guard let jwk = header["jwk"] as? [String: String], let x = jwk["x"].flatMap(Base64URL.decode),
              let y = jwk["y"].flatMap(Base64URL.decode), x.count == 32, y.count == 32,
              let key = try? P256.Signing.PublicKey(x963Representation: Data([0x04]) + x + y),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: s) else { signatureValid = false; return }
        signatureValid = key.isValidSignature(sig, for: Data((parts[0] + "." + parts[1]).utf8))
    }
}

final class AtprotoOAuthTests: XCTestCase {

    // MARK: PKCE — RFC 7636 Appendix B

    /// The RFC's own worked example: these 32 octets base64url to the verifier, and the verifier's
    /// SHA-256 base64urls to the challenge. Both halves are the RFC's numbers, not ours.
    func testPKCEMatchesRFC7636AppendixB() {
        let octets: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                               22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        let verifier = Base64URL.encode(Data(octets))
        XCTAssertEqual(verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(PKCE.method, "S256", "bsky.social answers `plain` with 400 (measured 2026-09-25)")
    }

    /// A generated pair: 43 characters from the unreserved set (RFC 7636 §4.1), challenge derived.
    func testGeneratedPKCEIsWellFormedAndFresh() {
        let a = PKCE.make(), b = PKCE.make()
        XCTAssertEqual(a.verifier.count, 43)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(a.verifier.unicodeScalars.allSatisfy(unreserved.contains))
        XCTAssertEqual(a.challenge, PKCE.challenge(for: a.verifier))
        XCTAssertNotEqual(a.verifier, b.verifier)
    }

    // MARK: DPoP proof — RFC 9449 §4.2

    func testProofHeaderIsES256WithAPublicOnlyJWKAndTheSignatureVerifies() throws {
        let key = DPoPKey.generate(preferSecureEnclave: false)
        let url = URL(string: "https://bsky.social/oauth/token")!
        let jwt = try DPoPProof.make(key: key, method: "post", url: url, nonce: nil, accessToken: nil,
                                     now: Date(timeIntervalSince1970: 1_790_013_846), jti: "jti-1")
        let proof = try XCTUnwrap(DecodedProof(jwt))
        XCTAssertEqual(proof.header["typ"] as? String, "dpop+jwt")
        XCTAssertEqual(proof.header["alg"] as? String, "ES256")
        let jwk = try XCTUnwrap(proof.header["jwk"] as? [String: String])
        XCTAssertEqual(Set(jwk.keys), ["kty", "crv", "x", "y"], "public-only: no `d`, nothing else")
        XCTAssertEqual(jwk["kty"], "EC")
        XCTAssertEqual(jwk["crv"], "P-256")
        XCTAssertTrue(proof.signatureValid, "the signature verifies with the key the proof carries")
        // The key in the proof is the session key's public half, byte for byte.
        let x963 = Data([0x04]) + Base64URL.decode(jwk["x"]!)! + Base64URL.decode(jwk["y"]!)!
        XCTAssertEqual(x963, key.publicKey.x963Representation)

        XCTAssertEqual(proof.claims["htm"] as? String, "POST", "method upper-cased")
        XCTAssertEqual(proof.claims["htu"] as? String, "https://bsky.social/oauth/token")
        XCTAssertEqual(proof.claims["iat"] as? Int, 1_790_013_846)
        XCTAssertEqual(proof.claims["jti"] as? String, "jti-1")
        XCTAssertNil(proof.claims["nonce"], "no nonce until a server hands one out")
        XCTAssertNil(proof.claims["ath"], "no ath without an access token")
    }

    /// A tampered proof must fail the same check — or `signatureValid` would be measuring nothing.
    func testTamperedProofFailsVerification() throws {
        let key = DPoPKey.generate(preferSecureEnclave: false)
        let jwt = try DPoPProof.make(key: key, method: "GET", url: URL(string: "https://pds.example/xrpc/a")!, nonce: nil, accessToken: nil)
        var parts = jwt.split(separator: ".").map(String.init)
        let forged = try JSONSerialization.data(withJSONObject: ["htm": "GET", "htu": "https://evil.example/", "iat": 1, "jti": "x"])
        parts[1] = Base64URL.encode(forged)
        XCTAssertFalse(try XCTUnwrap(DecodedProof(parts.joined(separator: "."))).signatureValid)
        // And a proof signed by a different key, carrying this key's JWK, fails too.
        let other = DPoPKey.generate(preferSecureEnclave: false)
        let real = try DPoPProof.make(key: key, method: "GET", url: URL(string: "https://pds.example/xrpc/a")!, nonce: nil, accessToken: nil)
        var p = real.split(separator: ".").map(String.init)
        p[2] = Base64URL.encode(try other.signature(for: Data((p[0] + "." + p[1]).utf8)))
        XCTAssertFalse(try XCTUnwrap(DecodedProof(p.joined(separator: "."))).signatureValid)
    }

    /// Resource requests: `htu` without query or fragment (§12.7 step 10), `ath` = base64url
    /// SHA-256 of the token, the nonce when given, and a fresh `jti` every time.
    func testResourceProofCarriesAthNonceAndAQuerylessHtu() throws {
        let key = DPoPKey.generate(preferSecureEnclave: false)
        let url = URL(string: "https://puffball.us-east.host.bsky.network/xrpc/app.bsky.feed.getTimeline?limit=30&cursor=abc#frag")!
        let token = "eyJ0eXAiOiJhdCtqd3QifQ.access.token"
        let a = try XCTUnwrap(DecodedProof(try DPoPProof.make(key: key, method: "GET", url: url, nonce: "n-pds-1", accessToken: token)))
        let b = try XCTUnwrap(DecodedProof(try DPoPProof.make(key: key, method: "GET", url: url, nonce: "n-pds-1", accessToken: token)))
        XCTAssertEqual(a.claims["htu"] as? String, "https://puffball.us-east.host.bsky.network/xrpc/app.bsky.feed.getTimeline")
        XCTAssertEqual(a.claims["nonce"] as? String, "n-pds-1")
        let expectedAth = Base64URL.encode(Data(SHA256.hash(data: Data(token.utf8))))
        XCTAssertEqual(a.claims["ath"] as? String, expectedAth)
        XCTAssertEqual(expectedAth.count, 43, "32 bytes, unpadded")
        XCTAssertNotEqual(a.claims["jti"] as? String, b.claims["jti"] as? String, "jti is single-use")
        XCTAssertTrue(a.signatureValid)
    }

    /// The key survives a Keychain round trip as the SAME key — a DPoP-bound token is useless
    /// with any other (§12.7 step 4).
    func testSoftwareKeyRestoresToTheSameKey() throws {
        let key = DPoPKey.generate(preferSecureEnclave: false)
        let restored = try XCTUnwrap(DPoPKey.restore(storage: key.storage, data: key.persisted))
        XCTAssertEqual(restored.publicKey.x963Representation, key.publicKey.x963Representation)
        let jwt = try DPoPProof.make(key: restored, method: "GET", url: URL(string: "https://a.example/")!, nonce: nil, accessToken: nil)
        XCTAssertEqual((DecodedProof(jwt)?.header["jwk"] as? [String: String]), key.jwk)
    }

    // MARK: The nonce retry — token endpoint (400) and resource server (401)

    /// Measured on bsky.social: the token endpoint answers a nonce-less proof with 400
    /// `use_dpop_nonce` and a `DPoP-Nonce` header. The client retries ONCE, with that nonce, and
    /// the retry's proof is freshly signed.
    func testTokenEndpointNonceRetry() async throws {
        let stub = StubTransport { req, n in
            XCTAssertEqual(req.url?.path, "/oauth/token")
            if n == 0 { return .json(400, ["error": "use_dpop_nonce", "error_description": "Authorization server requires nonce in DPoP proof"],
                                     headers: ["DPoP-Nonce": "as-nonce-1"]) }
            return .json(200, ["access_token": "at-1", "refresh_token": "rt-1", "expires_in": 300, "token_type": "DPoP",
                               "scope": AtprotoClientConfig.scope, "sub": "did:plc:z72i7hdynmk6r22z27h6tvur"],
                         headers: ["DPoP-Nonce": "as-nonce-2"])
        }
        let key = DPoPKey.generate(preferSecureEnclave: false)
        let sender = DPoPSender(key: key, transport: stub)
        let oauth = AtprotoOAuth(config: .reference, transport: stub)
        let token = try await oauth.exchange(code: "code-1", pkce: PKCE.make(), target: Self.target, dpop: sender)
        XCTAssertEqual(token.accessToken, "at-1")
        XCTAssertEqual(stub.requests.count, 2, "exactly one retry")
        let first = try XCTUnwrap(DecodedProof(stub.requests[0].value(forHTTPHeaderField: "DPoP") ?? ""))
        let second = try XCTUnwrap(DecodedProof(stub.requests[1].value(forHTTPHeaderField: "DPoP") ?? ""))
        XCTAssertNil(first.claims["nonce"])
        XCTAssertEqual(second.claims["nonce"] as? String, "as-nonce-1", "the retry carries the nonce the server sent")
        XCTAssertNotEqual(first.claims["jti"] as? String, second.claims["jti"] as? String)
        XCTAssertNil(stub.requests[1].value(forHTTPHeaderField: "Authorization"), "the token endpoint gets no access token")
        let nonce = await sender.nonce(for: URL(string: "https://bsky.social/anything")!)
        XCTAssertEqual(nonce, "as-nonce-2", "and keeps the newest nonce the origin sent")
        // The form carries the PKCE verifier and the public client's id — no secret.
        let form = String(data: stub.requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(form.contains("grant_type=authorization_code"))
        XCTAssertTrue(form.contains("code_verifier="))
        XCTAssertTrue(form.contains("client_id=https%3A%2F%2Flucianlabs.ca%2Ftgsocial%2Fclient-metadata.json"))
        XCTAssertFalse(form.contains("client_secret"))
    }

    /// A server that keeps asking is not retried forever: one retry, then the answer stands.
    func testNonceRetryHappensOnceOnly() async throws {
        let stub = StubTransport { _, n in .json(400, ["error": "use_dpop_nonce"], headers: ["DPoP-Nonce": "n\(n)"]) }
        let sender = DPoPSender(key: DPoPKey.generate(preferSecureEnclave: false), transport: stub)
        var req = URLRequest(url: URL(string: "https://bsky.social/oauth/par")!)
        req.httpMethod = "POST"
        let (_, response) = try await sender.send(req, accessToken: nil)
        XCTAssertEqual(response.statusCode, 400)
        XCTAssertEqual(stub.requests.count, 2)
    }

    /// PAR, measured: 400 `use_dpop_nonce`, then 201 `{request_uri}`. The URL handed to the browser
    /// carries only client_id and request_uri (PAR is required, so nothing else rides in it).
    func testPushedAuthorizationRetriesAndBuildsTheBrowserURL() async throws {
        let stub = StubTransport { req, n in
            if n == 0 { return .json(400, ["error": "use_dpop_nonce"], headers: ["DPoP-Nonce": "par-nonce"]) }
            return .json(201, ["request_uri": "urn:ietf:params:oauth:request_uri:req-abc", "expires_in": 299])
        }
        let sender = DPoPSender(key: DPoPKey.generate(preferSecureEnclave: false), transport: stub)
        let pkce = PKCE.make()
        let url = try await AtprotoOAuth(config: .reference, transport: stub)
            .pushAuthorization(Self.target, pkce: pkce, state: "state-1", dpop: sender)
        XCTAssertEqual(stub.requests.count, 2)
        let form = String(data: stub.requests[1].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(form.contains("code_challenge=\(pkce.challenge)"))
        XCTAssertTrue(form.contains("code_challenge_method=S256"))
        XCTAssertTrue(form.contains("redirect_uri=ca.lucianlabs%3A%2Ftgsocial%2Foauth%2Fcallback"))
        XCTAssertFalse(form.contains("transition%3Ageneric"), "never widened to transition:generic (§12.7)")
        XCTAssertEqual(DecodedProof(stub.requests[1].value(forHTTPHeaderField: "DPoP") ?? "")?.claims["nonce"] as? String, "par-nonce")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "bsky.social")
        XCTAssertEqual(c.path, "/oauth/authorize")
        XCTAssertEqual(Set(c.queryItems?.map(\.name) ?? []), ["client_id", "request_uri"])
        XCTAssertEqual(c.queryItems?.first { $0.name == "request_uri" }?.value, "urn:ietf:params:oauth:request_uri:req-abc")
    }

    /// Nonces are per server: the authorization server's nonce is never sent to the PDS, and the
    /// PDS's (measured: a 401 `use_dpop_nonce` of its own) is never sent back to the AS.
    func testNoncesArePerOrigin() async throws {
        let stub = StubTransport { req, _ in
            let host = req.url?.host ?? ""
            let proof = DecodedProof(req.value(forHTTPHeaderField: "DPoP") ?? "")
            let nonce = proof?.claims["nonce"] as? String
            if host == "bsky.social" {
                return nonce == "as-n" ? .json(200, [:]) : .json(400, ["error": "use_dpop_nonce"], headers: ["DPoP-Nonce": "as-n"])
            }
            return nonce == "pds-n" ? .json(200, [:])
                : .json(401, ["error": "use_dpop_nonce"], headers: ["DPoP-Nonce": "pds-n", "WWW-Authenticate": "DPoP error=\"use_dpop_nonce\""])
        }
        let sender = DPoPSender(key: DPoPKey.generate(preferSecureEnclave: false), transport: stub)
        var asReq = URLRequest(url: URL(string: "https://bsky.social/oauth/token")!); asReq.httpMethod = "POST"
        let pdsReq = URLRequest(url: URL(string: "https://puffball.us-east.host.bsky.network/xrpc/com.atproto.server.getSession")!)
        _ = try await sender.send(asReq, accessToken: nil)
        _ = try await sender.send(pdsReq, accessToken: "at")
        _ = try await sender.send(asReq, accessToken: nil)
        let sent = stub.requests.map { ($0.url!.host!, DecodedProof($0.value(forHTTPHeaderField: "DPoP")!)!.claims["nonce"] as? String) }
        XCTAssertEqual(sent.map(\.0), ["bsky.social", "bsky.social", "puffball.us-east.host.bsky.network",
                                       "puffball.us-east.host.bsky.network", "bsky.social"])
        XCTAssertEqual(sent.map(\.1), [nil, "as-n", nil, "pds-n", "as-n"],
                       "the PDS's first proof has no nonce — the AS's was not reused — and the AS keeps its own")
    }

    // MARK: The session — resource requests, refresh, single flight

    private static let did = "did:plc:z72i7hdynmk6r22z27h6tvur"
    private static let pds = URL(string: "https://puffball.us-east.host.bsky.network")!

    private static var target: AuthTarget {
        AuthTarget(did: did, handle: "bsky.app", pds: pds,
                   metadata: AuthServerMetadata(issuer: "https://bsky.social",
                                                authorizationEndpoint: URL(string: "https://bsky.social/oauth/authorize")!,
                                                tokenEndpoint: URL(string: "https://bsky.social/oauth/token")!,
                                                parEndpoint: URL(string: "https://bsky.social/oauth/par")!,
                                                revocationEndpoint: URL(string: "https://bsky.social/oauth/revoke")!),
                   loginHint: "bsky.app")
    }

    private static func session(expiresIn: TimeInterval, now: Date, started: Date? = nil) -> BlueskySession {
        BlueskySession(did: did, handle: "bsky.app", pds: pds, issuer: "https://bsky.social",
                       tokenEndpoint: URL(string: "https://bsky.social/oauth/token")!,
                       revocationEndpoint: URL(string: "https://bsky.social/oauth/revoke")!,
                       accessToken: "at-old", refreshToken: "rt-old", expiresAt: now.addingTimeInterval(expiresIn),
                       scope: AtprotoClientConfig.scope, startedAt: started ?? now)
    }

    private static func tokenReply(_ n: Int, sub: String = did) -> StubTransport.Reply {
        .json(200, ["access_token": "at-\(n)", "refresh_token": "rt-\(n)", "expires_in": 300, "token_type": "DPoP",
                    "scope": AtprotoClientConfig.scope, "sub": sub])
    }

    /// A resource request through the session: the PDS asks for its nonce (401 + WWW-Authenticate,
    /// measured), the retry carries it, `Authorization: DPoP <token>`, `ath`, and the AppView proxy
    /// header — and no refresh happens, because a nonce request is not an expired token.
    func testResourceRequestNonceRetryWithoutRefresh() async throws {
        let now = Date()
        let stub = StubTransport { req, n in
            XCTAssertEqual(req.url?.host, Self.pds.host, "never the token endpoint")
            if n == 0 { return .json(401, ["error": "use_dpop_nonce", "message": "Resource server requires nonce in DPoP proof"],
                                     headers: ["DPoP-Nonce": "pds-1", "WWW-Authenticate": "DPoP error=\"use_dpop_nonce\""]) }
            return .json(200, ["feed": [], "cursor": "c1"])
        }
        let vault = MemoryVault((Self.session(expiresIn: 300, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: stub), vault: vault, transport: stub, now: { now })
        let json = try await auth.get("app.bsky.feed.getTimeline", [("limit", "30")], proxy: true)
        XCTAssertEqual(json["cursor"].string, "c1")
        XCTAssertEqual(stub.requests.count, 2)
        let retry = stub.requests[1]
        XCTAssertEqual(retry.value(forHTTPHeaderField: "Authorization"), "DPoP at-old")
        XCTAssertEqual(retry.value(forHTTPHeaderField: "atproto-proxy"), "did:web:api.bsky.app#bsky_appview")
        let proof = try XCTUnwrap(DecodedProof(retry.value(forHTTPHeaderField: "DPoP") ?? ""))
        XCTAssertEqual(proof.claims["nonce"] as? String, "pds-1")
        XCTAssertEqual(proof.claims["ath"] as? String, DPoPProof.ath("at-old"))
        XCTAssertEqual(proof.claims["htu"] as? String, Self.pds.absoluteString + "/xrpc/app.bsky.feed.getTimeline")
        XCTAssertTrue(proof.signatureValid)
        let refreshes = await auth.refreshCount
        XCTAssertEqual(refreshes, 0)
    }

    /// Refresh BEFORE expiry: a token with under a minute left is refreshed first, so the request
    /// never leaves with a token that dies in flight. The new pair is in the vault afterwards.
    func testRefreshesBeforeExpiry() async throws {
        let now = Date()
        let stub = StubTransport { req, _ in
            if req.url?.path == "/oauth/token" { return Self.tokenReply(1) }
            return .json(200, ["ok": true])
        }
        let vault = MemoryVault((Self.session(expiresIn: 30, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: stub), vault: vault, transport: stub, now: { now })
        _ = try await auth.get("com.atproto.server.getSession", [], proxy: false)
        XCTAssertEqual(stub.requests.map { $0.url!.path }, ["/oauth/token", "/xrpc/com.atproto.server.getSession"])
        let form = String(data: stub.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(form.contains("grant_type=refresh_token"))
        XCTAssertTrue(form.contains("refresh_token=rt-old"))
        XCTAssertEqual(stub.requests[1].value(forHTTPHeaderField: "Authorization"), "DPoP at-1")
        XCTAssertEqual(vault.load()?.0.refreshToken, "rt-1", "the rotated refresh token was stored")
        XCTAssertEqual(vault.load()?.0.accessToken, "at-1")
    }

    /// Refresh ON 401: a fresh-looking token the PDS refuses (not a nonce request) is refreshed
    /// once and the request retried with the new token.
    func testRefreshesOn401AndRetries() async throws {
        let now = Date()
        let stub = StubTransport { req, _ in
            if req.url?.path == "/oauth/token" { return Self.tokenReply(2) }
            if req.value(forHTTPHeaderField: "Authorization") == "DPoP at-old" {
                return .json(401, ["error": "invalid_token", "message": "token expired"], headers: ["WWW-Authenticate": "DPoP error=\"invalid_token\""])
            }
            return .json(200, ["ok": true])
        }
        let vault = MemoryVault((Self.session(expiresIn: 300, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: stub), vault: vault, transport: stub, now: { now })
        let json = try await auth.get("com.atproto.server.getSession", [], proxy: false)
        XCTAssertEqual(json["ok"].bool, true)
        XCTAssertEqual(stub.requests.map { $0.url!.path },
                       ["/xrpc/com.atproto.server.getSession", "/oauth/token", "/xrpc/com.atproto.server.getSession"])
        XCTAssertEqual(stub.requests[2].value(forHTTPHeaderField: "Authorization"), "DPoP at-2")
        let refreshes = await auth.refreshCount
        XCTAssertEqual(refreshes, 1)
    }

    /// Refresh tokens are single-use (§12.7 step 11): five callers finding the token stale at once
    /// must spend it ONCE. Measured at the token endpoint, with a slow server so they overlap.
    func testConcurrentCallersShareOneRefresh() async throws {
        let now = Date()
        let stub = StubTransport { req, _ in
            if req.url?.path == "/oauth/token" {
                var r = Self.tokenReply(3); r.delay = .milliseconds(150); return r
            }
            return .json(200, ["ok": true])
        }
        let vault = MemoryVault((Self.session(expiresIn: 10, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: stub), vault: vault, transport: stub, now: { now })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try await auth.get("com.atproto.server.getSession", [], proxy: false) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(stub.requests.filter { $0.url?.path == "/oauth/token" }.count, 1, "one refresh reached the server")
        XCTAssertEqual(stub.requests.filter { $0.url?.path != "/oauth/token" }.count, 5)
        XCTAssertTrue(stub.requests.filter { $0.url?.path != "/oauth/token" }
                        .allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "DPoP at-3" })
    }

    /// A refused refresh (invalid_grant: spent, revoked) ends the session and clears the vault;
    /// a server that did not answer does not.
    func testRefusedRefreshEndsTheSessionButAnOutageDoesNot() async throws {
        let now = Date()
        let refused = StubTransport { _, _ in .json(400, ["error": "invalid_grant", "error_description": "refresh token replayed"]) }
        let vault = MemoryVault((Self.session(expiresIn: 10, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: refused), vault: vault, transport: refused, now: { now })
        do { _ = try await auth.fresh(); XCTFail("expected sessionEnded") } catch { XCTAssertEqual(error as? AtprotoError, .sessionEnded) }
        XCTAssertNil(vault.load(), "tokens and key are gone")

        let down = StubTransport { _, _ in .json(503, ["error": "Unavailable"]) }
        let vault2 = MemoryVault((Self.session(expiresIn: 10, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let auth2 = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: down), vault: vault2, transport: down, now: { now })
        do { _ = try await auth2.fresh(); XCTFail("expected an http error") } catch { XCTAssertNotEqual(error as? AtprotoError, .sessionEnded) }
        XCTAssertNotNil(vault2.load(), "an outage keeps the session for the next try")
    }

    /// atproto's two-week cap for a public client: past it the session is over whatever is refreshed.
    func testSessionEndsAtTheTwoWeekCap() async throws {
        let now = Date()
        let stub = StubTransport { _, _ in Self.tokenReply(9) }
        let started = now.addingTimeInterval(-BlueskySession.maxLifetime - 1)
        let vault = MemoryVault((Self.session(expiresIn: 300, now: now, started: started), DPoPKey.generate(preferSecureEnclave: false)))
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: stub), vault: vault, transport: stub, now: { now })
        do { _ = try await auth.fresh(); XCTFail("expected sessionEnded") } catch { XCTAssertEqual(error as? AtprotoError, .sessionEnded) }
        XCTAssertEqual(stub.requests.count, 0, "no refresh attempted past the cap")
    }

    /// A refresh that comes back for a different account is refused (§12.7 step 9 applies again).
    func testRefreshThatChangesSubIsRefused() async throws {
        let now = Date()
        let stub = StubTransport { _, _ in Self.tokenReply(4, sub: "did:plc:ana2ana2ana2ana2ana2ana2") }
        let vault = MemoryVault((Self.session(expiresIn: 10, now: now), DPoPKey.generate(preferSecureEnclave: false)))
        let auth = BlueskyAuth(oauth: AtprotoOAuth(config: .reference, transport: stub), vault: vault, transport: stub, now: { now })
        do { _ = try await auth.fresh(); XCTFail("expected a refusal") } catch {}
        XCTAssertEqual(vault.load()?.0.accessToken, "at-old", "the other account's tokens were never stored")
    }

    // MARK: §12.7 step 9 — sub and issuer

    func testVerifyRefusesAWrongSubOrIssuer() async throws {
        let plc = """
        {"id":"\(Self.did)","alsoKnownAs":["at://bsky.app"],"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"\(Self.pds.absoluteString)"}]}
        """
        func stub(issuer: String) -> StubTransport {
            StubTransport { req, _ in
                if req.url?.host == "plc.directory" { return StubTransport.Reply(status: 200, body: Data(plc.utf8)) }
                return .json(200, ["authorization_servers": [issuer]])
            }
        }
        let good = TokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 300, scope: "atproto", sub: Self.did, tokenType: "DPoP")
        let checked = try await AtprotoOAuth(config: .reference, transport: stub(issuer: "https://bsky.social")).verify(good, target: Self.target)
        XCTAssertEqual(checked.did, Self.did)
        XCTAssertEqual(checked.pds, Self.pds)

        let otherSub = TokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 300, scope: "atproto",
                                     sub: "did:plc:ana2ana2ana2ana2ana2ana2", tokenType: "DPoP")
        do { _ = try await AtprotoOAuth(config: .reference, transport: stub(issuer: "https://bsky.social")).verify(otherSub, target: Self.target); XCTFail("sub") } catch {}
        do { _ = try await AtprotoOAuth(config: .reference, transport: stub(issuer: "https://evil.example")).verify(good, target: Self.target); XCTFail("issuer") } catch {}
        let bearer = TokenResponse(accessToken: "a", refreshToken: "r", expiresIn: 300, scope: "atproto", sub: Self.did, tokenType: "Bearer")
        do { _ = try await AtprotoOAuth(config: .reference, transport: stub(issuer: "https://bsky.social")).verify(bearer, target: Self.target); XCTFail("token_type") } catch {}
    }

    /// Step 7: the callback must be ours, carry our state and the issuer, and an `error` ends it.
    func testCallbackChecks() throws {
        let r = "ca.lucianlabs:/tgsocial/oauth/callback"
        let ok = URL(string: "\(r)?code=abc&state=s1&iss=https%3A%2F%2Fbsky.social")!
        XCTAssertEqual(try AtprotoOAuth.callbackCode(ok, state: "s1", issuer: "https://bsky.social", redirectURI: r), "abc")
        XCTAssertThrowsError(try AtprotoOAuth.callbackCode(URL(string: "\(r)?code=abc&state=s2&iss=https%3A%2F%2Fbsky.social")!,
                                                           state: "s1", issuer: "https://bsky.social", redirectURI: r))
        XCTAssertThrowsError(try AtprotoOAuth.callbackCode(URL(string: "\(r)?code=abc&state=s1&iss=https%3A%2F%2Fevil.example")!,
                                                           state: "s1", issuer: "https://bsky.social", redirectURI: r))
        XCTAssertThrowsError(try AtprotoOAuth.callbackCode(URL(string: "ca.lucianlabs:/other?code=abc&state=s1&iss=https%3A%2F%2Fbsky.social")!,
                                                           state: "s1", issuer: "https://bsky.social", redirectURI: r))
        XCTAssertThrowsError(try AtprotoOAuth.callbackCode(URL(string: "\(r)?error=access_denied&state=s1")!,
                                                           state: "s1", issuer: "https://bsky.social", redirectURI: r)) { e in
            guard case .authorizationDenied = e as? AtprotoError else { return XCTFail("expected authorizationDenied, got \(e)") }
        }
    }

    /// Step 3: the metadata bsky.social actually served on 2026-09-25, trimmed to the fields read.
    func testAuthServerMetadataChecks() throws {
        var doc: [String: JSONValue] = [
            "issuer": .string("https://bsky.social"),
            "authorization_endpoint": .string("https://bsky.social/oauth/authorize"),
            "token_endpoint": .string("https://bsky.social/oauth/token"),
            "pushed_authorization_request_endpoint": .string("https://bsky.social/oauth/par"),
            "revocation_endpoint": .string("https://bsky.social/oauth/revoke"),
            "code_challenge_methods_supported": .array([.string("S256")]),
            "dpop_signing_alg_values_supported": .array([.string("RS256"), .string("ES256")]),
            "require_pushed_authorization_requests": .bool(true),
        ]
        let m = try AuthServerMetadata.parse(.object(doc), askedIssuer: "https://bsky.social")
        XCTAssertEqual(m.parEndpoint.absoluteString, "https://bsky.social/oauth/par")
        XCTAssertThrowsError(try AuthServerMetadata.parse(.object(doc), askedIssuer: "https://other.example"))
        doc["dpop_signing_alg_values_supported"] = .array([.string("RS256")])
        XCTAssertThrowsError(try AuthServerMetadata.parse(.object(doc), askedIssuer: "https://bsky.social"))
    }

    // MARK: The client this build signs in as

    /// The metadata the reference build expects at its client_id is exactly the vector document
    /// (which a web test also holds HOSTING.md §7 to), and it passes the §12.7 checklist.
    func testReferenceClientMetadataIsTheVectorDocument() throws {
        let v = try AtprotoVectorTests.loadAtprotoVectors()
        let doc = try XCTUnwrap(v["clientMetadata"]["cases"].array?.first?["doc"])
        XCTAssertEqual(AtprotoClientConfig.reference.metadata, doc)
        XCTAssertEqual(Atproto.clientMetadataProblems(AtprotoClientConfig.reference.metadata,
                                                      fetchedFrom: AtprotoClientConfig.reference.clientId), [])
        XCTAssertEqual(AtprotoClientConfig.reference.callbackScheme, "ca.lucianlabs")
        XCTAssertEqual(Atproto.nativeRedirectScheme(AtprotoClientConfig.reference.clientId), "ca.lucianlabs")
        XCTAssertFalse(AtprotoClientConfig.scope.contains("transition:generic"))
    }

    /// Tokens live in the Keychain and nowhere else: a round trip through the real Keychain. On
    /// Mac Catalyst this is the data protection keychain, which answers -34018 to a build without
    /// the access group in tgsocial-Mac.entitlements — `save` throws that status rather than
    /// pretending, so the failure names itself here.
    func testKeychainVaultRoundTrip() throws {
        let vault = KeychainVault(service: "ca.lucianlabs.tgsocial.tests.\(UUID().uuidString)")
        defer { vault.clear() }
        XCTAssertNil(vault.load())
        let key = DPoPKey.generate(preferSecureEnclave: false)
        try vault.save(Self.session(expiresIn: 300, now: Date()), key: key)
        let loaded = try XCTUnwrap(vault.load(), "the Keychain holds the session")
        XCTAssertEqual(loaded.0.refreshToken, "rt-old")
        XCTAssertEqual(loaded.1.publicKey.x963Representation, key.publicKey.x963Representation)
        vault.clear()
        XCTAssertNil(vault.load())
    }
}
