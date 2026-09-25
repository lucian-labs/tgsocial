// Atproto — Sign in with Bluesky, the wire half (PROTOCOL.md §12.7). No UI, no Keychain.
//
// A public client: PAR, PKCE S256, DPoP-bound tokens, no secret — an app binary cannot keep one.
// The twelve steps of §12.7 map onto this file as: 1–3 `discover`, 4 the caller (`DPoPKey`,
// `PKCE`), 5–6 `pushAuthorization`, 7 `callbackCode`, 8 `exchange`, 9 `verify`, 11 `refresh`,
// 12 `revoke`. Step 10 is `DPoPSender`. Each step's measured behaviour is cited where it is used.
//
// What has not been observed (§12.7): no login has completed end to end. Token issuance, refresh
// rotation, real lifetimes and a PDS accepting a granular-scope token are from the spec and the
// servers' error messages. The discovery chain IS measured, by `AtprotoLiveTests`.

import Foundation

/// The client this build signs in as. §12.7: "the client is a URL" — every fork and instance hosts
/// its own document and changes these (`docs/FORKING.md`).
struct AtprotoClientConfig: Equatable {
    let clientId: String
    let redirectURI: String
    let scope: String

    /// Six narrow grants, each for one thing §12 does; `transition:generic` is never requested and a
    /// client MUST NOT widen to it on its own — the person consented to this list (§12.7 Scopes).
    static let scope = [
        "atproto",
        "repo:\(Atproto.linkCollection)",
        "repo:app.bsky.feed.post?action=create",
        "blob:image/*",
        "rpc:app.bsky.feed.getTimeline?aud=did:web:api.bsky.app%23bsky_appview",
        "rpc:app.bsky.feed.searchPosts?aud=did:web:api.bsky.app%23bsky_appview",
    ].joined(separator: " ")

    /// The reference native build (`docs/HOSTING.md §7`). The scheme is `lucianlabs.ca` reversed —
    /// NOT the bundle id `ca.lucianlabs.tgsocial` — then one colon and ONE slash: bsky.social refused
    /// `app.waveloop://oauth/callback` for its two slashes (measured 2026-09-25).
    static let reference = AtprotoClientConfig(
        clientId: "https://lucianlabs.ca/tgsocial/client-metadata.json",
        redirectURI: "ca.lucianlabs:/tgsocial/oauth/callback",
        scope: scope)

    /// A fork sets `TGS_ATPROTO_CLIENT_ID` and `TGS_ATPROTO_REDIRECT` in Secrets.xcconfig. A pair
    /// that fails §12.7's own checklist is refused and the reference is used — a half-set override
    /// would send people to a consent page for one client and back to an app that is not it.
    static func fromBundle(_ bundle: Bundle = .main) -> AtprotoClientConfig {
        let id = (bundle.object(forInfoDictionaryKey: "TGSAtprotoClientId") as? String ?? "").trimmingCharacters(in: .whitespaces)
        let redirect = (bundle.object(forInfoDictionaryKey: "TGSAtprotoRedirect") as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !redirect.isEmpty else { return reference }
        let candidate = AtprotoClientConfig(clientId: id, redirectURI: redirect, scope: scope)
        return Atproto.clientMetadataProblems(candidate.metadata).isEmpty ? candidate : reference
    }

    /// The document this build expects to find at `clientId` — what `docs/HOSTING.md §7` prints.
    var metadata: JSONValue {
        .object([
            "client_id": .string(clientId),
            "client_name": .string("tgsocial"),
            "application_type": .string("native"),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "redirect_uris": .array([.string(redirectURI)]),
            "scope": .string(scope),
            "token_endpoint_auth_method": .string("none"),
            "dpop_bound_access_tokens": .bool(true),
        ])
    }

    /// The URL scheme the app registers (CFBundleURLTypes, project.yml): everything before the
    /// redirect's colon. The callback comes back through it as an ordinary URL open (§12.7 step 6).
    var callbackScheme: String { String(redirectURI.prefix { $0 != ":" }) }
}

struct AuthServerMetadata: Equatable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let parEndpoint: URL
    let revocationEndpoint: URL?

    /// §12.7 step 3: `issuer` must equal the URL asked; the server must require PAR, offer S256
    /// and offer ES256 for DPoP. Anything short of that is not a server this client can use safely.
    static func parse(_ json: JSONValue, askedIssuer: String) throws -> AuthServerMetadata {
        guard json["issuer"].string == askedIssuer else { throw AtprotoError.authFailed("issuer mismatch: \(json["issuer"].string ?? "none") for \(askedIssuer)") }
        guard (json["code_challenge_methods_supported"].array ?? []).contains(.string("S256")) else { throw AtprotoError.authFailed("no S256 at \(askedIssuer)") }
        guard (json["dpop_signing_alg_values_supported"].array ?? []).contains(.string("ES256")) else { throw AtprotoError.authFailed("no ES256 DPoP at \(askedIssuer)") }
        guard let auth = json["authorization_endpoint"].string.flatMap(URL.init(string:)),
              let token = json["token_endpoint"].string.flatMap(URL.init(string:)),
              let par = json["pushed_authorization_request_endpoint"].string.flatMap(URL.init(string:)) else {
            throw AtprotoError.authFailed("incomplete metadata at \(askedIssuer)")
        }
        return AuthServerMetadata(issuer: askedIssuer, authorizationEndpoint: auth, tokenEndpoint: token, parEndpoint: par,
                                  revocationEndpoint: json["revocation_endpoint"].string.flatMap(URL.init(string:)))
    }
}

/// Where a sign-in is going, after steps 1–3.
struct AuthTarget: Equatable {
    /// Nil only when the person typed something that is not a handle or a DID — never here.
    let did: String
    let handle: String?
    let pds: URL
    let metadata: AuthServerMetadata
    /// What the person typed, sent as `login_hint` so Bluesky's page opens on the right account.
    let loginHint: String
}

struct TokenResponse: Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int
    let scope: String
    let sub: String
    let tokenType: String

    static func parse(_ json: JSONValue) throws -> TokenResponse {
        guard let access = json["access_token"].string, let sub = json["sub"].string else {
            throw AtprotoError.authFailed("token response without access_token or sub")
        }
        return TokenResponse(accessToken: access, refreshToken: json["refresh_token"].string,
                             expiresIn: json["expires_in"].int ?? 300, scope: json["scope"].string ?? "",
                             sub: sub, tokenType: json["token_type"].string ?? "")
    }
}

/// A live session (§7 local state; the Keychain holds it, `SessionVault`). The DPoP key is stored
/// beside it, never inside it.
struct BlueskySession: Codable, Equatable {
    var did: String
    var handle: String
    var pds: URL
    var issuer: String
    var tokenEndpoint: URL
    var revocationEndpoint: URL?
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String
    /// When the person signed in. A public client's session ends two weeks from here whatever is
    /// refreshed (atproto's cap, §12.7 step 11).
    var startedAt: Date

    static let maxLifetime: TimeInterval = 14 * 24 * 3600
    /// Refresh this long before `expires_in` runs out, so a request never leaves with a token that
    /// dies in flight.
    static let refreshMargin: TimeInterval = 60

    func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < Self.refreshMargin }
    func isPastCap(now: Date = Date()) -> Bool { now.timeIntervalSince(startedAt) >= Self.maxLifetime }
}

struct AtprotoOAuth {
    let config: AtprotoClientConfig
    let transport: HTTPTransport
    var identity: AtprotoIdentity

    init(config: AtprotoClientConfig, transport: HTTPTransport) {
        self.config = config; self.transport = transport
        identity = AtprotoIdentity(transport: transport)
    }

    // MARK: Steps 1–3

    /// Handle or DID → DID → PDS → issuer → validated metadata.
    func discover(_ input: String) async throws -> AuthTarget {
        guard let typed = AtprotoIdentity.handleInput(input) else { throw AtprotoError.accountNotFound }
        let did: String
        var handle: String?
        if let d = Atproto.normaliseDid(typed) {
            did = d
        } else if let h = AtprotoIdentity.normaliseHandle(typed) {
            guard let d = await identity.resolveHandle(h) else { throw AtprotoError.accountNotFound }
            did = d; handle = h
        } else {
            throw AtprotoError.accountNotFound
        }
        let doc: DidDocument
        do { doc = try await identity.document(did) } catch let e as AtprotoError {
            if case .http(let status, _, _, _) = e, status == 404 || status == 410 { throw AtprotoError.accountNotFound }
            throw e
        }
        guard let pds = doc.pds else { throw AtprotoError.accountNotFound }
        let issuer = try await issuer(forPDS: pds)
        let metadata = try await metadata(issuer: issuer)
        return AuthTarget(did: did, handle: handle ?? doc.handle, pds: pds, metadata: metadata, loginHint: handle ?? did)
    }

    /// Step 2: the first of the PDS's `authorization_servers`.
    func issuer(forPDS pds: URL) async throws -> String {
        let json = try await AtprotoHTTP.getJSON(transport, pds.appendingPathComponent(".well-known/oauth-protected-resource"))
        guard let first = json["authorization_servers"].array?.first?.string, URL(string: first)?.scheme == "https" else {
            throw AtprotoError.authFailed("no authorization server named by \(pds.host ?? "the PDS")")
        }
        return first
    }

    /// Step 3.
    func metadata(issuer: String) async throws -> AuthServerMetadata {
        guard let base = URL(string: issuer) else { throw AtprotoError.authFailed("bad issuer \(issuer)") }
        let json = try await AtprotoHTTP.getJSON(transport, base.appendingPathComponent(".well-known/oauth-authorization-server"))
        return try AuthServerMetadata.parse(json, askedIssuer: issuer)
    }

    // MARK: Steps 5–6

    /// PAR with a DPoP proof; the first answer is 400 `use_dpop_nonce` and `DPoPSender` retries once
    /// with the nonce (measured → 201 `{ request_uri, expires_in: 299 }`). Returns the URL to open.
    func pushAuthorization(_ target: AuthTarget, pkce: PKCE, state: String, dpop: DPoPSender) async throws -> URL {
        var req = URLRequest(url: target.metadata.parEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = AtprotoHTTP.formBody([
            ("client_id", config.clientId),
            ("response_type", "code"),
            ("redirect_uri", config.redirectURI),
            ("scope", config.scope),
            ("state", state),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", PKCE.method),
            ("login_hint", target.loginHint),
        ])
        let (data, response) = try await dpop.send(req, accessToken: nil)
        let body = try AtprotoHTTP.check(data, response, host: target.metadata.parEndpoint.host ?? "?")
        guard let requestUri = JSONValue.parse(body)?["request_uri"].string else { throw AtprotoError.authFailed("PAR returned no request_uri") }
        var c = URLComponents(url: target.metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "client_id", value: config.clientId), URLQueryItem(name: "request_uri", value: requestUri)]
        guard let url = c.url else { throw AtprotoError.authFailed("bad authorization endpoint") }
        return url
    }

    // MARK: Step 7

    /// The callback: path is ours, `state` matches, `iss` is the issuer, and an `error` ends it.
    static func callbackCode(_ url: URL, state: String, issuer: String, redirectURI: String) throws -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let q = c?.queryItems ?? []
        func param(_ n: String) -> String? { q.first(where: { $0.name == n })?.value }
        let expected = URLComponents(string: redirectURI)
        guard c?.scheme == expected?.scheme, c?.path == expected?.path else { throw AtprotoError.authFailed("callback on the wrong path") }
        if let error = param("error") { throw AtprotoError.authorizationDenied(param("error_description") ?? error) }
        guard param("state") == state else { throw AtprotoError.authFailed("state mismatch") }
        guard param("iss") == issuer else { throw AtprotoError.authFailed("iss mismatch") }
        guard let code = param("code"), !code.isEmpty else { throw AtprotoError.authFailed("no code") }
        return code
    }

    // MARK: Step 8

    func exchange(code: String, pkce: PKCE, target: AuthTarget, dpop: DPoPSender) async throws -> TokenResponse {
        try await tokenRequest(target.metadata.tokenEndpoint, [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", config.redirectURI),
            ("client_id", config.clientId),
            ("code_verifier", pkce.verifier),
        ], dpop: dpop)
    }

    private func tokenRequest(_ endpoint: URL, _ fields: [(String, String)], dpop: DPoPSender) async throws -> TokenResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = AtprotoHTTP.formBody(fields)
        let (data, response) = try await dpop.send(req, accessToken: nil)
        let body = try AtprotoHTTP.check(data, response, host: endpoint.host ?? "?")
        guard let json = JSONValue.parse(body) else { throw AtprotoError.invalidResponse("token response not JSON") }
        return try TokenResponse.parse(json)
    }

    // MARK: Step 9

    /// Check before trusting: `token_type` DPoP, `scope` holds `atproto`, `sub` is a DID, it is the
    /// DID the typed handle resolved to, and `sub`'s PDS names this same issuer (steps 1–2 again,
    /// on `sub`). Any mismatch throws; the caller discards the tokens and the key.
    func verify(_ token: TokenResponse, target: AuthTarget) async throws -> (did: String, handle: String, pds: URL) {
        guard token.tokenType.caseInsensitiveCompare("DPoP") == .orderedSame else { throw AtprotoError.authFailed("token_type \(token.tokenType)") }
        guard token.scope.split(separator: " ").contains("atproto") else { throw AtprotoError.authFailed("scope without atproto") }
        guard let sub = Atproto.normaliseDid(token.sub) else { throw AtprotoError.authFailed("sub is not a DID") }
        guard sub == target.did else { throw AtprotoError.authFailed("sub \(sub) is not \(target.did)") }
        let doc = try await identity.document(sub)
        guard let pds = doc.pds else { throw AtprotoError.authFailed("sub has no PDS") }
        let issuer = try await issuer(forPDS: pds)
        guard issuer == target.metadata.issuer else { throw AtprotoError.authFailed("sub's PDS names \(issuer), not \(target.metadata.issuer)") }
        return (sub, doc.handle ?? target.handle ?? sub, pds)
    }

    // MARK: Steps 11–12

    /// Refresh tokens are single-use and rotate; the CALLER guarantees one refresh in flight
    /// (`BlueskyAuth`), and stores the new pair before dropping the old.
    func refresh(_ session: BlueskySession, dpop: DPoPSender) async throws -> TokenResponse {
        try await tokenRequest(session.tokenEndpoint, [
            ("grant_type", "refresh_token"),
            ("refresh_token", session.refreshToken),
            ("client_id", config.clientId),
        ], dpop: dpop)
    }

    /// Best effort: a revocation that fails still ends the session on this device.
    func revoke(_ session: BlueskySession, dpop: DPoPSender) async {
        guard let endpoint = session.revocationEndpoint else { return }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = AtprotoHTTP.formBody([("token", session.refreshToken), ("client_id", config.clientId)])
        _ = try? await dpop.send(req, accessToken: nil)
    }
}
