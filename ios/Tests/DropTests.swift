// Unit tests — reading a WaveLoop drop (PROTOCOL.md §12.12, PRODUCT.md §2.36.1).
//
// No drop existed on the network when this was written (relay `listReposByCollection` for
// `app.waveloop.social.drop` answered `{"repos":[]}` on 2026-09-25), so there is no live test here:
// every drop below is synthetic. The pictures are a port of WaveLoop's `/drop/?demo=` generator —
// discs at three depths, the right eye shifted against the left by ±0.03 of the width in
// proportion to nearness, and a depth map with near = white — served by a stub PDS that answers
// exactly what a real one was measured to answer (200 for a `Range`, `RecordNotFound`, 429s).
//
// Every test measures: requests made, bytes written, cache counts and costs, pixels rendered,
// what the shipped card reports it is showing, and what is still alive after it disappears.

import CryptoKit
import SceneKit
import SwiftUI
import UIKit
import XCTest
@testable import tgsocial

// MARK: - Fixtures

enum DropFixture {
    static let ana = "did:plc:ana2ana2ana2ana2ana2ana2"
    static let ref = "at://did:plc:ana2ana2ana2ana2ana2ana2/app.waveloop.social.drop/3drop2drop2d2"
    static let pds = URL(string: "https://pds.example.test")!

    static func ref(_ rkey: String) -> String { "at://\(ana)/app.waveloop.social.drop/\(rkey)" }

    static var didDocument: [String: Any] {
        ["id": ana, "alsoKnownAs": ["at://ana.bsky.social"],
         "service": [["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": pds.absoluteString]]]
    }

    /// The CID atproto would give these bytes: raw codec, SHA-256.
    static func cid(_ data: Data) -> String { Atproto.rawCid(sha256: Array(SHA256.hash(data: data))) }

    static func blob(_ data: Data, mime: String) -> [String: Any] {
        ["$type": "blob", "ref": ["$link": cid(data)], "mimeType": mime, "size": data.count]
    }

    static func record(ref: String = DropFixture.ref, kind: String, fields: [String: [String: Any]],
                       aspect: (Int, Int)? = (4, 3), extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["$type": Atproto.dropCollection, "kind": kind, "createdAt": "2026-09-25T18:00:00.000Z"]
        for (k, v) in fields { value[k] = v }
        if let aspect { value["aspectRatio"] = ["width": aspect.0, "height": aspect.1] }
        for (k, v) in extra { value[k] = v }
        return ["uri": ref, "cid": "bafyreidropdropdropdropdrop", "value": value]
    }

    // The /drop/ demo scene, ported: three discs at depths 0.3, 0.6 and 0.9 over a far background.
    struct Disc { let x: CGFloat; let y: CGFloat; let r: CGFloat; let depth: CGFloat; let color: UIColor }
    static let discs = [
        Disc(x: 0.25, y: 0.55, r: 0.16, depth: 0.3, color: .systemTeal),
        Disc(x: 0.55, y: 0.45, r: 0.20, depth: 0.6, color: .systemOrange),
        Disc(x: 0.78, y: 0.60, r: 0.12, depth: 0.9, color: .systemPink),
    ]

    enum Frame { case left, right, colour, depth }

    static func scene(_ frame: Frame, width: Int = 1600, height: Int = 1200) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            (frame == .depth ? UIColor.black : UIColor(white: 0.12, alpha: 1)).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            for d in discs {
                // ±0.03 of the width at full nearness, as the demo's eyes.
                let dx: CGFloat = frame == .left ? 0.015 * d.depth : frame == .right ? -0.015 * d.depth : 0
                let rect = CGRect(x: (d.x + dx - d.r) * size.width, y: (d.y - d.r) * size.height,
                                  width: 2 * d.r * size.width, height: 2 * d.r * size.width)
                (frame == .depth ? UIColor(white: d.depth, alpha: 1) : d.color).setFill()
                g.fillEllipse(in: rect)
            }
        }
    }

    static func jpeg(_ frame: Frame, width: Int = 1600, height: Int = 1200) -> Data { scene(frame, width: width, height: height).jpegData(compressionQuality: 0.85)! }
    static func png(_ frame: Frame, width: Int = 800, height: Int = 600) -> Data { scene(frame, width: width, height: height).pngData()! }
}

/// A PDS's getBlob, stubbed: the head, then the body in chunks, each a couple of milliseconds
/// apart so an abort mid-body is visible as chunks never sent.
final class StubBlobSource: BlobSource, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var contentType = "application/octet-stream"
        var sendsLength = true
        /// Overrides the real length in `Content-Length` (a PDS lying about its size).
        var claimedLength: Int?
        var headers: [String: String] = [:]
        var chunk = 16 << 10
        var delay: Duration = .milliseconds(1)
        var headDelay: Duration?
    }

    private let lock = NSLock()
    private var _requests: [URL] = []
    private var _chunksSent = 0
    private let handler: @Sendable (String) -> Reply

    /// `handler(cid)`.
    init(_ handler: @escaping @Sendable (String) -> Reply) { self.handler = handler }

    var requests: [URL] { lock.lock(); defer { lock.unlock() }; return _requests }
    var requestedCids: [String] { requests.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cid" }?.value } }
    var chunksSent: Int { lock.lock(); defer { lock.unlock() }; return _chunksSent }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<BlobEvent, Error> {
        let url = request.url!
        lock.lock(); _requests.append(url); lock.unlock()
        let cid = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cid" }?.value ?? ""
        let reply = handler(cid)
        return AsyncThrowingStream { continuation in
            let task = Task {
                if let d = reply.headDelay { try? await Task.sleep(for: d) }
                var headers = reply.headers
                headers["Content-Type"] = reply.contentType
                if reply.sendsLength { headers["Content-Length"] = "\(reply.claimedLength ?? reply.body.count)" }
                continuation.yield(.response(HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!))
                var i = 0
                while i < reply.body.count, !Task.isCancelled {
                    let end = min(i + reply.chunk, reply.body.count)
                    continuation.yield(.data(reply.body.subdata(in: i..<end)))
                    self.lock.lock(); self._chunksSent += 1; self.lock.unlock()
                    i = end
                    try? await Task.sleep(for: reply.delay)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private func spin(_ seconds: Double = 0.05) async { try? await Task.sleep(for: .seconds(seconds)) }

/// A window in the test host's own scene, so it is on a screen and its display link runs.
@MainActor
private func sceneWindow(_ frame: CGRect) -> UIWindow {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return UIWindow(frame: frame) }
    let window = UIWindow(windowScene: scene)
    window.frame = frame
    return window
}

@MainActor
private func until(_ timeout: Double = 8, _ what: String, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { await spin(0.02) }
    XCTAssertTrue(condition(), "timed out waiting for \(what)")
}

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("drop-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The PDS and the directory, answering one drop record (or `recordReply`) for every rkey.
private func pdsTransport(record: [String: Any]?, recordStatus: Int = 200, plcStatus: Int = 200) -> StubTransport {
    StubTransport { req, _ in
        let url = req.url!
        if url.host == "plc.directory" {
            return plcStatus == 200 ? .json(200, DropFixture.didDocument) : .json(plcStatus, ["message": "DID not registered"])
        }
        if url.path.hasSuffix("com.atproto.repo.getRecord") {
            if let record, recordStatus == 200 { return .json(200, record) }
            if recordStatus == 200 || recordStatus == 400 { return .json(400, ["error": "RecordNotFound", "message": "Could not locate record"]) }
            return .json(recordStatus, ["error": "Unavailable"])
        }
        return .json(404, [:])
    }
}

@MainActor
private func store(transport: StubTransport, blobs: StubBlobSource, images: ImageMemoryCache = ImageMemoryCache(byteLimit: 64 << 20, countLimit: 64),
                   disk: DropBlobCache? = nil) -> DropStore {
    DropStore(reader: AtprotoReader(transport: transport), blobs: blobs, images: images,
              disk: disk ?? DropBlobCache(directory: tempDir()))
}

// MARK: - Vectors: finding a drop, and what a record renders as

final class DropVectorTests: XCTestCase {
    private func cases(_ name: String) throws -> [JSONValue] {
        let list = try AtprotoVectorTests.loadAtprotoVectors()[name]["cases"].array ?? []
        XCTAssertGreaterThan(list.count, 0, "\(name) has cases")
        return list
    }

    /// §12.6: every form a drop link takes — `?at=`, `?d=&r=`, a facet, a URL in the text, the
    /// media half of recordWithMedia, a subdomain — and every way one is refused.
    func testDropRefVectorsCoverEveryForm() throws {
        let list = try cases("drop")
        XCTAssertGreaterThanOrEqual(list.count, 12)
        var found = 0
        for c in list {
            let got = Atproto.dropRef(c["post"])
            XCTAssertEqual(got, c["out"].string, c["name"].string ?? "?")
            if got != nil { found += 1 }
        }
        XCTAssertGreaterThanOrEqual(found, 6, "the admitting cases are really admitted")
    }

    /// §12.12 rules 2, 4, 7, 8 and 10 — `atproto.dropRecord`, the vectors web and Android will run.
    func testDropRecordVectors() throws {
        for c in try cases("dropRecord") {
            let name = c["name"].string ?? "?"
            let plan = Atproto.dropPlan(ref: c["ref"].string ?? "", response: c["response"], thumb: c["thumb"].bool ?? true)
            let out = c["out"]
            XCTAssertEqual(plan.kind?.rawValue ?? "link", out["render"].string, name)
            guard out["render"].string != "link" else { continue }
            XCTAssertEqual(plan.onScreen, (out["onScreen"].array ?? []).compactMap(\.string), "\(name): on screen")
            XCTAssertEqual(plan.onTap, (out["onTap"].array ?? []).compactMap(\.string), "\(name): on tap")
            if let aspect = out["aspect"].number {
                XCTAssertEqual(try XCTUnwrap(plan.aspect, name), aspect, accuracy: 1e-12, name)
            } else {
                XCTAssertNil(plan.aspect, name)
            }
            if let shift = out["shift"].number { XCTAssertEqual(try XCTUnwrap(plan.shift, name), shift, accuracy: 1e-12, name) }
        }
    }

    /// Rule 4: a CID is `b` + base32, so nothing else reaches the getBlob URL; and rule 6's check
    /// reads the digest back out of a real CID.
    func testCidGrammarAndDigest() {
        XCTAssertFalse(Atproto.isBlobCid("QmNotBase32&did=x"))
        XCTAssertFalse(Atproto.isBlobCid("bafk/../x"))
        XCTAssertFalse(Atproto.isBlobCid("bshort"))
        let data = Data("a drop".utf8)
        let cid = DropFixture.cid(data)
        XCTAssertTrue(cid.hasPrefix("bafkrei"), cid)
        XCTAssertEqual(Atproto.sha256Digest(ofCid: cid), Data(SHA256.hash(data: data)))
        XCTAssertNil(Atproto.sha256Digest(ofCid: "bafyreidropdropdropdropdrop"), "a dag-cbor CID is not a blob digest")
        let url = Atproto.blobURL(pds: DropFixture.pds, did: DropFixture.ana, cid: cid)
        XCTAssertEqual(url?.absoluteString, "https://pds.example.test/xrpc/com.atproto.sync.getBlob?did=\(DropFixture.ana)&cid=\(cid)")
        XCTAssertNil(Atproto.blobURL(pds: DropFixture.pds, did: DropFixture.ana, cid: "QmNotBase32&did=x"))
    }
}

// MARK: - Resolution against a stubbed PDS (rules 1–3)

@MainActor
final class DropResolutionTests: XCTestCase {
    func testResolvesOnceAndCachesTheRecord() async throws {
        let left = DropFixture.jpeg(.left), right = DropFixture.jpeg(.right)
        let rec = DropFixture.record(kind: "stereo", fields: ["left": DropFixture.blob(left, mime: "image/jpeg"),
                                                              "right": DropFixture.blob(right, mime: "image/jpeg")],
                                     extra: ["stereo": ["disparityAdjust": 12]])
        let transport = pdsTransport(record: rec)
        let s = store(transport: transport, blobs: StubBlobSource { _ in .init() })
        // Three cards ask at once: one read (rule 1).
        async let a = s.resolve(DropFixture.ref)
        async let b = s.resolve(DropFixture.ref)
        async let c = s.resolve(DropFixture.ref)
        let results = await [a, b, c]
        guard case .drop(let record, let source) = results[0] else { return XCTFail("\(results[0])") }
        XCTAssertEqual(results[1], results[0]); XCTAssertEqual(results[2], results[0])
        XCTAssertEqual(record.kind, .stereo)
        XCTAssertEqual(record.disparityAdjust, 12)
        XCTAssertEqual(source, DropSource(did: DropFixture.ana, pds: DropFixture.pds))
        XCTAssertEqual(s.recordReads, 1)
        XCTAssertEqual(transport.requests.count, 2, "one DID document, one getRecord")
        let get = try XCTUnwrap(transport.requests.last?.url)
        XCTAssertEqual(get.host, "pds.example.test", "read from the owner's own PDS")
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: get, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q, ["repo": DropFixture.ana, "collection": Atproto.dropCollection, "rkey": "3drop2drop2d2"])
        XCTAssertNil(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "unauthenticated")
        // A fourth ask costs nothing.
        _ = await s.resolve(DropFixture.ref)
        XCTAssertEqual(transport.requests.count, 2)
    }

    /// Rule 3: RecordNotFound, a DID the directory 404s, and a record rule 2 refuses are answers and
    /// are cached; a 503 is not, and the next time on screen asks again.
    func testDefinitiveNoIsCachedAndAFailureIsNot() async {
        let notFound = pdsTransport(record: nil)
        let s1 = store(transport: notFound, blobs: StubBlobSource { _ in .init() })
        do { let got = await s1.resolve(DropFixture.ref); XCTAssertEqual(got, DropResolution.none) }
        do { let got = await s1.resolve(DropFixture.ref); XCTAssertEqual(got, DropResolution.none) }
        XCTAssertEqual(notFound.requests.count, 2, "cached after the first answer")

        let gone = pdsTransport(record: nil, plcStatus: 404)
        let s2 = store(transport: gone, blobs: StubBlobSource { _ in .init() })
        do { let got = await s2.resolve(DropFixture.ref); XCTAssertEqual(got, DropResolution.none) }
        XCTAssertEqual(gone.requests.count, 1, "no getRecord for a DID the directory does not know")

        let otherRepo = DropFixture.record(ref: "at://did:plc:bob2bob2bob2bob2bob2bob2/app.waveloop.social.drop/3drop2drop2d2",
                                           kind: "image", fields: ["media": DropFixture.blob(Data("x".utf8), mime: "image/jpeg")])
        let s3 = store(transport: pdsTransport(record: otherRepo), blobs: StubBlobSource { _ in .init() })
        do { let got = await s3.resolve(DropFixture.ref); XCTAssertEqual(got, DropResolution.none, "a record read out of another repo proves nothing") }

        let down = pdsTransport(record: nil, recordStatus: 503)
        let s4 = store(transport: down, blobs: StubBlobSource { _ in .init() })
        do { let got = await s4.resolve(DropFixture.ref); XCTAssertEqual(got, .later(rateLimited: nil)) }
        XCTAssertNil(s4.cached(DropFixture.ref))
        _ = await s4.resolve(DropFixture.ref)
        XCTAssertEqual(down.requests.count, 4, "asked again")
    }

    /// Rule 3: at most 64 records, least recently used out first.
    func testRecordCacheIsCountBounded() async {
        let transport = pdsTransport(record: nil)
        let s = store(transport: transport, blobs: StubBlobSource { _ in .init() })
        let refs = (0..<70).map { DropFixture.ref(String(format: "3drop%08d", $0)) }
        for r in refs { _ = await s.resolve(r) }
        XCTAssertEqual(s.recordCount, DropStore.recordLimit)
        let before = transport.requests.count
        _ = await s.resolve(refs[69])
        XCTAssertEqual(transport.requests.count, before, "a recent ref is still cached")
        _ = await s.resolve(refs[0])
        XCTAssertEqual(transport.requests.count, before + 2, "the oldest was evicted and is read again")
    }

    /// §12.4 applies: a 429 on getRecord backs the reader off, and the answer is `.later` with the
    /// server's own number for the toast.
    func testRateLimitIsNotAnAnswer() async {
        let transport = StubTransport { req, _ in
            req.url!.host == "plc.directory" ? .json(200, DropFixture.didDocument) : .json(429, ["error": "RateLimitExceeded"], headers: ["Retry-After": "23"])
        }
        let s = store(transport: transport, blobs: StubBlobSource { _ in .init() })
        let got = await s.resolve(DropFixture.ref)
        XCTAssertEqual(got, .later(rateLimited: 23))
        XCTAssertNil(s.cached(DropFixture.ref))
    }
}

// MARK: - Blobs on the wire and on disk (rules 4–6)

@MainActor
final class DropBlobTests: XCTestCase {
    private let source = DropSource(did: DropFixture.ana, pds: DropFixture.pds)

    private func blob(_ data: Data, mime: String = "image/jpeg", declared: Int? = nil, cap: Int = 5_000_000) -> DropBlob {
        DropBlob(cid: DropFixture.cid(data), mimeType: mime, size: declared ?? data.count, cap: cap)
    }

    /// Rule 4: a `content-length` over the declared size is refused on the head — no byte of the
    /// body is written.
    func testContentLengthOverTheDeclaredSizeIsRefusedBeforeTheBody() async throws {
        let data = Data(repeating: 7, count: 200_000)
        let b = blob(data, declared: 100_000)
        let stub = StubBlobSource { _ in .init(body: data, delay: .milliseconds(5)) }
        let tmp = tempDir().appendingPathComponent("x.part")
        do {
            _ = try await DropDownload.run(source: stub, request: URLRequest(url: source.url(b)!), blob: b, to: tmp) { _, _ in }
            XCTFail("accepted an over-size blob")
        } catch let f as DropFailure {
            XCTAssertEqual(f, .overCap)
        }
        let written = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? -1
        XCTAssertEqual(written, 0, "no body byte written")
    }

    /// Rule 4: with no `content-length`, a body that runs past the cap is aborted at that byte.
    func testABodyPastTheCapIsAbortedMidway() async throws {
        let data = Data(repeating: 1, count: 64 * 16 << 10)   // 64 chunks of 16 KB
        let b = DropBlob(cid: DropFixture.cid(data), mimeType: "image/jpeg", size: nil, cap: 100_000)
        let stub = StubBlobSource { _ in .init(body: data, sendsLength: false, delay: .milliseconds(3)) }
        let tmp = tempDir().appendingPathComponent("y.part")
        do {
            _ = try await DropDownload.run(source: stub, request: URLRequest(url: source.url(b)!), blob: b, to: tmp) { _, _ in }
            XCTFail("accepted a blob past its cap")
        } catch let f as DropFailure {
            XCTAssertEqual(f, .overCap)
        }
        await spin(0.1)
        // 100 KB is the seventh 16 KB chunk; the stream stops a few chunks later at most.
        XCTAssertLessThan(stub.chunksSent, 16, "sent \(stub.chunksSent) of 64 chunks")
        let written = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(written, 100_000)
    }

    /// Rule 6: bytes that are not the ones the CID names never reach the cache.
    func testAMismatchedBlobIsDiscarded() async {
        let real = DropFixture.jpeg(.left, width: 64, height: 48)
        let b = blob(real)
        let stub = StubBlobSource { _ in .init(body: Data(repeating: 9, count: real.count)) }
        let s = store(transport: pdsTransport(record: nil), blobs: stub)
        s.fetch(b, from: source, priority: .tap)
        let url = await s.file(b.cid)
        XCTAssertNil(url)
        XCTAssertEqual(s.state(b.cid).failure, .mismatch)
        XCTAssertEqual(s.disk.count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: s.disk.directory.path), [], "no temp file left behind")
    }

    /// Rule 5: two in flight, and a tap goes ahead of the scroll.
    func testTheLaneIsTwoWideAndTapsGoFirst() async {
        let datas = (0..<5).map { Data("blob \($0)".utf8) + Data(repeating: UInt8($0), count: 4000) }
        let byCid = Dictionary(uniqueKeysWithValues: datas.map { (DropFixture.cid($0), $0) })
        // The two running downloads end 300 ms apart, so "the first free slot" is one slot: with
        // equal delays both freed in the same instant, and two resumed tasks raced to the wire.
        let slow = DropFixture.cid(datas[1])
        let stub = StubBlobSource { cid in .init(body: byCid[cid] ?? Data(), headDelay: .milliseconds(cid == slow ? 450 : 150)) }
        let s = store(transport: pdsTransport(record: nil), blobs: stub)
        let blobs = datas.map { blob($0) }
        for b in blobs[0..<4] { s.fetch(b, from: source, priority: .screen) }
        await until(3, "two running, two queued") { s.laneBusy == 2 && s.laneQueued == 2 }
        s.fetch(blobs[4], from: source, priority: .tap)
        await until(3, "the tap queued") { s.laneQueued == 3 }
        for b in blobs { _ = await s.file(b.cid) }
        XCTAssertEqual(s.peakLane, DropStore.laneWidth)
        XCTAssertEqual(s.blobRequests, 5)
        XCTAssertEqual(stub.requestedCids.count, 5)
        XCTAssertEqual(stub.requestedCids[2], blobs[4].cid, "the tap took the first free slot, ahead of two queued screen downloads")
        XCTAssertEqual(s.disk.count, 5)
    }

    /// Rule 5: an on-screen download nobody wants any more is cancelled; a tapped one is not.
    func testLeavingTheScreenCancelsScreenDownloadsOnly() async {
        let big = Data(repeating: 3, count: 40 * 16 << 10)
        let other = Data(repeating: 4, count: 40 * 16 << 10)
        let bigCid = DropFixture.cid(big)
        let s = store(transport: pdsTransport(record: nil), blobs: StubBlobSource { cid in
            .init(body: cid == bigCid ? big : other, delay: .milliseconds(10))
        })
        let screen = blob(big, cap: 50_000_000), tapped = blob(other, cap: 50_000_000)
        s.fetch(screen, from: source, priority: .screen)
        s.fetch(tapped, from: source, priority: .tap)
        await spin(0.05)
        s.release(screen.cid)
        s.release(tapped.cid)
        let a = await s.file(screen.cid)
        let b = await s.file(tapped.cid)
        XCTAssertNil(a)
        XCTAssertEqual(s.state(screen.cid).failure, .cancelled)
        XCTAssertNotNil(b, "the reader asked for this one")
    }

    /// A card that leaves the screen and comes straight back — a fast scroll back, or a lazy stack's
    /// disappear/appear on relayout — while its cancelled download is still unwinding gets a fresh
    /// download, not the dying one's `.cancelled`; whoever had joined the old one gets its answer;
    /// and the old one's end does not overwrite the new one's state.
    func testACardBackOnScreenDoesNotJoinACancelledDownload() async {
        let data = Data(repeating: 5, count: 30 * 16 << 10)
        let b = blob(data, cap: 50_000_000)
        let stub = StubBlobSource { _ in .init(body: data, delay: .milliseconds(10)) }
        let s = store(transport: pdsTransport(record: nil), blobs: stub)
        s.fetch(b, from: source, priority: .screen)
        let joinedBefore = Task { await s.file(b.cid) }
        await spin(0.05)
        s.release(b.cid)                                  // off screen: cancelled…
        s.fetch(b, from: source, priority: .screen)       // …and back before the cancel has unwound
        XCTAssertTrue(s.state(b.cid).active, "the fresh download is what the ring shows")
        let url = await s.file(b.cid)
        XCTAssertNotNil(url, "the card that came back gets its file")
        XCTAssertNil(s.state(b.cid).failure)
        let old = await joinedBefore.value
        XCTAssertNil(old, "the caller that joined the cancelled download is told so")
        XCTAssertEqual(s.blobRequests, 2, "a fresh request, not the dying one")
        await spin(0.2)
        XCTAssertNotNil(s.state(b.cid).url, "the old download's end left the new one's state alone")
        XCTAssertFalse(s.state(b.cid).active)
        XCTAssertEqual(s.disk.count, 1)
        XCTAssertEqual(s.activeDownloads, 0)
    }

    /// What a stereo or depth card does when its blobs did not all arrive: a failure is rule 8's
    /// link card; a cancel nobody chose as a failure leaves the poster waiting for a tap.
    func testACancelIsNotAFailure() {
        XCTAssertEqual(DropLoadOutcome.after(.status(500), readerCancelled: false), .fallBack)
        XCTAssertEqual(DropLoadOutcome.after(.mismatch, readerCancelled: false), .fallBack)
        XCTAssertEqual(DropLoadOutcome.after(nil, readerCancelled: false), .fallBack)
        XCTAssertEqual(DropLoadOutcome.after(.cancelled, readerCancelled: false), .waitForTap)
        XCTAssertEqual(DropLoadOutcome.after(.cancelled, readerCancelled: true), .nothing)
        XCTAssertEqual(DropLoadOutcome.after(.status(500), readerCancelled: true), .nothing)
    }

    /// Rule 6: LRU to both bounds, pinned files kept, a relaunch rebuilds the index from disk.
    func testDiskCacheBoundsAndPins() async throws {
        let dir = tempDir()
        let cache = DropBlobCache(directory: dir, fileLimit: 3, byteLimit: 10_000)
        func put(_ n: Int, size: Int) -> String {
            let data = Data(repeating: UInt8(n), count: size)
            let cid = DropFixture.cid(data)
            let tmp = cache.temporaryURL()
            FileManager.default.createFile(atPath: tmp.path, contents: data)
            cache.admit(tmp, cid: cid, fileExtension: "jpg")
            return cid
        }
        let a = put(1, size: 1000), b = put(2, size: 1000), c = put(3, size: 1000)
        cache.pin(a)
        _ = cache.url(for: b)
        let d = put(4, size: 1000)
        XCTAssertEqual(cache.count, 3)
        XCTAssertNotNil(cache.url(for: a), "pinned")
        XCTAssertNil(cache.url(for: c), "least recently used went")
        XCTAssertNotNil(cache.url(for: b)); XCTAssertNotNil(cache.url(for: d))
        _ = put(5, size: 9500)
        XCTAssertLessThanOrEqual(cache.totalBytes, 10_000 + 1000, "over the byte bound only by the pinned file")
        XCTAssertNotNil(cache.url(for: a))
        cache.unpin(a)
        XCTAssertLessThanOrEqual(cache.totalBytes, 10_000)
        XCTAssertEqual(DropBlobCache.fileLimit, 16)
        XCTAssertEqual(DropBlobCache.byteLimit, 200_000_000)
        let reopened = DropBlobCache(directory: dir, fileLimit: 3, byteLimit: 10_000)
        XCTAssertEqual(reopened.count, cache.count, "the index is rebuilt from the directory")
    }

    /// Rule 9: drop pixels are decoded at card width into the SAME cache the photos use, and the
    /// depth map is one channel at half that — the byte numbers §12.12 states.
    func testDecodedCostsAndTheOneBudget() async throws {
        let model = AppModel()
        XCTAssertTrue(model.drops.images === BlueskyImages.budget, "drops and Bluesky images share the photo budget")

        let eye = DropFixture.jpeg(.left, width: 2400, height: 1800)
        let map = DropFixture.png(.depth, width: 2400, height: 1800)
        let stub = StubBlobSource { cid in .init(body: cid == DropFixture.cid(eye) ? eye : map) }
        let images = ImageMemoryCache(byteLimit: 64 << 20, countLimit: 64)
        let s = store(transport: pdsTransport(record: nil), blobs: stub, images: images)
        let eyeBlob = blob(eye), mapBlob = blob(map, mime: "image/png")
        _ = await s.files([eyeBlob, mapBlob], from: source, priority: .screen)
        let cardImage = await s.image(eyeBlob.cid, .card)
        let depthImage = await s.image(mapBlob.cid, .depthMap)
        let card = try XCTUnwrap(cardImage)
        let depth = try XCTUnwrap(depthImage)
        let w = ScreenPixels.width
        let cg = try XCTUnwrap(card.cgImage), dg = try XCTUnwrap(depth.cgImage)
        XCTAssertEqual(max(cg.width, cg.height), w, "an eye is never decoded wider than the screen")
        XCTAssertLessThanOrEqual(ImageMemoryCache.cost(of: card), w * (w * 3 / 4 + 1) * 4 + 64 * cg.height)
        XCTAssertEqual(dg.bitsPerPixel, 8, "one channel")
        XCTAssertEqual(max(dg.width, dg.height), w / 2)
        let depthCost = ImageMemoryCache.cost(of: depth)
        XCTAssertLessThanOrEqual(depthCost, 400_000, "≈0.33 MB on a 440 pt phone; \(depthCost) here")
        XCTAssertLessThan(depthCost * 3, ImageMemoryCache.cost(of: card), "a quarter of an RGBA card, less the half-width")
        XCTAssertNotNil(images.image(DropStore.cacheKey(eyeBlob.cid, .card)), "charged to the budget it was handed")
        XCTAssertEqual(s.decodeCount, 2)
        _ = await s.image(eyeBlob.cid, .card)
        XCTAssertEqual(s.decodeCount, 2, "a second draw is a cache hit")
    }
}

// MARK: - The shipped card

@MainActor
final class DropCardTests: XCTestCase {
    private final class Box { var phases: [String] = []; var history: [[String]] = [] }

    private func post(ref: String = DropFixture.ref) -> (BlueskyPost, BlueskyExternal) {
        let ext = BlueskyExternal(uri: "https://waveloop.app/drop/?at=\(ref)", title: "Dusk at the pier", description: "", thumb: nil)
        var p = BlueskyPost(uri: "at://\(DropFixture.ana)/app.bsky.feed.post/3mw2c6jepkk22", cid: "bafy", authorDid: DropFixture.ana,
                            handle: "ana.bsky.social", displayName: "Ana Iliovic", avatar: nil, text: RichText(spans: []),
                            likeCount: 12, replyCount: 3, dropRef: ref)
        p.external = ext
        return (p, ext)
    }

    private struct Hosted { let window: UIWindow; let host: UIHostingController<AnyView>; let box: Box }

    private func host(_ model: AppModel) -> Hosted {
        let (p, ext) = post()
        let box = Box()
        let view = DropCard(post: p, external: ext, ref: DropFixture.ref)
            .frame(width: 402)
            .environment(model)
            // A bare hosting controller is not inside an app scene; the card only moves while the
            // scene is active (rule 11), which is what a reader looking at it has.
            .environment(\.scenePhase, .active)
            .onPreferenceChange(DropPhaseKey.self) { v in
                box.phases = v
                box.history.append(v)
            }
        let host = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return Hosted(window: window, host: host, box: box)
    }

    private func tearDown(_ h: Hosted) async {
        h.host.rootView = AnyView(EmptyView())
        h.host.view.layoutIfNeeded()
        await spin(0.2)
        h.window.isHidden = true
        h.window.rootViewController = nil
        await spin(0.1)
    }

    private func model(record: [String: Any]?, recordStatus: Int = 200, blobs: StubBlobSource) -> AppModel {
        let m = AppModel()
        m.drops = store(transport: pdsTransport(record: record, recordStatus: recordStatus), blobs: blobs)
        return m
    }

    /// Rule 8: a kind this build does not know is its link card — and costs no blob request.
    func testUnknownKindStaysTheLinkCard() async {
        let rec = DropFixture.record(kind: "hologram", fields: ["media": DropFixture.blob(Data("x".utf8), mime: "application/octet-stream")])
        let blobs = StubBlobSource { _ in .init() }
        let m = model(record: rec, blobs: blobs)
        let h = host(m)
        await until(3, "the record read") { m.drops.recordReads == 1 && m.drops.cached(DropFixture.ref) != nil }
        await spin(0.2)
        XCTAssertEqual(h.box.phases, ["card:link"])
        XCTAssertFalse(h.box.history.flatMap { $0 }.contains { $0 != "card:link" }, "never anything but the link card: \(h.box.history)")
        XCTAssertEqual(blobs.requests.count, 0)
        await tearDown(h)
    }

    /// Rule 8 again, for the one kind WaveLoop does write without a renderer here: a GLB-only model
    /// never fetches its 50 MB `media`.
    func testGlbOnlyModelNeverFetchesMedia() async {
        let glb = Data(repeating: 0x67, count: 1000)
        let rec = DropFixture.record(kind: "model", fields: ["media": DropFixture.blob(glb, mime: "model/gltf-binary")], aspect: (1, 1))
        let blobs = StubBlobSource { _ in .init(body: glb) }
        let m = model(record: rec, blobs: blobs)
        let h = host(m)
        await until(3, "the record read") { m.drops.cached(DropFixture.ref) != nil }
        await spin(0.2)
        XCTAssertEqual(h.box.phases, ["card:link"])
        XCTAssertEqual(blobs.requests.count, 0)
        await tearDown(h)
    }

    /// A failed read leaves the plain Bluesky post: the record's host is down → the link card, no
    /// blob request, and nothing cached (the next time on screen asks again).
    func testARecordFailureLeavesThePlainPost() async {
        let blobs = StubBlobSource { _ in .init() }
        let m = model(record: nil, recordStatus: 503, blobs: blobs)
        let h = host(m)
        await until(3, "the read attempt") { m.drops.recordReads >= 1 }
        await spin(0.3)
        XCTAssertEqual(h.box.phases, ["card:link"])
        XCTAssertNil(m.drops.cached(DropFixture.ref))
        XCTAssertEqual(blobs.requests.count, 0)
        await tearDown(h)
    }

    /// A blob failure the reader did not ask for: the stereo card becomes the drop, its eyes 500,
    /// and it returns to the link card — silently (no toast).
    func testABlobFailureFallsBackToTheLinkCard() async {
        let left = DropFixture.jpeg(.left, width: 320, height: 240), right = DropFixture.jpeg(.right, width: 320, height: 240)
        let rec = DropFixture.record(kind: "stereo", fields: ["left": DropFixture.blob(left, mime: "image/jpeg"),
                                                              "right": DropFixture.blob(right, mime: "image/jpeg")])
        let blobs = StubBlobSource { _ in .init(status: 500, body: Data("{}".utf8)) }
        let m = model(record: rec, blobs: blobs)
        let h = host(m)
        await until(4, "the stereo phase then the fallback") {
            h.box.history.contains(["card:stereo"]) && h.box.phases == ["card:link"]
        }
        XCTAssertEqual(blobs.requests.count, 2, "both eyes asked for, once")
        XCTAssertNil(m.toast, "a failure the reader did not ask for says nothing")
        await tearDown(h)
    }

    /// The stereo card loads both eyes on screen, holds card renditions from the shared budget with
    /// the files pinned, and lets go of all of it when it disappears.
    func testStereoMemoryIsReleasedOnDisappear() async throws {
        let left = DropFixture.jpeg(.left), right = DropFixture.jpeg(.right)
        let rec = DropFixture.record(kind: "stereo", fields: ["left": DropFixture.blob(left, mime: "image/jpeg"),
                                                              "right": DropFixture.blob(right, mime: "image/jpeg")],
                                     extra: ["stereo": ["disparityAdjust": 12]])
        let byCid = [DropFixture.cid(left): left, DropFixture.cid(right): right]
        let blobs = StubBlobSource { cid in .init(body: byCid[cid] ?? Data(), contentType: "image/jpeg") }
        let m = model(record: rec, blobs: blobs)
        let h = host(m)
        await until(8, "both eyes on screen") { h.box.phases.contains("stereo:ready") }
        XCTAssertTrue(h.box.phases.contains("card:stereo"), "\(h.box.phases)")
        let s = m.drops!
        XCTAssertEqual(s.disk.pinnedCount, 2, "both eye files pinned while shown")
        weak var l = s.cachedImage(DropFixture.cid(left), .card)
        weak var r = s.cachedImage(DropFixture.cid(right), .card)
        XCTAssertNotNil(l); XCTAssertNotNil(r)
        let pairCost = ImageMemoryCache.cost(of: try XCTUnwrap(l)) + ImageMemoryCache.cost(of: try XCTUnwrap(r))
        let w = ScreenPixels.width
        XCTAssertLessThanOrEqual(pairCost, 2 * (w * (w * 3 / 4 + 1) * 4 + 64 * w), "≈10.5 MB a pair on a 440 pt phone; \(pairCost) here")

        await tearDown(h)
        XCTAssertEqual(s.disk.pinnedCount, 0, "unpinned on disappear")
        XCTAssertEqual(s.activeDownloads, 0)
        // The shared cache still holds them — that is its job — until it is purged; then nothing
        // of the card's is left holding the pixels.
        s.images.removeAll()
        await spin(0.3)
        XCTAssertNil(l, "the left eye outlived its card")
        XCTAssertNil(r, "the right eye outlived its card")
    }

    /// The poster fills its box and never grows it: a 4:3 preview in a model's 1:1 box is 402 × 402
    /// in a 402 pt column, pill inside. (It ran off the column in the running app before: a fill
    /// image in a ZStack under `maxWidth: .infinity` sized the stack.)
    func testPosterStaysInsideItsBox() async throws {
        let preview = DropFixture.jpeg(.colour, width: 1200, height: 900)
        let usdz = Data(repeating: 1, count: 100)
        let rec = DropFixture.record(kind: "model", fields: ["usdz": DropFixture.blob(usdz, mime: "model/vnd.usdz+zip"),
                                                             "preview": DropFixture.blob(preview, mime: "image/jpeg")], aspect: (1, 1))
        let m = model(record: rec, blobs: StubBlobSource { _ in .init(body: preview, contentType: "image/jpeg") })
        guard case .drop(let record, let source) = await m.drops.resolve(DropFixture.ref) else { return XCTFail("unresolved") }
        let drop = ResolvedDrop(record: record, source: source, plan: Atproto.dropPlan(record, thumb: false), posterURL: nil)
        XCTAssertEqual(drop.plan.onScreen, ["preview"])
        final class Measured { var size = CGSize.zero }
        let measured = Measured()
        let poster = VStack(spacing: 0) {
            DropPoster(drop: drop, pill: DropCopy.modelPill)
                .background(GeometryReader { g in Color.clear.onChange(of: g.size, initial: true) { _, s in measured.size = s } })
            Spacer(minLength: 0)
        }
        .frame(width: 402)
        .environment(m)
        let host = UIHostingController(rootView: AnyView(poster))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        await until(4, "the preview decoded") { m.drops.cachedImage(DropFixture.cid(preview), .card) != nil }
        await spin(0.2)
        host.view.layoutIfNeeded()
        XCTAssertEqual(measured.size.width, 402, accuracy: 0.5, "the poster is the column's width, not the filled image's")
        XCTAssertEqual(measured.size.height, 402, accuracy: 0.5, "1:1")
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The depth card: the motion source is subscribed while it is on screen, and on disappear the
    /// view, the subscription and the pins are all gone.
    func testDepthReleasesMotionAndPinsOnDisappear() async {
        let colour = DropFixture.png(.colour), map = DropFixture.png(.depth)
        let rec = DropFixture.record(kind: "depth", fields: ["media": DropFixture.blob(colour, mime: "image/png"),
                                                             "depth": DropFixture.blob(map, mime: "image/png")])
        let byCid = [DropFixture.cid(colour): colour, DropFixture.cid(map): map]
        let blobs = StubBlobSource { cid in .init(body: byCid[cid] ?? Data(), contentType: "image/png") }
        let m = model(record: rec, blobs: blobs)
        let h = host(m)
        await until(8, "the parallax on screen") { h.box.phases.contains("depth:ready") }
        let s = m.drops!
        XCTAssertEqual(s.liveDepthViews, 1)
        XCTAssertEqual(s.motion.subscribers, 1, "one app-wide motion source, subscribed while on screen")
        XCTAssertEqual(s.disk.pinnedCount, 2)
        await tearDown(h)
        XCTAssertEqual(s.liveDepthViews, 0)
        XCTAssertEqual(s.motion.subscribers, 0, "stopped when no depth view is on screen")
        XCTAssertEqual(s.disk.pinnedCount, 0)
    }
}

// MARK: - When the shipped card moves (rule 11)

/// The environment a hosted card sees, switchable mid-test.
@MainActor @Observable
final class DropHostEnvironment {
    var scenePhase: ScenePhase = .active
}

/// A drop card at the top of a real ScrollView over a non-lazy column — the Thread screen's
/// shape, where the card stays in the hierarchy after it scrolls away and only `DropVisibility`
/// knows it left.
private struct ScrollingDropHost: View {
    let post: BlueskyPost
    let external: BlueskyExternal
    let environment: DropHostEnvironment
    let reduceMotion: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DropCard(post: post, external: external, ref: DropFixture.ref).frame(width: 402)
                Color.clear.frame(width: 402, height: 3000)
            }
        }
        .environment(\.scenePhase, environment.scenePhase)
        .environment(\._accessibilityReduceMotion, reduceMotion)
    }
}

@MainActor
final class DropPauseTests: XCTestCase {
    private final class Box { var phases: [String] = [] }

    private struct Hosted {
        let window: UIWindow
        let host: UIHostingController<AnyView>
        let box: Box
        let environment: DropHostEnvironment
        let post: BlueskyPost

        var scrollView: UIScrollView? { Self.find(host.view) }
        private static func find(_ v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
    }

    private func host(_ model: AppModel, reduceMotion: Bool = false) -> Hosted {
        let ext = BlueskyExternal(uri: "https://waveloop.app/drop/?at=\(DropFixture.ref)", title: "Dusk at the pier", description: "", thumb: nil)
        var p = BlueskyPost(uri: "at://\(DropFixture.ana)/app.bsky.feed.post/3mw2c6jepkk22", cid: "bafy", authorDid: DropFixture.ana,
                            handle: "ana.bsky.social", displayName: "Ana Iliovic", avatar: nil, text: RichText(spans: []),
                            likeCount: 0, replyCount: 0, dropRef: DropFixture.ref)
        p.external = ext
        let box = Box()
        let env = DropHostEnvironment()
        let view = ScrollingDropHost(post: p, external: ext, environment: env, reduceMotion: reduceMotion)
            .environment(model)
            .onPreferenceChange(DropPhaseKey.self) { box.phases = $0 }
        let host = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 900))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return Hosted(window: window, host: host, box: box, environment: env, post: p)
    }

    private func tearDown(_ h: Hosted) async {
        h.host.rootView = AnyView(EmptyView())
        h.host.view.layoutIfNeeded()
        await spin(0.2)
        h.window.isHidden = true
        h.window.rootViewController = nil
        await spin(0.1)
    }

    private func stereoModel() -> AppModel {
        let left = DropFixture.jpeg(.left, width: 640, height: 480), right = DropFixture.jpeg(.right, width: 640, height: 480)
        let rec = DropFixture.record(kind: "stereo", fields: ["left": DropFixture.blob(left, mime: "image/jpeg"),
                                                              "right": DropFixture.blob(right, mime: "image/jpeg")])
        let byCid = [DropFixture.cid(left): left, DropFixture.cid(right): right]
        let m = AppModel()
        m.drops = store(transport: pdsTransport(record: rec), blobs: StubBlobSource { cid in .init(body: byCid[cid] ?? Data(), contentType: "image/jpeg") })
        return m
    }

    private func depthModel() -> AppModel {
        let colour = DropFixture.png(.colour, width: 640, height: 480), map = DropFixture.png(.depth, width: 640, height: 480)
        let rec = DropFixture.record(kind: "depth", fields: ["media": DropFixture.blob(colour, mime: "image/png"),
                                                             "depth": DropFixture.blob(map, mime: "image/png")])
        let byCid = [DropFixture.cid(colour): colour, DropFixture.cid(map): map]
        let m = AppModel()
        m.drops = store(transport: pdsTransport(record: rec), blobs: StubBlobSource { cid in .init(body: byCid[cid] ?? Data(), contentType: "image/png") })
        return m
    }

    private func request(_ m: AppModel, _ post: BlueskyPost) -> DropViewerRequest? {
        guard case .drop(let record, let source) = m.drops.cached(DropFixture.ref) else { return nil }
        let drop = ResolvedDrop(record: record, source: source, plan: Atproto.dropPlan(record, thumb: false), posterURL: nil)
        return DropViewerRequest(post: post, title: "", drop: drop, stereo: StereoSettings(), sway: true)
    }

    /// Rule 11 on the shipped stereo card: the wiggle's timeline runs on screen, in front, with no
    /// viewer over it; pauses under the viewer and in the background; and when the card scrolls out
    /// of a non-lazy column the pair itself goes — pins, renditions and all — and comes back.
    func testWigglePausesUnderTheViewerInTheBackgroundAndOffScreen() async throws {
        let m = stereoModel()
        let h = host(m)
        let s = m.drops!
        await until(8, "the pair wiggling") { h.box.phases.contains("stereo:ready") && h.box.phases.contains("wiggle:moving") }
        XCTAssertTrue(h.box.phases.contains("canvas:wiggle"), "wiggle is the default mode: \(h.box.phases)")
        XCTAssertEqual(s.disk.pinnedCount, 2)

        m.dropViewer = try XCTUnwrap(request(m, h.post))
        await until(3, "paused under the viewer") { h.box.phases.contains("wiggle:paused") }
        XCTAssertFalse(h.box.phases.contains("wiggle:moving"))
        m.dropViewer = nil
        await until(3, "moving again") { h.box.phases.contains("wiggle:moving") }

        h.environment.scenePhase = .background
        await until(3, "paused in the background") { h.box.phases.contains("wiggle:paused") }
        h.environment.scenePhase = .active
        await until(3, "moving again") { h.box.phases.contains("wiggle:moving") }

        let scroll = try XCTUnwrap(h.scrollView)
        scroll.setContentOffset(CGPoint(x: 0, y: 2000), animated: false)
        await until(3, "the pair gone off screen") { !h.box.phases.contains("stereo:ready") }
        XCTAssertFalse(h.box.phases.contains("wiggle:moving"), "nothing draws off screen: \(h.box.phases)")
        XCTAssertEqual(s.disk.pinnedCount, 0, "unpinned when it scrolled away, with no onDisappear")
        XCTAssertEqual(s.activeDownloads, 0)
        XCTAssertTrue(h.box.phases.contains("card:stereo"), "still the drop, not the link card: \(h.box.phases)")

        scroll.setContentOffset(.zero, animated: false)
        await until(3, "back and wiggling") { h.box.phases.contains("stereo:ready") && h.box.phases.contains("wiggle:moving") }
        XCTAssertEqual(s.disk.pinnedCount, 2)
        XCTAssertEqual(s.blobRequests, 2, "back on screen is the disk cache, not the PDS")
        await tearDown(h)
    }

    /// Rule 11: under Reduce Motion stereo opens side by side, so nothing alternates.
    func testReduceMotionOpensSideBySide() async {
        let m = stereoModel()
        let h = host(m, reduceMotion: true)
        await until(8, "the pair on screen") { h.box.phases.contains("stereo:ready") }
        XCTAssertTrue(h.box.phases.contains("canvas:sideBySide"), "\(h.box.phases)")
        XCTAssertFalse(h.box.phases.contains { $0.hasPrefix("wiggle:") }, "\(h.box.phases)")
        await tearDown(h)
    }

    /// The same for depth: its timeline and the motion source run only while it can be seen.
    func testDepthPausesUnderTheViewerAndLetsGoOffScreen() async throws {
        let m = depthModel()
        let h = host(m)
        let s = m.drops!
        await until(8, "the parallax moving") { h.box.phases.contains("depth:moving") }
        XCTAssertEqual(s.motion.subscribers, 1)
        m.dropViewer = try XCTUnwrap(request(m, h.post))
        await until(3, "paused under the viewer") { h.box.phases.contains("depth:paused") }
        XCTAssertEqual(s.motion.subscribers, 0, "no motion source for a covered card")
        m.dropViewer = nil
        await until(3, "moving again") { h.box.phases.contains("depth:moving") }
        XCTAssertEqual(s.motion.subscribers, 1)

        let scroll = try XCTUnwrap(h.scrollView)
        scroll.setContentOffset(CGPoint(x: 0, y: 2000), animated: false)
        await until(3, "gone off screen") { !h.box.phases.contains("depth:ready") }
        XCTAssertEqual(s.motion.subscribers, 0)
        XCTAssertEqual(s.disk.pinnedCount, 0)
        await tearDown(h)
    }
}

// MARK: - The viewer's failures (PRODUCT §2.36.1 "Errors the reader asked for")

@MainActor
final class DropViewerTests: XCTestCase {
    private func post() -> BlueskyPost {
        BlueskyPost(uri: "at://\(DropFixture.ana)/app.bsky.feed.post/3mw2c6jepkk22", cid: "bafy", authorDid: DropFixture.ana,
                    handle: "ana.bsky.social", displayName: "Ana Iliovic", avatar: nil, text: RichText(spans: []),
                    likeCount: 0, replyCount: 0, dropRef: DropFixture.ref)
    }

    /// The model, its drop resolved, and the viewer open over it — the state a tap leaves.
    private func open(_ record: [String: Any], blobs: StubBlobSource) async throws -> (AppModel, ResolvedDrop) {
        let m = AppModel()
        m.drops = store(transport: pdsTransport(record: record), blobs: blobs)
        guard case .drop(let rec, let src) = await m.drops.resolve(DropFixture.ref) else { throw XCTSkip("unresolved") }
        let drop = ResolvedDrop(record: rec, source: src, plan: Atproto.dropPlan(rec, thumb: false), posterURL: nil)
        m.dropViewer = DropViewerRequest(post: post(), title: "", drop: drop, stereo: StereoSettings(), sway: true)
        return (m, drop)
    }

    private func show<V: View>(_ view: V, _ m: AppModel) -> (UIWindow, UIHostingController<AnyView>) {
        let host = UIHostingController(rootView: AnyView(view.frame(width: 402, height: 600).environment(m)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func close(_ w: UIWindow, _ h: UIHostingController<AnyView>) async {
        h.rootView = AnyView(EmptyView())
        h.view.layoutIfNeeded()
        await spin(0.2)
        w.isHidden = true
        w.rootViewController = nil
        await spin(0.1)
    }

    /// The stereo viewer whose eyes cannot be had (evicted, and the PDS now 500s): the toast, and
    /// back to the card — not a poster held forever.
    func testStereoViewerThatCannotLoadSaysSoAndCloses() async throws {
        let left = DropFixture.jpeg(.left, width: 320, height: 240), right = DropFixture.jpeg(.right, width: 320, height: 240)
        let rec = DropFixture.record(kind: "stereo", fields: ["left": DropFixture.blob(left, mime: "image/jpeg"),
                                                              "right": DropFixture.blob(right, mime: "image/jpeg")])
        let blobs = StubBlobSource { _ in .init(status: 500, body: Data("{}".utf8)) }
        let (m, drop) = try await open(rec, blobs: blobs)
        let (w, h) = show(DropViewerStereo(drop: drop, settings: StereoSettings()), m)
        await until(4, "the viewer closed") { m.dropViewer == nil }
        XCTAssertEqual(m.toast?.text, DropCopy.failed)
        XCTAssertGreaterThanOrEqual(blobs.requests.count, 1)
        await close(w, h)
    }

    /// A USDZ whose bytes match their CID but that SceneKit cannot read: the toast and the card,
    /// never an empty box — no scene is ever made, and only `usdz` was fetched (the GLB never).
    func testModelViewerWithAnUnreadableUsdzSaysSoAndCloses() async throws {
        let junk = Data("PK not a usdz at all".utf8) + Data(repeating: 0x42, count: 4000)
        let glb = Data(repeating: 0x67, count: 1000)
        let rec = DropFixture.record(kind: "model", fields: ["media": DropFixture.blob(glb, mime: "model/gltf-binary"),
                                                             "usdz": DropFixture.blob(junk, mime: "model/vnd.usdz+zip")], aspect: (1, 1))
        let blobs = StubBlobSource { _ in .init(body: junk) }
        let (m, drop) = try await open(rec, blobs: blobs)
        let (w, h) = show(DropViewerModel(drop: drop, spin: true), m)
        var peakScenes = 0
        let deadline = Date().addingTimeInterval(5)
        while m.dropViewer != nil, Date() < deadline {
            peakScenes = max(peakScenes, m.drops.liveModelScenes)
            await spin(0.01)
        }
        XCTAssertNil(m.dropViewer, "closed")
        XCTAssertEqual(m.toast?.text, DropCopy.failed)
        XCTAssertEqual(peakScenes, 0, "no scene view was ever made")
        XCTAssertEqual(blobs.requestedCids, [DropFixture.cid(junk)], "the usdz, and never the GLB")
        await close(w, h)
        XCTAssertEqual(m.drops.disk.pinnedCount, 0)
    }

    /// And a real USDZ: the scene, no toast, the viewer stays; closing tears it down.
    func testModelViewerShowsAReadableUsdz() async throws {
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).usdz")
        XCTAssertTrue(scene.write(to: url, options: nil, delegate: nil, progressHandler: nil))
        let usdz = try Data(contentsOf: url)
        let rec = DropFixture.record(kind: "model", fields: ["usdz": DropFixture.blob(usdz, mime: "model/vnd.usdz+zip")], aspect: (1, 1))
        let (m, drop) = try await open(rec, blobs: StubBlobSource { _ in .init(body: usdz) })
        let (w, h) = show(DropViewerModel(drop: drop, spin: true), m)
        await until(5, "the scene") { m.drops.liveModelScenes == 1 }
        XCTAssertNotNil(m.dropViewer)
        XCTAssertNil(m.toast)
        XCTAssertEqual(m.drops.disk.pinnedCount, 1, "the file is pinned while shown")
        await close(w, h)
        XCTAssertEqual(m.drops.liveModelScenes, 0)
        XCTAssertEqual(m.drops.disk.pinnedCount, 0)
    }
}

// MARK: - The renderers respond to input (rule 10)

@MainActor
final class DropRenderTests: XCTestCase {
    private func pixels(_ image: UIImage) -> (data: [UInt8], width: Int, height: Int) {
        let cg = image.cgImage!
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (data, w, h)
    }

    private func difference(_ a: UIImage, _ b: UIImage) -> Double {
        let pa = pixels(a), pb = pixels(b)
        XCTAssertEqual(pa.width, pb.width); XCTAssertEqual(pa.height, pb.height)
        var changed = 0
        for i in stride(from: 0, to: min(pa.data.count, pb.data.count), by: 4) where abs(Int(pa.data[i]) - Int(pb.data[i])) + abs(Int(pa.data[i + 1]) - Int(pb.data[i + 1])) + abs(Int(pa.data[i + 2]) - Int(pb.data[i + 2])) > 24 {
            changed += 1
        }
        return Double(changed) / Double(pa.width * pa.height)
    }

    private func render<V: View>(_ view: V, size: CGSize) -> UIImage {
        let r = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        r.scale = 1
        return r.uiImage!
    }

    /// A drag across the media moves the target; the ease carries the parallax there at the
    /// viewer's rate; and the picture — the shader on the GPU, and its CPU reference — changes.
    func testDragMovesTheDepthParallax() throws {
        let size = CGSize(width: 240, height: 180)
        let t0 = Date()
        let state = DepthMotionState(born: t0)
        let rest = state.frame(at: t0, sway: false)
        XCTAssertEqual(rest.cx, 0); XCTAssertEqual(rest.shift.x, 0)
        // A drag at the right edge, halfway down.
        let n = try XCTUnwrap(DropDepthSurface.normalised(CGPoint(x: size.width, y: size.height / 2), in: size))
        XCTAssertEqual(n.x, 1); XCTAssertEqual(n.y, 0)
        state.point(n.x, n.y, at: t0)
        var p = rest
        for i in 1...60 { p = state.frame(at: t0.addingTimeInterval(Double(i) / 60), sway: false) }
        // One second at 0.08 per frame: 1 − 0.92^60 ≈ 0.9934 of the way.
        XCTAssertEqual(p.cx, 1 - pow(0.92, 60), accuracy: 1e-9)
        XCTAssertEqual(p.shift.x, p.cx * DepthParallax.defaultAmp, accuracy: 1e-12)
        XCTAssertEqual(p.zoom, 1 - 1.2 * 0.04, accuracy: 1e-12)

        // The same second at 120 Hz lands in the same place (k = 1 − 0.92^(Δt·60)).
        let fast = DepthMotionState(born: t0)
        _ = fast.frame(at: t0, sway: false)
        fast.point(1, 0, at: t0)
        var q = rest
        for i in 1...120 { q = fast.frame(at: t0.addingTimeInterval(Double(i) / 120), sway: false) }
        XCTAssertEqual(q.cx, p.cx, accuracy: 1e-9)

        // On the GPU, at ONE amp — so one zoom — and the drag's eased position against rest: a
        // change of amp alone rescales the whole picture by its zoom and would move every edge
        // with no displacement at all, so it is held fixed and only the shift differs.
        let colour = DropFixture.scene(.colour, width: 480, height: 360)
        let map = DropStore.decode(path: try writeTemp(DropFixture.png(.depth, width: 480, height: 360)), maxPixelSize: 240, gray: true)!
        var still = rest
        still.amp = DepthParallax.ampRange.upperBound
        var strong = p
        strong.amp = still.amp
        XCTAssertEqual(still.zoom, strong.zoom, "the same zoom: nothing but the shift differs")
        let atRest = render(DepthLayer(image: colour, map: map, parallax: still), size: size)
        let moved = render(DepthLayer(image: colour, map: map, parallax: strong), size: size)
        let gpu = difference(atRest, moved)
        XCTAssertGreaterThan(gpu, 0.01, "the shader moved \(gpu * 100)% of the pixels")

        // The CPU reference: the near disc's edge moves, the far background does not.
        let depthAt: (Double, Double) -> Double = { u, v in
            for d in DropFixture.discs {
                let dx = (u - Double(d.x)) * 4, dy = (v - Double(d.y)) * 3
                if dx * dx + dy * dy <= Double(d.r * 4) * Double(d.r * 4) { return Double(d.depth) }
            }
            return 0
        }
        let far = DepthParallax.sample(v: (0.05, 0.05), shift: strong.shift, zoom: strong.zoom, depth: depthAt)
        let farRest = DepthParallax.sample(v: (0.05, 0.05), shift: still.shift, zoom: still.zoom, depth: depthAt)
        XCTAssertNotEqual(far.x, farRest.x, "background sits at depth 0, which is −0.5: it moves opposite the near")
        let near = DepthParallax.sample(v: (0.78, 0.6), shift: strong.shift, zoom: strong.zoom, depth: depthAt)
        let nearRest = DepthParallax.sample(v: (0.78, 0.6), shift: still.shift, zoom: still.zoom, depth: depthAt)
        XCTAssertLessThan((near.x - nearRest.x) * (far.x - farRest.x), 0, "near and far move opposite ways")
    }

    /// The Metal shader itself against its CPU reference, pixel by pixel (rule 10). The colour image
    /// is a gradient whose red channel IS the horizontal sample position and whose green is the
    /// vertical one, so each rendered pixel reads back where DropDepth.metal sampled —
    /// `uv + shift × (depth − 0.5)`. The box is 2:1 over a 4:3 image, so the map is read through a
    /// real cover-fit crop. Every render is at the same amp (the same zoom): what differs is the
    /// shift, so every change measured is the displacement term, read out of the map.
    func testDepthShaderDisplacesByTheMap() throws {
        let size = CGSize(width: 240, height: 120)
        let gradient = gradientImage(width: 480, height: 360)
        let map = DropStore.decode(path: try writeTemp(DropFixture.png(.depth, width: 480, height: 360)), maxPixelSize: 240, gray: true)!
        let texels = grayTexels(map)
        let crop = DepthLayer.coverCrop(image: gradient.size, box: size)
        XCTAssertEqual(crop.minY, 1.0 / 6, accuracy: 1e-9, "the map is read through a crop")
        XCTAssertEqual(crop.height, 2.0 / 3, accuracy: 1e-9)

        var rest = DepthParallax()
        rest.amp = DepthParallax.ampRange.upperBound
        var right = rest
        right.cx = 1
        var down = rest
        down.cy = 1
        let r0 = pixels(render(DepthLayer(image: gradient, map: map, parallax: rest), size: size))
        let rx = pixels(render(DepthLayer(image: gradient, map: map, parallax: right), size: size))
        let ry = pixels(render(DepthLayer(image: gradient, map: map, parallax: down), size: size))

        // The shader's sampler: normalised coordinates, clamp to edge, bilinear between texel
        // centres — here on the CPU over the same decoded map, through the same crop.
        let depth: (Double, Double) -> Double = { u, v in
            texels.bilinear(Double(crop.minX) + u * Double(crop.width), Double(crop.minY) + v * Double(crop.height))
        }
        var agree = 0
        var background: [Double] = [], near: [Double] = [], backgroundY: [Double] = []
        let w = Int(size.width), h = Int(size.height)
        for y in 0..<h {
            for x in 0..<w {
                let v = ((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h))
                let p0 = DepthParallax.sample(v: v, shift: rest.shift, zoom: rest.zoom, depth: depth)
                let px = DepthParallax.sample(v: v, shift: right.shift, zoom: right.zoom, depth: depth)
                let py = DepthParallax.sample(v: v, shift: down.shift, zoom: down.zoom, depth: depth)
                // Red is the layer's x (the crop is the full width); green is the image's y, of
                // which the layer shows the crop's height.
                let wantX = (px.x - p0.x) * 255
                let wantY = (py.y - p0.y) * Double(crop.height) * 255
                let i = (y * w + x) * 4
                let gotX = Double(Int(rx.data[i]) - Int(r0.data[i]))
                let gotY = Double(Int(ry.data[i + 1]) - Int(r0.data[i + 1]))
                if abs(gotX - wantX) <= 2.5, abs(gotY - wantY) <= 2.5 { agree += 1 }
                let uv = ((v.0 - 0.5) * rest.zoom + 0.5, (v.1 - 0.5) * rest.zoom + 0.5)
                let d = depth(uv.0, uv.1)
                if d < 0.01 { background.append(gotX); backgroundY.append(gotY) }
                if d > 0.89 { near.append(gotX) }
            }
        }
        let share = Double(agree) / Double(w * h)
        // What disagrees is the discs' one-texel rims, where two bilinear filters round apart.
        XCTAssertGreaterThan(share, 0.97, "\(share * 100)% of pixels sampled where the reference says")
        func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(max(a.count, 1)) }
        XCTAssertGreaterThan(background.count, 2000)
        XCTAssertGreaterThan(near.count, 300)
        // Depth 0 is d = −0.5: amp × −0.5 × 255 ≈ −15.3 levels. The near disc is 0.9 → d = +0.4 —
        // read as the byte WaveLoop's WebGL reads, not linearised (0.79 would give +8.8).
        XCTAssertEqual(mean(background), -0.12 * 0.5 * 255, accuracy: 1.5, "the far background moves left")
        XCTAssertEqual(mean(near), 0.12 * 0.4 * 255, accuracy: 1.5, "the near disc moves right, against the background")
        XCTAssertEqual(mean(backgroundY), -0.12 * 0.6 * 0.5 * (2.0 / 3) * 255, accuracy: 1.5, "cy moves by amp × 0.6")
    }

    /// A gray map's bytes, read the way the shader's sampler reads its texture.
    private struct GrayTexels {
        let data: [UInt8]
        let width: Int
        let height: Int

        func at(_ x: Int, _ y: Int) -> Double {
            Double(data[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]) / 255
        }

        func bilinear(_ u: Double, _ v: Double) -> Double {
            let sx = u * Double(width) - 0.5, sy = v * Double(height) - 0.5
            let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
            let fx = sx - Double(x0), fy = sy - Double(y0)
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    private func grayTexels(_ image: UIImage) -> GrayTexels {
        let cg = image.cgImage!
        var data = [UInt8](repeating: 0, count: cg.width * cg.height)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return GrayTexels(data: data, width: cg.width, height: cg.height)
    }

    /// Red = x and green = y across the image, one byte each, in sRGB with no colour management
    /// between the bytes and the render.
    private func gradientImage(width: Int, height: Int) -> UIImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((Double(x) + 0.5) / Double(width) * 255)
                bytes[i + 1] = UInt8((Double(y) + 0.5) / Double(height) * 255)
                bytes[i + 2] = 0
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }

    /// Rule 10's sway: after 1.8 s with no input the target is the Lissajous path; before, the input.
    func testSwayStartsAfterIdle() {
        let t0 = Date()
        let state = DepthMotionState(born: t0)
        _ = state.frame(at: t0, sway: true)
        state.point(-1, 0, at: t0)
        var p = DepthParallax()
        for i in 1...102 { p = state.frame(at: t0.addingTimeInterval(Double(i) / 60), sway: true) }   // 1.7 s
        XCTAssertLessThan(p.cx, -0.9, "still following the input")
        for i in 103...240 { p = state.frame(at: t0.addingTimeInterval(Double(i) / 60), sway: true) }  // 4 s
        let target = DepthParallax.sway(4)
        XCTAssertEqual(p.cx, target.x, accuracy: 0.25, "tracking the sway")
        // Sway off: rest.
        let still = DepthMotionState(born: t0)
        for i in 0...240 { p = still.frame(at: t0.addingTimeInterval(Double(i) / 60), sway: false) }
        XCTAssertEqual(p.cx, 0); XCTAssertEqual(p.cy, 0)
    }

    /// `Depth +` / `Depth −` and tilt: ×1.3 within 0.005…0.12, ±18° ↦ ±1.
    func testDepthControlsAndTilt() {
        var p = DepthParallax()
        p.stepAmp(up: true)
        XCTAssertEqual(p.amp, 0.052, accuracy: 1e-12)
        for _ in 0..<20 { p.stepAmp(up: true) }
        XCTAssertEqual(p.amp, 0.12)
        for _ in 0..<40 { p.stepAmp(up: false) }
        XCTAssertEqual(p.amp, 0.005)
        XCTAssertEqual(DepthParallax.tilt(9), 0.5)
        XCTAssertEqual(DepthParallax.tilt(-40), -1)
        let s = DepthMotionState()
        s.tilt(roll: 5, pitch: -3)
        XCTAssertEqual(s.input.x, 0, "the first reading is the reference")
        s.tilt(roll: 14, pitch: -3)
        XCTAssertEqual(s.input.x, 0.5, accuracy: 1e-12)
        let stamp = s.lastInput
        s.tilt(roll: 14.05, pitch: -3)
        XCTAssertEqual(s.lastInput, stamp, "hand tremor is not input")
    }

    /// Wiggle: one schedule entry per 110 ms, one eye flip per entry — two frames per wiggle period —
    /// and a paused schedule is a single entry, so nothing redraws off screen.
    func testWiggleScheduleFramesAndPause() {
        // Date keeps seconds since 2001 as a Double: about 1e-7 s of resolution today.
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let entries = Array(WiggleSchedule(start: start, paused: false).entries(from: start, mode: .normal).prefix(20))
        for (i, e) in entries.enumerated() {
            XCTAssertEqual(e.timeIntervalSince(start), Double(i) * 0.110, accuracy: 1e-6)
            XCTAssertEqual(StereoMath.eye(at: e.timeIntervalSince(start)), i % 2 == 0 ? .left : .right, "entry \(i)")
        }
        let inOnePeriod = entries.filter { $0.timeIntervalSince(start) < 2 * StereoMath.period - 1e-3 }.count
        XCTAssertEqual(inOnePeriod, 2, "left then right")
        XCTAssertEqual(Array(WiggleSchedule(start: start, paused: true).entries(from: start, mode: .normal).prefix(5)).count, 1)
        XCTAssertEqual(Array(WiggleSchedule(start: start, paused: false).entries(from: start, mode: .lowFrequency).prefix(5)).count, 1)
        // Joining mid-stream keeps the beat.
        let later = start.addingTimeInterval(0.5)
        let first = WiggleSchedule(start: start, paused: false).entries(from: later, mode: .normal).first { _ in true }!
        XCTAssertEqual(first.timeIntervalSince(start), 0.44, accuracy: 1e-6)
    }

    /// The shipped StereoCanvas in a window, its TimelineView on the display link, sampled every
    /// ~20 ms for 1.3 s with a red left eye and a blue right one: the eye on screen alternates at
    /// the 110 ms beat. Inactive, the same canvas holds the left eye and never changes.
    func testWiggleAlternatesOnScreenAndHoldsWhenPaused() async {
        let red = UIImage(color: .red), blue = UIImage(color: .blue)
        func sample(active: Bool) async -> [(t: Double, left: Bool)] {
            let view = StereoCanvas(left: red, right: blue, settings: StereoSettings(mode: .wiggle), active: active)
                .frame(width: 200, height: 100)
            let host = UIHostingController(rootView: view)
            // In the app's own window scene: a window with no scene is never on a screen, and a
            // TimelineView off every screen has no display link to tick it.
            let window = sceneWindow(CGRect(x: 0, y: 0, width: 200, height: 100))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            await spin(0.15)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            var out: [(Double, Bool)] = []
            let t0 = Date()
            while Date().timeIntervalSince(t0) < 1.3 {
                let frame = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                }
                let px = pixels(frame)
                let mid = ((px.height / 2) * px.width + px.width / 2) * 4
                out.append((Date().timeIntervalSince(t0), px.data[mid] > px.data[mid + 2]))
                await spin(0.02)
            }
            window.isHidden = true
            window.rootViewController = nil
            return out
        }

        let moving = await sample(active: true)
        var flips: [Double] = []
        for i in 1..<moving.count where moving[i].left != moving[i - 1].left { flips.append(moving[i].t) }
        XCTAssertTrue(moving.contains { $0.left } && moving.contains { !$0.left }, "both eyes shown")
        // 1.3 s at 110 ms is 11 flips; a 20 ms sample misses none, and may land a flip one sample late.
        XCTAssertGreaterThanOrEqual(flips.count, 9, "\(flips.count) flips in 1.3 s")
        XCTAssertLessThanOrEqual(flips.count, 13, "\(flips.count) flips in 1.3 s")
        let gaps = zip(flips.dropFirst(), flips).map { $0 - $1 }.sorted()
        if !gaps.isEmpty {
            let median = gaps[gaps.count / 2]
            XCTAssertEqual(median, StereoMath.period, accuracy: 0.03, "one eye per beat; median \(median) s")
        }

        let paused = await sample(active: false)
        XCTAssertGreaterThan(paused.count, 20)
        XCTAssertTrue(paused.allSatisfy { $0.left }, "a paused wiggle holds the left eye and never redraws the right")
    }

    /// A Mac card's click is the drag's own: a press that ends where it began opens the viewer; a
    /// drag past the slop only moves the parallax.
    func testAClickIsAPressThatDoesNotMove() {
        XCTAssertTrue(DropDepthSurface.isClick(.zero))
        XCTAssertTrue(DropDepthSurface.isClick(CGSize(width: 3, height: 2)))
        XCTAssertFalse(DropDepthSurface.isClick(CGSize(width: 5, height: 0)))
        XCTAssertFalse(DropDepthSurface.isClick(CGSize(width: 0, height: -40)))
    }

    /// Converging moves the rendered eyes; anaglyph is red from the left, cyan from the right;
    /// swap exchanges the side-by-side panes.
    func testStereoRendersRespondToControls() {
        let size = CGSize(width: 240, height: 120)
        let l = DropFixture.scene(.left, width: 480, height: 360), r = DropFixture.scene(.right, width: 480, height: 360)
        var s = StereoSettings(mode: .sideBySide, shift: 0, swap: false)
        let flat = render(StereoCanvas(left: l, right: r, settings: s, active: false), size: size)
        s.shift = StereoMath.converge(0, steps: 25)
        XCTAssertEqual(s.shift, 0.1, accuracy: 1e-12)
        let converged = render(StereoCanvas(left: l, right: r, settings: s, active: false), size: size)
        XCTAssertGreaterThan(difference(flat, converged), 0.01, "converging moved the eyes")
        XCTAssertEqual(StereoMath.converge(0.19, steps: 10), 0.2, "within ±0.2")
        XCTAssertEqual(StereoMath.offset(.left, shift: 0.1, width: 200), 10)
        XCTAssertEqual(StereoMath.offset(.right, shift: 0.1, width: 200), -10)
        s.shift = 0
        s.swap = true
        let swapped = render(StereoCanvas(left: l, right: r, settings: s, active: false), size: size)
        XCTAssertGreaterThan(difference(flat, swapped), 0.001, "swap exchanged the panes")

        let white = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { c in UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let anaglyph = render(StereoCanvas(left: white, right: white, settings: StereoSettings(mode: .anaglyph), active: false), size: size)
        let px = pixels(anaglyph)
        let mid = ((px.height / 2) * px.width + px.width / 2) * 4
        XCTAssertGreaterThan(px.data[mid], 240, "red from the left eye")
        XCTAssertGreaterThan(px.data[mid + 1], 240, "green from the right")
        XCTAssertGreaterThan(px.data[mid + 2], 240, "blue from the right")
        let leftOnly = render(StereoCanvas(left: white, right: UIImage(color: .black), settings: StereoSettings(mode: .anaglyph), active: false), size: size)
        let lp = pixels(leftOnly)
        XCTAssertGreaterThan(lp.data[mid], 240)
        XCTAssertLessThan(lp.data[mid + 1], 16, "no green without the right eye")
    }

    /// Rule 11: one model scene at a time, and its scene is released when the viewer closes.
    func testModelSceneIsCountedAndTornDown() async throws {
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.1)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).usdz")
        XCTAssertTrue(scene.write(to: url, options: nil, delegate: nil, progressHandler: nil), "SceneKit writes USDZ")
        let s = store(transport: pdsTransport(record: nil), blobs: StubBlobSource { _ in .init() })
        // Handed over inline, so nothing here holds the scene and its teardown is observable.
        let handoff = DropSceneHandoff(try XCTUnwrap(DropModelScene.load(url)))
        let host = UIHostingController(rootView: AnyView(DropModelScene(url: url, handoff: handoff, spinning: true, store: s)
            .frame(width: 300, height: 300)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        await spin(0.2)
        XCTAssertEqual(s.liveModelScenes, 1)
        let view = try XCTUnwrap(findSCNView(host.view))
        weak var loaded = view.scene
        XCTAssertNotNil(loaded)
        XCTAssertGreaterThan(loaded?.rootNode.childNodes.first?.childNodes.count ?? 0, 0, "the model sits under the turning pivot")
        XCTAssertNotNil(loaded?.rootNode.childNodes.first?.action(forKey: "spin"))
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        await spin(0.3)
        window.isHidden = true
        window.rootViewController = nil
        await spin(0.2)
        XCTAssertEqual(s.liveModelScenes, 0)
        XCTAssertNil(loaded, "the scene went with the viewer")
    }

    private func findSCNView(_ v: UIView) -> SCNView? {
        if let s = v as? SCNView { return s }
        for sub in v.subviews { if let s = findSCNView(sub) { return s } }
        return nil
    }

    private func writeTemp(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: url)
        return url.path
    }
}

private extension UIImage {
    convenience init(color: UIColor) {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { c in color.setFill(); c.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        self.init(cgImage: img.cgImage!)
    }
}
