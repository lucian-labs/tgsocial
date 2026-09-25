// Atproto — the HTTP seam, the errors, and the DPoP nonce dance (PROTOCOL.md §12.4, §12.7).
//
// Every atproto request in the app goes through `HTTPTransport`, so a test can stand exactly where
// the network stands and answer `400 use_dpop_nonce` on cue. `DPoPSender` is the one place a proof
// is attached: it keeps the last nonce each ORIGIN handed out — the authorization server and the
// PDS each run their own (measured 2026-09-25: the PDS answered `use_dpop_nonce` with a nonce of its
// own) — and retries a request exactly once when the server asks for a fresh one.

import Foundation

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    static let shared = URLSessionTransport(session: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "tgsocial (+https://github.com/lucian-labs/tgsocial)"]
        return URLSession(configuration: config)
    }())

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AtprotoError.invalidResponse("not HTTP") }
        return (data, http)
    }
}

/// What can go wrong, in the shapes PRODUCT §2.39 speaks to.
enum AtprotoError: Error, Equatable, LocalizedError {
    /// The host did not answer at all — offline, DNS, TLS, timeout.
    case unreachable(host: String)
    /// The host answered with an error. `error` is XRPC's / OAuth's `error` code.
    case http(status: Int, error: String?, message: String?, host: String)
    /// 429: back off for this long (§12.4), `Retry-After` or `RateLimit-Reset`, else 60 s.
    case rateLimited(seconds: Int)
    /// A handle that does not resolve (`Couldn't find that Bluesky account.`).
    case accountNotFound
    /// The person closed Bluesky's page. Not an error to show (§2.35: "nothing is said").
    case cancelled
    /// Bluesky's page came back with `error=` (`Bluesky didn't finish signing you in.`).
    case authorizationDenied(String)
    /// A §12.7 check failed, or the client metadata could not be fetched (`Couldn't sign in to
    /// Bluesky.`). The string goes to `Last error` verbatim.
    case authFailed(String)
    /// The session is over: refresh refused, two weeks up, revoked (§2.39).
    case sessionEnded
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): return "Can't reach \(host)"
        case .http(let status, let error, let message, let host):
            return [message ?? error, "\(status) at \(host)"].compactMap { $0 }.joined(separator: " \u{00B7} ")
        case .rateLimited(let s): return "Bluesky asked us to wait \(s) s."
        case .accountNotFound: return "Couldn't find that Bluesky account."
        case .cancelled: return "Cancelled"
        case .authorizationDenied(let s): return s
        case .authFailed(let s): return s
        case .sessionEnded: return "Bluesky signed you out."
        case .invalidResponse(let s): return s
        }
    }

    /// The host a failed read names on the Status sheet (§2.39 `Can't reach <host>`).
    var host: String? {
        switch self {
        case .unreachable(let h): return h
        case .http(let status, _, _, let h) where status >= 500: return h
        default: return nil
        }
    }

    /// XRPC's RecordNotFound — a definitive "no" for the §12.3 link check.
    var isRecordNotFound: Bool {
        if case .http(let status, let error, _, _) = self { return status == 400 && error == "RecordNotFound" }
        return false
    }
}

enum AtprotoHTTP {
    static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "https"
        let port = url.port.flatMap { (scheme == "https" && $0 == 443) || (scheme == "http" && $0 == 80) ? nil : $0 }
        return "\(scheme)://\(url.host?.lowercased() ?? "")" + (port.map { ":\($0)" } ?? "")
    }

    /// `{ "error": "...", "message" | "error_description": "..." }` — XRPC and OAuth spell it apart.
    static func errorBody(_ data: Data) -> (error: String?, message: String?) {
        guard let json = JSONValue.parse(data) else { return (nil, nil) }
        return (json["error"].string, json["message"].string ?? json["error_description"].string)
    }

    /// §12.4: a 429 is §4's `FLOOD_WAIT` — the server's own number, else a minute.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> Int {
        if let s = response.value(forHTTPHeaderField: "Retry-After"), let n = Int(s.trimmingCharacters(in: .whitespaces)), n > 0 { return n }
        if let s = response.value(forHTTPHeaderField: "RateLimit-Reset"), let n = Int(s.trimmingCharacters(in: .whitespaces)) {
            // atproto sends an epoch second; a small number is a delta.
            let delta = n > 1_000_000_000 ? n - Int(now.timeIntervalSince1970) : n
            if delta > 0 { return delta }
        }
        return 60
    }

    /// Sends and maps every failure onto `AtprotoError`. 2xx comes back as data.
    static func send(_ transport: HTTPTransport, _ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url?.host ?? "?"
        let result: (Data, HTTPURLResponse)
        do { result = try await transport.send(request) } catch let e as AtprotoError { throw e } catch {
            throw AtprotoError.unreachable(host: host)
        }
        return result
    }

    static func check(_ data: Data, _ response: HTTPURLResponse, host: String) throws -> Data {
        if (200..<300).contains(response.statusCode) { return data }
        if response.statusCode == 429 { throw AtprotoError.rateLimited(seconds: retryAfter(response)) }
        let body = errorBody(data)
        throw AtprotoError.http(status: response.statusCode, error: body.error, message: body.message, host: host)
    }

    static func getJSON(_ transport: HTTPTransport, _ url: URL, headers: [String: String] = [:]) async throws -> JSONValue {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await send(transport, req)
        let ok = try check(data, response, host: url.host ?? "?")
        guard let json = JSONValue.parse(ok) else { throw AtprotoError.invalidResponse("not JSON from \(url.host ?? "?")") }
        return json
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = fields.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }
}

/// Attaches DPoP proofs and runs the nonce retry (§12.7 steps 5, 8, 10). One per session: its key
/// is the session's key, and its nonces are that key's conversation with each server.
actor DPoPSender {
    let key: DPoPKey
    private let transport: HTTPTransport
    /// The last `DPoP-Nonce` each origin sent. Per server, never shared: a PDS nonce is garbage to
    /// the authorization server and the other way round.
    private(set) var nonces: [String: String] = [:]
    // Sent proofs are not kept: a log here grows by a ~600-byte JWT per authorised request for the
    // life of the session — thousands a day at §12.4's 60 s refresh. Tests read proofs where the
    // network stands (`StubTransport`).

    init(key: DPoPKey, transport: HTTPTransport, nonces: [String: String] = [:]) {
        self.key = key; self.transport = transport; self.nonces = nonces
    }

    func nonce(for url: URL) -> String? { nonces[AtprotoHTTP.origin(url)] }

    /// The server asked for a (new) nonce. The authorization server says so as a 400 body
    /// (measured: `use_dpop_nonce`); a resource server as a 401 with `WWW-Authenticate: DPoP
    /// error="use_dpop_nonce"` (RFC 9449 §9) — measured on the PDS with the body too. Both checked.
    static func wantsNonce(_ data: Data, _ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 400 || response.statusCode == 401 else { return false }
        if AtprotoHTTP.errorBody(data).error == "use_dpop_nonce" { return true }
        let www = response.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
        return www.contains("use_dpop_nonce")
    }

    /// Sends `request` with a proof (and `Authorization: DPoP <token>` when `accessToken` is set),
    /// stores whatever nonce comes back, and retries ONCE when the server asked for one. Returns the
    /// final response whatever its status; callers map it with `AtprotoHTTP.check`.
    func send(_ request: URLRequest, accessToken: String?) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw AtprotoError.invalidResponse("no URL") }
        var attempt = 0
        while true {
            attempt += 1
            var req = request
            let proof = try DPoPProof.make(key: key, method: req.httpMethod ?? "GET", url: url,
                                           nonce: nonces[AtprotoHTTP.origin(url)], accessToken: accessToken)
            req.setValue(proof, forHTTPHeaderField: "DPoP")
            if let accessToken { req.setValue("DPoP \(accessToken)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await AtprotoHTTP.send(transport, req)
            if let fresh = response.value(forHTTPHeaderField: "DPoP-Nonce"), !fresh.isEmpty {
                nonces[AtprotoHTTP.origin(url)] = fresh
            }
            if attempt == 1, Self.wantsNonce(data, response) { continue }
            return (data, response)
        }
    }
}
