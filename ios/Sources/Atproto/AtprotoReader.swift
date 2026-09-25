// Atproto — the signed-out reads (PROTOCOL.md §12.3, §12.4). Every one is a GET against public
// atproto infrastructure from this device; nothing of tgsocial's sits in between.

import Foundation

/// The §12.3 link check's answer for one (node, DID) pair.
struct LinkCheck: Codable, Equatable {
    var did: String
    var node: String
    var verified: Bool
    var fetchedAt: Date
}

actor AtprotoReader {
    private let transport: HTTPTransport
    let identity: AtprotoIdentity
    private let now: @Sendable () -> Date

    /// §12.4's failover order, WaveLoop's rule, so two readers of the same tag behave alike.
    /// Measured 2026-09-25: `searchPosts` is 403 on the first (its CDN) and 200 on the second.
    static let appViews = [URL(string: "https://public.api.bsky.app")!, URL(string: "https://api.bsky.app")!]
    /// The host that last answered, remembered for the session (§12.4).
    private var preferred = 0

    /// §12.4: at most four atproto requests in flight.
    static let maxInFlight = 4
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// §12.4: a 429 backs everything off until this moment.
    private(set) var backoffUntil: Date?
    /// The last host that failed, for the Status sheet (`Can't reach <host>`, §2.39).
    private(set) var lastUnreachable: String?

    init(transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport; self.now = now
        identity = AtprotoIdentity(transport: transport)
    }

    private func acquire() async {
        if inFlight < Self.maxInFlight { inFlight += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { inFlight -= 1 } else { waiters.removeFirst().resume() }
    }

    /// Runs `op` inside the in-flight cap and the 429 back-off, recording what failed.
    func limited<T>(_ op: () async throws -> T) async throws -> T {
        if let until = backoffUntil, until > now() { throw AtprotoError.rateLimited(seconds: Int(until.timeIntervalSince(now()).rounded(.up))) }
        await acquire()
        defer { release() }
        do {
            let value = try await op()
            return value
        } catch let e as AtprotoError {
            if case .rateLimited(let s) = e { backoffUntil = now().addingTimeInterval(TimeInterval(s)) }
            if let h = e.host { lastUnreachable = h }
            throw e
        }
    }

    func noteRateLimit(_ seconds: Int) { backoffUntil = now().addingTimeInterval(TimeInterval(seconds)) }

    /// An AppView read, failing over on a network error, a 403 or a 5xx (§12.4).
    func appView(_ nsid: String, _ params: [(String, String)]) async throws -> JSONValue {
        try await limited {
            var lastError: Error = AtprotoError.unreachable(host: Self.appViews[0].host!)
            for step in 0..<Self.appViews.count {
                let i = (preferred + step) % Self.appViews.count
                var c = URLComponents(url: Self.appViews[i].appendingPathComponent("xrpc/\(nsid)"), resolvingAgainstBaseURL: false)!
                c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
                do {
                    let json = try await AtprotoHTTP.getJSON(transport, c.url!)
                    preferred = i
                    return json
                } catch let e as AtprotoError {
                    lastError = e
                    switch e {
                    case .unreachable: continue
                    case .http(let status, _, _, _) where status == 403 || status >= 500: continue
                    default: throw e
                    }
                }
            }
            throw lastError
        }
    }

    // MARK: §12.3 the link check

    /// `true` / `false` are answers; a throw is "no answer" (network, 5xx) and the caller keeps its
    /// previous verified result for at most a day (§12.3 Caching). RecordNotFound, a DID the
    /// directory answers 404 or 410 for, and a document with no `#atproto_pds` are definitive.
    func checkLink(did: String, node: String) async throws -> Bool {
        guard let key = Atproto.linkRecordKey(node) else { return false }
        return try await limited {
            let doc: DidDocument
            do { doc = try await identity.document(did) } catch let e as AtprotoError {
                if case .http(let status, _, _, _) = e, status == 404 || status == 410 { return false }
                throw e
            }
            guard let pds = doc.pds else { return false }
            var c = URLComponents(url: pds.appendingPathComponent("xrpc/com.atproto.repo.getRecord"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "repo", value: did),
                            URLQueryItem(name: "collection", value: Atproto.linkCollection),
                            URLQueryItem(name: "rkey", value: key)]
            do {
                let record = try await AtprotoHTTP.getJSON(transport, c.url!)
                return Atproto.recordNamesNode(record, did: did, key: key)
            } catch let e as AtprotoError where e.isRecordNotFound {
                return false
            }
        }
    }

    /// §12.9: the signed-in account's Bluesky blocks are public records — `app.bsky.graph.block`
    /// in its own repo, readable with `listRecords` and no auth. Their subjects' DIDs.
    func blockedDids(of did: String, pds: URL, maxPages: Int = 10) async throws -> Set<String> {
        var out = Set<String>()
        var cursor: String?
        for _ in 0..<maxPages {
            var c = URLComponents(url: pds.appendingPathComponent("xrpc/com.atproto.repo.listRecords"), resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "repo", value: did), URLQueryItem(name: "collection", value: "app.bsky.graph.block"),
                            URLQueryItem(name: "limit", value: "100")] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let page = try await limited { try await AtprotoHTTP.getJSON(transport, c.url!) }
            for r in page["records"].array ?? [] { if let d = Atproto.normaliseDid(r["value"]["subject"].string) { out.insert(d) } }
            guard let next = page["cursor"].string, !next.isEmpty, !(page["records"].array ?? []).isEmpty else { break }
            cursor = next
        }
        return out
    }
}
