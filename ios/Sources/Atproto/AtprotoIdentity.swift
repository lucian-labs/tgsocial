// Atproto — identity: handle → DID → PDS (PROTOCOL.md §12.3 step 1, §12.7 step 1).
//
// Never assume a PDS: `bsky.social` is one host among many (§12.3). A handle is a DNS name and a
// claim; the DID is what everything here keys on. Measured for `bsky.app` on 2026-09-25: the DNS TXT
// record answered and the well-known path was 404, so both methods are implemented, in the order
// atproto gives them, and the AppView's `resolveHandle` is the last resort §12.7 allows.

import dnssd
import Foundation

struct DidDocument: Equatable {
    let did: String
    /// `#atproto_pds`'s endpoint. Nil is a definitive "no PDS" for the link check (§12.3 caching).
    let pds: URL?
    /// `alsoKnownAs` `at://<handle>`, first one.
    let handle: String?
}

struct AtprotoIdentity {
    let transport: HTTPTransport
    /// Override for tests; the real directory otherwise.
    var plcDirectory = URL(string: "https://plc.directory")!
    var txtLookup: @Sendable (String) async -> [String] = { await DNSTXT.lookup($0) }

    /// A person types `@elijah.bsky.social`, `elijah.bsky.social`, or a DID. Lowercased, no `@`.
    static func normaliseHandle(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("@") { s.removeFirst() }
        if s.hasPrefix("at://") { s = String(s.dropFirst(5)) }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, s.count <= 253 else { return nil }
        for label in labels {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }),
                  label.first != "-", label.last != "-" else { return nil }
        }
        return s
    }

    /// Handle → DID: DNS TXT `_atproto.<handle>`, then `https://<handle>/.well-known/atproto-did`,
    /// then the AppView. `nil` means none of the three knew it.
    func resolveHandle(_ handle: String) async -> String? {
        for record in await txtLookup("_atproto." + handle) where record.hasPrefix("did=") {
            if let did = Atproto.normaliseDid(String(record.dropFirst(4))) { return did }
        }
        if let url = URL(string: "https://\(handle)/.well-known/atproto-did") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            if let (data, response) = try? await transport.send(req), response.statusCode == 200,
               let text = String(data: data, encoding: .utf8),
               let did = Atproto.normaliseDid(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return did
            }
        }
        var c = URLComponents(string: "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle")!
        c.queryItems = [URLQueryItem(name: "handle", value: handle)]
        if let json = try? await AtprotoHTTP.getJSON(transport, c.url!) { return Atproto.normaliseDid(json["did"].string) }
        return nil
    }

    /// DID → document. `plc.directory` for `did:plc`, `https://<host>/.well-known/did.json` for
    /// `did:web` (hostname-level only; §12.2 refuses the path form before it gets here).
    func document(_ did: String) async throws -> DidDocument {
        guard let did = Atproto.normaliseDid(did) else { throw AtprotoError.accountNotFound }
        let url: URL
        if did.hasPrefix("did:plc:") {
            url = plcDirectory.appendingPathComponent(did)
        } else {
            url = URL(string: "https://\(did.dropFirst("did:web:".count))/.well-known/did.json")!
        }
        let json = try await AtprotoHTTP.getJSON(transport, url)
        return Self.parseDocument(json, did: did)
    }

    static func parseDocument(_ json: JSONValue, did: String) -> DidDocument {
        var pds: URL?
        for s in json["service"].array ?? [] {
            let id = s["id"].string ?? ""
            guard id == "#atproto_pds" || id == did + "#atproto_pds",
                  s["type"].string == "AtprotoPersonalDataServer",
                  let endpoint = s["serviceEndpoint"].string, let u = URL(string: endpoint),
                  u.scheme == "https" || u.scheme == "http", u.host != nil else { continue }
            pds = u
            break
        }
        let handle = (json["alsoKnownAs"].array ?? []).compactMap(\.string)
            .first(where: { $0.hasPrefix("at://") }).map { String($0.dropFirst(5)) }
        return DidDocument(did: did, pds: pds, handle: handle)
    }
}

/// `_atproto.<handle>` TXT, over the system resolver. dns_sd is the one DNS API on every Apple
/// platform this app ships to; a unicast query needs no permission.
enum DNSTXT {
    private final class Box { var records: [String] = [] }

    static func lookup(_ name: String, timeout: TimeInterval = 4) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let box = Box()
                var ref: DNSServiceRef?
                let context = Unmanaged.passUnretained(box).toOpaque()
                let err = DNSServiceQueryRecord(&ref, 0, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
                                                { _, _, _, errorCode, _, _, _, rdlen, rdata, _, context in
                    guard errorCode == DNSServiceErrorType(kDNSServiceErr_NoError), let rdata, let context else { return }
                    let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                    let bytes = UnsafeRawBufferPointer(start: rdata, count: Int(rdlen))
                    var i = 0
                    // TXT rdata: a run of <length byte><bytes> strings.
                    while i < bytes.count {
                        let n = Int(bytes[i]); i += 1
                        guard i + n <= bytes.count else { break }
                        if let s = String(bytes: bytes[i..<(i + n)], encoding: .utf8) { box.records.append(s) }
                        i += n
                    }
                }, context)
                guard err == DNSServiceErrorType(kDNSServiceErr_NoError), let ref else {
                    cont.resume(returning: []); return
                }
                var pfd = pollfd(fd: DNSServiceRefSockFD(ref), events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, Int32(timeout * 1000)) > 0 { DNSServiceProcessResult(ref) }
                DNSServiceRefDeallocate(ref)
                cont.resume(returning: box.records)
            }
        }
    }
}
