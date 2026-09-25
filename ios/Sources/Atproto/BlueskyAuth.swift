// Atproto — the live session: Keychain storage, single-flight refresh, authorised XRPC
// (PROTOCOL.md §12.7 steps 10–12, "Where the session lives").

import Foundation
import Security

// MARK: - Where the session lives

/// The Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (§12.7): never synced, never
/// in a backup, never readable before the first unlock. A protocol so the auth tests can hold a
/// session in memory without touching the simulator's Keychain.
protocol SessionVault: AnyObject, Sendable {
    func load() -> (BlueskySession, DPoPKey)?
    /// Throws when the pair did not reach storage. A vault that swallowed the failure would leave a
    /// session that works until the next launch and then is simply gone, with nothing said — what a
    /// Mac build signed without `keychain-access-groups` did (errSecMissingEntitlement, -34018).
    func save(_ session: BlueskySession, key: DPoPKey) throws
    func clear()
}

/// A Keychain call that did not succeed, carrying its OSStatus so `Last error` (§2.39) can name it.
struct VaultError: Error, Equatable, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "The Keychain refused the Bluesky session (OSStatus \(status))." }
}

final class KeychainVault: SessionVault, @unchecked Sendable {
    private let service: String
    init(service: String = "ca.lucianlabs.tgsocial.bluesky") { self.service = service }

    private struct KeyBlob: Codable { let storage: DPoPKey.Storage; let data: Data }

    func load() -> (BlueskySession, DPoPKey)? {
        guard let s = read("session"), let session = try? JSONDecoder.iso.decode(BlueskySession.self, from: s),
              let k = read("dpop-key"), let blob = try? JSONDecoder().decode(KeyBlob.self, from: k),
              let key = DPoPKey.restore(storage: blob.storage, data: blob.data) else { return nil }
        return (session, key)
    }

    /// The new pair is written before anything else happens with it (§12.7 step 11: "stored before
    /// the old is dropped"). A write is an update-or-add, so there is never a moment with neither.
    func save(_ session: BlueskySession, key: DPoPKey) throws {
        try write("session", try JSONEncoder.iso.encode(session))
        try write("dpop-key", try JSONEncoder().encode(KeyBlob(storage: key.storage, data: key.persisted)))
    }

    func clear() {
        for account in ["session", "dpop-key"] { SecItemDelete(query(account) as CFDictionary) }
    }

    private func query(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        #if targetEnvironment(macCatalyst)
        // The iOS-style keychain on the Mac, so `kSecAttrAccessible` means what it says. It needs the
        // app's access group, which tgsocial-Mac.entitlements declares; without it every add fails
        // with -34018 and `write` now throws instead of saying nothing.
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    private func read(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func write(_ account: String, _ data: Data) throws {
        let q = query(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(attrs) { $1 } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw VaultError(status: status) }
    }
}

final class MemoryVault: SessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (BlueskySession, DPoPKey)?
    init(_ stored: (BlueskySession, DPoPKey)? = nil) { self.stored = stored }
    func load() -> (BlueskySession, DPoPKey)? { lock.lock(); defer { lock.unlock() }; return stored }
    func save(_ session: BlueskySession, key: DPoPKey) { lock.lock(); stored = (session, key); lock.unlock() }
    func clear() { lock.lock(); stored = nil; lock.unlock() }
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

// MARK: - The session

/// Owns the session and every authorised request. An actor because of §12.7 step 11: refresh
/// tokens are single-use, so two refreshes racing spend one token twice and end the session. Every
/// caller that finds the token stale awaits the SAME refresh task.
actor BlueskyAuth {
    private let oauth: AtprotoOAuth
    private let vault: SessionVault
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private(set) var session: BlueskySession?
    private var sender: DPoPSender?
    private var refreshing: Task<BlueskySession, Error>?
    /// How many refreshes reached the token endpoint — what the single-flight test measures.
    private(set) var refreshCount = 0

    /// The AppView a PDS proxies to (`atproto-proxy`, §12.4): the service DID with the fragment.
    static let appViewProxy = "did:web:api.bsky.app#bsky_appview"

    init(oauth: AtprotoOAuth, vault: SessionVault, transport: HTTPTransport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.oauth = oauth; self.vault = vault; self.transport = transport; self.now = now
        if let (session, key) = vault.load() {
            self.session = session
            sender = DPoPSender(key: key, transport: transport)
        }
    }

    /// A refreshed pair the vault refused (see `refresh`), for the caller to put in `Last error`.
    private(set) var vaultFailure: String?

    /// After §12.7 step 9 passed. The key that signed the token request is the session's key — a
    /// DPoP-bound token is useless with any other.
    ///
    /// Stored FIRST, and a pair the vault refuses is not installed: "Where the session lives" is the
    /// Keychain, and a session held only in memory would sign the person out at the next launch
    /// with no word. The sign-in fails instead, naming the OSStatus, and the tokens are revoked
    /// (best effort) because nothing is left holding them.
    func install(_ session: BlueskySession, sender: DPoPSender) async throws {
        do {
            try vault.save(session, key: sender.key)
        } catch {
            vault.clear()
            await oauth.revoke(session, dpop: sender)
            throw AtprotoError.authFailed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        self.session = session
        self.sender = sender
    }

    /// Hands over, once, a refresh the vault refused.
    func takeVaultFailure() -> String? {
        defer { vaultFailure = nil }
        return vaultFailure
    }

    /// Step 12: revoke (best effort), then delete the tokens, the key and the nonces.
    func signOut() async {
        if let session, let sender { await oauth.revoke(session, dpop: sender) }
        end()
    }

    /// Local teardown only — Telegram `logOut` (§7) and a session Bluesky ended.
    func end() {
        refreshing?.cancel()
        refreshing = nil
        session = nil
        sender = nil
        vault.clear()
    }

    /// A session whose token is good for at least another minute, refreshing when it is not.
    func fresh() async throws -> BlueskySession {
        guard let session else { throw AtprotoError.sessionEnded }
        if session.isPastCap(now: now()) { end(); throw AtprotoError.sessionEnded }
        if !session.needsRefresh(now: now()) { return session }
        return try await refresh()
    }

    /// One refresh in flight, whoever asks (§12.7 step 11).
    func refresh() async throws -> BlueskySession {
        if let refreshing { return try await refreshing.value }
        guard let current = session, let sender else { throw AtprotoError.sessionEnded }
        let task = Task { () throws -> BlueskySession in
            let token = try await oauth.refresh(current, dpop: sender)
            guard Atproto.normaliseDid(token.sub) == current.did else { throw AtprotoError.authFailed("refresh changed sub") }
            var next = current
            next.accessToken = token.accessToken
            // Rotation: a refresh that returns no new token leaves the old one, which is spent.
            next.refreshToken = token.refreshToken ?? current.refreshToken
            next.expiresAt = now().addingTimeInterval(TimeInterval(token.expiresIn))
            next.scope = token.scope.isEmpty ? current.scope : token.scope
            return next
        }
        refreshing = task
        refreshCount += 1
        defer { refreshing = nil }
        do {
            let next = try await task.value
            // Stored before the old pair is dropped. The old refresh token is already spent, so a
            // refused write keeps the new pair in memory — this launch still works — and is reported:
            // the next launch will find only the spent token and end the session (§2.39).
            do {
                try vault.save(next, key: sender.key)
            } catch {
                vaultFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            session = next
            return next
        } catch let e as AtprotoError {
            // A refused refresh is the end (invalid_grant: spent, revoked, past the cap). A server
            // that did not answer is not: the session stays and the next call tries again.
            if case .http(let status, _, _, _) = e, (400..<500).contains(status) { end(); throw AtprotoError.sessionEnded }
            throw e
        }
    }

    /// An authorised request to the session's PDS: DPoP proof with `ath`, the per-origin nonce
    /// retry, and one refresh-and-retry on a 401 that is not a nonce request (§12.7 steps 10–11).
    func send(_ build: (BlueskySession) -> URLRequest) async throws -> Data {
        var session = try await fresh()
        guard let sender else { throw AtprotoError.sessionEnded }
        var refreshed = false
        while true {
            let req = build(session)
            let (data, response) = try await sender.send(req, accessToken: session.accessToken)
            if response.statusCode == 401, !refreshed, !DPoPSender.wantsNonce(data, response) {
                refreshed = true
                session = try await refresh()
                continue
            }
            if response.statusCode == 401 {
                // Refreshed and still refused: Bluesky has ended it (§2.39).
                end()
                throw AtprotoError.sessionEnded
            }
            return try AtprotoHTTP.check(data, response, host: req.url?.host ?? "?")
        }
    }

    // MARK: XRPC

    func get(_ nsid: String, _ params: [(String, String)], proxy: Bool) async throws -> JSONValue {
        let data = try await send { s in
            var c = URLComponents(url: s.pds.appendingPathComponent("xrpc/\(nsid)"), resolvingAgainstBaseURL: false)!
            if !params.isEmpty { c.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) } }
            var req = URLRequest(url: c.url!)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if proxy { req.setValue(Self.appViewProxy, forHTTPHeaderField: "atproto-proxy") }
            return req
        }
        guard let json = JSONValue.parse(data) else { throw AtprotoError.invalidResponse("\(nsid) not JSON") }
        return json
    }

    func post(_ nsid: String, _ body: JSONValue) async throws -> JSONValue {
        let data = try await send { s in
            var req = URLRequest(url: s.pds.appendingPathComponent("xrpc/\(nsid)"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body.data()
            return req
        }
        return JSONValue.parse(data) ?? .null
    }

    /// `com.atproto.repo.uploadBlob`: the raw bytes with their real MIME type; the returned blob
    /// object goes into the record verbatim.
    func uploadBlob(_ bytes: Data, mimeType: String) async throws -> JSONValue {
        let data = try await send { s in
            var req = URLRequest(url: s.pds.appendingPathComponent("xrpc/com.atproto.repo.uploadBlob"))
            req.httpMethod = "POST"
            req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
            req.httpBody = bytes
            return req
        }
        let blob = JSONValue.parse(data)?["blob"] ?? .null
        guard !blob.isNull else { throw AtprotoError.invalidResponse("uploadBlob returned no blob") }
        return blob
    }
}
