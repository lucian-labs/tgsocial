// Connector — the bearer token and the handshake file (CONNECTOR.md §2). Mac only.
//
// The token is the whole of the bridge's authentication, so two properties are load-bearing:
//
//  * It comes from a CSPRNG. 32 bytes from `SecRandomCopyBytes`, base64url — 256 bits, which is
//    not guessable and not derived from anything (time, pid, node name) an attacker can observe.
//  * It is compared in constant time. A byte-at-a-time `==` leaks the length of the shared prefix
//    through timing, and a local attacker is exactly the attacker who can measure that: they are
//    on the same machine, dialling loopback, with no rate limit in front of them. `matches` folds
//    every byte into one accumulator and returns after a fixed amount of work.
//
// The file it is written to is the handshake with `lucian-mcp`: the app writes it, the MCP server
// reads it, and it never leaves the machine. Mode 0600 inside a 0700 directory, because a token
// readable by every process on the box is not a token.

#if targetEnvironment(macCatalyst)

import Foundation
import Security

enum ConnectorToken {
    /// CONNECTOR.md §2: "32 random bytes, base64url".
    static let byteCount = 32
    /// 32 bytes base64 is 44 characters with padding, 43 without. base64url drops the padding.
    static let encodedLength = 43

    /// A fresh token from the system CSPRNG. Traps rather than falling back to a weaker source:
    /// a bridge whose token came from `arc4random` because `SecRandomCopyBytes` failed would be
    /// worse than a bridge that did not start.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status)); refusing to mint a weak token.")
        return base64url(Data(bytes))
    }

    /// RFC 4648 §5: `+` → `-`, `/` → `_`, no padding. URL- and shell-safe, which matters because
    /// this string is pasted into config files and command lines.
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Constant time in the *content* of the two strings. The length comparison is not secret —
    /// a token's length is public — and the fold below runs over `expected` regardless of what
    /// `presented` contains, so no branch depends on where a mismatch first appears.
    static func matches(expected: String, presented: String) -> Bool {
        let a = Array(expected.utf8)
        let b = Array(presented.utf8)
        // Comparing against a zero-length secret must never succeed, whatever was presented.
        guard !a.isEmpty else { return false }
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for i in 0..<a.count {
            // Out of range on a short `presented` folds in a fixed byte rather than stopping,
            // so a wrong-length guess costs the same as a wrong-content one.
            let presentedByte = i < b.count ? b[i] : 0
            difference |= a[i] ^ presentedByte
        }
        return difference == 0
    }

    /// `Authorization: Bearer <token>` → the token. Nil for any other scheme or a missing header.
    static func bearer(_ header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let prefix = "bearer "
        guard trimmed.count > prefix.count,
              trimmed.prefix(prefix.count).lowercased() == prefix else { return nil }
        let token = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }
}

/// `~/.tgsocial/connector.json` — the file the MCP server reads (CONNECTOR.md §2).
struct ConnectorHandshake: Codable, Equatable {
    var port: Int
    var token: String
    var enabled: Bool
    var version: Int

    static let currentVersion = 1
    static let defaultPort = 8477
}

/// Reads and writes the handshake file with the permissions §2 requires.
struct ConnectorHandshakeStore {
    static let directoryName = ".tgsocial"
    static let fileName = "connector.json"
    static let directoryMode: NSNumber = 0o700
    static let fileMode: NSNumber = 0o600

    let directory: URL

    init(directory: URL) { self.directory = directory }

    /// The user's real home — not the sandbox container. `lucian-mcp` runs outside this app's
    /// sandbox and looks in `~/.tgsocial`, so a handshake written into the container is a token
    /// no client can read.
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let real = String(cString: dir)
            if !real.isEmpty { return URL(fileURLWithPath: real) }
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Where the handshake actually goes. The real home when the sandbox lets us write there (the
    /// entitlements carry a one-directory temporary exception for exactly this), the container
    /// home when it does not — the bridge still works either way, and `handshakePath` on the
    /// Connector screen says which one it landed in rather than leaving anyone guessing.
    static var defaultDirectory: URL {
        for home in [realHome, URL(fileURLWithPath: NSHomeDirectory())] {
            let candidate = home.appendingPathComponent(directoryName, isDirectory: true)
            if isWritable(candidate) { return candidate }
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Probes by writing, not by asking: `isWritableFile(atPath:)` reports the mode bits, and the
    /// sandbox denies long after the mode bits say yes.
    private static func isWritable(_ directory: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            guard (try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: directoryMode])) != nil else { return false }
        }
        let probe = directory.appendingPathComponent(".probe")
        guard (try? Data().write(to: probe)) != nil else { return false }
        try? fm.removeItem(at: probe)
        return true
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Creates the directory 0700 and tightens it if it already exists with looser bits — an old
    /// 0755 `~/.tgsocial` from some other tool must not be where this token lands.
    private func prepareDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: Self.directoryMode])
        } else {
            try? fm.setAttributes([.posixPermissions: Self.directoryMode], ofItemAtPath: directory.path)
        }
    }

    func write(_ handshake: ConnectorHandshake) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(handshake)
        let fm = FileManager.default
        // Create the file 0600 *before* the bytes land, so the token is never briefly world
        // readable between `write` and `setAttributes`.
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: Self.fileMode])
        }
        try data.write(to: fileURL, options: [.atomic])
        // `.atomic` writes a temporary file and renames it, which brings its own mode along.
        try? fm.setAttributes([.posixPermissions: Self.fileMode], ofItemAtPath: fileURL.path)
    }

    func read() -> ConnectorHandshake? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ConnectorHandshake.self, from: data)
    }

    /// Signing out (PRODUCT §2.14) and rotating both go through here: the old token stops working
    /// the moment the file no longer carries it.
    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func mode(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue
    }
}

#endif
