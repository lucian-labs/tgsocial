// Atproto — PKCE and DPoP (PROTOCOL.md §12.7 steps 4, 5, 8, 10). CryptoKit only.
//
// atproto OAuth for a public client binds every token to a key the client holds: each request to
// the authorization server or the PDS carries a fresh ES256 JWT (a "DPoP proof") signed by that key,
// naming the method and URL it is for. This file is the whole of that, and nothing about a session:
// the key, the proof, the PKCE pair. Hand-rolled rather than taken from a package because the app
// depends on TDLibKit alone, the one Swift OAuth package in the family calls its DPoP support
// preliminary with FIXMEs on exactly the claims below, and these ~200 lines are measurable —
// `AtprotoOAuthTests` checks the RFC 7636 vector and verifies a proof's signature with the public
// key the proof carries.

import CryptoKit
import Foundation
import Security

// MARK: - base64url (RFC 7515 §2: no padding)

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}

// MARK: - PKCE (RFC 7636), S256 only — bsky.social refuses `plain` (measured 2026-09-25)

struct PKCE: Equatable {
    let verifier: String
    let challenge: String
    static let method = "S256"

    /// 32 random bytes, base64url — 43 characters, inside RFC 7636's 43…128.
    static func make() -> PKCE {
        let verifier = Base64URL.encode(randomBytes(32))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// BASE64URL(SHA256(ASCII(code_verifier))), RFC 7636 §4.2.
    static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomBytes(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }
}

// MARK: - The DPoP key

/// One P-256 key per session (§12.7 step 4), never exported: the Secure Enclave where the device has
/// one, else a software key whose raw bytes live only in the Keychain. Either way the private half
/// never leaves this object except as the Keychain blob `persisted` names.
struct DPoPKey: @unchecked Sendable {
    enum Storage: String, Codable { case secureEnclave, software }

    private let sign: (Data) throws -> Data
    let publicKey: P256.Signing.PublicKey
    /// What the Keychain holds to rebuild this key: an opaque Secure Enclave handle, or the raw
    /// software key. Tagged so a restore knows which it is.
    let storage: Storage
    let persisted: Data

    /// A fresh key. `preferSecureEnclave` is false in tests so a proof can be produced on a
    /// simulator, which has no enclave; the app passes true and falls back when there is none.
    static func generate(preferSecureEnclave: Bool = true) -> DPoPKey {
        if preferSecureEnclave, SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            return DPoPKey(enclave: key)
        }
        return DPoPKey(software: P256.Signing.PrivateKey())
    }

    static func restore(storage: Storage, data: Data) -> DPoPKey? {
        switch storage {
        case .secureEnclave:
            return (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)).map { DPoPKey(enclave: $0) }
        case .software:
            return (try? P256.Signing.PrivateKey(rawRepresentation: data)).map { DPoPKey(software: $0) }
        }
    }

    init(software key: P256.Signing.PrivateKey) {
        publicKey = key.publicKey
        storage = .software
        persisted = key.rawRepresentation
        sign = { try key.signature(for: $0).rawRepresentation }
    }

    init(enclave key: SecureEnclave.P256.Signing.PrivateKey) {
        publicKey = key.publicKey
        storage = .secureEnclave
        persisted = key.dataRepresentation
        sign = { try key.signature(for: $0).rawRepresentation }
    }

    /// The public JWK (RFC 7518 §6.2.1): x and y only. `d` is never in it — that is the whole of
    /// "public-only", and `AtprotoOAuthTests` asserts it.
    var jwk: [String: String] {
        // x963: 0x04 || X (32) || Y (32).
        let raw = publicKey.x963Representation
        return ["kty": "EC", "crv": "P-256",
                "x": Base64URL.encode(raw.subdata(in: 1..<33)),
                "y": Base64URL.encode(raw.subdata(in: 33..<65))]
    }

    /// ES256 over the JWS signing input: r || s, 64 bytes (RFC 7518 §3.4) — CryptoKit's raw form.
    func signature(for data: Data) throws -> Data { try sign(data) }
}

// MARK: - The proof

/// RFC 9449 §4.2. Header `{typ: "dpop+jwt", alg: "ES256", jwk}`; claims `jti`, `htm`, `htu`, `iat`,
/// and `nonce` when the server has handed one out, `ath` when the request carries an access token.
enum DPoPProof {
    struct Header: Codable, Equatable {
        let typ: String
        let alg: String
        let jwk: [String: String]
    }

    struct Claims: Codable, Equatable {
        let jti: String
        let htm: String
        let htu: String
        let iat: Int
        let nonce: String?
        let ath: String?
    }

    /// §12.7 step 10: `htu` has no query and no fragment. RFC 9449 §4.3 compares it that way, and a
    /// proof that carried `?limit=30` would be a proof for a different resource.
    static func htu(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.query = nil
        c.fragment = nil
        return c.string ?? url.absoluteString
    }

    /// `ath`: base64url SHA-256 of the access token's ASCII (RFC 9449 §4.2).
    static func ath(_ accessToken: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(accessToken.utf8))))
    }

    static func make(key: DPoPKey, method: String, url: URL, nonce: String?, accessToken: String?,
                     now: Date = Date(), jti: String = UUID().uuidString) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let header = Header(typ: "dpop+jwt", alg: "ES256", jwk: key.jwk)
        let claims = Claims(jti: jti, htm: method.uppercased(), htu: htu(url), iat: Int(now.timeIntervalSince1970),
                            nonce: nonce, ath: accessToken.map(ath))
        let input = Base64URL.encode(try encoder.encode(header)) + "." + Base64URL.encode(try encoder.encode(claims))
        let sig = try key.signature(for: Data(input.utf8))
        return input + "." + Base64URL.encode(sig)
    }
}
